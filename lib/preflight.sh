#!/usr/bin/env bash
# Pre-flight checks run before any copy: required commands and the ssh
# connection to the server. Sourced, never executed.

# Exits 1 when one of the given commands is not installed.
#   check_dependencies ssh rsync du
check_dependencies() {
    print_info "Checking dependencies..."

    local command
    for command in "$@"; do
        if ! command -v "$command" >/dev/null 2>&1; then
            echo "❌ Missing dependency: $command"
            exit 1
        fi
    done

    print_info "✅ Dependencies OK"
}

# Exits 1 when the server does not answer over ssh.
#   test_ssh_connection
test_ssh_connection() {
    print_info
    print_info "Testing SSH connection..."

    if remote_is_reachable; then
        print_info "✅ Connected to ZimaOS"
    else
        print_info "❌ Could not connect to ZimaOS"
        exit 1
    fi
}
