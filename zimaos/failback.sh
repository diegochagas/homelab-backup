#!/bin/sh
# Switch back from the backup drive to a repaired or new data drive after a
# failover. Manual, run as root on the ZimaOS box:
#
#   sudo ./zimaos/failback.sh --dry-run   # always first
#   sudo ./zimaos/failback.sh             # asks you to type "failback"
#   sudo ./zimaos/failback.sh --yes       # no question (scripts)
#
# A replacement disk must be formatted ext4 with the same label as before (so
# ZimaOS mounts it at SRC_DATA) and its UUID put in config.sh as DATA_UUID:
#   blkid -o value -s UUID /dev/sdX
#
# Steps: stop apps -> drop the bind mount -> mount the data drive at SRC_DATA
# -> rsync --delete DST_MIRROR onto it (hours) -> clear the failover flag ->
# start apps -> detach the backup drive again when MIRROR_DETACH=yes.
set -u

# shellcheck disable=SC1007
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CONFIG="${HOMELAB_CONFIG:-$SCRIPT_DIR/config.sh}"

YES=0
for arg in "$@"; do
    case $arg in
        --dry-run) DRY_RUN=1 ;;
        --yes) YES=1 ;;
        *) echo "Usage: $0 [--dry-run] [--yes]" >&2; exit 2 ;;
    esac
done
export DRY_RUN="${DRY_RUN:-0}"

if [ ! -f "$CONFIG" ]; then
    echo "Missing $CONFIG - copy config.sh.example and adjust it." >&2
    exit 1
fi
# shellcheck source=/dev/null
. "$CONFIG"
# shellcheck source=lib/drive.sh
. "$SCRIPT_DIR/lib/drive.sh"

for v in DATA_UUID MIRROR_UUID STATE_DIR SRC_DATA DST_MIRROR APPS; do
    eval "val=\${$v:-}"
    if [ -z "$val" ]; then
        echo "failback: $v is not set in $CONFIG" >&2
        exit 1
    fi
done

FLAG="$STATE_DIR/failover.active"
FAILOVER_LOG="$STATE_DIR/failover.log"

log() {
    echo "$1"
    echo "$(date '+%F %T') failback: $1" >> "$FAILOVER_LOG" 2> /dev/null || true
}
notify() {
    [ -x "$SCRIPT_DIR/../notify.sh" ] || return 0
    [ "$DRY_RUN" = 1 ] && { echo "[dry-run] notify: $1"; return 0; }
    "$SCRIPT_DIR/../notify.sh" "$1" > /dev/null 2>&1 || true
}
# docker prints the container name; its stderr is noise when a container is already stopped/started.
stop_apps() { for c in $APPS; do run docker stop "$c" 2> /dev/null || true; done; }
start_apps() { for c in $APPS; do run docker start "$c" 2> /dev/null || true; done; }

if [ ! -f "$FLAG" ]; then
    echo "No failover is active ($FLAG missing) - nothing to do." >&2
    exit 1
fi
data_dev=$(drive_dev_by_uuid "$DATA_UUID") || {
    echo "No drive with UUID $DATA_UUID is connected. New disk? Put its UUID in $CONFIG first." >&2
    exit 1
}
mirror_dev=$(drive_dev_by_uuid "$MIRROR_UUID") || {
    echo "The backup drive (UUID $MIRROR_UUID) is not connected." >&2
    exit 1
}

echo "Failover active since: $(cat "$FLAG")"
echo "Data drive:   $data_dev  -> will be mounted at $SRC_DATA and OVERWRITTEN with the mirror"
echo "Backup drive: $mirror_dev ($DST_MIRROR)"
echo "Apps stopped meanwhile: $APPS"
if [ "$DRY_RUN" != 1 ] && [ "$YES" != 1 ]; then
    printf 'Type "failback" to continue: '
    read -r answer
    [ "$answer" = failback ] || { echo "Aborted."; exit 1; }
fi

# Hold the same lock as backup.sh / failover-check.sh for the whole run.
mkdir -p "$STATE_DIR"
exec 9> "$STATE_DIR/lock"
flock -n 9 || { echo "Another backup/failover script is running - try again later." >&2; exit 1; }

START=$(date +%s)
log "=== Failback started ==="
notify "🔁 FAILBACK STARTED — $(hostname)

Copying $DST_MIRROR back onto the data drive. Apps are stopped until it finishes."

stop_apps

# Peel the bind mount (and whatever ZimaOS stacked there) off SRC_DATA until
# the data drive itself is the one mounted there.
while drive_is_mounted "$SRC_DATA" && [ "$(drive_mount_source "$SRC_DATA")" != "$data_dev" ]; do
    run umount -l "$SRC_DATA" || { log "ABORT: cannot unmount $SRC_DATA"; exit 1; }
    [ "$DRY_RUN" = 1 ] && break
done
if ! drive_is_mounted "$SRC_DATA"; then
    run mkdir -p "$SRC_DATA"
    run mount "UUID=$DATA_UUID" "$SRC_DATA" || { log "ABORT: cannot mount the data drive at $SRC_DATA"; exit 1; }
fi
if [ "$DRY_RUN" != 1 ] && ! drive_is_rw "$SRC_DATA"; then
    run mount -o remount,rw "$SRC_DATA" || { log "ABORT: $SRC_DATA is read-only"; exit 1; }
fi

if [ "$DRY_RUN" = 1 ]; then
    rsync -a --delete --dry-run --stats "$DST_MIRROR/" "$SRC_DATA/" | tail -15
else
    rsync -a --delete --info=progress2 "$DST_MIRROR/" "$SRC_DATA/" || {
        rc=$?
        if [ "$rc" -ne 24 ]; then
            log "ABORT: rsync exit code $rc - apps left stopped, failover flag kept"
            notify "🚨 FAILBACK FAILED — $(hostname)

rsync exited with code $rc. Apps are left stopped and the failover flag kept; fix and rerun failback.sh."
            exit "$rc"
        fi
    }
fi

if [ "$DRY_RUN" != 1 ]; then
    rm -f "$FLAG" "$STATE_DIR/failover.count" "$STATE_DIR/failover.last-state" "$STATE_DIR/failover.data-returned"
fi
start_apps

if [ "${MIRROR_DETACH:-no}" = yes ]; then
    drive_detach "$MIRROR_UUID" || log "WARN: could not detach the backup drive"
fi

secs=$(( $(date +%s) - START ))
log "=== Failback finished in $(printf '%02d:%02d:%02d' $((secs / 3600)) $(((secs % 3600) / 60)) $((secs % 60))) ==="
notify "✅ FAILBACK DONE — $(hostname)

Apps are running from the data drive again. Nightly backups resume."
