#!/bin/sh
# Drive helpers shared by zimaos/backup.sh, failover-check.sh and failback.sh:
# attach/detach the USB backup drive and check the data drive's health.
#
# Everything that touches the system goes through SYSFS/DEVFS (so the tests
# can point them at a fake tree) and every mutating command goes through
# `run`/`sysfs_write`, which only print when DRY_RUN=1.
#
# Detaching works at the SCSI level: unmount, spin the disk down, delete the
# SCSI device and let the USB port autosuspend. The enclosure stays plugged
# in, but the OS no longer sees the disk, nothing can write to it and the
# platters stop. Attaching rescans the SCSI host the drive hung off (recorded
# in STATE_DIR at detach time) and waits for ZimaOS to auto-mount it.
SYSFS="${SYSFS:-/sys}"
DEVFS="${DEVFS:-/dev}"
DRY_RUN="${DRY_RUN:-0}"
ATTACH_TIMEOUT="${ATTACH_TIMEOUT:-90}" # seconds to wait for the disk to reappear
MOUNT_WAIT="${MOUNT_WAIT:-30}"         # seconds to give ZimaOS before mounting it ourselves
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-30}" # seconds before a stalled read/write counts as an I/O error
POLL="${POLL:-2}"                      # seconds between polls

run() {
    if [ "$DRY_RUN" = 1 ]; then
        echo "[dry-run] $*"
        return 0
    fi
    "$@"
}

# sysfs_write VALUE FILE
sysfs_write() {
    if [ "$DRY_RUN" = 1 ]; then
        echo "[dry-run] echo '$1' > $2"
        return 0
    fi
    echo "$1" >"$2"
}

# Resolved block device (/dev/sdX) of a filesystem UUID; fails when absent.
drive_dev_by_uuid() {
    [ -e "$DEVFS/disk/by-uuid/$1" ] && readlink -f "$DEVFS/disk/by-uuid/$1"
}

# sysfs directory of the USB device a block device (sdX) hangs off: the first
# ancestor with an idVendor attribute.
drive_usb_dir() {
    d=$(readlink -f "$SYSFS/block/$1/device") || return 1
    while [ -n "$d" ] && [ "$d" != / ]; do
        if [ -f "$d/idVendor" ]; then
            echo "$d"
            return 0
        fi
        d=$(dirname "$d")
    done
    return 1
}

# SCSI host (hostN) a block device (sdX) is attached to.
drive_scsi_host() {
    d=$(readlink -f "$SYSFS/block/$1/device") || return 1
    echo "$d" | tr / '\n' | grep -m1 '^host[0-9][0-9]*$'
}

drive_is_mounted() { findmnt -n "$1" >/dev/null 2>&1; }

drive_mount_opts() { findmnt -no OPTIONS "$1" 2>/dev/null | head -1; }

drive_is_rw() {
    case ",$(drive_mount_opts "$1")," in
        *,rw,*) return 0 ;;
    esac
    return 1
}

# Block device mounted at MOUNTPOINT ("/dev/sdX[/sub]" becomes "/dev/sdX").
drive_mount_source() { findmnt -no SOURCE "$1" 2>/dev/null | head -1 | sed 's/\[.*$//'; }

# Unmounts everything stacked at MOUNTPOINT (lazily, so a dead disk can't
# block it). Shared-subtree peers (/DATA/.media, /var/lib/casaos_data/.media)
# go away with it.
drive_umount_all() {
    while drive_is_mounted "$1"; do
        run umount -l "$1" || return 1
        [ "$DRY_RUN" = 1 ] && return 0
    done
    return 0
}

# Prints the state of the data drive: MISSING (no block device with UUID $2),
# UNMOUNTED, RO, IOERR (a read+write on $1 failed or stalled) or OK.
drive_health() {
    mnt=$1
    uuid=$2
    drive_dev_by_uuid "$uuid" >/dev/null || {
        echo MISSING
        return 0
    }
    drive_is_mounted "$mnt" || {
        echo UNMOUNTED
        return 0
    }
    drive_is_rw "$mnt" || {
        echo RO
        return 0
    }
    if drive_io_ok "$mnt"; then
        echo OK
    else
        echo IOERR
    fi
}

# drive_io_ok MOUNTPOINT — true when a listing plus a write+delete finish
# within HEALTH_TIMEOUT: a dying USB bridge stalls here instead of failing.
# shellcheck disable=SC2016 # $1 is expanded by the inner sh, on purpose
drive_io_ok() {
    timeout "$HEALTH_TIMEOUT" sh -c 'ls "$1" > /dev/null && echo ok > "$1/.homelab-health" && rm -f "$1/.homelab-health"' sh "$1" >/dev/null 2>&1
}

