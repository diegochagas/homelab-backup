#!/usr/bin/env bash
# Log file lifecycle and the ERR trap handler shared by the workstation
# scripts. Sourced by the entry scripts, never executed.
#
# Expects from the entry script: LOG_DIR (config.sh), LOG_PREFIX ("" for
# backup.sh, "restore_", "mirror_", ...), SCRIPT_TITLE, VERSION, MODE_LABEL,
# DRY_RUN and LOG_FILE. backup.sh additionally defines notify_failure, which
# handle_error calls when present.

########################################
# Initializes the log file.
########################################
#   initialize_logging   # LOG_FILE=$LOG_DIR/<prefix>2026-01-31_04-00-00.log
initialize_logging() {
    mkdir -p "$LOG_DIR"

    LOG_FILE="$LOG_DIR/${LOG_PREFIX}$(date +%Y-%m-%d_%H-%M-%S).log"

    : >"$LOG_FILE"
}

########################################
# Writes the log header.
########################################
# The extra arguments are the script-specific lines printed after "Mode:".
#   write_log_header "Folder:      $TARGET" "Destination: $LOCAL_BACKUP"
write_log_header() {
    {
        echo "========================================"
        echo "$SCRIPT_TITLE v$VERSION"
        echo "========================================"
        echo

        echo "Date:        $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Host:        $(hostname)"
        echo "Mode:        $(run_mode_label)"
        printf '%s\n' "$@"

        echo
        echo "========================================"
        echo
    } >>"$LOG_FILE"
}

# Writes the SUCCESS footer with the elapsed time.
#   write_log_footer "$elapsed"
write_log_footer() {
    local elapsed="$1"

    {
        echo
        echo "========================================"
        echo "Finished"
        echo "========================================"
        echo

        echo "Status:      SUCCESS"
        echo "Elapsed:     $(format_time "$elapsed")"
        echo
    } >>"$LOG_FILE"
}

########################################
# Handles unexpected errors.
#
# Arguments:
#   $1 - Exit code
#   $2 - Line number
#   $3 - Command
#   $4 - File the command is in
########################################
# Installed by every entry script:
#   trap 'handle_error $? $LINENO "$BASH_COMMAND" "${BASH_SOURCE[0]}"' ERR
handle_error() {
    local exit_code="$1"
    local line="$2"
    local command="$3"
    local file="$4"

    print_info
    print_info "❌ $MODE_LABEL failed!"
    print_info

    print_field "Exit code:" "$exit_code"
    print_field "Line:" "$line"
    print_field "File:" "$(basename "$file")"
    print_field "Command:" "$command"

    print_log_location
    notify_failure_if_defined "$exit_code" "$line" "$command"

    exit "$exit_code"
}

# Points at the log, unless the error happened before initialize_logging
# (argument parsing, config loading).
#   print_log_location
print_log_location() {
    [[ -n "$LOG_FILE" ]] || return 0

    print_info
    print_info "See log:"
    print_info "  $LOG_FILE"
}

# Calls notify_failure (defined by backup.sh only) with the error details.
#   notify_failure_if_defined "$exit_code" "$line" "$command"
notify_failure_if_defined() {
    declare -F notify_failure >/dev/null || return 0

    notify_failure "$@"
}
