#!/usr/bin/env bash

set -Eeuo pipefail
trap 'handle_error $? $LINENO "$BASH_COMMAND" "${BASH_SOURCE[0]}"' ERR

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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME

# shellcheck source=lib/output.sh
source "$SCRIPT_DIR/lib/output.sh"
# shellcheck source=lib/logging.sh
source "$SCRIPT_DIR/lib/logging.sh"
# shellcheck source=lib/config-loader.sh
source "$SCRIPT_DIR/lib/config-loader.sh"
# shellcheck source=lib/remote.sh
source "$SCRIPT_DIR/lib/remote.sh"
# shellcheck source=lib/transfer.sh
source "$SCRIPT_DIR/lib/transfer.sh"
# shellcheck source=lib/disk-space.sh
source "$SCRIPT_DIR/lib/disk-space.sh"
# shellcheck source=lib/arguments.sh
source "$SCRIPT_DIR/lib/arguments.sh"
# shellcheck source=lib/preflight.sh
source "$SCRIPT_DIR/lib/preflight.sh"

readonly VERSION="1.0.0"
readonly SCRIPT_TITLE="Mirror to External"
readonly MODE_LABEL="Mirror"
readonly LOG_PREFIX="mirror_"

load_config
load_profiles
require_config_values REMOTE_HOST REMOTE_USER SSH_PORT LOG_DIR PROFILES

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

# rsync wrappers (lib/transfer.sh) record outcomes here; unused by this
# script's single transfer but required by the shared helpers.
declare -a SUMMARY=()

########################################
# Functions
########################################

# clean-code-audit: allow-long -- heredoc help text, no logic
print_help() {
    cat <<EOF
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

# One line per PROFILES entry: name, type, source, description.
#   print_profile_list
print_profile_list() {
    local entry name type source description
    for entry in "${PROFILES[@]}"; do
        IFS="|" read -r name type source description <<<"$entry"
        printf "    %-12s [%-6s] %s (%s)\n" "$name" "$type" "$source" "$description"
    done
}

# Parses the command line into PROFILE_NAME and DRY_RUN; --list, --help and
# --version exit on the spot.
#   parse_arguments "$@"
parse_arguments() {
    if [[ $# -eq 0 ]]; then
        print_help
        exit 1
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) DRY_RUN=true && shift ;;
            --list) list_profiles_and_exit ;;
            --help) print_help && exit 0 ;;
            --version) print_version && exit 0 ;;
            -*) reject_unknown_option "$1" ;;
            *) take_profile_name "$1" && shift ;;
        esac
    done

    require_profile_name
}

# --list: the configured profiles, then exit 0.
list_profiles_and_exit() {
    echo "Available profiles:"
    print_profile_list
    exit 0
}

# Exits 1 with the usage hint for an option this script does not know.
#   reject_unknown_option "$1"
reject_unknown_option() {
    echo "❌ Unknown option: $1"
    exit_with_usage_hint
}

# Stores the positional profile name; a second one is an error.
#   take_profile_name "$1"
take_profile_name() {
    if [[ -n "$PROFILE_NAME" ]]; then
        echo "❌ Unexpected argument: $1"
        exit 1
    fi
    PROFILE_NAME="$1"
}

# Exits 1 when the command line named no profile.
#   require_profile_name
require_profile_name() {
    [[ -z "$PROFILE_NAME" ]] || return 0

    echo "❌ No profile given."
    exit_with_usage_hint
}

