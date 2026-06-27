#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=../config.sh
source "$PROJECT_DIR/config.sh"

if [[ -z "${NEXTCLOUD_DATA:-}" ]]; then
	echo "NEXTCLOUD_DATA is not configured in config.sh; skipping Nextcloud backup."
	exit 0
fi

mkdir -p "$LOCAL_BACKUP/nextcloud" "$LOG_DIR"

echo "Backing up Nextcloud from $REMOTE_HOST..."
rsync -az --delete -e "ssh -p $SSH_PORT" \
	"$REMOTE_USER@$REMOTE_HOST:$NEXTCLOUD_DATA/" \
	"$LOCAL_BACKUP/nextcloud/data/"

