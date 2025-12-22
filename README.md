# docker-template

A minimal starter template for organizing a Docker Compose project.

This repository provides a basic directory layout and helper scripts to manage one or more Compose stacks. It's intended to maintain compose files and folder structure only — it does not track secrets (e.g. .env files, credentials) unless you explicitly add them to git.

**What's included**
- `dc.sh`: batch controller to run `docker compose` commands in child folders.
- `backup.sh`: optional Borg-based backup script for the stack directory (configurable via `.env`).
- `get-templates.sh`: helper intended to fetch or update template compose files (in progress).

**Quickstart**
- Clone the repo:

```sh
git clone https://github.com/kyle-mckay/docker-template.git docker
cd docker
```

- Make the controller script executable (optional):

```sh
chmod +x dc.sh
```

- Use the batch controller to run compose commands in all child stacks:

```sh
./dc.sh up        # start stacks detached (-d)
./dc.sh down      # stop stacks
./dc.sh pull      # pull images
```

**Using the backup script**
- `backup.sh` is a convenience wrapper around Borg to snapshot the stack directory. It reads configuration from `.env` (copy `.env.template` -> `.env` and edit values).
- Requirements: install `borgbackup` on the host.
- Common usage:

```sh
# make a .env from the template and edit paths/settings
cp .env.template .env
# run backup (will run preflight checks, bring stacks down/up, and run borg)
./backup.sh
# update the script from upstream
./backup.sh --update
```

Notes:
- By default `backup.sh` is configured for local mode; review and edit `.env` before running.
- The backup script will backup *does not* exclude `.env` files during backup — ensure any sensitive data is added to the exclusion variable out of the repository or handled securely.

## Environment variables (`.env.template`)

Copy `.env.template` to `.env` and edit as needed. Below are the variables present in `.env.template` and their purpose:

- `CREATE_DIRS`: (true|false) Allow the script to create missing directories.
- `BACKUP_SOURCE`: Path to the directory to back up (default: script directory).
- `BACKUP_MODE`: Backup mode, e.g. `local` (other modes not yet supported).
- `BORG_REPO`: Path to the Borg repository (local path or remote spec depending on `BACKUP_MODE`).
- `BORG_ARCHIVE_NAME`: Base name for archives created by Borg (timestamp appended by script).
- `LOG_LEVEL`: Logging verbosity (`TRACE`, `DEBUG`, `INFO`, `WARN`, `ERROR`).
- `DC_BATCH_CONTROLLER`: Path to the `dc.sh` batch controller used for bringing stacks up/down.
- `SAVE_LOGS`: (true|false) Whether to save script output to log files.
- `LOG_DIR`: Directory where logs are written when `SAVE_LOGS` is enabled.
- `LOG_FILE`: Log filename; defaults to a name based on the archive/timestamp.
- `LOG_TIMESTAMP_FORMAT`: Format string for timestamps in logs (e.g. `%F %T`).
- `LOG_ENABLE_COLORS`: (true|false) Enable colored log output.
- `BORG_ENCRYPTION`: Borg encryption mode (`none` or `repokey`).
- `BORG_REPO_PASSPHRASE`: Passphrase for Borg when using encryption (keep this secret — do not commit if using plain text).
- `BORG_COMPRESSION`: Compression setting for Borg (e.g. `lz4`, `zstd,3`, `zlib,6`, `none`).
- `BORG_PROGRESS_BAR`: (true|false) Show Borg progress bar during create.
- `BORG_LIST`: (true|false) Have Borg list files as it archives them.
- `BORG_STATS`: (true|false) Show Borg stats after backup.
- `EXCLUDE_PATTERNS`: Array of shell patterns to exclude from the backup (use this to omit secrets, logs, caches, etc.).
- `PERFORM_URL_HEALTHCHECK`: (true|false) Whether to ping a healthcheck URL after backup.
- `HEALTHCHECK_URL`: URL to call when `PERFORM_URL_HEALTHCHECK` is true.
- `HEALTHCHECK_DELAY`: Number in seconds to delay the execution of the healthcheck. Best used if the backup brings down the healthcheck service to allow time to restart.
- `CHOWN_AFTER`: (true|false) If true, change ownership of created files to `OWNER_UID`/`OWNER_GID`.
- `OWNER_UID`: Numeric UID to chown files to when `CHOWN_AFTER` is enabled.
- `OWNER_GID`: Numeric GID to chown files to when `CHOWN_AFTER` is enabled.

Important:
- Do not commit secrets or passphrases to the repository. If you must store sensitive values for automation, use a secure secret manager or keep them out of git and set them in the environment or a protected configuration store.

See `.env.template` for default values and further comments.
