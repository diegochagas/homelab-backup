#!/bin/sh
# Puts the data drive back at its expected path when ZimaOS mounted it
# somewhere else.
#
# Why: after the 2026-11-18 ZimaOS update the drive came up at
# <SRC_DATA>_1 because an empty folder already sat at <SRC_DATA>; every app
# bound to <SRC_DATA> then saw an empty directory and exited, while the
# watchdog only reported UNMOUNTED. Needs `run`, `drive_*` from lib/drive.sh
# and `containers_*` from lib/containers.sh.

# drive_stray_targets DEV TARGET — mountpoints of DEV other than TARGET, one per line.
#   drive_stray_targets /dev/sdc /media/YOUR-DATA-DRIVE
drive_stray_targets() {
    findmnt -rno TARGET -S "$1" 2>/dev/null | grep -vx -- "$2"
    return 0
}

# drive_remount_at UUID TARGET — unmounts the drive from wherever ZimaOS put
# it and mounts it read-write at TARGET. Fails (touching nothing) when the
# drive is absent or not mounted anywhere else; never unmounts the drive from
# TARGET itself.
#   drive_remount_at "$DATA_UUID" "$SRC_DATA"
drive_remount_at() {
    dev=$(drive_dev_by_uuid "$1") || return 1
    strays=$(drive_stray_targets "$dev" "$2")
    [ -n "$strays" ] || return 1
    run sync
    for t in $strays; do
        drive_is_mounted "$t" || continue # peers vanish with the first unmount
        drive_umount_all "$t" || return 1
    done
    # The now-empty folders ZimaOS made for the stray mounts (rmdir refuses non-empty ones).
    for t in $strays; do run rmdir "$t" 2>/dev/null || true; done
    run mkdir -p "$2"
    run mount -o rw,noatime,nodiratime "$dev" "$2"
}
