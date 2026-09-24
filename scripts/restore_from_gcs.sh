#!/usr/bin/env bash
# ============================================================================
# Vaultwarden GCS Restore Script
# Restores Vaultwarden data from a Google Cloud Storage backup archive
# ============================================================================

set -euo pipefail

# Ensure standard tools and gcloud are in PATH
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${HOME}/google-cloud-sdk/bin:${HOME}/.local/bin:${PATH:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Load environment configuration if available
if [[ -f "${PROJECT_ROOT}/env/vaultwarden.env" ]]; then
  set -a
  # shellcheck source=/dev/null
  . "${PROJECT_ROOT}/env/vaultwarden.env"
  set +a
fi

# ============================================================================
# Defaults and Settings
# ============================================================================

BUCKET_NAME="${GCS_BUCKET_NAME:-home-server-ss}"
BUCKET_PATH="${GCS_BUCKET_PATH:-bitwarden-backups}"
DATA_DIR="${VAULTWARDEN_DATA_DIR:-/home/shampad/bitwarden-data/vaultwarden}"
SERVICE_ACCOUNT_KEY="${GCS_SERVICE_ACCOUNT_KEY:-${PROJECT_ROOT}/env/service_account.json}"
COMPOSE_FILE="${PROJECT_ROOT}/docker-compose.yml"
COMPOSE_BIN="${DOCKER_COMPOSE_BIN:-docker compose}"

AUTO_CONFIRM=false
SKIP_SAFETY_BACKUP=false
ACTION_LIST=false
SPECIFIC_TARGET=""

# ============================================================================
# Helper Functions
# ============================================================================

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

fail() {
  log "ERROR: $*" >&2
  exit 1
}

usage() {
  cat << 'EOF'
Vaultwarden GCS Restore Utility

Usage:
  ./scripts/restore_from_gcs.sh [OPTIONS] [BACKUP_NAME_OR_URI]

Options:
  -l, --list        List available backups in the GCS bucket and exit
  --latest          Restore the most recent backup in GCS (default)
  -y, --yes         Skip interactive confirmation prompts
  --no-backup       Skip creating a pre-restore safety snapshot of the live data dir
  -h, --help        Show this help message

Examples:
  # List all available backups
  ./scripts/restore_from_gcs.sh --list

  # Restore the latest backup interactively
  ./scripts/restore_from_gcs.sh

  # Restore the latest backup automatically without prompts
  ./scripts/restore_from_gcs.sh --latest -y

  # Restore a specific backup by filename
  ./scripts/restore_from_gcs.sh vaultwarden-data_20260924_011501.tar.gz -y

  # Restore from a full GCS URI
  ./scripts/restore_from_gcs.sh gs://home-server-ss/bitwarden-backups/vaultwarden-data_20260924_011501.tar.gz -y
EOF
}

# ============================================================================
# Parse Arguments
# ============================================================================

while [[ $# -gt 0 ]]; do
  case "$1" in
    -l|--list)
      ACTION_LIST=true
      shift
      ;;
    --latest)
      SPECIFIC_TARGET="latest"
      shift
      ;;
    -y|--yes)
      AUTO_CONFIRM=true
      shift
      ;;
    --no-backup)
      SKIP_SAFETY_BACKUP=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      fail "Unknown option: $1 (run with --help for usage)"
      ;;
    *)
      if [[ -z "${SPECIFIC_TARGET}" ]]; then
        SPECIFIC_TARGET="$1"
      else
        fail "Multiple backup targets specified: '${SPECIFIC_TARGET}' and '$1'"
      fi
      shift
      ;;
  esac
done

# ============================================================================
# Pre-flight Checks
# ============================================================================

if ! command -v gcloud >/dev/null 2>&1; then
  fail "gcloud CLI is not installed or not in PATH"
fi

if ! command -v tar >/dev/null 2>&1; then
  fail "tar utility is required"
fi

if ! command -v ${COMPOSE_BIN%% *} >/dev/null 2>&1; then
  fail "docker compose command '${COMPOSE_BIN}' is required"
fi

if [[ ! -f "${COMPOSE_FILE}" ]]; then
  fail "Could not locate docker-compose.yml at ${COMPOSE_FILE}"
fi

# ============================================================================
# Authenticate with Google Cloud
# ============================================================================

if [[ -f "${SERVICE_ACCOUNT_KEY}" ]]; then
  log "Authenticating with service account: ${SERVICE_ACCOUNT_KEY}"
  gcloud auth activate-service-account --key-file="${SERVICE_ACCOUNT_KEY}" --quiet
elif gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | grep -q "@"; then
  ACTIVE_ACCT=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | head -n1)
  log "Using existing active gcloud account: ${ACTIVE_ACCT}"
else
  fail "Service account key not found at ${SERVICE_ACCOUNT_KEY} and no active gcloud account"
fi

GCS_PREFIX="gs://${BUCKET_NAME}/${BUCKET_PATH}/"

