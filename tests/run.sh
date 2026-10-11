#!/usr/bin/env bash
# Unit + scenario tests for zimaos/lib/drive.sh, failover-check.sh,
# failback.sh and backup.sh, run against a fake /sys, /dev and fake system
# commands (tests/fakes) in a temp dir - nothing on the real machine is
# touched and no Telegram message is sent.
#
#   tests/run.sh        # all
#   tests/run.sh attach # only tests whose name contains "attach"
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$REPO/tests/fakes:$PATH"
export TELEGRAM_ENV=/nonexistent/telegram.env # keep notify.sh silent
FILTER="${1:-}"
PASS=0
FAIL=0
FAILED=()

DATA_UUID=11111111-1111-1111-1111-111111111111
MIRROR_UUID=22222222-2222-2222-2222-222222222222

# --- fixtures -------------------------------------------------------------

setup() {
    T=$(mktemp -d)
    export SYSFS="$T/sys" DEVFS="$T/dev" STATE_DIR="$T/state"
    export FAKE_MOUNTS="$T/mounts" FAKE_CALLS="$T/calls"
    # ATTACH_TIMEOUT is in whole seconds, so tests where the disk comes back
    # asynchronously raise it: with 1s the deadline can be a few ms away.
    export DRY_RUN=0 POLL=0 ATTACH_TIMEOUT=1 MOUNT_WAIT=0 HEALTH_TIMEOUT=5
    : > "$FAKE_MOUNTS"
    : > "$FAKE_CALLS"
    DATA="$T/media/DATA4TB"
    MIRROR="$T/media/BACKUP4TB"
    mkdir -p "$DATA" "$MIRROR" "$T/DATA/AppData" "$T/DATA/Projects" "$STATE_DIR"
    mk_disk sdc "$DATA_UUID" 1-5 host1
    mk_disk sdd "$MIRROR_UUID" 2-3 host2
    mount_fake "$DATA" "$DEVFS/sdc" rw,noatime
    mount_fake "$MIRROR" "$DEVFS/sdd" rw,noatime
    write_config
}

teardown() { rm -rf "$T"; }

# mk_disk NAME UUID USBDIR HOST - fake block device with its sysfs ancestry
mk_disk() {
    local usb="$SYSFS/devices/pci0000:00/usb/$3"
    mkdir -p "$usb/$3:1.0/$4/target/lun" "$usb/power" "$SYSFS/block/$1" "$SYSFS/class/scsi_host/$4" "$DEVFS/disk/by-uuid"
    touch "$usb/idVendor"
    echo on > "$usb/power/control"
    ln -s "$usb/$3:1.0/$4/target/lun" "$SYSFS/block/$1/device"
    : > "$SYSFS/block/$1/device/delete"
    : > "$SYSFS/class/scsi_host/$4/scan"
    : > "$DEVFS/$1"
    ln -sf "../../$1" "$DEVFS/disk/by-uuid/$2"
}

unplug() { rm -f "$DEVFS/disk/by-uuid/$1"; }      # device vanishes (by UUID)
replug() { ln -sf "../../$2" "$DEVFS/disk/by-uuid/$1"; } # UUID NAME

mount_fake() { echo "$1 $2 $3" >> "$FAKE_MOUNTS"; }
unmount_fake() { grep -v "^$1 " "$FAKE_MOUNTS" > "$FAKE_MOUNTS.tmp"; mv "$FAKE_MOUNTS.tmp" "$FAKE_MOUNTS"; }

write_config() {
    export HOMELAB_CONFIG="$T/config.sh"
    cat > "$HOMELAB_CONFIG" <<EOF
LOG="$T/backup.log"
SRC_APPDATA="$T/DATA/AppData"
DST_APPDATA="$DATA/Backups/AppData"
SRC_PROJECTS="$T/DATA/Projects"
DST_PROJECTS="$DATA/Backups/Projects"
SRC_DATA="$DATA"
DST_MIRROR="$MIRROR"
MIRROR_EXCLUDE="nc-skeleton"
APPS="app1 app2"
DATA_UUID="$DATA_UUID"
MIRROR_UUID="$MIRROR_UUID"
STATE_DIR="$STATE_DIR"
MIRROR_DETACH="${CFG_DETACH:-yes}"
FAILOVER_ENABLED="${CFG_FAILOVER:-yes}"
FAIL_THRESHOLD="${CFG_THRESHOLD:-2}"
EOF
}

# --- assertions -----------------------------------------------------------

