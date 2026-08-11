#!/usr/bin/env bash

set -Eeuo pipefail
trap 'handle_error $? $LINENO "$BASH_COMMAND"' ERR

########################################
# Mirror to External
#
# Wipes a connected external USB drive and mirrors a named
# profile's data onto it. Use this for cold/offline copies, e.g.
# "erase this drive and put the Nextcloud data on it".
#
# This is a ONE-WAY, DESTRUCTIVE mirror (rsync --delete): whatever
# is on the drive that isn't in the source gets removed.
########################################

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/config.sh"

if [[ ! -f "$SCRIPT_DIR/profiles.conf" ]]; then
    echo "❌ Missing $SCRIPT_DIR/profiles.conf - copy profiles.conf.example and adjust it." >&2
    exit 1
fi
source "$SCRIPT_DIR/profiles.conf"

readonly VERSION="1.0.0"
readonly REMOTE="$REMOTE_USER@$REMOTE_HOST"

########################################
# Runtime options
########################################

PROFILE_NAME=""
DRY_RUN=false
declare LOG_FILE=""

# Resolved from PROFILES: name, type, source, description
P_TYPE=""
P_SOURCE=""
P_DESCRIPTION=""

# Resolved drive: device, label, mountpoint
D_NAME=""
D_LABEL=""
D_MOUNTPOINT=""

declare -a CANDIDATES=()

########################################
# Functions
########################################

print_info() {
    echo "$@"

    if [[ -n "$LOG_FILE" ]]; then
        echo "$@" >> "$LOG_FILE"
    fi
}

print_field() {
    printf "%-18s %s\n" "$1" "$2"

    if [[ -n "$LOG_FILE" ]]; then
        printf "%-18s %s\n" "$1" "$2" >> "$LOG_FILE"
    fi
}

print_section() {
    print_info
    print_info "========================================"
    print_info "$1"
    print_info "========================================"
    print_info
}

initialize_logging() {
    mkdir -p "$LOG_DIR"
    LOG_FILE="$LOG_DIR/mirror_$(date +%Y-%m-%d_%H-%M-%S).log"
    : > "$LOG_FILE"
}

handle_error() {
    local exit_code="$1"
    local line="$2"
    local command="$3"

    print_info
    print_info "❌ Mirror failed!"
    print_info

    print_field "Exit code:" "$exit_code"
    print_field "Line:" "$line"
    print_field "Command:" "$command"

    if [[ -n "$LOG_FILE" ]]; then
        print_info
        print_info "See log:"
        print_info "  $LOG_FILE"
    fi

    exit "$exit_code"
}

print_help() {
    cat << EOF
Mirror to External v$VERSION

Wipes a connected external USB drive and mirrors a named profile's
data onto it (rsync --delete). DESTRUCTIVE: anything already on
the drive that isn't part of the source gets removed.

Usage:
    ./mirror-to-external.sh <profile> [options]

Options:
    --dry-run    Simulate the mirror (no files touched).
    --list       List configured profiles and exit.
    --help       Show help.
    --version    Show version.

Available profiles:
$(print_profile_list)

Example:
    ./mirror-to-external.sh nextcloud --dry-run
EOF
}

print_version() {
    echo "$VERSION"
}

print_profile_list() {
    local entry name type source description
    for entry in "${PROFILES[@]}"; do
        IFS="|" read -r name type source description <<< "$entry"
        printf "    %-12s [%-6s] %s (%s)\n" "$name" "$type" "$source" "$description"
    done
}

parse_arguments() {
    if [[ $# -eq 0 ]]; then
        print_help
        exit 1
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)
                DRY_RUN=true
                shift
                ;;

            --list)
                echo "Available profiles:"
                print_profile_list
                exit 0
                ;;

            --help)
                print_help
                exit 0
                ;;

            --version)
                print_version
                exit 0
                ;;

            -*)
                echo "❌ Unknown option: $1"
                echo
                echo "Run './mirror-to-external.sh --help' for usage information."
                exit 1
                ;;

            *)
                if [[ -n "$PROFILE_NAME" ]]; then
                    echo "❌ Unexpected argument: $1"
                    exit 1
                fi
                PROFILE_NAME="$1"
                shift
                ;;
        esac
    done

    if [[ -z "$PROFILE_NAME" ]]; then
        echo "❌ No profile given."
        echo
        echo "Run './mirror-to-external.sh --help' for usage information."
        exit 1
    fi
}

