#!/usr/bin/env bash
# ============================================================================
# Vaultwarden Complete Backup & GCS Sync Entrypoint
# Main cron entry point: performs Vaultwarden backup, GCS sync, and sends
# Telegram status notifications on success or failure.
# ============================================================================

set -euo pipefail

# Ensure standard tools and gcloud are in PATH
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${HOME}/google-cloud-sdk/bin:${HOME}/.local/bin:${PATH:-}"

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Get the project root directory
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Ensure lock prevents overlapping backup runs
LOCK_FILE="/tmp/vaultwarden-backup.lock"
exec 200>"${LOCK_FILE}"
if ! flock -n 200; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Another backup process is already running. Exiting." >&2
  exit 1
fi

# Load environment variables from vaultwarden.env file
if [[ -f "${PROJECT_ROOT}/env/vaultwarden.env" ]]; then
  set -a
  # shellcheck source=/dev/null
  . "${PROJECT_ROOT}/env/vaultwarden.env"
  set +a
fi

export VAULTWARDEN_REMOTE_SYNC_CMD="${SCRIPT_DIR}/upload_to_gcs.sh \"\$LAST_BACKUP\""

# Best-effort Telegram notification helper
notify_result() {
  local status="$1"
  local detail="$2"

  if [[ -f "${SCRIPT_DIR}/notify-backup.py" ]]; then
    if python3 "${SCRIPT_DIR}/notify-backup.py" "${status}" "${detail}"; then
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] Backup notification sent: ${status}"
    else
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: Could not send backup notification" >&2
    fi
  fi
}

started_at="$(date '+%s')"
run_output="$(mktemp "${TMPDIR:-/tmp}/vaultwarden-backup-run.XXXXXX")"
trap 'rm -f "${run_output}"' EXIT

backup_exit=0
if ( "${SCRIPT_DIR}/vaultwarden-backup.sh" ) >"${run_output}" 2>&1; then
  backup_exit=0
else
  backup_exit="$?"
fi

# Print run output to stdout/stderr (e.g. captured by backup.log in cron)
cat "${run_output}"

finished_at="$(date '+%s')"
duration_seconds=$((finished_at - started_at))

if [[ "${backup_exit}" -eq 0 ]]; then
  archive_name="$(grep -oE 'vaultwarden-data_[0-9_]+\.tar\.gz' "${run_output}" | tail -n 1 || true)"
  backup_size=""
  if [[ -n "${archive_name}" && -f "${PROJECT_ROOT}/backups/${archive_name}" ]]; then
    backup_size="$(du -h "${PROJECT_ROOT}/backups/${archive_name}" | cut -f1)"
  fi

  detail_lines=()
  if [[ -n "${archive_name}" ]]; then
    detail_lines+=("Archive: ${archive_name}")
  fi
  if [[ -n "${backup_size}" ]]; then
    detail_lines+=("Size: ${backup_size}")
  fi
  detail_lines+=("GCS Bucket: ${GCS_BUCKET_NAME:-home-server-ss}/${GCS_BUCKET_PATH:-bitwarden-backups}")
  detail_lines+=("Duration: ${duration_seconds}s")

  detail="$(printf '%s\n' "${detail_lines[@]}")"
  notify_result "success" "${detail}"
else
  reason="$(grep -oE 'ERROR: .*' "${run_output}" | tail -n 1 | sed 's/^ERROR: *//' || true)"
  if [[ -z "${reason}" ]]; then
    reason="$(awk 'NF {line=$0} END {print line}' "${run_output}")"
  fi
  if [[ -z "${reason}" ]]; then
    reason="Backup process terminated unexpectedly"
  fi

  detail="$(printf 'Reason: %s\nExit code: %s\nDuration: %ss\nLog: backup.log' \
    "${reason}" "${backup_exit}" "${duration_seconds}")"
  notify_result "failure" "${detail}"
  exit "${backup_exit}"
fi