# drive_detach UUID — hide the drive from the OS (see the header). Records its
# USB device and SCSI host under STATE_DIR so drive_attach can find it again.
drive_detach() {
    dev=$(drive_dev_by_uuid "$1") || {
        echo "drive_detach: no device with UUID $1" >&2
        return 1
    }
    name=${dev##*/}
    usb=$(drive_usb_dir "$name" 2>/dev/null) || usb=
    host=$(drive_scsi_host "$name" 2>/dev/null) || host=

    drive_unmount_all "$dev" || return 1
    drive_record_location "$1" "$usb" "$host"
    drive_power_down "$dev" "$name" "$usb"
}

# drive_unmount_all DEV — sync, then unmount every mountpoint of the device.
drive_unmount_all() {
    run sync
    for t in $(findmnt -rno TARGET -S "$1" 2>/dev/null); do
        # A failed umount is only fatal if the target is really still mounted
        # (peers of a shared mount vanish together, so later ones "fail").
        run umount "$t" 2>/dev/null || ! drive_is_mounted "$t" || return 1
    done
}

# drive_record_location UUID USB_DIR SCSI_HOST — remembers where the drive
# hung off so drive_attach can rescan just that host (not on a dry run).
drive_record_location() {
    [ "$DRY_RUN" != 1 ] || return 0
    mkdir -p "$STATE_DIR"
    printf 'USB_DIR=%s\nSCSI_HOST=%s\n' "$2" "$3" >"$STATE_DIR/drive-$1"
}

# drive_power_down DEV NAME USB_DIR — spin the disk down, delete the SCSI
# device and let the USB port autosuspend.
drive_power_down() {
    # Best effort: not every USB bridge passes the ATA sleep command through.
    if command -v hdparm >/dev/null 2>&1; then
        run hdparm -Y "$1" 2>/dev/null || true
    fi
    sysfs_write 1 "$SYSFS/block/$2/device/delete"
    if [ -n "$3" ] && [ -w "$3/power/control" ]; then
        sysfs_write auto "$3/power/control"
    fi
}

# drive_attach UUID MOUNTPOINT — bring a detached drive back and make sure it
# is mounted at MOUNTPOINT. Rescans the recorded SCSI host (every host when
# nothing was recorded), waits ATTACH_TIMEOUT for the disk and MOUNT_WAIT for
# ZimaOS's auto-mount before mounting it itself.
drive_attach() {
    uuid=$1
    mnt=$2
    if ! drive_dev_by_uuid "$uuid" >/dev/null; then
        drive_rescan "$uuid"
        drive_wait_for_device "$uuid" || return 1
    fi
    drive_wait_for_mount "$uuid" "$mnt" || return 1
    [ "$DRY_RUN" = 1 ] || drive_is_mounted "$mnt"
}

# drive_rescan UUID — wake the recorded USB port and rescan the recorded SCSI
# host (every host when nothing was recorded) so the deleted disk reappears.
drive_rescan() {
    USB_DIR=
    SCSI_HOST=
    # shellcheck source=/dev/null
    [ -f "$STATE_DIR/drive-$1" ] && . "$STATE_DIR/drive-$1"
    if [ -n "$USB_DIR" ] && [ -w "$USB_DIR/power/control" ]; then
        sysfs_write on "$USB_DIR/power/control"
    fi
    if [ -n "$SCSI_HOST" ] && [ -e "$SYSFS/class/scsi_host/$SCSI_HOST/scan" ]; then
        sysfs_write "- - -" "$SYSFS/class/scsi_host/$SCSI_HOST/scan"
    else
        for s in "$SYSFS"/class/scsi_host/host*/scan; do
            [ -e "$s" ] && sysfs_write "- - -" "$s"
        done
    fi
    return 0
}

# drive_wait_for_device UUID — polls until the block device is back, giving
# up after ATTACH_TIMEOUT seconds.
drive_wait_for_device() {
    deadline=$(($(date +%s) + ATTACH_TIMEOUT))
    until drive_dev_by_uuid "$1" >/dev/null; do
        if [ "$(date +%s)" -ge "$deadline" ]; then
            echo "drive_attach: no device with UUID $1 appeared within ${ATTACH_TIMEOUT}s" >&2
            return 1
        fi
        sleep "$POLL"
    done
}

# drive_wait_for_mount UUID MOUNTPOINT — gives ZimaOS MOUNT_WAIT seconds to
# auto-mount the drive, then mounts it itself.
drive_wait_for_mount() {
    deadline=$(($(date +%s) + MOUNT_WAIT))
    until drive_is_mounted "$2"; do
        if [ "$(date +%s)" -ge "$deadline" ]; then
            run mkdir -p "$2"
            run mount "UUID=$1" "$2" || return 1
            break
        fi
        sleep "$POLL"
    done
}
