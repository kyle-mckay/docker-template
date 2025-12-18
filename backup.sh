#!/bin/bash

# Fail fast, treat unset variables as errors, and make pipelines fail on first failure
set -euo pipefail

# Backup script for Docker stack using Borg
#
# - Purpose: create a Borg archive of the Docker stack directory,
#   prune old backups and optionally ping a heartbeat endpoint.
# - Safety: script uses strict mode and quotes variables where practical.
# - Notes: Set `BACKUP_TYPE` to "local" to store repo on the same host.
#   For a remote repo (ssh) set `BACKUP_TYPE` accordingly and update `DST`.

#region Configuration
# Directory Settings
# Path to the folder you want backed up. Typically the directory that
# contains your `dc.sh` and docker stack files.
BACKUP_SOURCE="/full/path/to/source"

# Timestamp used for archive names. Format: YYYY-MM-DD_HH-MM-SS
TIMESTAMP=$(date +%F_%H-%M-%S)

# Logging configuration
# Levels: TRACE, DEBUG, INFO, WARN, ERROR
LOG_LEVEL="${LOG_LEVEL:-INFO}"   # default level; can be overridden via environment variable
LOG_TIMESTAMP_FORMAT="%F %T"     # timestamp format for logs
LOG_ENABLE_COLORS=true           # set to false to disable ANSI colors

BACKUP_MODE="local" # Options: "local" "ssh" "ftp"
# Borg repository destination.
# - For a local repo use a path like: /full/path/to/dest/repo
# - For a remote repo use an ssh path like: user@host:/path/to/repo
BORG_REPO="/full/path/to/dest/repo"

BORG_ENCRYPTION="none"   # e.g. "none" or "repokey"
BORG_REPO_PASSPHRASE="${BORG_REPO_PASSPHRASE-}"  # optional: passphrase/key when using repokey encryption
                                                 # to set environment variable use `export BORG_REPO_PASSPHRASE="your_secret_passphrase"
                                                 # if using sudo and env, preserve env with `sudo -E`
                                                 # you can also set your env in crontab as any other variable if running with root
BORG_COMPRESSION="lz4"    # Options: "" "lz4" "zstd,3" or "zlib,6"
BORG_PROGRESS_BAR=true    # Show progress bar during backup (true/false)
BORG_LIST=false            # List paths of files as they are backed up (true/false)
BORG_STATS=true           # Show statistics after backup (true/false)

# Skip patterns passed to Borg. These are shell globs and/or sh: patterns.
EXCLUDE_PATTERNS=(
    "**/@eaDir"
    "**/@tmp"
    "**/Plex Media Server/Cache"
    "**/Plex Media Server/Codecs"
    "**/Plex Media Server/Logs"
    "**/Plex Media Server/Updates"
    "**/Plex Media Server/Crash Reports"
    "**/Plex Media Server/Diagnostics"
    "**/Plex Media Server/*.pid"
    "**/*.log"
    "**/logs"
)

# Other Settings
# Optional healthcheck URL to ping after a successful run
PERFORM_URL_HEALTHCHECK=false
HEALTHCHECK_URL="http://example.com/your-healthcheck-endpoint"
CHOWN_AFTER=false
OWNER_UID=1000
OWNER_GID=1000
#endregion Configuration

#region Functions

