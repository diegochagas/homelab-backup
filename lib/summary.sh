#!/usr/bin/env bash
# End-of-run summary shared by backup.sh and restore.sh: one block per
# SUMMARY entry ("label|size|status"), then mode, path and elapsed time.
# Sourced, never executed.
#
# Expects from the entry script: the SUMMARY array, DRY_RUN and MODE_LABEL.

########################################
# Prints the backup summary.
########################################
# print_summary ELAPSED PATH_LABEL PATH: PATH_LABEL is "Destination:" for a
# backup and "Source:" for a restore.
#   print_summary "$elapsed" "Destination:" "$LOCAL_BACKUP"
print_summary() {
    local elapsed="$1"
    local path_label="$2"
    local path="$3"
    print_section "Summary"

    local item name size status
    for item in "${SUMMARY[@]}"; do
        IFS="|" read -r name size status <<<"$item"
        print_info "• $name"
        print_field "    Size:" "$size"
        print_field "    Status:" "$status"
        print_info
    done

    echo

    print_field "Mode:" "$(run_mode_label)"
    print_field "$path_label" "$path"
    print_field "Elapsed:" "$(format_time "$elapsed")"
}