########################################
# Resolves PROFILE_NAME into P_TYPE,
# P_SOURCE, P_DESCRIPTION.
########################################
resolve_profile() {
    local entry name type source description

    for entry in "${PROFILES[@]}"; do
        IFS="|" read -r name type source description <<< "$entry"

        if [[ "$name" == "$PROFILE_NAME" ]]; then
            P_TYPE="$type"
            P_SOURCE="$source"
            P_DESCRIPTION="$description"
            return
        fi
    done

    print_info "❌ Unknown profile: $PROFILE_NAME"
    print_info
    print_info "Available profiles:"
    print_info "$(print_profile_list)"
    exit 1
}

check_dependencies() {
    print_info "Checking dependencies..."

    local dependencies=(rsync lsblk du df)

    if [[ "$P_TYPE" == "remote" ]]; then
        dependencies+=(ssh)
    fi

    for command in "${dependencies[@]}"; do
        if ! command -v "$command" >/dev/null 2>&1; then
            echo "❌ Missing dependency: $command"
            exit 1
        fi
    done

    print_info "✅ Dependencies OK"
}

check_source() {
    print_info
    print_info "Checking source..."

    if [[ "$P_TYPE" == "local" ]]; then
        if [[ ! -d "$P_SOURCE" ]] || [[ -z "$(find "$P_SOURCE" -mindepth 1 -print -quit)" ]]; then
            print_info "❌ Local source is missing or empty: $P_SOURCE"
            exit 1
        fi
    else
        if ! ssh -p "$SSH_PORT" -o BatchMode=yes -o ConnectTimeout=5 "$REMOTE" "[ -d '$P_SOURCE' ]"; then
            print_info "❌ Remote source not found: $REMOTE:$P_SOURCE"
            exit 1
        fi
    fi

    print_info "✅ Source OK"
}