# ============================================================================
# List Backups Action
# ============================================================================

if [[ "${ACTION_LIST}" = true ]]; then
  log "Available backups in ${GCS_PREFIX}:"
  echo "--------------------------------------------------------------------------------"
  gcloud storage ls --long "${GCS_PREFIX}" 2>/dev/null | grep "gs://" | sort -k2,2 -r || true
  echo "--------------------------------------------------------------------------------"
  exit 0
fi

# ============================================================================
# Resolve Target Backup
# ============================================================================

SELECTED_BACKUP_URI=""

if [[ -z "${SPECIFIC_TARGET}" || "${SPECIFIC_TARGET}" == "latest" ]]; then
  log "Locating latest backup in ${GCS_PREFIX}..."
  # List files, filter for gs://, sort to pick the newest by name (contains timestamp)
  NEWEST_URI=$(gcloud storage ls "${GCS_PREFIX}" 2>/dev/null | grep "gs://" | grep -E '\.tar\.gz$' | sort | tail -n 1 || true)
  if [[ -z "${NEWEST_URI}" ]]; then
    fail "No backup archives (*.tar.gz) found in ${GCS_PREFIX}"
  fi
  SELECTED_BACKUP_URI="${NEWEST_URI}"
elif [[ "${SPECIFIC_TARGET}" == gs://* ]]; then
  SELECTED_BACKUP_URI="${SPECIFIC_TARGET}"
else
  # Treat as filename relative to bucket path
  SELECTED_BACKUP_URI="gs://${BUCKET_NAME}/${BUCKET_PATH}/${SPECIFIC_TARGET}"
fi

# Verify the object exists in GCS
log "Verifying remote backup object: ${SELECTED_BACKUP_URI}"
if ! gcloud storage ls "${SELECTED_BACKUP_URI}" >/dev/null 2>&1; then
  fail "Backup object '${SELECTED_BACKUP_URI}' not found in GCS"
fi

# ============================================================================
# Confirmation Prompt
# ============================================================================

echo ""
echo "================================================================================"
echo " VAULTWARDEN RESTORE SUMMARY"
echo "================================================================================"
echo " Target GCS Backup  : ${SELECTED_BACKUP_URI}"
echo " Destination Data Dir: ${DATA_DIR}"
echo " Compose File       : ${COMPOSE_FILE}"
echo " Safety Backup      : $([[ "${SKIP_SAFETY_BACKUP}" = true ]] && echo "Disabled" || echo "Enabled")"
echo "================================================================================"
echo ""

if [[ "${AUTO_CONFIRM}" != true ]]; then
  read -r -p "Are you sure you want to proceed with this restore? [y/N]: " confirm
  case "${confirm}" in
    y|Y|yes|YES) ;;
    *)
      log "Restore aborted by user."
      exit 0
      ;;
  esac
fi

# ============================================================================
# Download and Verify Backup
# ============================================================================

SCRATCH_DIR="${PROJECT_ROOT}/scratch"
mkdir -p "${SCRATCH_DIR}"
TMP_WORK_DIR="$(mktemp -d "${SCRATCH_DIR}/vaultwarden-restore.XXXXXX")"
cleanup() {
  if [[ -d "${TMP_WORK_DIR}" ]]; then
    rm -rf "${TMP_WORK_DIR}"
  fi
}
trap cleanup EXIT INT TERM

BACKUP_FILENAME="$(basename "${SELECTED_BACKUP_URI}")"
LOCAL_ARCHIVE="${TMP_WORK_DIR}/${BACKUP_FILENAME}"

log "Downloading ${SELECTED_BACKUP_URI} -> ${LOCAL_ARCHIVE}..."
gcloud storage cp "${SELECTED_BACKUP_URI}" "${LOCAL_ARCHIVE}"

log "Verifying integrity of downloaded archive..."
if ! tar -tzf "${LOCAL_ARCHIVE}" >/dev/null 2>&1; then
  fail "Archive verification failed: ${LOCAL_ARCHIVE} is corrupted or not a valid gzip tarball"
fi

# Determine directory structure inside archive
FIRST_ENTRY=""
if command -v python3 >/dev/null 2>&1; then
  FIRST_ENTRY="$(python3 -c "import tarfile; t=tarfile.open('${LOCAL_ARCHIVE}'); m=t.next(); print(m.name if m else ''); t.close()" 2>/dev/null || true)"
fi
if [[ -z "${FIRST_ENTRY}" ]]; then
  FIRST_ENTRY="$(tar -ztf "${LOCAL_ARCHIVE}" 2>/dev/null | awk 'NR==1{print}' || true)"
fi
log "Archive structure sample: ${FIRST_ENTRY}"

STRIP_COMPONENTS=0
if [[ "${FIRST_ENTRY}" =~ ^(data|vaultwarden)(/|$) ]]; then
  STRIP_COMPONENTS=1
  log "Archive contains top-level prefix ('${BASH_REMATCH[1]}'). Extracting with --strip-components=1"
fi

