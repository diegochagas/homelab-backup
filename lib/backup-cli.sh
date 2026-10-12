#!/usr/bin/env bash
# Command line of backup.sh: help text and argument parsing. Sourced by
# backup.sh, never executed.
#
# Expects from backup.sh: VERSION, TARGET, DRY_RUN and FOLDERS (config.sh).

########################################
# Prints the help message.
########################################
# clean-code-audit: allow-long -- heredoc help text, no logic
print_help() {
    cat <<EOF
Homelab Backup v$VERSION

Usage:
    ./backup.sh [options]

Options:
    --folder <name>     Backup only one folder (skips the push to ZimaOS).
    --dry-run           Simulate the backup.
    --help              Show help.
    --version           Show version.

Available folders:
    all
$(printf '    %s\n' "${FOLDERS[@]}")

Examples:
    ./backup.sh

$(printf '    ./backup.sh --folder %s\n\n' "${FOLDERS[@]}")
EOF
}

########################################
# Parses command-line arguments.
#
# Options:
#   --folder <name>
########################################
#   parse_arguments "$@"
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --folder)
                TARGET="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --help) print_help && exit 0 ;;
            --version) print_version && exit 0 ;;
            *)
                print_info "❌ Unknown argument: $1"
                exit_with_usage_hint
                ;;
        esac
    done
}