########################################
# Finds mounted removable drives under
# /media or /run/media.
########################################
detect_candidates() {
    print_info
    print_info "Looking for connected external drives..."

    local line NAME LABEL MOUNTPOINT RM TYPE

    while IFS= read -r line; do
        NAME=""; LABEL=""; MOUNTPOINT=""; RM=""; TYPE=""
        eval "$line"

        [[ "$RM" == "1" ]] || continue
        [[ -n "$MOUNTPOINT" ]] || continue
        [[ "$TYPE" == "part" || "$TYPE" == "disk" ]] || continue

        case "$MOUNTPOINT" in
            /media/*|/run/media/*) ;;
            *) continue ;;
        esac

        CANDIDATES+=("$NAME|$LABEL|$MOUNTPOINT")
    done < <(lsblk -P -o NAME,LABEL,MOUNTPOINT,RM,TYPE)

    if [[ ${#CANDIDATES[@]} -eq 0 ]]; then
        print_info "❌ No mounted external drive found under /media or /run/media."
        print_info "   Connect the drive and make sure it's mounted, then retry."
        exit 1
    fi
}

########################################
# Resolves D_NAME/D_LABEL/D_MOUNTPOINT
# from CANDIDATES, prompting if there's
# more than one.
########################################
select_drive() {
    if [[ ${#CANDIDATES[@]} -eq 1 ]]; then
        IFS="|" read -r D_NAME D_LABEL D_MOUNTPOINT <<< "${CANDIDATES[0]}"
        return
    fi

    print_info "Multiple external drives found:"
    local i=1
    for c in "${CANDIDATES[@]}"; do
        IFS="|" read -r n l m <<< "$c"
        print_info "  [$i] $n  label=$l  mount=$m"
        i=$((i + 1))
    done

    local choice
    read -r -p "Select drive #: " choice

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#CANDIDATES[@]} )); then
        print_info "❌ Invalid selection."
        exit 1
    fi

    IFS="|" read -r D_NAME D_LABEL D_MOUNTPOINT <<< "${CANDIDATES[$((choice - 1))]}"
}

get_source_size() {
    if [[ "$P_TYPE" == "local" ]]; then
        du -sh "$P_SOURCE" 2>/dev/null | cut -f1
    else
        ssh -p "$SSH_PORT" "$REMOTE" "du -sh '$P_SOURCE' 2>/dev/null | cut -f1"
    fi
}

get_source_size_bytes() {
    if [[ "$P_TYPE" == "local" ]]; then
        du -sb "$P_SOURCE" 2>/dev/null | cut -f1
    else
        ssh -p "$SSH_PORT" "$REMOTE" "du -sb '$P_SOURCE' 2>/dev/null | cut -f1"
    fi
}

check_disk_space() {
    print_info
    print_info "Checking destination capacity..."

    local required
    required=$(get_source_size_bytes)

    local capacity
    capacity=$(df -B1 --output=size "$D_MOUNTPOINT" | tail -n 1 | tr -d ' ')

    print_field "Required:" "$(numfmt --to=iec "$required")"
    print_field "Drive capacity:" "$(numfmt --to=iec "$capacity")"

    if (( capacity < required )); then
        print_field "Status:" "❌ Drive is too small"
        exit 1
    fi

    print_field "Status:" "✅ Fits"
}

########################################
# Shows the plan and requires the exact
# drive label typed back before wiping
# anything.
########################################
confirm_wipe() {
    print_info
    print_info "⚠️  ABOUT TO ERASE: $D_MOUNTPOINT (device $D_NAME, label '$D_LABEL')"
    print_info "⚠️  Everything on it that isn't part of this profile will be DELETED."
    print_info
    print_field "Profile:" "$PROFILE_NAME - $P_DESCRIPTION"
    print_field "Source:" "$([[ "$P_TYPE" == local ]] && echo "$P_SOURCE" || echo "$REMOTE:$P_SOURCE")"
    print_field "Destination:" "$D_MOUNTPOINT"
    print_info

    if [[ "$DRY_RUN" == true ]]; then
        return
    fi

    if [[ -z "$D_LABEL" ]]; then
        read -r -p "Type the mountpoint ($D_MOUNTPOINT) to continue: " reply
        [[ "$reply" == "$D_MOUNTPOINT" ]] && return
    else
        read -r -p "Type the drive label ($D_LABEL) to continue: " reply
        [[ "$reply" == "$D_LABEL" ]] && return
    fi

    print_info "Aborted."
    exit 1
}

run_mirror() {
    print_section "Mirroring $PROFILE_NAME -> $D_MOUNTPOINT"

    local options=(
        -a
        --human-readable
        --delete
    )

    if [[ "$DRY_RUN" == true ]]; then
        options+=(-n --stats)
    else
        options+=(--info=progress2,name0)
        print_info "Syncing..."
    fi

    if [[ "$P_TYPE" == "local" ]]; then
        rsync "${options[@]}" "$P_SOURCE/" "$D_MOUNTPOINT/"
    else
        options+=(--rsync-path="sudo /usr/bin/rsync")
        rsync "${options[@]}" "$REMOTE:$P_SOURCE/" "$D_MOUNTPOINT/"
    fi

    print_info
    print_info "✅ Done"
}

main() {
    parse_arguments "$@"
    resolve_profile

    initialize_logging

    print_info "=========================================="
    print_info "        Mirror to External v$VERSION"
    print_info "=========================================="
    print_info "Mode: $([[ "$DRY_RUN" == true ]] && echo "Simulation" || echo "Mirror")"

    check_dependencies
    check_source

    detect_candidates
    select_drive

    check_disk_space
    confirm_wipe

    run_mirror
}

main "$@"