########################################
# Resolves PROFILE_NAME into P_TYPE,
# P_SOURCE, P_DESCRIPTION.
########################################
#   resolve_profile
resolve_profile() {
    local entry name type source description

    for entry in "${PROFILES[@]}"; do
        IFS="|" read -r name type source description <<<"$entry"

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

# The tools a mirror needs; ssh only for a remote profile.
#   check_mirror_dependencies
check_mirror_dependencies() {
    local dependencies=(rsync lsblk du df)

    if [[ "$P_TYPE" == "remote" ]]; then
        dependencies+=(ssh)
    fi

    check_dependencies "${dependencies[@]}"
}

# Exits 1 when the profile's source is missing or (locally) empty, so an
# empty source can never wipe the drive.
#   check_source
check_source() {
    print_info
    print_info "Checking source..."

    if [[ "$P_TYPE" == "local" ]]; then
        if ! local_dir_has_files "$P_SOURCE"; then
            print_info "❌ Local source is missing or empty: $P_SOURCE"
            exit 1
        fi
    else
        if ! remote_run_unattended "[ -d '$P_SOURCE' ]"; then
            print_info "❌ Remote source not found: $REMOTE:$P_SOURCE"
            exit 1
        fi
    fi

    print_info "✅ Source OK"
}

# Block devices as `NAME="sdb" LABEL=... MOUNTPOINT=... RM=... TYPE=...`
# lines; the one lsblk call, so tests/fakes/lsblk can stand in.
#   list_block_devices
list_block_devices() {
    lsblk -P -o NAME,LABEL,MOUNTPOINT,RM,TYPE
}

########################################
# Finds mounted removable drives under
# /media or /run/media.
########################################
#   detect_candidates
detect_candidates() {
    print_info
    print_info "Looking for connected external drives..."

    local line
    while IFS= read -r line; do
        add_external_candidate "$line"
    done < <(list_block_devices)

    if [[ ${#CANDIDATES[@]} -eq 0 ]]; then
        print_info "❌ No mounted external drive found under /media or /run/media."
        print_info "   Connect the drive and make sure it's mounted, then retry."
        exit 1
    fi
}

# Adds one lsblk -P line to CANDIDATES when it describes a removable disk
# or partition mounted under /media or /run/media.
#   add_external_candidate 'NAME="sdb1" LABEL="EXT" MOUNTPOINT="/media/u/EXT" RM="1" TYPE="part"'
add_external_candidate() {
    local NAME="" LABEL="" MOUNTPOINT="" RM="" TYPE=""
    eval "$1"

    [[ "$RM" == "1" ]] || return 0
    [[ -n "$MOUNTPOINT" ]] || return 0
    [[ "$TYPE" == "part" || "$TYPE" == "disk" ]] || return 0

    case "$MOUNTPOINT" in
        /media/* | /run/media/*) ;;
        *) return 0 ;;
    esac

    CANDIDATES+=("$NAME|$LABEL|$MOUNTPOINT")
}

########################################
# Resolves D_NAME/D_LABEL/D_MOUNTPOINT
# from CANDIDATES, prompting if there's
# more than one.
########################################
#   select_drive
select_drive() {
    if [[ ${#CANDIDATES[@]} -eq 1 ]]; then
        IFS="|" read -r D_NAME D_LABEL D_MOUNTPOINT <<<"${CANDIDATES[0]}"
        return
    fi

    print_drive_choices

    local choice
    read -r -p "Select drive #: " choice

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || ((choice < 1 || choice > ${#CANDIDATES[@]})); then
        print_info "❌ Invalid selection."
        exit 1
    fi

    IFS="|" read -r D_NAME D_LABEL D_MOUNTPOINT <<<"${CANDIDATES[$((choice - 1))]}"
}

# Numbered list of CANDIDATES for the drive prompt.
#   print_drive_choices
print_drive_choices() {
    print_info "Multiple external drives found:"

    local i=1 c n l m
    for c in "${CANDIDATES[@]}"; do
        IFS="|" read -r n l m <<<"$c"
        print_info "  [$i] $n  label=$l  mount=$m"
        i=$((i + 1))
    done
}

# Size of the profile's source in bytes, local or over ssh.
#   get_source_size_bytes
get_source_size_bytes() {
    if [[ "$P_TYPE" == "local" ]]; then
        local_size_bytes "$P_SOURCE"
    else
        remote_size_bytes "$P_SOURCE"
    fi
}

# Exits 1 when the source is bigger than the whole drive.
#   check_drive_capacity
check_drive_capacity() {
    print_info
    print_info "Checking destination capacity..."

    local required
    required=$(get_source_size_bytes)

    local capacity
    capacity=$(local_capacity_bytes "$D_MOUNTPOINT")

    print_field "Required:" "$(numfmt --to=iec "$required")"
    print_field "Drive capacity:" "$(numfmt --to=iec "$capacity")"

    if ((capacity < required)); then
        print_field "Status:" "❌ Drive is too small"
        exit 1
    fi

    print_field "Status:" "✅ Fits"
}

# What is about to be erased and replaced with what.
#   print_wipe_plan
print_wipe_plan() {
    print_info
    print_info "⚠️  ABOUT TO ERASE: $D_MOUNTPOINT (device $D_NAME, label '$D_LABEL')"
    print_info "⚠️  Everything on it that isn't part of this profile will be DELETED."
    print_info
    print_field "Profile:" "$PROFILE_NAME - $P_DESCRIPTION"
    print_field "Source:" "$([[ "$P_TYPE" == local ]] && echo "$P_SOURCE" || echo "$REMOTE:$P_SOURCE")"
    print_field "Destination:" "$D_MOUNTPOINT"
    print_info
}

########################################
# Shows the plan and requires the exact
# drive label typed back before wiping
# anything.
########################################
# A drive without a label has to be confirmed by its mountpoint instead.
#   confirm_wipe
confirm_wipe() {
    print_wipe_plan

    if [[ "$DRY_RUN" == true ]]; then
        return
    fi

    local what="drive label" expected="$D_LABEL" reply
    if [[ -z "$D_LABEL" ]]; then
        what="mountpoint"
        expected="$D_MOUNTPOINT"
    fi

    read -r -p "Type the $what ($expected) to continue: " reply
    [[ "$reply" != "$expected" ]] || return 0

    print_info "Aborted."
    exit 1
}

# The mirror itself: rsync --delete from the source onto the drive; a remote
# source is read through sudo rsync on the server.
#   run_mirror
run_mirror() {
    print_section "Mirroring $PROFILE_NAME -> $D_MOUNTPOINT"

    build_rsync_options --delete
    print_transfer_start "Syncing..."

    if [[ "$P_TYPE" == "local" ]]; then
        run_rsync "$P_SOURCE/" "$D_MOUNTPOINT/"
    else
        RSYNC_OPTIONS+=(--rsync-path="sudo /usr/bin/rsync")
        run_rsync "$REMOTE:$P_SOURCE/" "$D_MOUNTPOINT/"
    fi

    print_info
    print_info "✅ Done"
}

# The banner, logged as well (this script has no separate log header).
#   print_mirror_header
print_mirror_header() {
    print_info "=========================================="
    print_info "        $SCRIPT_TITLE v$VERSION"
    print_info "=========================================="
    print_info "Mode: $(run_mode_label)"
}

main() {
    parse_arguments "$@"
    resolve_profile

    initialize_logging
    print_mirror_header

    check_mirror_dependencies
    check_source

    detect_candidates
    select_drive

    check_drive_capacity
    confirm_wipe

    run_mirror
}

main "$@"
