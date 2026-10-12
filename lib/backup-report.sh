#!/usr/bin/env bash
# What backup.sh reports when it ends: the Telegram messages for success
# and failure. Sourced by backup.sh, never executed.
#
# Expects from backup.sh: LOCAL_BACKUP, TARGET, DRY_RUN, LOG_FILE and the
# SUMMARY array.

########################################
# Builds the Telegram summary sent when
# the backup finishes.
#
# Arguments:
#   $1 - Elapsed seconds
########################################
#   notify "$(build_notification "$elapsed")"
build_notification() {
    local elapsed="$1"

    echo "✅ BACKUP FINISHED — $(hostname -s)"
    echo
    echo "ZimaOS → $LOCAL_BACKUP"
    echo

    local item name size status
    for item in "${SUMMARY[@]}"; do
        IFS="|" read -r name size status <<<"$item"
        echo "$status $name ($size)"
    done

    echo
    echo "Elapsed: $(format_time "$elapsed")"
}

# Telegram alert for an unexpected error; called by handle_error
# (lib/logging.sh). Silent on a dry run.
#   notify_failure "$exit_code" "$line" "$command"
notify_failure() {
    local exit_code="$1"
    local line="$2"
    local command="$3"

    [[ "$DRY_RUN" != true ]] || return 0

    notify "🚨 BACKUP FAILED — $(hostname -s)

Folder:    $TARGET
Exit code: $exit_code
Line:      $line
Command:   $command

Log: $(basename "$LOG_FILE")"
}

# Sends the success summary, unless this was a dry run.
#   notify_success "$elapsed"
notify_success() {
    [[ "$DRY_RUN" != true ]] || return 0

    notify "$(build_notification "$1")"
}
