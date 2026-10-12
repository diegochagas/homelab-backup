#!/usr/bin/env bash
# The pull stage of backup.sh: one folder of REMOTE_ROOT mirrored into
# LOCAL_BACKUP with rsync --delete. Sourced by backup.sh, never executed.
#
# Expects from backup.sh: REMOTE, REMOTE_ROOT, LOCAL_BACKUP, DRY_RUN and
# the SUMMARY array.

########################################
# Synchronizes a folder from the remote
# server to the local backup, showing
# overall transfer progress.
#
# Arguments:
#   $1 - Folder name
########################################
#   sync_folder Gallery || return 1
sync_folder() {
    local folder="$1"
    local remote_path="$REMOTE_ROOT/$folder"
    local destination="$LOCAL_BACKUP/$folder"
    print_info "📂 $folder"

    local size
    size=$(remote_size_human "$remote_path")
    print_field "   Size:" "$size"
    mkdir -p "$destination"

    build_rsync_options --delete --rsync-path="sudo /usr/bin/rsync"
    print_transfer_start "" "Synchronizing..."

    local rc=0
    run_rsync "$REMOTE:$remote_path/" "$destination/" || rc=$?
    record_transfer_result "$folder" "$size" "$(ignore_vanished_source_files "$rc")" || return 1

    print_info
}

########################################
# Backs up a folder from the ZimaOS
# server.
#
# Arguments:
#   $1 - Folder name
########################################
#   backup_folder Gallery || exit 1
backup_folder() {
    local folder="$1"

    print_section "Backing up $folder"

    local start_time
    start_time=$(date +%s)

    sync_folder "$folder" || return 1

    print_completed_in "$start_time"
}
