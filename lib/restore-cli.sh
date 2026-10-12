#!/usr/bin/env bash
# Command line of restore.sh: help text, argument parsing and the typed
# confirmation. Sourced by restore.sh, never executed.
#
# Expects from restore.sh: VERSION, TARGET, DRY_RUN, DELETE, ASSUME_YES,
# SELECTED, REMOTE and FOLDERS / REMOTE_APPDATA (config.sh).

# clean-code-audit: allow-long -- heredoc help text, no logic
print_help() {
    cat <<EOF
Homelab Restore v$VERSION

Pushes the local backup (created by backup.sh) back to the
ZimaOS server, restoring each folder to its respective remote
location. Use this after a drive failure or a fresh ZimaOS
install to bring the server back to its last backed-up state.

Usage:
    ./restore.sh [options]

Options:
    --target <name>      Restore only one target.
    --delete              Remove remote files that no longer exist
                           locally (exact mirror restore). Off by
                           default: restore only adds/updates files.
    --yes                 Skip the interactive confirmation prompt.
    --dry-run             Simulate the restore.
    --help                 Show help.
    --version              Show version.

Available targets:
    all
    appdata      -> $REMOTE_APPDATA (live app data, containers stopped/restarted)
$(printf '    %s\n' "${FOLDERS[@]}")

Examples:
    ./restore.sh --dry-run

    ./restore.sh --target appdata

$(printf '    ./restore.sh --target %s\n\n' "${FOLDERS[@]}")
EOF
}

# Parses the command line into TARGET, DELETE, ASSUME_YES and DRY_RUN.
#   parse_arguments "$@"
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --target) TARGET="$2" && shift 2 ;;
            --delete) DELETE=true && shift ;;
            --yes) ASSUME_YES=true && shift ;;
            --dry-run) DRY_RUN=true && shift ;;
            --help) print_help && exit 0 ;;
            --version) print_version && exit 0 ;;
            *)
                print_info "❌ Unknown argument: $1"
                exit_with_usage_hint
                ;;
        esac
    done
}

########################################
# Shows what is about to happen and
# requires a typed confirmation before
# any remote data gets overwritten.
########################################
#   confirm_restore
confirm_restore() {
    if [[ "$DRY_RUN" == true ]] || [[ "$ASSUME_YES" == true ]]; then
        return
    fi

    print_info "⚠️  This will push local data to $REMOTE, overwriting files there."
    if [[ "$DELETE" == true ]]; then
        print_info "⚠️  --delete is set: remote files with no local counterpart will be REMOVED."
    fi
    print_info "   Targets: ${SELECTED[*]}"
    print_info

    read -r -p "Type 'restore' to continue: " reply
    if [[ "$reply" != "restore" ]]; then
        print_info "Aborted."
        exit 1
    fi
}