# New: logging function
log() {
    local level="${1:-INFO}"
    shift || true
    local msg="$*"

    # Normalize level to uppercase
    level="${level^^}"

    # map level to numeric severity (lower is more verbose)
    local lvl_num
    case "$level" in
        TRACE) lvl_num=0 ;;
        DEBUG) lvl_num=1 ;;
        INFO)  lvl_num=2 ;;
        WARN|WARNING) lvl_num=3 ;;
        ERROR) lvl_num=4 ;;
        *) lvl_num=2 ;; # default INFO
    esac

    local cfg_num
    case "${LOG_LEVEL^^}" in
        TRACE) cfg_num=0 ;;
        DEBUG) cfg_num=1 ;;
        INFO)  cfg_num=2 ;;
        WARN|WARNING) cfg_num=3 ;;
        ERROR) cfg_num=4 ;;
        *) cfg_num=2 ;;
    esac

    # If message severity is lower (more verbose) than configured, skip
    if [[ "$lvl_num" -lt "$cfg_num" ]]; then
        return 0
    fi

    # Colors
    local clr_reset="\033[0m"
    local clr_info="\033[1;37m"   # bright white
    local clr_warn="\033[1;33m"   # bright yellow
    local clr_error="\033[1;31m"  # bright red
    local clr_debug="\033[1;34m"  # bright blue
    local clr_trace="\033[1;35m"  # bright magenta

    local color="$clr_info"
    case "$level" in
        TRACE) color="$clr_trace" ;;
        DEBUG) color="$clr_debug" ;;
        INFO)  color="$clr_info" ;;
        WARN|WARNING) color="$clr_warn" ;;
        ERROR) color="$clr_error" ;;
    esac

    # Timestamp
    local ts=""
    if [[ -n "$LOG_TIMESTAMP_FORMAT" ]]; then
        ts="$(date +"$LOG_TIMESTAMP_FORMAT") "
    fi

    # Compose output; send logs to stderr
    if [[ "$LOG_ENABLE_COLORS" == "true" ]]; then
        printf "%b%s[%s] %s%b\n" "$color" "$ts" "$level" "$msg" "$clr_reset" >&2
    else
        printf "%s[%s] %s\n" "$ts" "$level" "$msg" >&2
    fi
}

run_and_log() {
    # Usage:
    #   run_and_log <STDOUT_LEVEL> [<STDERR_LEVEL|SMART>] <command...>
    # Examples:
    #   run_and_log INFO borg prune ...                 # stderr -> ERROR (legacy behavior)
    #   run_and_log INFO SMART borg prune ...           # SMART mapping for stderr (downgrade known non-fatal lines)
    #
    # Runs the command with line-buffered output and routes stdout->log STDOUT_LEVEL.
    # STDERR handling:
    #   - If STDERR_LEVEL is "SMART", certain stderr lines are mapped to INFO/WARN based on content.
    #   - If STDERR_LEVEL is provided (e.g. DEBUG/WARN), all stderr lines use that level.
    #   - If not provided, stderr defaults to ERROR (legacy).
    local stdout_level="${1:-INFO}"; shift || true
    local stderr_mode="ERROR"
    # If next token is a level name or SMART, treat as stderr_mode
    if [[ "${1-}" =~ ^(TRACE|DEBUG|INFO|WARN|WARNING|ERROR|SMART)$ ]]; then
        stderr_mode="${1}"; shift || true
    fi
    local -a cmd=( "$@" )

    # Trace: environment snapshot useful for debugging (don't print secrets)
    log TRACE "run_and_log env: LOG_LEVEL=${LOG_LEVEL}, BORG_PROGRESS_BAR=${BORG_PROGRESS_BAR:-}, BORG_COMPRESSION=${BORG_COMPRESSION:-}, BORG_REPO=${BORG_REPO:-}, BORG_ENCRYPTION=${BORG_ENCRYPTION:-}, BORG_REPO_PASSPHRASE_SET=$( [[ -n "${BORG_REPO_PASSPHRASE:-}" ]] && echo yes || echo no )"

    # Detect borg create with progress requested: allow direct run to preserve TTY/progress.
    if [[ "${cmd[0]}" == "borg" && "${cmd[1]-}" == "create" && "${BORG_PROGRESS_BAR:-false}" == "true" ]]; then
        log DEBUG "Running interactive command: ${cmd[*]}"
        local start_ts=$(date +%s)
        "${cmd[@]}"
        local status=$?
        local end_ts=$(date +%s)
        local dur=$((end_ts - start_ts))
        log TRACE "Interactive command finished: ${cmd[*]} (exit=${status}, duration=${dur}s)"
        return $?
    fi

    log DEBUG "Running: ${cmd[*]} (stdout->${stdout_level}, stderr->${stderr_mode})"

    # Helper to classify stderr line under SMART rules
    _classify_stderr() {
        local line="$1"
        local low="${line,,}"   # lowercase for matching

        # Explicit error indicators -> ERROR
        if [[ "$low" =~ (error|failed|failure|cannot|permission denied|segmentation fault) ]]; then
            echo "ERROR"
            return
        fi

        # Warnings -> WARN
        if [[ "$low" =~ (level=warning|warning) ]]; then
            echo "WARN"
            return
        fi

        # Common benign status/summary messages -> INFO
        if [[ "$low" =~ (creating|created|starting|started|stopping|stopped|removing|removed|done|downloaded|keeping|pruning|pruned|skipping|skipped|already|up-to-date|up to date|kept archive) ]]; then
            echo "INFO"
            return
        fi

        # Many docker-compose outputs are indented status lines (e.g. "  Container foo  Stopped")
        # Treat such indented structured lines as INFO unless they contain error keywords (handled above).
        if [[ "$line" =~ ^[[:space:]]+[A-Za-z] ]]; then
            echo "INFO"
            return
        fi

        # Fallback -> ERROR
        echo "ERROR"
    }

    # Use stdbuf for line buffering where available. If stdbuf missing, fall back and note it.
    if command -v stdbuf >/dev/null 2>&1; then
        local runner=(stdbuf -oL -eL)
    else
        log TRACE "stdbuf not found; output may be buffered. Install coreutils for better realtime logging."
        local runner=()
    fi

    local start_ts=$(date +%s)
    ( exec "${runner[@]}" "${cmd[@]}" ) \
        > >( while IFS= read -r line; do log "${stdout_level}" "$line"; done ) \
        2> >( while IFS= read -r line; do
                  if [[ "${stderr_mode^^}" == "SMART" ]]; then
                      mapped="$(_classify_stderr "$line")"
                      log "${mapped}" "$line"
                  else
                      # explicit level provided (or default ERROR)
                      log "${stderr_mode}" "$line"
                  fi
              done )

    local status=$?
    local end_ts=$(date +%s)
    local dur=$((end_ts - start_ts))
    # Provide more verbose trace about execution duration and exit code
    if [[ $status -ne 0 ]]; then
        log DEBUG "Command exited with status $status: ${cmd[*]}"
    fi
    log TRACE "Command finished: ${cmd[*]} (exit=${status}, duration=${dur}s)"
    return $status
}

