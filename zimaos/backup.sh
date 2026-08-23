#!/bin/sh
# Daily ZimaOS server-side backup - v2 (config-driven)
#
# Runs locally on the ZimaOS box:
#   1. Stops the app containers, mirrors SRC_APPDATA onto the external
#      drive (DST_APPDATA), restarts the containers.
#   2. Mirrors SRC_PROJECTS onto the external drive (DST_PROJECTS).
#   3. Mirrors the whole external drive (SRC_DATA) onto the second
#      drive (DST_MIRROR).
#
# This is stage 1 of the backup chain; homelab-backup/backup.sh (stage 2,
# runs on Linux Mint) then pulls SRC_DATA's folders over SSH.
set -eu

# shellcheck disable=SC1007
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

if [ ! -f "$SCRIPT_DIR/config.sh" ]; then
    echo "Missing $SCRIPT_DIR/config.sh - copy config.sh.example and adjust it." >&2
    exit 1
fi
# shellcheck source=/dev/null
. "$SCRIPT_DIR/config.sh"

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

START=$(date +%s)
APPS_STOPPED=0

restart_apps() { for c in $APPS; do docker start "$c" >> "$LOG" 2>&1 || true; done; APPS_STOPPED=0; }

# Runs on every exit: restarts apps if we died while they were stopped and
# reports failures, so a crashed backup never goes unnoticed.
on_exit() {
    rc=$?
    [ "$APPS_STOPPED" = 1 ] && restart_apps
    if [ "$rc" -ne 0 ]; then
        log "ABORT: exit code $rc"
        notify "🚨 BACKUP FAILED — $(hostname)

ZimaOS server-side backup exited with code $rc after $(elapsed).
See $LOG"
    fi
}
trap on_exit EXIT

for p in "$SRC_APPDATA" "$SRC_PROJECTS" "$SRC_DATA" "$DST_MIRROR"; do
  [ -d "$p" ] || { log "ABORT: $p missing - drive not mounted?"; exit 1; }
done
mountpoint -q "$SRC_DATA"   || { log "ABORT: $SRC_DATA not a mountpoint"; exit 1; }
mountpoint -q "$DST_MIRROR" || { log "ABORT: $DST_MIRROR not a mountpoint"; exit 1; }

mkdir -p "$DST_APPDATA"
log "=== Backup started ==="

APPS_STOPPED=1
for c in $APPS; do docker stop "$c" >> "$LOG" 2>&1 || true; done

rsync -a --delete "$SRC_APPDATA/" "$DST_APPDATA/" >> "$LOG" 2>&1
restart_apps

mkdir -p "$DST_PROJECTS"
rsync -a --delete --exclude 'node_modules' "$SRC_PROJECTS/" "$DST_PROJECTS/" >> "$LOG" 2>&1

rsync -a --delete --exclude "$MIRROR_EXCLUDE" "$SRC_DATA/" "$DST_MIRROR/" >> "$LOG" 2>&1

log "=== Backup finished ==="

notify "✅ BACKUP FINISHED — $(hostname)

AppData + Projects → $SRC_DATA
$SRC_DATA → $DST_MIRROR

Elapsed: $(elapsed)"
