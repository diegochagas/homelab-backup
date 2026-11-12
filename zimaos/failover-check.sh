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
# With AUTO_FAILBACK=yes it runs failback.sh itself once the data drive has
# been present for AUTO_FAILBACK_STABLE_CHECKS checks in a row. One attempt
# per failover: when it fails, the apps go back onto the backup drive and the
# rest is manual (the Telegram message says what failed).
#
# Containers: see lib/containers.sh for which ones are stopped, started again
# and reported when they stay down.
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
# shellcheck source=lib/containers.sh
. "$SCRIPT_DIR/lib/containers.sh"

[ "${FAILOVER_ENABLED:-no}" = yes ] || exit 0

for v in DATA_UUID MIRROR_UUID STATE_DIR SRC_DATA DST_MIRROR APPS; do
    eval "val=\${$v:-}"
    if [ -z "$val" ]; then
        echo "failover-check: $v is not set in $CONFIG" >&2
        exit 1
    fi
done
FAIL_THRESHOLD="${FAIL_THRESHOLD:-3}"
AUTO_FAILBACK="${AUTO_FAILBACK:-no}"
AUTO_FAILBACK_STABLE_CHECKS="${AUTO_FAILBACK_STABLE_CHECKS:-3}"
case $AUTO_FAILBACK_STABLE_CHECKS in
    '' | *[!0-9]* | 0)
        echo "failover-check: AUTO_FAILBACK_STABLE_CHECKS \"$AUTO_FAILBACK_STABLE_CHECKS\" must be a whole number of checks, 1 or more" >&2
        exit 1
        ;;
esac

FLAG="$STATE_DIR/failover.active"
COUNT="$STATE_DIR/failover.count"
LAST="$STATE_DIR/failover.last-state"
RETURNED="$STATE_DIR/failover.data-returned"
STABLE="$STATE_DIR/failover.data-stable"
TRIED="$STATE_DIR/failover.auto-failback-tried"
# Containers that ran at the last healthy check (see lib/containers.sh).
SNAPSHOT="$STATE_DIR/containers.running"
# Not under LOG: that file lives on the data drive this script is watching.
FAILOVER_LOG="$STATE_DIR/failover.log"

mkdir -p "$STATE_DIR"

# One run at a time, and never while backup.sh holds the same lock (it is
# attaching/detaching the backup drive).
exec 9>"$STATE_DIR/lock"
flock -n 9 || exit 0

log() {
    [ "$DRY_RUN" = 1 ] && echo "$1"
    echo "$(date '+%F %T') $1" >>"$FAILOVER_LOG" 2>/dev/null || true
}

notify() {
    [ -x "$SCRIPT_DIR/../notify.sh" ] || return 0
    if [ "$DRY_RUN" = 1 ]; then
        echo "[dry-run] notify: $1"
        return 0
    fi
    "$SCRIPT_DIR/../notify.sh" "$1" >/dev/null 2>&1 || true
}

state_write() {
    [ "$DRY_RUN" = 1 ] && return 0
    echo "$1" >"$2"
}
state_rm() {
    [ "$DRY_RUN" = 1 ] && return 0
    rm -f "$1"
}

# Starts the expected containers and sends one Telegram message naming the
# ones that stayed down.
#   start_and_verify_containers
start_and_verify_containers() {
    containers_start_expected "$SNAPSHOT"
    down=$(containers_verify "$SNAPSHOT")
    [ -n "$down" ] || return 0
    log "containers still down: $down"
    notify "🚨 CONTAINERS DOWN — $(hostname)

Did not come back after the drive switch: $down
Start them by hand: sudo docker start $down"
}

mirror_is_primary() {
    src=$(drive_mount_source "$SRC_DATA")
    [ -n "$src" ] && [ "$src" = "$(drive_dev_by_uuid "$MIRROR_UUID")" ]
}

# Puts the backup drive at SRC_DATA. Leaves the apps STOPPED on failure: with
# nothing mounted at SRC_DATA they would write into the system drive instead.
mount_mirror_as_data() {
    containers_stop_for_drive "$SRC_DATA"
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
    start_and_verify_containers
}