borg_init(){
    # Initialize the repository
    if [[ "$BACKUP_MODE" == "local" ]]; then
        # Create parent dir if it doesnt exist
        mkdir -p "$(dirname "$BORG_REPO")"
        if [[ -z "$BORG_REPO_PASSPHRASE" && "$BORG_ENCRYPTION" == "repokey" ]]; then
            log ERROR "Borg encryption enabled but passphrase is unreadable or null. Aborting creation of DIR."
            exit 1
        fi
        if [[ ! -d "$BORG_REPO" ]]; then
            # Using 'none' encryption for simplicity, or 'repokey' if you want a password
            log INFO "Creating borg repo"
            log DEBUG "borg init args: --encryption=${BORG_ENCRYPTION} repo=${BORG_REPO}"
            borg init --encryption="$BORG_ENCRYPTION" "$BORG_REPO"
            log INFO "Borg repo created"
        fi
        if [[ "$CHOWN_AFTER" == "true" ]]; then
            log DEBUG "Setting ownership ${OWNER_UID}:${OWNER_GID} on ${BORG_REPO}"
            chown -R $OWNER_UID:$OWNER_GID "$BORG_REPO"
        fi
    else
        log ERROR "BACKUP_MODE '$BACKUP_MODE' not implemented in this script."
        exit 1
    
    fi

    # Trace repository/encryption details (mask sensitive info)
    log TRACE "Borg repo present: $( [[ -d "$BORG_REPO" ]] && echo yes || echo no ), encryption=${BORG_ENCRYPTION}, passphrase_set=$( [[ -n "${BORG_REPO_PASSPHRASE:-}" ]] && echo yes || echo no )"

    # Verify compression variable
    case "$BORG_COMPRESSION" in
        lz4|zstd,[1-9]|zlib,[0-9]|none)
            log DEBUG "Compression set to $BORG_COMPRESSION"
            ;;
        *)
            log WARN "Invalid compression '$BORG_COMPRESSION'. Falling back to lz4."
             BORG_COMPRESSION="lz4"
             ;;
    esac

    # Verify Encryption settings
    if  [[ "$BORG_ENCRYPTION" == "repokey" && -z "$BORG_REPO_PASSPHRASE" ]]; then
        log ERROR "BORG_REPO_PASSPHRASE must be set when using repokey encryption."
        exit 1
    fi
}

