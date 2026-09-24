# Vaultwarden Backup Automation

This repository now includes a host-side helper script that triggers the built-in Vaultwarden backup routine, keeps a local history of the artefacts, optionally compresses the whole data directory, and can encrypt and/or ship the results to remote storage. By default, the copied artefacts land in `backups/` under the project directory.

## Files

- `scripts/run-backup-upload-to-gcs.sh` – main entry point called by cron; executes backup, GCS upload, and Telegram notification
- `scripts/vaultwarden-backup.sh` – automation script creating DB backup and archiving data directory
- `scripts/upload_to_gcs.sh` – uploads backup tarball to Google Cloud Storage with retention policies
- `scripts/notify-backup.py` – sends backup execution status (success/failure) to Telegram via Bot API
- `scripts/restore_from_gcs.sh` – utility to restore Vaultwarden data from GCS backups

## Prerequisites

- Docker Compose access to the Vaultwarden container (`vaultwarden` service name in `docker-compose.yml`)
- Google Cloud SDK (`gcloud`) with a valid service account key
- Python 3 standard library (no pip dependencies required for Telegram notifications)
- The Vaultwarden data volume mounted on the host at `/home/shampad/bitwarden-data/vaultwarden`

## Configuration

The script exposes a few environment variables so you can tailor behaviour without editing the file:

| Variable | Default | Purpose |
| --- | --- | --- |
| `DOCKER_COMPOSE_BIN` | `docker compose` | Override if your host still uses the legacy `docker-compose` binary |
| `VAULTWARDEN_DATA_DIR` | `/mnt/ssd/nas/bitwarden-data/vaultwarden` | Location of the Vaultwarden data volume on the host |
| `VAULTWARDEN_BACKUP_DIR` | `<project>/backups` | Where the script stores copies (or encrypted copies) of each new backup |
| `VAULTWARDEN_BACKUP_PATTERN` | `db_*.sqlite3` | File glob matched after each run to gather new artefacts |
| `VAULTWARDEN_ARCHIVE_ENABLED` | `true` | When truthy, compress the entire data directory after the DB snapshot |
| `VAULTWARDEN_ARCHIVE_PREFIX` | `vaultwarden-data` | Prefix used for the generated tarball name |
| `VAULTWARDEN_ARCHIVE_EXCLUDES` | `backups` | Colon-separated relative paths inside the data dir to exclude from the archive |
| `VAULTWARDEN_RETENTION_DAYS` | `7` | Number of days to retain files in the local backup directory (use empty string to skip pruning) |
| `VAULTWARDEN_ENCRYPT_CMD` | _unset_ | Optional encryption command that reads from STDIN and writes the encrypted blob to STDOUT |
| `VAULTWARDEN_REMOTE_SYNC_CMD` | _unset_ | Optional command to push the most recent backup to remote storage |

During execution the following helper variables are exported for hooks:

- `LAST_BACKUP_SOURCE` – absolute path of the file produced by Vaultwarden (before encryption)
- `LAST_BACKUP` – absolute path of the final artefact stored in `VAULTWARDEN_BACKUP_DIR`
- `DATA_DIR` – host data directory (same as `VAULTWARDEN_DATA_DIR`)

## Usage examples

Trigger a one-off backup:

```bash
./scripts/vaultwarden-backup.sh
```

Encrypt backups with GPG (public key already imported for `backup@example.com`):

```bash
VAULTWARDEN_ENCRYPT_CMD='gpg --batch --yes --trust-model always --recipient backup@example.com --encrypt' \
  ./scripts/vaultwarden-backup.sh
```

Sync the most recent backup to an `rclone` remote:

```bash
VAULTWARDEN_REMOTE_SYNC_CMD='rclone copy "$LAST_BACKUP" b2:vaultwarden-offsite/' \
  ./scripts/vaultwarden-backup.sh
```

Combine both encryption and remote sync:

```bash
VAULTWARDEN_ENCRYPT_CMD='age -r your-age-recipient' \
VAULTWARDEN_REMOTE_SYNC_CMD='rsync -az "$LAST_BACKUP" backup@192.0.2.10:/srv/vaultwarden/' \
  ./scripts/vaultwarden-backup.sh
```

Archive the full data directory and send the tarball to Google Drive via `rclone` (remote named `gdrive`):

```bash
VAULTWARDEN_REMOTE_SYNC_CMD='rclone copy "$LAST_BACKUP" gdrive:vaultwarden-nightly/' \
  ./scripts/vaultwarden-backup.sh
```

