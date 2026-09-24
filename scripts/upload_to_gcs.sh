#!/usr/bin/env bash
# Upload backup file to Google Cloud Storage (GCS) bucket
# This script:
# 1. Authenticates with GCS using a service account
# 2. Uploads the backup file to the specified bucket
# 3. Cleans up old backups in GCS based on retention policy

# Enable strict error handling
set -euo pipefail

# Add gcloud to PATH if not already present
if ! command -v gcloud >/dev/null 2>&1; then
  for _gc_dir in "$HOME/google-cloud-sdk/bin" /opt/google-cloud-sdk/bin /usr/local/google-cloud-sdk/bin; do
    if [[ -x "${_gc_dir}/gcloud" ]]; then
      export PATH="${_gc_dir}:${PATH}"
      break
    fi
  done
fi

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
# Number of days to keep daily backups in GCS
RETENTION_DAYS="${GCS_RETENTION_DAYS:-30}"
# Number of months to keep monthly archive backups (one per month, earliest of each month)
MONTHLY_RETENTION_MONTHS="${GCS_MONTHLY_RETENTION_MONTHS:-12}"
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

# ============================================================================
# Authenticate with Google Cloud
# ============================================================================

if [[ -f "${SERVICE_ACCOUNT_KEY}" ]]; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Authenticating with service account: ${SERVICE_ACCOUNT_KEY}"
  gcloud auth activate-service-account --key-file="${SERVICE_ACCOUNT_KEY}" --quiet
elif gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | grep -q "@"; then
  ACTIVE_ACCT=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | head -n1)
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Using existing active gcloud account: ${ACTIVE_ACCT}"
else
  echo "Error: Service account key not found at ${SERVICE_ACCOUNT_KEY} and no active gcloud account" >&2
  exit 1
fi

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
  # Clean Up Old Backups in GCS (Two-Tier Retention)
  # Tier 1 – Daily  : keep all backups from the last RETENTION_DAYS days
  # Tier 2 – Monthly: for older backups, keep the earliest backup of each
  #                   calendar month for up to MONTHLY_RETENTION_MONTHS months
  # ============================================================================

  if [[ -n "${RETENTION_DAYS}" && "${RETENTION_DAYS}" -gt 0 ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Checking backups for cleanup (daily: ${RETENTION_DAYS}d, monthly: ${MONTHLY_RETENTION_MONTHS}mo)"

    # List all backup URLs in GCS
    BACKUP_LIST=$(gcloud storage ls "gs://${BUCKET_NAME}/${BUCKET_PATH}/" 2>/dev/null || echo "")
    TOTAL_BACKUPS=$(echo "${BACKUP_LIST}" | grep -c "gs://" || echo "0")

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Total backups in GCS: ${TOTAL_BACKUPS}"

    if [[ "${TOTAL_BACKUPS}" -gt 0 ]]; then
      DAILY_CUTOFF=$(date -d "${RETENTION_DAYS} days ago" '+%Y%m%d')
      MONTHLY_CUTOFF=$(date -d "${MONTHLY_RETENTION_MONTHS} months ago" '+%Y%m%d')

      echo "[$(date '+%Y-%m-%d %H:%M:%S')] Daily window back to: ${DAILY_CUTOFF}, Monthly archive back to: ${MONTHLY_CUTOFF}"

      # ---- Pass 1: find the earliest backup URL for each YYYYMM ----
      declare -A _monthly_rep
      declare -A _monthly_rep_date

      while read -r gcs_url; do
        [[ "${gcs_url}" == gs://* ]] || continue
        filename="$(basename "${gcs_url}")"
        [[ "${filename}" =~ ([0-9]{8})_[0-9]{6} ]] || continue
        file_date="${BASH_REMATCH[1]}"
        ym="${file_date:0:6}"

        if [[ "${file_date}" < "${DAILY_CUTOFF}" ]]; then
          if [[ -z "${_monthly_rep[$ym]:-}" || "${file_date}" < "${_monthly_rep_date[$ym]}" ]]; then
            _monthly_rep[$ym]="${gcs_url}"
            _monthly_rep_date[$ym]="${file_date}"
          fi
        fi
      done <<< "${BACKUP_LIST}"

      # ---- Pass 2: delete files that don't qualify for either tier ----
      while read -r gcs_url; do
        [[ "${gcs_url}" == gs://* ]] || continue
        filename="$(basename "${gcs_url}")"

        if [[ "${filename}" =~ ([0-9]{8})_[0-9]{6} ]]; then
          file_date="${BASH_REMATCH[1]}"
        else
          echo "[$(date '+%Y-%m-%d %H:%M:%S')] Skipping ${filename}: cannot extract date from filename"
          continue
        fi

        ym="${file_date:0:6}"

        # Tier 1: within daily window — keep unconditionally
        if [[ ! "${file_date}" < "${DAILY_CUTOFF}" ]]; then
          continue
        fi

        # Beyond monthly archive horizon — delete regardless
        if [[ "${file_date}" < "${MONTHLY_CUTOFF}" ]]; then
          echo "[$(date '+%Y-%m-%d %H:%M:%S')] Deleting (beyond monthly horizon): ${gcs_url}"
          gcloud storage rm "${gcs_url}" || true
          continue
        fi

        # Tier 2: monthly representative — keep it
        if [[ "${_monthly_rep[$ym]:-}" == "${gcs_url}" ]]; then
          echo "[$(date '+%Y-%m-%d %H:%M:%S')] Keeping monthly archive (${ym}): ${filename}"
          continue
        fi

        # Not in daily window and not the monthly rep — delete
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Deleting (superseded within month ${ym}): ${gcs_url}"
        gcloud storage rm "${gcs_url}" || true
      done <<< "${BACKUP_LIST}"

      unset _monthly_rep _monthly_rep_date
    else
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] No backups found in GCS, skipping cleanup"
    fi
  fi
else
  # Upload failed
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Upload failed" >&2
  exit 1
fi
