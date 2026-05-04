#!/bin/bash
# Complete backup script: backup Vaultwarden data and upload to GCS
# This is the main entry point called by cron

set -euo pipefail

# Get the directory where this script is located
SCRIPT_DIR="$(dirname "$0")"

# Get the project root directory
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Load environment variables from vaultwarden.env file
if [ -f "${PROJECT_ROOT}/env/vaultwarden.env" ]; then
  set -a
  . "${PROJECT_ROOT}/env/vaultwarden.env"
  set +a
fi

# Run the main backup script which will:
# 1. Create database backup in Vaultwarden container
# 2. Create compressed archive of all data
# 3. Upload to GCS
# 4. Clean up old backups
"${SCRIPT_DIR}/vaultwarden-backup.sh"
