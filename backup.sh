#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=config.sh
source "$SCRIPT_DIR/config.sh"

mkdir -p "$BACKUP_DEST_DIR" "$LOG_DIR"

echo "Backup workflow is not implemented yet."
echo "Source: $BACKUP_SOURCE_DIR"
echo "Destination: $BACKUP_DEST_DIR"
