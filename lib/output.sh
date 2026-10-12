#!/usr/bin/env bash
# Console + log printing shared by the workstation scripts (backup.sh,
# restore.sh, mirror-to-external.sh, push-exif-fixes.sh). Every print_* line
# goes to stdout and, once initialize_logging (lib/logging.sh) has set
# LOG_FILE, to the log as well. Sourced by the entry scripts, never executed.
#
# Expects from the entry script: SCRIPT_TITLE, VERSION, MODE_LABEL, DRY_RUN
# and LOG_FILE.

# Prints a line to the console and to the log.
#   print_info "✅ Dependencies OK"
print_info() {
    echo "$@"

    if [[ -n "$LOG_FILE" ]]; then
        echo "$@" >>"$LOG_FILE"
    fi
}

########################################
# Prints a formatted field.
#
# Arguments:
#   $1 - Label
#   $2 - Value
########################################
#   print_field "Required:" "1.2G"
print_field() {
    printf "%-18s %s\n" "$1" "$2"

    if [[ -n "$LOG_FILE" ]]; then
        printf "%-18s %s\n" "$1" "$2" >>"$LOG_FILE"
    fi
}

########################################
# Prints a section header.
#
# Arguments:
#   $1 - Section title
########################################
#   print_section "Backing up Gallery"
print_section() {
    print_info
    print_info "========================================"
    print_info "$1"
    print_info "========================================"
    print_info
}

# Prints the console banner (not logged, the log gets write_log_header).
#   print_header
print_header() {
    echo
    echo "=========================================="
    echo "        $SCRIPT_TITLE v$VERSION"
    echo "=========================================="
    echo "Mode: $(run_mode_label)"
    echo
}

# Prints "Simulation" on a dry run, otherwise the script's MODE_LABEL
# (Backup, Restore, Mirror, Push).
#   print_field "Mode:" "$(run_mode_label)"
run_mode_label() {
    if [[ "$DRY_RUN" == true ]]; then
        echo "Simulation"
    else
        echo "$MODE_LABEL"
    fi
}

# Formats seconds as HH:MM:SS.
#   format_time 3725   # 01:02:05
format_time() {
    local seconds="$1"

    printf "%02d:%02d:%02d\n" \
        $((seconds / 3600)) \
        $(((seconds % 3600) / 60)) \
        $((seconds % 60))
}

# Prints the "Completed in:" field for a stage that started at $1 (epoch secs).
#   print_completed_in "$start_time"
print_completed_in() {
    local start_time="$1"
    local end_time
    end_time=$(date +%s)

    echo
    print_field "Completed in:" "$(format_time "$((end_time - start_time))")"
}
