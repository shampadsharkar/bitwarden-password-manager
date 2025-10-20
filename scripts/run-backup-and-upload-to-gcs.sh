#!/usr/bin/env bash
# Complete backup script: backup Vaultwarden data and upload to GCS
# This is the main entry point called by cron

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Get the project root directory (parent of scripts/)
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Load environment variables from vaultwarden.env file
# This includes backup settings, GCS configuration, etc.
if [[ -f "${PROJECT_ROOT}/env/vaultwarden.env" ]]; then
  set -a  # Export all variables
  source "${PROJECT_ROOT}/env/vaultwarden.env"
  set +a  # Stop exporting
fi

# Enable strict error handling:
# -e: Exit on any error
# -u: Exit on undefined variable
# -o pipefail: Exit on pipe failures
set -euo pipefail

# Run the main backup script which will:
# 1. Create database backup in Vaultwarden container
# 2. Create compressed archive of all data
# 3. Upload to GCS
# 4. Clean up old backups
"${SCRIPT_DIR}/vaultwarden-backup.sh"
