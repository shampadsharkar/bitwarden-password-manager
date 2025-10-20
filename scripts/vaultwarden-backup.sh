#!/usr/bin/env bash
# Vaultwarden backup script
# Creates database backup, archives all data, and uploads to remote storage
# shellcheck disable=SC2086

# Enable strict error handling
set -euo pipefail

# ============================================================================
# Configuration - Get paths and read environment variables
# ============================================================================

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Get the project root directory
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# Docker compose command (can be overridden with DOCKER_COMPOSE_BIN env var)
COMPOSE_BIN="${DOCKER_COMPOSE_BIN:-docker compose}"
# Path to docker-compose.yml file
COMPOSE_FILE="${PROJECT_ROOT}/docker-compose.yml"

# Data directory where Vaultwarden stores its data (mapped from Docker volume)
DATA_DIR="${VAULTWARDEN_DATA_DIR:-/mnt/ssd/nas/bitwarden-data/vaultwarden}"
# Local directory to store backup files
LOCAL_BACKUP_DIR="${VAULTWARDEN_BACKUP_DIR:-${PROJECT_ROOT}/backups}"
# Pattern to match database backup files created by Vaultwarden
BACKUP_PATTERN="${VAULTWARDEN_BACKUP_PATTERN:-db_*.sqlite3}"
# Whether to create a compressed archive of all data
ARCHIVE_ENABLED="${VAULTWARDEN_ARCHIVE_ENABLED:-true}"
# Prefix for archive filenames
ARCHIVE_PREFIX="${VAULTWARDEN_ARCHIVE_PREFIX:-vaultwarden-data}"
# Paths to exclude from the archive (relative to DATA_DIR)
ARCHIVE_EXCLUDES="${VAULTWARDEN_ARCHIVE_EXCLUDES:-backups}"
# Number of days to keep local backups
RETENTION_DAYS="${VAULTWARDEN_RETENTION_DAYS:-7}"
# Command to run for remote sync (e.g., upload to GCS)
REMOTE_SYNC_CMD="${VAULTWARDEN_REMOTE_SYNC_CMD:-}"
# Optional encryption command
ENCRYPT_CMD="${VAULTWARDEN_ENCRYPT_CMD:-}"

# ============================================================================
# Helper Functions
# ============================================================================

# Log a message with timestamp
log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

# Log error and exit with non-zero status
fail() {
  log "ERROR: $*" >&2
  exit 1
}

# Check if a value is truthy (true, yes, 1, etc.)
is_truthy() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|y|Y|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

# ============================================================================
# Pre-flight Checks - Verify all requirements are met
# ============================================================================

# Check if docker compose is installed
if ! command -v ${COMPOSE_BIN%% *} >/dev/null 2>&1; then
  fail "docker compose (or docker-compose) is required"
fi

# Check if docker-compose.yml exists
if [[ ! -f "${COMPOSE_FILE}" ]]; then
  fail "Could not locate docker-compose.yml at ${COMPOSE_FILE}"
fi

# Check if Vaultwarden data directory exists
if [[ ! -d "${DATA_DIR}" ]]; then
  fail "Expected Vaultwarden data directory '${DATA_DIR}' does not exist"
fi

# Create local backup directory if it doesn't exist
mkdir -p "${LOCAL_BACKUP_DIR}"

# Create a temporary marker file to track which backup files are new
# This file's timestamp will be used to find files created after it
marker="$(mktemp)"
trap 'rm -f "${marker}"' EXIT

# Touch the marker file to set its timestamp to now
touch "${marker}"

# ============================================================================
# Step 1: Create Database Backup in Vaultwarden Container
# ============================================================================

log "Triggering Vaultwarden in-container backup"
# Execute the /vaultwarden backup command inside the running container
# This creates a SQLite database backup file in the container's /data directory
# which is mapped to the host's DATA_DIR via Docker volume
${COMPOSE_BIN} -f "${COMPOSE_FILE}" exec -T vaultwarden /vaultwarden backup

# ============================================================================
# Step 2: Find and Copy New Backup Files
# ============================================================================

# The backup files are created in the DATA_DIR on the host (via volume mount)
host_backup_root="${DATA_DIR}"
if [[ ! -d "${host_backup_root}" ]]; then
  fail "Expected backup artefacts directory '${host_backup_root}' was not created"
fi

# Find all database backup files created after the marker file
# This ensures we only process files created by the current backup run
mapfile -t produced_files < <(find "${host_backup_root}" -maxdepth 1 -type f -name "${BACKUP_PATTERN}" -newer "${marker}" | sort)