# Runs failback.sh once per failover and, when it fails, puts the apps back
# onto the backup drive. The lock this script holds is passed on (fd 9).
#   auto_failback
auto_failback() {
    if [ "$DRY_RUN" = 1 ]; then
        echo "[dry-run] $SCRIPT_DIR/failback.sh --yes"
        return 0
    fi
    state_write "$(date '+%F %T')" "$TRIED"
    log "=== automatic failback: data drive stable for $AUTO_FAILBACK_STABLE_CHECKS checks ==="
    FAILBACK_LOCK_HELD=1 "$SCRIPT_DIR/failback.sh" --yes >/dev/null 2>&1 && return 0
    log "automatic failback FAILED - back onto the backup drive, no second attempt"
    mirror_is_primary || mount_mirror_as_data || return 1
    notify "⚠️ AUTOMATIC FAILBACK GAVE UP — $(hostname)

$(grep 'failback: ABORT' "$FAILOVER_LOG" | tail -1)
Apps are running from $DST_MIRROR again. It will not try again by itself.
When the cause is fixed: sudo $SCRIPT_DIR/failback.sh"
}

# True while AUTO_FAILBACK=yes and this failover has not used its one attempt.
#   auto_failback_pending && echo "will fail back by itself"
auto_failback_pending() { [ "$AUTO_FAILBACK" = yes ] && [ ! -f "$TRIED" ]; }

# Failover mode: reports the data drive coming back (and going again) and,
# with AUTO_FAILBACK=yes, counts the checks it stays before failing back.
#   watch_returned_data_drive
watch_returned_data_drive() {
    if ! drive_dev_by_uuid "$DATA_UUID" >/dev/null; then
        [ -f "$RETURNED" ] && log "data drive gone again"
        state_rm "$RETURNED"
        state_rm "$STABLE"
        return 0
    fi
    [ -f "$RETURNED" ] || announce_returned_data_drive
    auto_failback_pending || return 0
    n=$(($(cat "$STABLE" 2>/dev/null || echo 0) + 1))
    state_write "$n" "$STABLE"
    log "data drive present ($n/$AUTO_FAILBACK_STABLE_CHECKS checks before the automatic failback)"
    [ "$n" -lt "$AUTO_FAILBACK_STABLE_CHECKS" ] || auto_failback
}

# One Telegram message per return of the data drive, saying what happens next.
#   announce_returned_data_drive
announce_returned_data_drive() {
    state_write "$(date '+%F %T')" "$RETURNED"
    next="When ready:
sudo $SCRIPT_DIR/failback.sh"
    if auto_failback_pending; then
        next="Automatic failback after $AUTO_FAILBACK_STABLE_CHECKS checks in a row with the drive present."
    fi
    log "data drive is back"
    notify "ℹ️ DATA DRIVE IS BACK — $(hostname)

Apps still run from the backup drive. $next"
}

if [ -f "$FLAG" ]; then
    if ! mirror_is_primary; then
        log "failover active but $SRC_DATA is not the backup drive - re-establishing"
        mount_mirror_as_data || exit 1
        notify "⚠️ FAILOVER RE-ESTABLISHED — $(hostname)

$SRC_DATA was not the backup drive any more (reboot or the data drive came back).
Apps are running from $DST_MIRROR again."
    fi
    watch_returned_data_drive || exit 1
    exit 0
fi

state=$(drive_health "$SRC_DATA" "$DATA_UUID")
prev=$(cat "$LAST" 2>/dev/null || echo OK)
state_write "$state" "$LAST"

case $state in
    OK)
        if [ "$prev" != OK ]; then
            log "data drive OK again (was $prev)"
            notify "✅ DATA DRIVE OK — $(hostname)

$SRC_DATA is back to normal (was $prev)."
        fi
        state_rm "$COUNT"
        containers_snapshot "$SNAPSHOT"
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
        n=$(($(cat "$COUNT" 2>/dev/null || echo 0) + 1))
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
Replace/repair the data drive, then run: sudo $SCRIPT_DIR/failback.sh
(AUTO_FAILBACK=$AUTO_FAILBACK: with yes it fails back by itself once the drive is back and stable.)"
        elif [ "$n" -eq 1 ]; then
            notify "⚠️ DATA DRIVE $state — $(hostname)

$SRC_DATA: $state. Failover after $FAIL_THRESHOLD consecutive checks."
        fi
        ;;
esac