Upload directly with the bundled Python helper (personal Drive example using OAuth tokens stored under `env/`):

```bash
VAULTWARDEN_REMOTE_SYNC_CMD='python3 scripts/upload_to_gdrive.py --auth oauth --credentials /home/<user>/Desktop/projects/bitwarden-password-manager/env/client_secret.json --token /home/<user>/Desktop/projects/bitwarden-password-manager/env/gdrive-token.json --folder-id <drive-folder-id> "$LAST_BACKUP"' \
  ./scripts/vaultwarden-backup.sh
```

Add `--keep-days 7` (and optionally `--keep-prefix vaultwarden-data`) so the helper prunes remote files older than a week:

```bash
VAULTWARDEN_REMOTE_SYNC_CMD='python3 scripts/upload_to_gdrive.py --auth oauth --credentials /home/<user>/Desktop/projects/bitwarden-password-manager/env/client_secret.json --token /home/<user>/Desktop/projects/bitwarden-password-manager/env/gdrive-token.json --folder-id <drive-folder-id> --keep-days 7 "$LAST_BACKUP"' \
  ./scripts/vaultwarden-backup.sh
```

### Google Drive helper setup

1. Create a Google Cloud project and enable the Drive API.
2. Decide on the auth model:
   - **Service account:** create a key JSON in `env/service_account.json` and grant the account access to a shared drive/folder (service accounts lack personal storage).
   - **Personal OAuth:** create an OAuth Desktop client and download its JSON to `env/client_secret.json`.
3. Install prerequisites: `python3 -m pip install --break-system-packages google-api-python-client google-auth google-auth-httplib2 google-auth-oauthlib`.
4. For OAuth, the first run spawns a browser to collect consent and stores a refresh token (default `<client secret>.token.json` or the explicit `--token` path).
5. Use the helper as shown above; add `--replace` if you want to overwrite files with the same name and `--keep-days N`/`--keep-prefix prefix` to prune older remote backups.

## Scheduling options

### Cron

Install a crontab entry under the account that has Docker access:

```cron
# Run every day at 01:15, logging to syslog
15 1 * * * /home/<user>/Desktop/projects/bitwarden-password-manager/scripts/vaultwarden-backup.sh >> /var/log/vaultwarden-backup.log 2>&1
```

If you need custom environment overrides, wrap the call in a small shell script (e.g. `/usr/local/sbin/vaultwarden-backup`) that exports them before invoking the helper, then reference that wrapper from cron.

### systemd timer

For tighter control add a `vaultwarden-backup.service` and matching timer:

`/etc/systemd/system/vaultwarden-backup.service`
```ini
[Unit]
Description=Vaultwarden backup

[Service]
Type=oneshot
Environment=DOCKER_COMPOSE_BIN=docker\ compose
Environment=VAULTWARDEN_ENCRYPT_CMD=gpg --batch --yes --trust-model always --recipient backup@example.com --encrypt
Environment=VAULTWARDEN_REMOTE_SYNC_CMD=rclone copy "$LAST_BACKUP" b2:vaultwarden-offsite/
WorkingDirectory=/home/<user>/Desktop/projects/bitwarden-password-manager
ExecStart=/home/<user>/Desktop/projects/bitwarden-password-manager/scripts/vaultwarden-backup.sh
```

`/etc/systemd/system/vaultwarden-backup.timer`
```ini
[Unit]
Description=Run Vaultwarden backup nightly

[Timer]
OnCalendar=*-*-* 01:15:00
Persistent=true

[Install]
WantedBy=timers.target
```

Then enable and start:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now vaultwarden-backup.timer
```

## Off-site strategy

1. Pick a remote target (another NAS, VPS, cloud bucket, etc.).
2. Configure the tooling required (`ssh-keygen` + `rsync`, `rclone config`, etc.).
3. Add the corresponding command to `VAULTWARDEN_REMOTE_SYNC_CMD`.
4. Periodically test restores on a non-production instance to verify backups.

## Restore checklist

1. Stop Vaultwarden (`docker compose down`).
2. Decrypt the desired backup if applicable.
3. Extract the archive into the data directory (replacing `attachments`, `sends`, `config.json`, SQLite files, etc.).
4. Remove any stale `db.sqlite3-wal` file if you used `.backup` or the built-in backup command.
5. Start Vaultwarden (`docker compose up -d`).

Remember to practice a restore dry-run so you understand the process before an emergency.
