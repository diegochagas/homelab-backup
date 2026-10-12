#!/usr/bin/env bash
# Restoring one target of restore.sh: the local checks, the space check on
# the server and the rsync push itself. Sourced by restore.sh, never
# executed.
#
# Expects from restore.sh: LOCAL_BACKUP, REMOTE, REMOTE_ROOT, DELETE,
# DRY_RUN and the SUMMARY array.

########################################
# Verifies that the local source for a
# target exists and is not empty, so an
# empty/missing folder can never wipe
# out the remote copy with --delete.
#
# Arguments:
#   $1 - Local path (relative to LOCAL_BACKUP)
########################################
#   check_local_source "Backups/AppData"
check_local_source() {
    local full="$LOCAL_BACKUP/$1"

    if ! local_dir_has_files "$full"; then
        print_info "❌ Local source is missing or empty: $full"
        print_info "   Refusing to restore from it."
        exit 1
    fi
}

# Exits 1 when the local directory ($1) would not fit on the filesystem
# holding the remote path ($2).
#   check_restore_disk_space "$LOCAL_BACKUP/Gallery" "$REMOTE_ROOT"
check_restore_disk_space() {
    local local_path="$1"
    local remote_path="$2"

    print_info
    print_info "Checking available disk space on ZimaOS..."

    local required
    required=$(local_size_bytes "$local_path")

    require_free_space "$required" "$(remote_available_bytes "$remote_path")"
}

########################################
# Pushes a local directory to a remote
# path, showing overall transfer progress.
#
# Arguments:
#   $1 - Local source (relative to LOCAL_BACKUP)
#   $2 - Remote destination (absolute)
#   $3 - Label
########################################
#   push_path "Gallery" "$REMOTE_ROOT/Gallery" "Gallery" || return 1
push_path() {
    local local_rel="$1"
    local remote_path="$2"
    local label="$3"
    local source="$LOCAL_BACKUP/$local_rel"
    print_info "📂 $label"

    local size
    size=$(local_size_human "$source")
    print_field "   Size:" "$size"
    remote_mkdir "$remote_path"

    build_restore_rsync_options
    print_transfer_start "" "Restoring..."

    local rc=0
    run_rsync "$source/" "$REMOTE:$remote_path/" || rc=$?
    record_transfer_result "$label" "$size" "$rc" || return 1

    print_info
}

# rsync flags for a restore: --delete only with the --delete option, since
# by default a restore adds and updates files but never removes any.
#   build_restore_rsync_options
build_restore_rsync_options() {
    if [[ "$DELETE" == true ]]; then
        build_rsync_options --rsync-path="sudo /usr/bin/rsync" --delete
    else
        build_rsync_options --rsync-path="sudo /usr/bin/rsync"
    fi
}

########################################
# Restores a top-level backup folder to
# REMOTE_ROOT/<folder>.
#
# Arguments:
#   $1 - Folder name
########################################
#   restore_folder Gallery || exit 1
restore_folder() {
    local folder="$1"

    print_section "Restoring $folder -> $REMOTE_ROOT/$folder"

    check_local_source "$folder"
    check_restore_disk_space "$LOCAL_BACKUP/$folder" "$REMOTE_ROOT"

    local start_time
    start_time=$(date +%s)

    push_path "$folder" "$REMOTE_ROOT/$folder" "$folder" || return 1

    print_completed_in "$start_time"
}

# Restores one selected target: the synthetic "appdata" or a FOLDERS entry.
#   restore_target appdata || exit 1
restore_target() {
    local target="$1"

    if [[ "$target" == "appdata" ]]; then
        restore_appdata
    else
        restore_folder "$target"
    fi
}