makeCopy(){
    local archiveName=$1  # This will be "Docker-Stack"
    local borg_opts=()

    # Prepare Borg options
    ## Compression
    if [[ -n "$BORG_COMPRESSION" ]]; then
        borg_opts+=( "--compression" "$BORG_COMPRESSION" )
    fi

    ## Exclusions
    for skip in "${EXCLUDE_PATTERNS[@]}"; do
        borg_opts+=( "--exclude" "sh:$skip" )
    done

    ## Stats
    if [[ "$BORG_STATS" == "true" ]]; then
        borg_opts+=( "--stats" )
    fi

    ## Progress bar
    if [[ "$BORG_PROGRESS_BAR" == "true" ]]; then
        borg_opts+=( "--progress" )
    fi

    ## List files
    if [[ "$BORG_LIST" == "true" ]]; then
        borg_opts+=( "--list" )
    fi

    log INFO "Starting Borg snapshot for $BACKUP_SOURCE"
    log DEBUG "Borg options count: ${#borg_opts[@]}; excludes=${#EXCLUDE_PATTERNS[@]}"
    log TRACE "Borg opts: ${borg_opts[*]}"
    # show first few excludes for trace (don't spam)
    log TRACE "Excludes (sample): ${EXCLUDE_PATTERNS[@]:0:5}"

    # Execute the backup
    if [[ "${BORG_PROGRESS_BAR:-false}" == "true" ]]; then
        # Preserve TTY/progress output
        log DEBUG "Running borg create directly to preserve progress bar"
        log TRACE "borg create ${borg_opts[*]} ${BORG_REPO}::${archiveName}-$TIMESTAMP ${BACKUP_SOURCE}"
        local start_ts=$(date +%s)
        borg create "${borg_opts[@]}" "${BORG_REPO}::${archiveName}-$TIMESTAMP" "${BACKUP_SOURCE}"
        local status=$?
        local end_ts=$(date +%s)
        log TRACE "borg create finished (interactive) exit=${status}, duration=$((end_ts-start_ts))s"
    else
        # Use SMART stderr mapping to avoid treating non-fatal warnings/status lines as ERROR
        log TRACE "borg create (wrapped) ${borg_opts[*]} ${BORG_REPO}::${archiveName}-$TIMESTAMP ${BACKUP_SOURCE}"
        run_and_log INFO SMART borg create "${borg_opts[@]}" "${BORG_REPO}::${archiveName}-$TIMESTAMP" "${BACKUP_SOURCE}"
    fi

    if [[ "$CHOWN_AFTER" == "true" ]]; then
            log DEBUG "Chowning borg repo to ${OWNER_UID}:${OWNER_GID}"
            chown -R $OWNER_UID:$OWNER_GID "$BORG_REPO"
    fi
    log INFO "Backup complete: ${archiveName}-$TIMESTAMP"
}

cleanupOldBackups() {
    log INFO "Pruning old backups..."
    # Keep the last 7 backups, regardless of time
    # run prune with SMART stderr handling (docker/compose/borg emit warnings/status on stderr)
    log TRACE "Starting borg prune: borg prune -v --list --keep-last 7 ${BORG_REPO}"
    run_and_log INFO SMART borg prune -v --list --keep-last 7 "$BORG_REPO"
    log TRACE "borg prune completed"
    
    # Crucial: Prune marks data for deletion, Compact actually frees the space
    log TRACE "Starting borg compact: borg compact ${BORG_REPO}"
    run_and_log INFO SMART borg compact "$BORG_REPO"
    log TRACE "borg compact completed"
}

#endregion Functions

#region Main Script

borg_init

# Ensure the target directory exists before proceeding
if [[ ! -d "$BACKUP_SOURCE" ]]; then
    log ERROR "Source directory '$BACKUP_SOURCE' does not exist. Aborting."
    exit 1
fi

cd "$BACKUP_SOURCE"

# Take down the stack, make backup, then bring it back up
# dc.sh is a shell script to perform `docker-compose [args]` in each child folder
log DEBUG "Bringing stacks down"
run_and_log INFO SMART bash "$BACKUP_SOURCE/dc.sh" down
makeCopy "Docker-Stack"
log DEBUG "Bringing stacks up"
run_and_log INFO SMART bash "$BACKUP_SOURCE/dc.sh" up

# cleanup
cleanupOldBackups

# ping healthcheck
if [[ "$PERFORM_URL_HEALTHCHECK" == "true" ]]; then
    run_and_log DEBUG curl -s "$HEALTHCHECK_URL" > /dev/null || log WARN "Healthcheck ping failed"
fi 

#endregion Main Script