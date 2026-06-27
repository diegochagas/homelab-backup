#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=../config.sh
source "$PROJECT_DIR/config.sh"

mkdir -p "$LOCAL_BACKUP/jellyfin" "$LOG_DIR"

echo "Backing up Jellyfin from $REMOTE_HOST..."
rsync -az --delete -e "ssh -p $SSH_PORT" \
	"$REMOTE_USER@$REMOTE_HOST:$JELLYFIN_CONFIG/" \
	"$LOCAL_BACKUP/jellyfin/config/"

rsync -az --delete -e "ssh -p $SSH_PORT" \
	"$REMOTE_USER@$REMOTE_HOST:$JELLYFIN_MEDIA/" \
	"$LOCAL_BACKUP/jellyfin/media/"