# Verify that at least one backup file was created
if [[ ${#produced_files[@]} -eq 0 ]]; then
  fail "No new backup artefact detected in ${host_backup_root}"
fi

log "Detected ${#produced_files[@]} new backup artefact(s)"

# Track the last backup file for remote sync
last_backup=""

# Process each backup file (usually just one SQLite backup)
for src in "${produced_files[@]}"; do
  base="$(basename "${src}")"
  dest="${LOCAL_BACKUP_DIR}/${base}"

  # Optional: Encrypt the backup file if ENCRYPT_CMD is set
  if [[ -n "${ENCRYPT_CMD}" ]]; then
    tmp_out="${dest}.enc.in-progress"
    log "Encrypting ${base}"
    if env LAST_BACKUP_SOURCE="${src}" ${ENCRYPT_CMD} < "${src}" > "${tmp_out}"; then
      mv -f "${tmp_out}" "${dest}.enc"
      dest="${dest}.enc"
    else
      rm -f "${tmp_out}"
      fail "Encryption command failed for ${base}"
    fi
  else
    # Copy the backup file to local backup directory
    log "Copying ${base} to local backup dir"
    cp -a "${src}" "${dest}"
  fi

  # Remember this file for potential remote upload
  last_backup="${dest}"
done

# ============================================================================
# Step 3: Create Compressed Archive of All Vaultwarden Data
# ============================================================================

archive_path=""
# Only create archive if ARCHIVE_ENABLED is set to true
if is_truthy "${ARCHIVE_ENABLED}"; then
  # Generate timestamp for unique archive filename
  timestamp="$(date '+%Y%m%d_%H%M%S')"
  archive_basename="${ARCHIVE_PREFIX}_${timestamp}.tar.gz"
  archive_path="${LOCAL_BACKUP_DIR}/${archive_basename}"
  tmp_archive="${archive_path}.in-progress"

  # Get parent directory and basename for tar command
  # e.g., if DATA_DIR is /mnt/ssd/nas/bitwarden-data/vaultwarden
  # parent_dir will be /mnt/ssd/nas/bitwarden-data
  # data_basename will be vaultwarden
  parent_dir="$(dirname "${DATA_DIR}")"
  data_basename="$(basename "${DATA_DIR}")"

  # Build tar command with compression
  tar_cmd=(tar --create --gzip --file "${tmp_archive}" --directory "${parent_dir}")

  # Add exclusions (e.g., exclude backups subdirectory to avoid recursion)
  IFS=':' read -r -a archive_excludes <<< "${ARCHIVE_EXCLUDES}"
  for rel_path in "${archive_excludes[@]}"; do
    rel_path_trimmed="${rel_path//[[:space:]]/}"
    if [[ -n "${rel_path_trimmed}" ]]; then
      tar_cmd+=(--exclude="${data_basename}/${rel_path_trimmed}")
    fi
  done

  # Add the directory to archive
  tar_cmd+=("${data_basename}")

  # Create the compressed archive
  log "Archiving ${DATA_DIR} -> ${archive_basename}"
  if "${tar_cmd[@]}"; then
    # Move the completed archive to its final location
    mv -f "${tmp_archive}" "${archive_path}"
    # Update last_backup to point to the archive (this will be uploaded to GCS)
    last_backup="${archive_path}"
  else
    rm -f "${tmp_archive}"
    fail "Failed to create archive ${archive_basename}"
  fi
fi

# ============================================================================
# Step 4: Clean Up Old Local Backups
# ============================================================================

# Delete local backup files older than RETENTION_DAYS
if [[ -n "${RETENTION_DAYS}" ]]; then
  log "Pruning local backups older than ${RETENTION_DAYS} day(s)"
  # Find and delete files in backup directory older than RETENTION_DAYS
  # -mtime +N means files modified more than N days ago
  find "${LOCAL_BACKUP_DIR}" -maxdepth 1 -type f -mtime +"${RETENTION_DAYS}" -print -delete || true
fi

# ============================================================================
# Step 5: Upload to Remote Storage (GCS)
# ============================================================================

# If a remote sync command is configured and we have a backup file to upload
if [[ -n "${REMOTE_SYNC_CMD}" && -n "${last_backup}" ]]; then
  log "Running remote sync command"

  # Write the remote sync command to a temporary script file
  # This allows for complex commands with variables
  cmd_script="$(mktemp)"
  printf '%s\n' "${REMOTE_SYNC_CMD}" > "${cmd_script}"

  # Execute the remote sync command with environment variables
  # LAST_BACKUP: Path to the backup file to upload
  # DATA_DIR: Path to the Vaultwarden data directory
  if ! env LAST_BACKUP="${last_backup}" DATA_DIR="${DATA_DIR}" bash "${cmd_script}"; then
    rm -f "${cmd_script}"
    fail "Remote sync command failed"
  fi

  # Clean up the temporary script
  rm -f "${cmd_script}"
fi

# ============================================================================
# Backup Complete
# ============================================================================

log "Backup routine completed successfully"