assert_eq() { [[ "$2" == "$1" ]] || fail "expected '$1', got '$2' ($3)"; }
assert_file() { [[ -e "$1" ]] || fail "expected file $1"; }
assert_no_file() { [[ ! -e "$1" ]] || fail "unexpected file $1"; }
assert_calls() { grep -qE "$1" "$FAKE_CALLS" || fail "expected call matching '$1'; calls were:
$(cat "$FAKE_CALLS")"; }
assert_no_calls() { ! grep -qE "$1" "$FAKE_CALLS" || fail "unexpected call matching '$1'; calls were:
$(cat "$FAKE_CALLS")"; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "expected output to contain '$2'; got:
$1"; }
assert_mounted() { grep -q "^$1 " "$FAKE_MOUNTS" || fail "expected $1 mounted; mounts:
$(cat "$FAKE_MOUNTS")"; }
assert_not_mounted() { ! grep -q "^$1 " "$FAKE_MOUNTS" || fail "expected $1 not mounted; mounts:
$(cat "$FAKE_MOUNTS")"; }
mount_source() { awk -v t="$1" '$1 == t { s = $2 } END { print s }' "$FAKE_MOUNTS"; }

fail() { CURRENT_FAILED=1; echo "    ✗ $1"; }

run_test() {
    local tname=$1
    [[ -z $FILTER || $tname == *"$FILTER"* ]] || return 0
    CURRENT_FAILED=0
    setup
    "$tname"
    teardown
    if [[ $CURRENT_FAILED == 0 ]]; then
        PASS=$((PASS + 1))
        echo "  ✓ $tname"
    else
        FAIL=$((FAIL + 1))
        FAILED+=("$tname")
    fi
}

lib() { . "$REPO/zimaos/lib/drive.sh"; }

# --- lib/drive.sh ---------------------------------------------------------

test_lib_resolves_usb_dir_and_scsi_host() {
    lib
    assert_eq "$SYSFS/devices/pci0000:00/usb/2-3" "$(drive_usb_dir sdd)" "usb dir"
    assert_eq host2 "$(drive_scsi_host sdd)" "scsi host"
    assert_eq "$DEVFS/sdd" "$(drive_dev_by_uuid "$MIRROR_UUID")" "dev by uuid"
    ! drive_dev_by_uuid nope || fail "unknown uuid should fail"
}

test_lib_detach_unmounts_records_spins_down_and_deletes() {
    lib
    mount_fake "$T/DATA/.media/BACKUP4TB" "$DEVFS/sdd" rw,noatime # shared-subtree peer
    drive_detach "$MIRROR_UUID" || fail "detach failed"
    assert_not_mounted "$MIRROR"
    assert_not_mounted "$T/DATA/.media/BACKUP4TB"
    assert_calls "^sync$"
    assert_calls "^hdparm -Y $DEVFS/sdd$"
    assert_eq 1 "$(cat "$SYSFS/block/sdd/device/delete")" "scsi delete"
    assert_eq auto "$(cat "$SYSFS/devices/pci0000:00/usb/2-3/power/control")" "usb autosuspend"
    assert_eq "USB_DIR=$SYSFS/devices/pci0000:00/usb/2-3
SCSI_HOST=host2" "$(cat "$STATE_DIR/drive-$MIRROR_UUID")" "state file"
}

test_lib_detach_dry_run_touches_nothing() {
    lib
    DRY_RUN=1
    out=$(drive_detach "$MIRROR_UUID")
    assert_contains "$out" "[dry-run] umount $MIRROR"
    assert_contains "$out" "[dry-run] echo '1' > $SYSFS/block/sdd/device/delete"
    assert_mounted "$MIRROR"
    assert_eq "" "$(cat "$SYSFS/block/sdd/device/delete")" "delete untouched"
    assert_eq on "$(cat "$SYSFS/devices/pci0000:00/usb/2-3/power/control")" "power untouched"
    assert_no_file "$STATE_DIR/drive-$MIRROR_UUID"
}

test_lib_attach_rescans_recorded_host_and_fails_when_disk_never_returns() {
    lib
    drive_detach "$MIRROR_UUID"
    unplug "$MIRROR_UUID"
    : > "$FAKE_CALLS"
    ! drive_attach "$MIRROR_UUID" "$MIRROR" 2> /dev/null || fail "attach should fail without a disk"
    assert_eq "- - -" "$(cat "$SYSFS/class/scsi_host/host2/scan")" "rescanned host2"
    assert_eq "" "$(cat "$SYSFS/class/scsi_host/host1/scan")" "host1 left alone"
    assert_eq on "$(cat "$SYSFS/devices/pci0000:00/usb/2-3/power/control")" "usb woken up"
}

test_lib_attach_rescans_every_host_without_state() {
    lib
    unplug "$MIRROR_UUID"
    ! drive_attach "$MIRROR_UUID" "$MIRROR" 2> /dev/null
    assert_eq "- - -" "$(cat "$SYSFS/class/scsi_host/host1/scan")" "host1"
    assert_eq "- - -" "$(cat "$SYSFS/class/scsi_host/host2/scan")" "host2"
}

test_lib_attach_mounts_itself_when_zimaos_does_not() {
    lib
    unmount_fake "$MIRROR"
    drive_attach "$MIRROR_UUID" "$MIRROR" || fail "attach failed"
    assert_calls "^mount UUID=$MIRROR_UUID $MIRROR$"
    assert_mounted "$MIRROR"
}

test_lib_attach_is_a_noop_when_already_mounted() {
    lib
    drive_attach "$MIRROR_UUID" "$MIRROR" || fail "attach failed"
    assert_eq "" "$(cat "$FAKE_CALLS")" "no calls"
}

test_lib_health_states() {
    lib
    assert_eq OK "$(drive_health "$DATA" "$DATA_UUID")" "ok"
    unmount_fake "$DATA"; mount_fake "$DATA" "$DEVFS/sdc" ro,noatime
    assert_eq RO "$(drive_health "$DATA" "$DATA_UUID")" "ro"
    unmount_fake "$DATA"
    assert_eq UNMOUNTED "$(drive_health "$DATA" "$DATA_UUID")" "unmounted"
    mount_fake "$T/gone" "$DEVFS/sdc" rw
    assert_eq IOERR "$(drive_health "$T/gone" "$DATA_UUID")" "ioerr (path unreadable)"
    unplug "$DATA_UUID"
    assert_eq MISSING "$(drive_health "$DATA" "$DATA_UUID")" "missing"
}

# --- failover-check.sh ----------------------------------------------------

check() { "$REPO/zimaos/failover-check.sh"; }

test_failover_requires_config() {
    HOMELAB_CONFIG=/nonexistent out=$(check 2>&1); rc=$?
    assert_eq 1 "$rc" "exit code"
    assert_contains "$out" "Missing /nonexistent"
    CFG_FAILOVER=yes write_config
    sed -i 's/^DATA_UUID=.*/DATA_UUID=""/' "$HOMELAB_CONFIG"
    out=$(check 2>&1); rc=$?
    assert_eq 1 "$rc" "exit code on empty DATA_UUID"
    assert_contains "$out" "DATA_UUID is not set"
}

test_failover_disabled_does_nothing() {
    CFG_FAILOVER=no write_config
    unplug "$DATA_UUID"
    check; assert_eq 0 $? "exit"
    assert_no_file "$STATE_DIR/failover.count"
    assert_eq "" "$(cat "$FAKE_CALLS")" "no calls"
}

test_failover_ro_or_unmounted_only_alerts() {
    unmount_fake "$DATA"; mount_fake "$DATA" "$DEVFS/sdc" ro,noatime
    check; check
    assert_eq RO "$(cat "$STATE_DIR/failover.last-state")" "state"
    assert_no_file "$STATE_DIR/failover.count"
    assert_no_file "$STATE_DIR/failover.active"
    assert_eq "" "$(cat "$FAKE_CALLS")" "no docker/mount calls"
}

test_failover_switches_after_threshold_and_stays() {
    unplug "$DATA_UUID"
    check
    assert_eq 1 "$(cat "$STATE_DIR/failover.count")" "count after 1st miss"
    assert_no_file "$STATE_DIR/failover.active"
    assert_eq "" "$(cat "$FAKE_CALLS")" "nothing done yet"

    check
    assert_file "$STATE_DIR/failover.active"
    assert_no_file "$STATE_DIR/failover.count"
    assert_calls "^docker stop app1$"
    assert_calls "^docker stop app2$"
    assert_calls "^umount -l $DATA$"
    assert_calls "^mount --bind $MIRROR $DATA$"
    assert_calls "^docker start app2$"
    assert_eq "$DEVFS/sdd" "$(mount_source "$DATA")" "mirror serves at SRC_DATA"
    # backup.sh must now refuse to run
    out=$("$REPO/zimaos/backup.sh" 2>&1); rc=$?
    assert_eq 1 "$rc" "backup.sh exit"
    assert_contains "$out" "Failover is active"

    : > "$FAKE_CALLS"
    check # steady state: nothing to do
    assert_eq "" "$(cat "$FAKE_CALLS")" "idempotent"
}

test_failover_attaches_detached_mirror_before_switching() {
    lib
    drive_detach "$MIRROR_UUID" # nightly backup left it offline
    unplug "$MIRROR_UUID"
    unplug "$DATA_UUID"
    : > "$FAKE_CALLS"
    # the disk "comes back" on rescan: fake it by replugging as soon as scan is written
    ( while [[ "$(cat "$SYSFS/class/scsi_host/host2/scan")" != "- - -" ]]; do sleep 0.05; done; replug "$MIRROR_UUID" sdd ) &
    CFG_THRESHOLD=1 write_config
    ATTACH_TIMEOUT=5 check; rc=$?
    wait
    assert_eq 0 "$rc" "exit"
    assert_calls "^mount UUID=$MIRROR_UUID $MIRROR$"
    assert_calls "^mount --bind $MIRROR $DATA$"
    assert_file "$STATE_DIR/failover.active"
}

test_failover_leaves_apps_stopped_when_mirror_missing() {
    unplug "$DATA_UUID"
    unplug "$MIRROR_UUID"
    CFG_THRESHOLD=1 write_config
    check 2> /dev/null; rc=$?
    assert_eq 1 "$rc" "exit"
    assert_calls "^docker stop app1$"
    assert_no_calls "^docker start"
    assert_no_calls "^mount --bind"
    assert_no_file "$STATE_DIR/failover.active"
}

test_failover_reestablishes_after_reboot_and_reports_data_back() {
    unplug "$DATA_UUID"
    CFG_THRESHOLD=1 write_config
    check
    # "reboot": ZimaOS mounted only the mirror at its own path
    : > "$FAKE_MOUNTS"; mount_fake "$MIRROR" "$DEVFS/sdd" rw,noatime
    : > "$FAKE_CALLS"
    check
    assert_calls "^mount --bind $MIRROR $DATA$"
    assert_calls "^docker start app1$"
    assert_no_file "$STATE_DIR/failover.data-returned"
    # the data drive is plugged back in
    replug "$DATA_UUID" sdc
    check
    assert_file "$STATE_DIR/failover.data-returned"
    assert_file "$STATE_DIR/failover.active" # still failed over until failback.sh
}

test_failover_dry_run_changes_nothing() {
    unplug "$DATA_UUID"
    CFG_THRESHOLD=1 write_config
    out=$(DRY_RUN=1 check)
    assert_contains "$out" "[dry-run] docker stop app1"
    assert_contains "$out" "[dry-run] mount --bind $MIRROR $DATA"
    assert_no_file "$STATE_DIR/failover.active"
    assert_no_file "$STATE_DIR/failover.count"
    assert_eq "" "$(cat "$FAKE_CALLS")" "no real calls"
}

# --- backup.sh ------------------------------------------------------------

test_backup_requires_config() {
    HOMELAB_CONFIG=/nonexistent out=$("$REPO/zimaos/backup.sh" 2>&1); rc=$?
    assert_eq 1 "$rc" "exit"
    assert_contains "$out" "Missing /nonexistent"
}

test_backup_aborts_on_read_only_data_drive() {
    unmount_fake "$DATA"; mount_fake "$DATA" "$DEVFS/sdc" ro,noatime
    "$REPO/zimaos/backup.sh" 2> /dev/null; rc=$?
    assert_eq 1 "$rc" "exit"
    assert_contains "$(cat "$T/backup.log")" "mounted read-only"
    assert_no_calls "^rsync"
}

test_backup_attaches_mirrors_and_detaches() {
    lib
    drive_detach "$MIRROR_UUID"
    unplug "$MIRROR_UUID"
    : > "$FAKE_CALLS"
    ( while [[ "$(cat "$SYSFS/class/scsi_host/host2/scan")" != "- - -" ]]; do sleep 0.05; done; replug "$MIRROR_UUID" sdd ) &
    ATTACH_TIMEOUT=5 "$REPO/zimaos/backup.sh"; rc=$?
    wait
    assert_eq 0 "$rc" "exit"
    assert_eq "mount UUID=$MIRROR_UUID $MIRROR
docker stop app1
docker stop app2
rsync -a --delete $T/DATA/AppData/ $DATA/Backups/AppData/
docker start app1
docker start app2
rsync -a --delete --exclude node_modules $T/DATA/Projects/ $DATA/Backups/Projects/
rsync -a --delete --exclude nc-skeleton $DATA/ $MIRROR/
sync
umount $MIRROR
hdparm -Y $DEVFS/sdd" "$(cat "$FAKE_CALLS")" "call sequence"
    assert_eq 1 "$(cat "$SYSFS/block/sdd/device/delete")" "mirror deleted"
    assert_contains "$(cat "$T/backup.log")" "=== Backup finished ==="
}

test_backup_detaches_mirror_even_when_rsync_fails() {
    FAKE_RSYNC_RC=23 "$REPO/zimaos/backup.sh"; rc=$?
    assert_eq 23 "$rc" "exit"
    assert_calls "^docker start app1$" # apps restarted by the exit trap
    assert_calls "^umount $MIRROR$"
    assert_eq 1 "$(cat "$SYSFS/block/sdd/device/delete")" "mirror deleted"
    assert_contains "$(cat "$T/backup.log")" "ABORT: exit code 23"
}

test_backup_keeps_mirror_attached_when_detach_is_off() {
    CFG_DETACH=no write_config
    "$REPO/zimaos/backup.sh" || fail "backup failed"
    assert_no_calls "^umount"
    assert_eq "" "$(cat "$SYSFS/block/sdd/device/delete")" "not deleted"
}

test_backup_without_uuids_behaves_like_before() {
    sed -i -e 's/^MIRROR_UUID=.*/MIRROR_UUID=""/' -e 's/^STATE_DIR=.*/STATE_DIR=""/' "$HOMELAB_CONFIG"
    "$REPO/zimaos/backup.sh" || fail "backup failed"
    assert_calls "^rsync -a --delete --exclude nc-skeleton $DATA/ $MIRROR/$"
    assert_no_calls "^umount"
    assert_no_calls "^hdparm"
}

# --- failback.sh ----------------------------------------------------------

failover_now() {
    unplug "$DATA_UUID"
    CFG_THRESHOLD=1 write_config
    check
    replug "$DATA_UUID" sdc
    : > "$FAKE_CALLS"
}

test_failback_refuses_without_failover_or_data_drive() {
    out=$("$REPO/zimaos/failback.sh" --yes 2>&1); rc=$?
    assert_eq 1 "$rc" "exit without failover"
    assert_contains "$out" "No failover is active"
    failover_now
    unplug "$DATA_UUID"
    out=$("$REPO/zimaos/failback.sh" --yes 2>&1); rc=$?
    assert_eq 1 "$rc" "exit without data drive"
    assert_contains "$out" "No drive with UUID $DATA_UUID"
    assert_file "$STATE_DIR/failover.active"
}

test_failback_dry_run_changes_nothing() {
    failover_now
    out=$("$REPO/zimaos/failback.sh" --dry-run); rc=$?
    assert_eq 0 "$rc" "exit"
    assert_contains "$out" "[dry-run] docker stop app1"
    assert_calls "^rsync -a --delete --dry-run"
    assert_no_calls "^docker"
    assert_file "$STATE_DIR/failover.active"
    assert_eq "$DEVFS/sdd" "$(mount_source "$DATA")" "still on the mirror"
}

test_failback_restores_and_detaches_mirror() {
    failover_now
    "$REPO/zimaos/failback.sh" --yes > /dev/null; rc=$?
    assert_eq 0 "$rc" "exit"
    assert_calls "^umount -l $DATA$"
    assert_calls "^mount UUID=$DATA_UUID $DATA$"
    assert_calls "^rsync -a --delete --info=progress2 $MIRROR/ $DATA/$"
    assert_calls "^docker start app1$"
    assert_calls "^hdparm -Y $DEVFS/sdd$"
    assert_eq "$DEVFS/sdc" "$(mount_source "$DATA")" "data drive back at SRC_DATA"
    assert_no_file "$STATE_DIR/failover.active"
    assert_no_file "$STATE_DIR/failover.data-returned"
}

test_failback_keeps_flag_and_apps_stopped_when_rsync_fails() {
    failover_now
    FAKE_RSYNC_RC=11 "$REPO/zimaos/failback.sh" --yes > /dev/null 2>&1; rc=$?
    assert_eq 11 "$rc" "exit"
    assert_file "$STATE_DIR/failover.active"
    assert_no_calls "^docker start"
}

test_failback_asks_for_typed_confirmation() {
    failover_now
    out=$(printf "no\n" | "$REPO/zimaos/failback.sh" 2>&1); rc=$?
    assert_eq 1 "$rc" "exit"
    assert_contains "$out" "Aborted"
    assert_file "$STATE_DIR/failover.active"
    assert_no_calls "^docker"
}

# --- run ------------------------------------------------------------------

echo "homelab-backup tests"
for t in $(declare -F | awk '{ print $3 }' | grep '^test_'); do
    run_test "$t"
done
echo
echo "$PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
    printf '  failed: %s\n' "${FAILED[@]}"
    exit 1
fi
