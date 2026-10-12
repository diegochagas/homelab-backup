#!/usr/bin/env bash
# The push stage of backup.sh: PUSH_SOURCE (this workstation's data)
# mirrored onto PUSH_TARGET, a drive on the ZimaOS server, after the pull.
# Sourced by backup.sh, never executed.
#
# Expects from backup.sh: PUSH_SOURCE, PUSH_TARGET, PUSH_EXCLUDES, REMOTE,
# DRY_RUN and the SUMMARY array.

# rsync --exclude flags and the matching du --exclude paths, filled by
# build_push_excludes.
declare -a PUSH_RSYNC_EXCLUDES=()
declare -a PUSH_DU_EXCLUDES=()

########################################
# Pushes PUSH_SOURCE (this workstation's
# data) onto PUSH_TARGET on the ZimaOS
# server after the pull - the reverse
# direction, so the workstation's data
# also has an off-machine copy. Skipped
# when PUSH_SOURCE is empty.
#
# Refuses to run unless PUSH_TARGET is a
# mounted drive on the server: with the
# disk gone, rsync would fill the ZimaOS
# system drive instead.
########################################
#   push_local_data || exit 1
push_local_data() {
    [[ -n "$PUSH_SOURCE" ]] || return 0

    local label="$PUSH_SOURCE → ZimaOS:$PUSH_TARGET"
    print_section "Pushing $PUSH_SOURCE to ZimaOS"
    local start_time
    start_time=$(date +%s)

    check_push_target "$label" || return 1
    build_push_excludes

    local required size
    required=$(push_source_size_bytes)
    size=$(numfmt --to=iec "$required")
    print_push_size "$size"
    check_push_space "$label" "$size" "$required" || return 1
    push_source "$label" "$size" || return 1

    print_completed_in "$start_time"
}

# Refuses the push when PUSH_TARGET is unset, PUSH_SOURCE is missing or the
# target is not a mounted drive on the server.
#   check_push_target "$label" || return 1
check_push_target() {
    local label="$1"

    if [[ -z "$PUSH_TARGET" ]]; then
        push_failed "$label" "-" "❌ PUSH_TARGET is not set in config.sh"
        return 1
    fi

    if [[ ! -d "$PUSH_SOURCE" ]]; then
        push_failed "$label" "-" "❌ Local folder not found: $PUSH_SOURCE"
        return 1
    fi

    if ! remote_is_mountpoint "$PUSH_TARGET"; then
        push_failed "$label" "-" "❌ $PUSH_TARGET is not a mounted drive on ZimaOS"
        return 1
    fi
}

# Prints why the push stopped and records it in SUMMARY as failed.
#   push_failed "$label" "-" "❌ PUSH_TARGET is not set in config.sh"
push_failed() {
    local label="$1"
    local size="$2"
    local message="$3"

    print_info "$message"
    SUMMARY+=("$label|$size|❌ Failed")
}

# Turns PUSH_EXCLUDES into PUSH_RSYNC_EXCLUDES / PUSH_DU_EXCLUDES.
#   build_push_excludes
build_push_excludes() {
    # ZimaOS keeps its mount record (.zimaos_storage.json) at the root of
    # every drive it manages; --delete must never remove it, nor lost+found.
    PUSH_RSYNC_EXCLUDES=(--exclude /.zimaos_storage.json --exclude /lost+found)
    PUSH_DU_EXCLUDES=()

    local item
    for item in "${PUSH_EXCLUDES[@]}"; do
        PUSH_RSYNC_EXCLUDES+=(--exclude "/$item")
        PUSH_DU_EXCLUDES+=(--exclude "$PUSH_SOURCE/$item")
    done
}

# Bytes of PUSH_SOURCE minus the excluded folders.
#   required=$(push_source_size_bytes)
push_source_size_bytes() {
    du -sb "${PUSH_DU_EXCLUDES[@]}" "$PUSH_SOURCE" 2>/dev/null | cut -f1
}

# Prints the size and, when configured, the excluded folders.
#   print_push_size "$size"
print_push_size() {
    print_field "   Size:" "$1"

    if [[ ${#PUSH_EXCLUDES[@]} -gt 0 ]]; then
        print_field "Excluded:" "${PUSH_EXCLUDES[*]}"
    fi
}

# Refuses the push when the data would not fit on PUSH_TARGET.
#   check_push_space "$label" "$size" "$required" || return 1
check_push_space() {
    local label="$1"
    local size="$2"
    local required="$3"

    # The drive is dedicated to this push, so what is already there will be
    # replaced: only the growth has to fit in the remaining space.
    local remote_used remote_avail
    read -r remote_used remote_avail < <(remote_used_and_available_bytes "$PUSH_TARGET")

    if ((required - remote_used > remote_avail)); then
        print_field "  Status:" "❌ Not enough space on $PUSH_TARGET ($(numfmt --to=iec "$remote_avail") free)"
        SUMMARY+=("$label|$size|❌ Failed")
        return 1
    fi
}

# Mirrors PUSH_SOURCE onto the server with rsync --delete and records the
# outcome (24, vanished files, counts as OK).
#   push_source "$label" "$size" || return 1
push_source() {
    local label="$1"
    local size="$2"

    build_rsync_options --delete --rsync-path="sudo /usr/bin/rsync"
    print_transfer_start "" "Synchronizing..."

    local rc=0
    run_rsync "${PUSH_RSYNC_EXCLUDES[@]}" "$PUSH_SOURCE/" "$REMOTE:$PUSH_TARGET/" || rc=$?

    record_transfer_result "$label" "$size" "$(ignore_vanished_source_files "$rc")"
}
