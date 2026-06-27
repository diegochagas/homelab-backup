#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=../config.sh
source "$PROJECT_DIR/config.sh"

missing=0

for service in jellyfin immich nextcloud; do
	if [[ -d "$LOCAL_BACKUP/$service" ]]; then
		echo "OK: $LOCAL_BACKUP/$service"
	else
		echo "Missing: $LOCAL_BACKUP/$service"
		missing=1
	fi
done

exit "$missing"

