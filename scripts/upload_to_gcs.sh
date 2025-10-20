#!/usr/bin/env bash
# Upload backup file to Google Cloud Storage (GCS) bucket
# This script:
# 1. Authenticates with GCS using a service account
# 2. Uploads the backup file to the specified bucket
# 3. Cleans up old backups in GCS based on retention policy

# Enable strict error handling
set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Get the project root directory
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# GCS bucket name (can be overridden with GCS_BUCKET_NAME env var)
BUCKET_NAME="${GCS_BUCKET_NAME:-home-server-ss}"
# Path/folder within the bucket where backups will be stored
BUCKET_PATH="${GCS_BUCKET_PATH:-bitwarden-backups}"
# Number of days to keep backups in GCS (older ones will be deleted)
RETENTION_DAYS="${GCS_RETENTION_DAYS:-30}"
# Path to GCS service account key JSON file for authentication
SERVICE_ACCOUNT_KEY="${GCS_SERVICE_ACCOUNT_KEY:-${PROJECT_ROOT}/env/service_account.json}"

# ============================================================================
# Validate Input and Prerequisites
# ============================================================================

# Check if a file path was provided as argument
if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <file-to-upload>" >&2
  exit 1
fi

# Get the file path from first argument
FILE_PATH="$1"

# Verify the backup file exists
if [[ ! -f "${FILE_PATH}" ]]; then
  echo "Error: File not found: ${FILE_PATH}" >&2
  exit 1
fi

# Check if gcloud CLI is installed
if ! command -v gcloud >/dev/null 2>&1; then
  echo "Error: gcloud CLI is not installed or not in PATH" >&2
  exit 1
fi

# Verify service account key file exists
if [[ ! -f "${SERVICE_ACCOUNT_KEY}" ]]; then
  echo "Error: Service account key not found: ${SERVICE_ACCOUNT_KEY}" >&2
  exit 1
fi

# ============================================================================
# Authenticate with Google Cloud
# ============================================================================

# Authenticate using the service account JSON key
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Authenticating with service account"
gcloud auth activate-service-account --key-file="${SERVICE_ACCOUNT_KEY}" --quiet

# ============================================================================
# Upload Backup File to GCS
# ============================================================================

# Construct the full GCS destination path
# Format: gs://bucket-name/path/filename.tar.gz
DESTINATION="gs://${BUCKET_NAME}/${BUCKET_PATH}/$(basename "${FILE_PATH}")"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Uploading ${FILE_PATH} to ${DESTINATION}"

# Upload the backup file using gcloud storage cp command
if gcloud storage cp "${FILE_PATH}" "${DESTINATION}"; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Upload successful"

  # ============================================================================
  # Clean Up Old Backups in GCS
  # ============================================================================

  # Only clean up if retention policy is configured
  if [[ -n "${RETENTION_DAYS}" && "${RETENTION_DAYS}" -gt 0 ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Checking backups for cleanup (retention: ${RETENTION_DAYS} days)"

    # Count total backups in GCS to ensure we don't delete all backups
    TOTAL_BACKUPS=$(gcloud storage ls "gs://${BUCKET_NAME}/${BUCKET_PATH}/" 2>/dev/null | grep -c "gs://" || echo "0")

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Total backups in GCS: ${TOTAL_BACKUPS}"

    # Only proceed with cleanup if we have more backups than retention period
    # This ensures we always keep at least RETENTION_DAYS backups even if the system fails
    if [[ "${TOTAL_BACKUPS}" -gt "${RETENTION_DAYS}" ]]; then
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] Cleaning up backups older than ${RETENTION_DAYS} days"

      # Calculate the cutoff timestamp (files older than this will be deleted)
      # Convert to Unix timestamp (seconds since epoch)
      CUTOFF_TIMESTAMP=$(date -d "${RETENTION_DAYS} days ago" '+%s')

      # List all files in the GCS bucket path with detailed information
      # Format: SIZE  CREATION_DATE  CREATION_TIME  gs://path/to/file
      gcloud storage ls --long "gs://${BUCKET_NAME}/${BUCKET_PATH}/" | tail -n +2 | \
      while read -r size created time name; do
        # Convert the file's creation date to Unix timestamp
        file_timestamp=$(date -d "${created} ${time}" '+%s' 2>/dev/null || echo "0")

        # If file is older than retention period, delete it
        if [[ "${file_timestamp}" -gt 0 && "${file_timestamp}" -lt "${CUTOFF_TIMESTAMP}" ]]; then
          echo "[$(date '+%Y-%m-%d %H:%M:%S')] Deleting old backup: ${name}"
          # Delete the file from GCS (|| true prevents script from failing if delete fails)
          gcloud storage rm "${name}" || true
        fi
      done
    else
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] Skipping cleanup: Only ${TOTAL_BACKUPS} backups exist (need more than ${RETENTION_DAYS} to clean up)"
    fi
  fi
else
  # Upload failed
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Upload failed" >&2
  exit 1
fi