# ============================================================================
# Step 1: Pre-restore Safety Backup of Existing Data
# ============================================================================

if [[ -d "${DATA_DIR}" && -n "$(ls -A "${DATA_DIR}" 2>/dev/null)" ]]; then
  if [[ "${SKIP_SAFETY_BACKUP}" != true ]]; then
    SAFETY_TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
    SAFETY_ARCHIVE="${PROJECT_ROOT}/backups/vaultwarden-pre-restore_${SAFETY_TIMESTAMP}.tar.gz"
    mkdir -p "${PROJECT_ROOT}/backups"
    log "Creating pre-restore safety backup of live data -> ${SAFETY_ARCHIVE}"
    tar -czf "${SAFETY_ARCHIVE}" -C "$(dirname "${DATA_DIR}")" "$(basename "${DATA_DIR}")"
    log "Safety backup created: ${SAFETY_ARCHIVE}"
  else
    log "Skipping safety backup as requested (--no-backup)"
  fi
fi

# ============================================================================
# Step 2: Stop Vaultwarden Container
# ============================================================================

log "Checking if Vaultwarden container is running..."
if ${COMPOSE_BIN} -f "${COMPOSE_FILE}" ps --status running --format '{{.Names}}' | grep -q "vaultwarden"; then
  log "Stopping Vaultwarden container..."
  ${COMPOSE_BIN} -f "${COMPOSE_FILE}" stop vaultwarden
fi

# ============================================================================
# Step 3: Extract Archive into Data Directory
# ============================================================================

mkdir -p "${DATA_DIR}"

log "Extracting backup archive into ${DATA_DIR}..."
EXTRACT_DIR="${TMP_WORK_DIR}/extracted"
mkdir -p "${EXTRACT_DIR}"

if [[ "${STRIP_COMPONENTS}" -eq 1 ]]; then
  tar -xzf "${LOCAL_ARCHIVE}" --strip-components=1 --exclude='*db_*.sqlite3*' -C "${EXTRACT_DIR}"
else
  tar -xzf "${LOCAL_ARCHIVE}" --exclude='*db_*.sqlite3*' -C "${EXTRACT_DIR}"
fi

# Flatten nested data or vaultwarden directory if present
for nested_dir in data vaultwarden; do
  if [[ -d "${EXTRACT_DIR}/${nested_dir}" && -f "${EXTRACT_DIR}/${nested_dir}/db.sqlite3" ]]; then
    log "Flattening nested ${nested_dir}/ into root of extract directory"
    cp -a "${EXTRACT_DIR}/${nested_dir}/." "${EXTRACT_DIR}/"
    rm -rf "${EXTRACT_DIR}/${nested_dir}"
  fi
done

# Clean up any ancient in-container snapshot dumps that might have been packaged
rm -f "${EXTRACT_DIR}"/db_*.sqlite3* "${EXTRACT_DIR}"/*.tmp

# Remove stale SQLite WAL and SHM locks to prevent locks on startup
rm -f "${EXTRACT_DIR}/db.sqlite3-wal" "${EXTRACT_DIR}/db.sqlite3-shm"

log "Syncing extracted files into ${DATA_DIR}..."
# Clean out existing data in DATA_DIR to ensure a clean restore state
rm -rf "${DATA_DIR:?}"/*

# Copy extracted files into DATA_DIR
cp -a "${EXTRACT_DIR}/." "${DATA_DIR}/"

# Ensure proper permissions
chmod 750 "${DATA_DIR}"
find "${DATA_DIR}" -type f -exec chmod 640 {} + 2>/dev/null || true
find "${DATA_DIR}" -type d -exec chmod 750 {} + 2>/dev/null || true

log "Data directory contents after restore:"
ls -la "${DATA_DIR}"

# ============================================================================
# Step 4: Start Vaultwarden and Health Check
# ============================================================================

log "Starting Vaultwarden container..."
${COMPOSE_BIN} -f "${COMPOSE_FILE}" up -d vaultwarden

log "Waiting for Vaultwarden to initialize..."
HEALTHY=false
for i in {1..30}; do
  if curl -s -f -o /dev/null "http://127.0.0.1:8080/alive" 2>/dev/null || \
     curl -s -f -o /dev/null "http://127.0.0.1:8080/" 2>/dev/null; then
    HEALTHY=true
    break
  fi
  sleep 1
done

if [[ "${HEALTHY}" = true ]]; then
  log "SUCCESS: Vaultwarden is up and healthy on http://127.0.0.1:8080!"
else
  log "WARNING: Vaultwarden did not respond on http://127.0.0.1:8080 within 30 seconds."
  log "Checking container status:"
  ${COMPOSE_BIN} -f "${COMPOSE_FILE}" ps
  log "Last 20 container logs:"
  ${COMPOSE_BIN} -f "${COMPOSE_FILE}" logs --tail 20 vaultwarden
  exit 1
fi

log "Restore from ${SELECTED_BACKUP_URI} completed successfully!"
