#!/usr/bin/env bash
# rsync wrappers shared by the workstation scripts: one place builds the
# option list (archive, dry-run vs progress flags) and one function invokes
# rsync, so tests/fakes/rsync can stand in for it. Sourced, never executed.
#
# Expects from the entry script: DRY_RUN and the SUMMARY array.

declare -a RSYNC_OPTIONS=()

# Fills RSYNC_OPTIONS: the archive flags, the caller's extra flags, then
# `-n --stats` on a dry run or the overall-progress flag otherwise.
#   build_rsync_options --delete --rsync-path="sudo /usr/bin/rsync"
build_rsync_options() {
    RSYNC_OPTIONS=(-a --human-readable "$@")

    if [[ "$DRY_RUN" == true ]]; then
        RSYNC_OPTIONS+=(-n --stats)
        return 0
    fi

    # shellcheck disable=SC2054 # one rsync flag, the comma is part of it
    RSYNC_OPTIONS+=(--info=progress2,name0)
}

# Runs rsync with RSYNC_OPTIONS plus the given arguments (excludes, SRC/, DST/).
#   run_rsync "$REMOTE:$remote_path/" "$destination/"
run_rsync() {
    rsync "${RSYNC_OPTIONS[@]}" "$@"
}

# Prints the given lines unless this is a dry run (a simulation transfers
# nothing, so "Synchronizing..." would mislead).
#   print_transfer_start "" "Synchronizing..."
print_transfer_start() {
    [[ "$DRY_RUN" != true ]] || return 0

    local line
    for line in "$@"; do
        print_info "$line"
    done
}

# rsync exit 24 (source files vanished mid-transfer) is expected when
# pulling folders the server's apps are still writing to - treat it as OK.
#   rc=$(ignore_vanished_source_files "$rc")
ignore_vanished_source_files() {
    if [[ "$1" -eq 24 ]]; then
        echo 0
    else
        echo "$1"
    fi
}

# Prints the status field and records "label|size|status" in SUMMARY;
# returns 1 when the transfer failed so the caller can stop.
#   record_transfer_result "Gallery" "1.2G" "$rc" || return 1
record_transfer_result() {
    local label="$1"
    local size="$2"
    local rc="$3"

    if [[ "$rc" -eq 0 ]]; then
        print_field "  Status:" "✅ OK"
        SUMMARY+=("$label|$size|✅ OK")
        return 0
    fi

    print_field "  Status:" "❌ Failed"
    SUMMARY+=("$label|$size|❌ Failed")
    return 1
}
