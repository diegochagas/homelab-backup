#!/usr/bin/env bash
# Argument handling shared by the workstation scripts: resolving a
# --folder/--target name against the configured list and the usage hint
# printed on a bad argument. Sourced, never executed.
#
# Expects from the entry script: SCRIPT_NAME (e.g. backup.sh), TARGET and
# the SELECTED array.

########################################
# Resolves the --folder argument into
# the list of folders to back up.
########################################
# select_targets NOUN CANDIDATE...: "all" selects every candidate, otherwise
# the one matching TARGET case-insensitively; anything else lists them and
# exits 1. NOUN is the word used in the messages ("folder", "target").
#   select_targets folder "${FOLDERS[@]}"
select_targets() {
    local noun="$1"
    shift

    if [[ "$TARGET" == "all" ]]; then
        SELECTED=("$@")
        return 0
    fi

    local candidate
    for candidate in "$@"; do
        if [[ "${candidate,,}" == "${TARGET,,}" ]]; then
            SELECTED=("$candidate")
            return 0
        fi
    done

    exit_unknown_target "$noun" "$@"
}

# Lists the valid names for an unknown --folder/--target value and exits 1.
#   exit_unknown_target folder "${FOLDERS[@]}"
exit_unknown_target() {
    local noun="$1"
    shift

    print_info "❌ Unknown $noun: $TARGET"
    print_info
    print_info "Available ${noun}s:"
    print_info "  all"

    local candidate
    for candidate in "$@"; do
        print_info "  $candidate"
    done

    exit 1
}

# Prints the "--help" hint after an unknown argument and exits 1.
#   *) print_info "❌ Unknown argument: $1"; exit_with_usage_hint ;;
exit_with_usage_hint() {
    echo
    echo "Run './$SCRIPT_NAME --help' for usage information."
    exit 1
}
