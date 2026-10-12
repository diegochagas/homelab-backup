#!/usr/bin/env bash
# Loads the gitignored config files next to the entry script and checks the
# values a script needs before anything else runs. Sourced, never executed.
#
# Expects from the entry script: SCRIPT_DIR.

# Load configuration: sources config.sh and derives REMOTE (user@host) from
# it. Missing file → clear message and exit 1 instead of a bash error.
#   load_config
load_config() {
    local config="$SCRIPT_DIR/config.sh"

    if [[ ! -f "$config" ]]; then
        echo "❌ Missing $config - copy config.sh.example and adjust it." >&2
        exit 1
    fi

    # shellcheck source=/dev/null # gitignored, absent in CI
    source "$config"

    REMOTE="$REMOTE_USER@$REMOTE_HOST"
    readonly REMOTE
}

# Sources profiles.conf (mirror-to-external.sh's PROFILES array).
#   load_profiles
load_profiles() {
    local profiles_file="$SCRIPT_DIR/profiles.conf"

    if [[ ! -f "$profiles_file" ]]; then
        echo "❌ Missing $profiles_file - copy profiles.conf.example and adjust it." >&2
        exit 1
    fi

    # shellcheck source=/dev/null # gitignored, absent in CI
    source "$profiles_file"
}

# Exits with a clear message when a config variable is unset or empty (for an
# array: when it has no first element).
#   require_config_values REMOTE_HOST REMOTE_USER SSH_PORT FOLDERS
require_config_values() {
    local name

    for name in "$@"; do
        if [[ -z "${!name:-}" ]]; then
            echo "❌ $name is not set in $SCRIPT_DIR/config.sh - see config.sh.example." >&2
            exit 1
        fi
    done
}
