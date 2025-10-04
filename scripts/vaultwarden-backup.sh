#!/usr/bin/env bash
# shellcheck disable=SC2086

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMPOSE_BIN="${DOCKER_COMPOSE_BIN:-docker compose}"
COMPOSE_FILE="${PROJECT_ROOT}/docker-compose.yml"

DATA_DIR="${VAULTWARDEN_DATA_DIR:-/mnt/ssd/nas/bitwarden-data/vaultwarden}"
LOCAL_BACKUP_DIR="${VAULTWARDEN_BACKUP_DIR:-${PROJECT_ROOT}/backups}"
BACKUP_PATTERN="${VAULTWARDEN_BACKUP_PATTERN:-db_*.sqlite3}"
ARCHIVE_ENABLED="${VAULTWARDEN_ARCHIVE_ENABLED:-true}"
ARCHIVE_PREFIX="${VAULTWARDEN_ARCHIVE_PREFIX:-vaultwarden-data}"
ARCHIVE_EXCLUDES="${VAULTWARDEN_ARCHIVE_EXCLUDES:-backups}"
RETENTION_DAYS="${VAULTWARDEN_RETENTION_DAYS:-7}"
REMOTE_SYNC_CMD="${VAULTWARDEN_REMOTE_SYNC_CMD:-}"
ENCRYPT_CMD="${VAULTWARDEN_ENCRYPT_CMD:-}"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

fail() {
  log "ERROR: $*" >&2
  exit 1
}

is_truthy() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|y|Y|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

if ! command -v ${COMPOSE_BIN%% *} >/dev/null 2>&1; then
  fail "docker compose (or docker-compose) is required"
fi

if [[ ! -f "${COMPOSE_FILE}" ]]; then
  fail "Could not locate docker-compose.yml at ${COMPOSE_FILE}"
fi

if [[ ! -d "${DATA_DIR}" ]]; then
  fail "Expected Vaultwarden data directory '${DATA_DIR}' does not exist"
fi

mkdir -p "${LOCAL_BACKUP_DIR}"

marker="$(mktemp)"
trap 'rm -f "${marker}"' EXIT

touch "${marker}"

log "Triggering Vaultwarden in-container backup"
${COMPOSE_BIN} -f "${COMPOSE_FILE}" exec -T vaultwarden /vaultwarden backup

host_backup_root="${DATA_DIR}"
if [[ ! -d "${host_backup_root}" ]]; then
  fail "Expected backup artefacts directory '${host_backup_root}' was not created"
fi

mapfile -t produced_files < <(find "${host_backup_root}" -maxdepth 1 -type f -name "${BACKUP_PATTERN}" -newer "${marker}" | sort)

if [[ ${#produced_files[@]} -eq 0 ]]; then
  fail "No new backup artefact detected in ${host_backup_root}"
fi

log "Detected ${#produced_files[@]} new backup artefact(s)"

last_backup=""
for src in "${produced_files[@]}"; do
  base="$(basename "${src}")"
  dest="${LOCAL_BACKUP_DIR}/${base}"
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
    log "Copying ${base} to local backup dir"
    cp -a "${src}" "${dest}"
  fi
  last_backup="${dest}"

done

archive_path=""
if is_truthy "${ARCHIVE_ENABLED}"; then
  timestamp="$(date '+%Y%m%d_%H%M%S')"
  archive_basename="${ARCHIVE_PREFIX}_${timestamp}.tar.gz"
  archive_path="${LOCAL_BACKUP_DIR}/${archive_basename}"
  tmp_archive="${archive_path}.in-progress"
  parent_dir="$(dirname "${DATA_DIR}")"
  data_basename="$(basename "${DATA_DIR}")"

  tar_cmd=(tar --create --gzip --file "${tmp_archive}" --directory "${parent_dir}")
  IFS=':' read -r -a archive_excludes <<< "${ARCHIVE_EXCLUDES}"
  for rel_path in "${archive_excludes[@]}"; do
    rel_path_trimmed="${rel_path//[[:space:]]/}"
    if [[ -n "${rel_path_trimmed}" ]]; then
      tar_cmd+=(--exclude="${data_basename}/${rel_path_trimmed}")
    fi
  done
  tar_cmd+=("${data_basename}")

  log "Archiving ${DATA_DIR} -> ${archive_basename}"
  if "${tar_cmd[@]}"; then
    mv -f "${tmp_archive}" "${archive_path}"
    last_backup="${archive_path}"
  else
    rm -f "${tmp_archive}"
    fail "Failed to create archive ${archive_basename}"
  fi
fi

if [[ -n "${RETENTION_DAYS}" ]]; then
  log "Pruning local backups older than ${RETENTION_DAYS} day(s)"
  find "${LOCAL_BACKUP_DIR}" -maxdepth 1 -type f -mtime +"${RETENTION_DAYS}" -print -delete || true
fi

if [[ -n "${REMOTE_SYNC_CMD}" && -n "${last_backup}" ]]; then
  log "Running remote sync command"
  cmd_script="$(mktemp)"
  printf '%s\n' "${REMOTE_SYNC_CMD}" > "${cmd_script}"
  if ! env LAST_BACKUP="${last_backup}" DATA_DIR="${DATA_DIR}" bash "${cmd_script}"; then
    rm -f "${cmd_script}"
    fail "Remote sync command failed"
  fi
  rm -f "${cmd_script}"
fi

log "Backup routine completed successfully"
