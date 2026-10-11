#!/bin/sh
# Data-drive watchdog - runs every few minutes as root (systemd timer, see
# install-timer.sh).
#
# Normal mode: checks SRC_DATA. A read-only or unmounted (but present) drive
# only raises a Telegram alert, since that is a mount problem and not a dead
# disk. When the disk is gone or stops answering for FAIL_THRESHOLD checks in
# a row, it fails over: stops the apps, puts the backup drive in the data
# drive's place (bind-mounted at SRC_DATA) and starts the apps again, so
# everything keeps running from the last nightly mirror.
#
# Failover mode (STATE_DIR/failover.active exists): keeps the backup drive at
# SRC_DATA - also after a reboot, when ZimaOS mounts the drives back at their
# own paths - and tells you when the data drive is back so you can run
# failback.sh. zimaos/backup.sh refuses to run in this mode.
#
#   DRY_RUN=1 ./zimaos/failover-check.sh   # prints what it would do
set -u

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

[ "${FAILOVER_ENABLED:-no}" = yes ] || exit 0

for v in DATA_UUID MIRROR_UUID STATE_DIR SRC_DATA DST_MIRROR APPS; do
    eval "val=\${$v:-}"
    if [ -z "$val" ]; then
        echo "failover-check: $v is not set in $CONFIG" >&2
        exit 1
    fi
done
FAIL_THRESHOLD="${FAIL_THRESHOLD:-3}"

FLAG="$STATE_DIR/failover.active"
COUNT="$STATE_DIR/failover.count"
LAST="$STATE_DIR/failover.last-state"
RETURNED="$STATE_DIR/failover.data-returned"
# Not under LOG: that file lives on the data drive this script is watching.
FAILOVER_LOG="$STATE_DIR/failover.log"

mkdir -p "$STATE_DIR"

# One run at a time, and never while backup.sh holds the same lock (it is
# attaching/detaching the backup drive).
exec 9> "$STATE_DIR/lock"
flock -n 9 || exit 0

log() {
    [ "$DRY_RUN" = 1 ] && echo "$1"
    echo "$(date '+%F %T') $1" >> "$FAILOVER_LOG" 2> /dev/null || true
}

notify() {
    [ -x "$SCRIPT_DIR/../notify.sh" ] || return 0
    if [ "$DRY_RUN" = 1 ]; then
        echo "[dry-run] notify: $1"
        return 0
    fi
    "$SCRIPT_DIR/../notify.sh" "$1" > /dev/null 2>&1 || true
}

state_write() {
    [ "$DRY_RUN" = 1 ] && return 0
    echo "$1" > "$2"
}
state_rm() {
    [ "$DRY_RUN" = 1 ] && return 0
    rm -f "$1"
}

# docker prints the container name; its stderr is noise when a container is already stopped/started.
stop_apps() { for c in $APPS; do run docker stop "$c" 2> /dev/null || true; done; }
start_apps() { for c in $APPS; do run docker start "$c" 2> /dev/null || true; done; }

mirror_is_primary() {
    src=$(drive_mount_source "$SRC_DATA")
    [ -n "$src" ] && [ "$src" = "$(drive_dev_by_uuid "$MIRROR_UUID")" ]
}

# Puts the backup drive at SRC_DATA. Leaves the apps STOPPED on failure: with
# nothing mounted at SRC_DATA they would write into the system drive instead.
mount_mirror_as_data() {
    stop_apps
    drive_umount_all "$SRC_DATA" || log "WARN: could not unmount $SRC_DATA"
    if ! drive_attach "$MIRROR_UUID" "$DST_MIRROR"; then
        log "FAILOVER FAILED: backup drive did not come back - apps left stopped"
        notify "🚨 FAILOVER FAILED — $(hostname)

The backup drive did not come back; the apps are left stopped.
Check the drives and run the watchdog again: sudo systemctl start homelab-failover.service"
        return 1
    fi
    run mkdir -p "$SRC_DATA"
    if ! run mount --bind "$DST_MIRROR" "$SRC_DATA"; then
        log "FAILOVER FAILED: bind mount $DST_MIRROR -> $SRC_DATA failed - apps left stopped"
        notify "🚨 FAILOVER FAILED — $(hostname)

mount --bind $DST_MIRROR $SRC_DATA failed; the apps are left stopped."
        return 1
    fi
    start_apps
}

if [ -f "$FLAG" ]; then
    if ! mirror_is_primary; then
        log "failover active but $SRC_DATA is not the backup drive - re-establishing"
        mount_mirror_as_data || exit 1
        notify "⚠️ FAILOVER RE-ESTABLISHED — $(hostname)

$SRC_DATA was not the backup drive any more (reboot or the data drive came back).
Apps are running from $DST_MIRROR again."
    fi
    if drive_dev_by_uuid "$DATA_UUID" > /dev/null && [ ! -f "$RETURNED" ]; then
        state_write "$(date '+%F %T')" "$RETURNED"
        log "data drive is back - waiting for failback.sh"
        notify "ℹ️ DATA DRIVE IS BACK — $(hostname)

Apps still run from the backup drive. When ready:
sudo $SCRIPT_DIR/failback.sh"
    fi
    exit 0
fi

state=$(drive_health "$SRC_DATA" "$DATA_UUID")
prev=$(cat "$LAST" 2> /dev/null || echo OK)
state_write "$state" "$LAST"

case $state in
    OK)
        if [ "$prev" != OK ]; then
            log "data drive OK again (was $prev)"
            notify "✅ DATA DRIVE OK — $(hostname)

$SRC_DATA is back to normal (was $prev)."
        fi
        state_rm "$COUNT"
        ;;
    RO | UNMOUNTED)
        state_rm "$COUNT"
        if [ "$prev" != "$state" ]; then
            log "data drive $state"
            notify "⚠️ DATA DRIVE $state — $(hostname)

$SRC_DATA is $state. The disk is present, so this is a mount problem, not a failover:
sudo mount -o remount,rw $SRC_DATA   (or Unmount/Mount it in ZimaOS Storage)"
        fi
        ;;
    MISSING | IOERR)
        n=$(( $(cat "$COUNT" 2> /dev/null || echo 0) + 1 ))
        state_write "$n" "$COUNT"
        log "data drive $state ($n/$FAIL_THRESHOLD)"
        if [ "$n" -ge "$FAIL_THRESHOLD" ]; then
            log "=== FAILOVER: switching to the backup drive ==="
            notify "🚨 FAILOVER STARTED — $(hostname)

Data drive $state for $n checks. Stopping apps and switching to $DST_MIRROR..."
            mount_mirror_as_data || exit 1
            state_write "$(date '+%F %T') data drive $state" "$FLAG"
            state_rm "$COUNT"
            log "=== FAILOVER done ==="
            notify "✅ FAILOVER DONE — $(hostname)

Apps are running from the backup drive (bind-mounted at $SRC_DATA).
Anything written after the last nightly backup is lost. Nightly backups are paused.
Replace/repair the data drive, then run: sudo $SCRIPT_DIR/failback.sh"
        elif [ "$n" -eq 1 ]; then
            notify "⚠️ DATA DRIVE $state — $(hostname)

$SRC_DATA: $state. Failover after $FAIL_THRESHOLD consecutive checks."
        fi
        ;;
esac
