#!/bin/sh
# Daily ZimaOS server-side backup - v2 (config-driven)
#
# Runs locally on the ZimaOS box:
#   1. Stops the app containers, mirrors SRC_APPDATA onto the external
#      drive (DST_APPDATA), restarts the containers.
#   2. Mirrors SRC_PROJECTS onto the external drive (DST_PROJECTS).
#   3. Mirrors the whole external drive (SRC_DATA) onto the second
#      drive (DST_MIRROR). With MIRROR_UUID set the second drive is
#      re-attached first and, when MIRROR_DETACH=yes, detached again
#      afterwards (unmounted, spun down, removed from the OS) so it is
#      only ever online during the backup. See lib/drive.sh.
#
# Refuses to run while a failover is active (failover-check.sh switched
# the apps onto DST_MIRROR): mirroring would then go the wrong way.
#
# This is stage 1 of the backup chain; homelab-backup/backup.sh (stage 2,
# runs on Linux Mint) then pulls SRC_DATA's folders over SSH.
set -eu

# shellcheck disable=SC1007
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

CONFIG="${HOMELAB_CONFIG:-$SCRIPT_DIR/config.sh}"
if [ ! -f "$CONFIG" ]; then
    echo "Missing $CONFIG - copy config.sh.example and adjust it." >&2
    exit 1
fi
# shellcheck source=/dev/null
. "$CONFIG"
# shellcheck source=lib/drive.sh
. "$SCRIPT_DIR/lib/drive.sh"

MIRROR_UUID="${MIRROR_UUID:-}"
MIRROR_DETACH="${MIRROR_DETACH:-no}"
STATE_DIR="${STATE_DIR:-}"

if [ -n "$STATE_DIR" ]; then
    if [ -f "$STATE_DIR/failover.active" ]; then
        echo "Failover is active ($STATE_DIR/failover.active) - apps run from $DST_MIRROR; run failback.sh first." >&2
        exit 1
    fi
    mkdir -p "$STATE_DIR"
    # Same lock as failover-check.sh / failback.sh.
    exec 9> "$STATE_DIR/lock"
    flock -n 9 || { echo "Another backup/failover script is running." >&2; exit 1; }
fi

mkdir -p "$(dirname "$LOG")"

log() { echo "$(date '+%F %T') $1" >> "$LOG"; }

# Telegram notification via notify.sh at the repo root (no-op when unconfigured).
notify() {
    [ -x "$SCRIPT_DIR/../notify.sh" ] || return 0
    "$SCRIPT_DIR/../notify.sh" "$1" >/dev/null 2>&1 || true
}

elapsed() {
    secs=$(( $(date +%s) - START ))
    printf '%02d:%02d:%02d' $((secs/3600)) $(((secs%3600)/60)) $((secs%60))
}

# rsync exit 24 means source files vanished mid-transfer - expected when
# mirroring data that running apps are still writing (e.g. Nextcloud's
# SQLite -wal/-shm files); anything else stays fatal.
mirror() {
    rsync "$@" >> "$LOG" 2>&1 && return 0
    rc=$?
    [ "$rc" -eq 24 ] || return "$rc"
    log "WARN: some source files vanished during rsync (code 24) - continuing"
}

START=$(date +%s)
APPS_STOPPED=0
MIRROR_ATTACHED=0

restart_apps() { for c in $APPS; do docker start "$c" >> "$LOG" 2>&1 || true; done; APPS_STOPPED=0; }

# Puts the backup drive offline again (only when we brought it online).
detach_mirror() {
    [ "$MIRROR_ATTACHED" = 1 ] && [ "$MIRROR_DETACH" = yes ] || return 0
    MIRROR_ATTACHED=0
    if drive_detach "$MIRROR_UUID" >> "$LOG" 2>&1; then
        log "detached $DST_MIRROR"
    else
        log "WARN: could not detach $DST_MIRROR"
    fi
}

# Runs on every exit: restarts apps if we died while they were stopped,
# takes the backup drive offline and reports failures, so a crashed backup
# never goes unnoticed.
on_exit() {
    rc=$?
    [ "$APPS_STOPPED" = 1 ] && restart_apps
    detach_mirror
    if [ "$rc" -ne 0 ]; then
        log "ABORT: exit code $rc"
        notify "🚨 BACKUP FAILED — $(hostname)

ZimaOS server-side backup exited with code $rc after $(elapsed).
See $LOG"
    fi
}
trap on_exit EXIT

for p in "$SRC_APPDATA" "$SRC_PROJECTS" "$SRC_DATA"; do
  [ -d "$p" ] || { log "ABORT: $p missing - drive not mounted?"; exit 1; }
done
mountpoint -q "$SRC_DATA" || { log "ABORT: $SRC_DATA not a mountpoint"; exit 1; }
drive_is_rw "$SRC_DATA"   || { log "ABORT: $SRC_DATA is mounted read-only"; exit 1; }

log "=== Backup started ==="

if [ -n "$MIRROR_UUID" ]; then
    MIRROR_ATTACHED=1
    if drive_attach "$MIRROR_UUID" "$DST_MIRROR" >> "$LOG" 2>&1; then
        log "attached $DST_MIRROR"
    else
        log "ABORT: could not attach $DST_MIRROR (UUID $MIRROR_UUID)"
        exit 1
    fi
fi
[ -d "$DST_MIRROR" ]        || { log "ABORT: $DST_MIRROR missing - drive not mounted?"; exit 1; }
mountpoint -q "$DST_MIRROR" || { log "ABORT: $DST_MIRROR not a mountpoint"; exit 1; }

mkdir -p "$DST_APPDATA"

APPS_STOPPED=1
for c in $APPS; do docker stop "$c" >> "$LOG" 2>&1 || true; done

mirror -a --delete "$SRC_APPDATA/" "$DST_APPDATA/"
restart_apps

mkdir -p "$DST_PROJECTS"
mirror -a --delete --exclude 'node_modules' "$SRC_PROJECTS/" "$DST_PROJECTS/"

mirror -a --delete --exclude "$MIRROR_EXCLUDE" "$SRC_DATA/" "$DST_MIRROR/"
detach_mirror

log "=== Backup finished ==="

notify "✅ BACKUP FINISHED — $(hostname)

AppData + Projects → $SRC_DATA
$SRC_DATA → $DST_MIRROR

Elapsed: $(elapsed)"
