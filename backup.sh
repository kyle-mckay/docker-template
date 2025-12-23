#!/bin/bash

# Fail fast, treat unset variables as errors, and make pipelines fail on first failure
set -eo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Backup script for Docker stack using Borg
#
# - Purpose: create a Borg archive of the Docker stack directory,
#   prune old backups and optionally ping a heartbeat endpoint.
# - Safety: script uses strict mode and quotes variables where practical.
# - Notes: Set `BACKUP_TYPE` to "local" to store repo on the same host.
#   For a remote repo (ssh) set `BACKUP_TYPE` accordingly and update `DST`.

# Default Configuration
# You can override these by renaming `.env.template` to `.env` and editing the file
BACKUP_SOURCE="$SCRIPT_DIR"
LOG_LEVEL=INFO
LOG_TIMESTAMP_FORMAT="%F %T"
LOG_ENABLE_COLORS=true
BACKUP_MODE="local"
BORG_REPO="$SCRIPT_DIR/.borg-backup"
BORG_ARCHIVE_NAME="Docker-Stack"
BORG_ENCRYPTION="none"
BORG_COMPRESSION="lz4"
BORG_STATS=true
DC_BATCH_CONTROLLER="$BACKUP_SOURCE/dc.sh"
SAVE_LOGS=false
LOG_DIR="$BACKUP_SOURCE"
LOG_FILE="backup.log"
CREATE_DIRS=true
PREFLIGHT_COMPLETE=false
LOG_BUFFER=()


# Timestamp used for archive names. Format: YYYY-MM-DD_HH-MM-SS
TIMESTAMP=$(date +%F_%H-%M-%S)

# Load environment variables from .env file if it exists

if [ -f "$SCRIPT_DIR/.env" ]; then
    source "$SCRIPT_DIR/.env"
fi

# Set LOG_PATH based on LOG_DIR and LOG_FILE
LOG_PATH="$LOG_DIR/$LOG_FILE"

# Set LOG_PATH based on LOG_DIR and LOG_FILE
LOG_PATH="$LOG_DIR/$LOG_FILE"

PREFLIGHT_COMPLETE=false

#region Functions

#region Pre-flight verifications
# Performs a selftest of various functions
preflight() {
    log TRACE "=======start preflight()======="
    log TRACE "Starting selftest..."

    setup_logging

    if [[ "$LOG_LEVEL" == "TRACE" ]]; then
        log INFO "Log level set to $LOG_LEVEL; printing test messages at all levels."
        log INFO "This is an INFO message"
        log WARN "This is a WARN message"
        log ERROR "This is an ERROR message"
        log DEBUG "This is a DEBUG message"
        log TRACE "This is a TRACE message"
    fi

    borg > /dev/null 2>&1 || {
        log ERROR "Borg command not found or not installed. Please install Borg before running this script."
        log ERROR "It can be installed via your package manager, e.g., 'apt install borgbackup' or 'yum install borgbackup'."
        exit 1
    }
    log TRACE "Borg command found: $(borg --version)"

    verify_required_variables
    verify_variable_conflicts

    log DEBUG "Selftest Finished."
    log TRACE "=======end preflight()======="
}

setup_logging() {
    log TRACE "=======start setup_logging()======="
    if [[ "$SAVE_LOGS" == "true" ]]; then
        if [[ -z "$LOG_DIR" || -z "$LOG_FILE" ]]; then
            log ERROR "LOG_DIR or LOG_FILE is not set but SAVE_LOGS is true. Setting to false."
            SAVE_LOGS="false"
            log WARN "SAVE_LOGS reset to false."
        elif [[ ! -d "$LOG_DIR" && "$CREATE_DIRS" == true ]]; then
            log DEBUG "LOG_DIR does not exist. Creating $LOG_DIR."
            mkdir -p "$LOG_DIR"
            if [[ $? -ne 0 ]]; then
                log ERROR "Failed to create LOG_DIR $LOG_DIR"
                
            else
                log DEBUG "LOG_DIR $LOG_DIR created successfully."
            fi
        elif [[ ! -d "$LOG_DIR" && "$CREATE_DIRS" == false ]]; then
            log ERROR "LOG_DIR $LOG_DIR does not exist and CREATE_DIRS is false."
            SAVE_LOGS="false"
            log WARN "SAVE_LOGS reset to false."
        elif [[ -d "$LOG_DIR" ]]; then
            if [[ ! -w "$LOG_DIR" ]]; then
                log ERROR "LOG_DIR $LOG_DIR is not writable."
            fi
        else
            log DEBUG "LOG_DIR $LOG_DIR exists and is writable."
        fi

        # SAVE_LOGS was not reset due to failures above
        if [[ "$SAVE_LOGS" == "true" ]]; then
            log DEBUG "LOG_PATH PASSED: set to '$LOG_PATH'"
        fi
    else
        LOG_PATH="/dev/null"
        log DEBUG "SAVE_LOGS is false; command outputs will not be logged to file."
    fi

    PREFLIGHT_COMPLETE=true
    flush_log_buffer
    log DEBUG "Logging setup completed."
    log TRACE "=======end setup_logging()======="
}

verify_variable_conflicts() {
    log TRACE "=======start verify_variable_conflicts()======="
    log TRACE "Verifying variable conflicts..."

    if [[ "$BORG_ENCRYPTION" != "none" && "$BORG_ENCRYPTION" != "repokey" ]]; then
        log ERROR "BORG_ENCRYPTION '$BORG_ENCRYPTION' is not a valid option. Use 'none' or 'repokey'."
        exit 1
    else
        if [[ -z "$BORG_REPO_PASSPHRASE" && "$BORG_ENCRYPTION" == "repokey" ]]; then
            log ERROR "BORG_REPO_PASSPHRASE must be set when using repokey encryption."
            exit 1
        else
            if [[ "$BORG_ENCRYPTION" == "repokey" ]]; then
                log DEBUG "BORG_REPO_PASSPHRASE is set: length ${#BORG_REPO_PASSPHRASE} chars."
                export BORG_PASSPHRASE="$BORG_REPO_PASSPHRASE"
                if [[ $? -ne 0 ]]; then
                    log ERROR "Failed to set BORG_PASSPHRASE"
                else
                    log DEBUG "BORG_PASSPHRASE set successfully."
                fi
            else
                log DEBUG "BORG_ENCRYPTION PASSED: set to '$BORG_ENCRYPTION'"
            fi
        fi
    fi

    if [[ "$CHOWN_AFTER" == "true" && ( -z "$OWNER_UID" || -z "$OWNER_GID" ) ]]; then
        log ERROR "CHOWN_AFTER is true but OWNER_UID or OWNER_GID is not set."
        exit 1
    elif [[ "$CHOWN_AFTER" == "true" ]]; then
        log DEBUG "CHOWN_AFTER PASSED: OWNER_UID=${OWNER_UID}, OWNER_GID=${OWNER_GID}"
    else
        log DEBUG "CHOWN_AFTER PASSED: Enabled: $CHOWN_AFTER"
    fi

    if [[ "$PERFORM_URL_HEALTHCHECK" == "true" && -z "$HEALTHCHECK_URL" ]]; then
        log WARN "PERFORM_URL_HEALTHCHECK is true but HEALTHCHECK_URL is not set."
    elif [[ "$PERFORM_URL_HEALTHCHECK" == "true" ]]; then
        log DEBUG "PERFORM_URL_HEALTHCHECK PASSED: Enabled for $HEALTHCHECK_URL"
    else 
        log DEBUG "PERFORM_URL_HEALTHCHECK PASSED: Enabled: $PERFORM_URL_HEALTHCHECK"
    fi

    if [[ "$LOG_LEVEL" != "TRACE" && "$LOG_LEVEL" != "DEBUG" && "$LOG_LEVEL" != "INFO" && "$LOG_LEVEL" != "WARN" && "$LOG_LEVEL" != "WARNING" && "$LOG_LEVEL" != "ERROR" ]]; then
        log WARN "LOG_LEVEL '$LOG_LEVEL' is not a valid option. Resetting to INFO for this session."
        LOG_LEVEL="INFO"
    else
        log DEBUG "LOG_LEVEL PASSED: set to '$LOG_LEVEL'"
    fi

    if [[ "$BORG_STATS" != "true" && "$BORG_STATS" != "false" ]]; then
        log WARN "BORG_STATS '$BORG_STATS' is not a valid option. Use 'true' or 'false'."
    else
        log DEBUG "BORG_STATS PASSED: set to '$BORG_STATS'"
    fi

    if [[ "$BORG_PROGRESS_BAR" != "true" && "$BORG_PROGRESS_BAR" != "false" ]]; then
        log WARN "BORG_PROGRESS_BAR '$BORG_PROGRESS_BAR' is not a valid option. Use 'true' or 'false'."
    else
        log DEBUG "BORG_PROGRESS_BAR PASSED: set to '$BORG_PROGRESS_BAR'"
    fi

    if [[ "$BORG_LIST" != "true" && "$BORG_LIST" != "false" ]]; then
        log WARN "BORG_LIST '$BORG_LIST' is not a valid option. Use 'true' or 'false'."
    else
        log DEBUG "BORG_LIST PASSED: set to '$BORG_LIST'"
    fi

    if [[ "$CHOWN_AFTER" != "true" && "$CHOWN_AFTER" != "false" ]]; then
        log WARN "CHOWN_AFTER '$CHOWN_AFTER' is not a valid option. Use 'true' or 'false'."
    else
        log DEBUG "CHOWN_AFTER PASSED: set to '$CHOWN_AFTER'"
    fi

    if [[ ! -z "$DC_BATCH_CONTROLLER" ]]; then
        if [[ ! -f "$DC_BATCH_CONTROLLER" ]]; then
            log ERROR "'docker compose' batch controller not found in $BACKUP_SOURCE"
            exit 1
        else
            log DEBUG "DC_BATCH_CONTROLLER PASSED: set to '$DC_BATCH_CONTROLLER'"
        fi
    else
        log DEBUG "DC_BATCH_CONTROLLER PASSED: Docker compose batch controller not set; will skip batch controller operations."
    fi

    if [[ "$SAVE_LOGS" != "true" && "$SAVE_LOGS" != "false" ]]; then
        log WARN "SAVE_LOGS '$SAVE_LOGS' is not a valid option. Use 'true' or 'false'."
        SAVE_LOGS="false"
        log WARN "SAVE_LOGS reset to false."
    else
        log DEBUG "SAVE_LOGS PASSED: set to '$SAVE_LOGS'"
    fi

    log DEBUG "Variable conflict checks completed."
    log TRACE "=======end verify_variable_conflicts()======="
}


verify_required_variables() {
    log TRACE "=======start verify_required_variables()======="
    log TRACE "Verifying required environment variables..."

    if [[ "$BACKUP_MODE" != "local" ]]; then
        log ERROR "BACKUP_MODE '$BACKUP_MODE' not supported in this script."
        exit 1
    elif [[ "$BACKUP_MODE" == "local" ]]; then
        log DEBUG "BACKUP_MODE PASSED: set to '$BACKUP_MODE'"
    fi

    if [[ -z "$BACKUP_SOURCE" ]]; then
        log ERROR "BACKUP_SOURCE is not set."
        exit 1
    elif [[ ! "$BACKUP_SOURCE" ]]; then
        log ERROR "BACKUP_SOURCE '$BACKUP_SOURCE' does not exist."
        exit 1
    elif [[ ! -d "$BACKUP_SOURCE" ]]; then
        log ERROR "BACKUP_SOURCE '$BACKUP_SOURCE' is not a directory."
        exit 1
    elif [[ ! -r "$BACKUP_SOURCE" ]]; then
        log ERROR "BACKUP_SOURCE '$BACKUP_SOURCE' is not readable."
        exit 1
    else
        log DEBUG "BACKUP_SOURCE PASSED: set to '$BACKUP_SOURCE'"
    fi

    if [[ -z "$BORG_REPO" ]]; then
        log ERROR "BORG_REPO is not set."
        exit 1
    elif [[ "$BACKUP_MODE" == "local" ]]; then
        log DEBUG "BORG_REPO PASSED: set to '$BORG_REPO'"
    fi

    if [[ "$BORG_COMPRESSION" != "lz4" && "$BORG_COMPRESSION" != "zstd,[1-9]" && "$BORG_COMPRESSION" != "zlib,[0-9]" && "$BORG_COMPRESSION" != "none" ]]; then
        log WARN "BORG_COMPRESSION '$BORG_COMPRESSION' is not a valid option. Setting to 'lz4' for this session."
        BORG_COMPRESSION="lz4"
    else
        log DEBUG "BORG_COMPRESSION PASSED: set to '$BORG_COMPRESSION'"
    fi

    if [[ -z "$BORG_ARCHIVE_NAME" ]]; then
        log WARN "BORG_ARCHIVE_NAME is not set. Setting to 'backup' for this session."
        BORG_ARCHIVE_NAME="backup"
    else
        log DEBUG "BORG_ARCHIVE_NAME PASSED: set to '$BORG_ARCHIVE_NAME'"
    fi

    log DEBUG "All required environment variables verified."
    log TRACE "=======end verify_required_variables()======="
}

#endregion Selftests

log() {
    local level="${1:-INFO}"
    local no_timestamp=false
    if [[ "$2" == "no_timestamp" ]]; then
        no_timestamp=true
        shift
    fi
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
    if [[ "$no_timestamp" == "false" && -n "$LOG_TIMESTAMP_FORMAT" ]]; then
        ts="$(date +"$LOG_TIMESTAMP_FORMAT") "
    fi

    # Compose output; send logs to stderr
    if [[ "$LOG_ENABLE_COLORS" == "true" ]]; then
        printf "%b%s[%s] %s%b\n" "$color" "$ts" "$level" "$msg" "$clr_reset" >&2
    else
        printf "%s[%s] %s\n" "$ts" "$level" "$msg" >&2
    fi

    # Save to file if enabled (clean text only)
    if [[ "$SAVE_LOGS" == "true" ]]; then
        if [[ "$PREFLIGHT_COMPLETE" == "false" ]]; then
            LOG_BUFFER+=("$ts [$level] $msg")
        else
            printf "%s[%s] %s\n" "$ts" "$level" "$msg" >> "$LOG_PATH"
        fi
    fi
}

borg_init(){
    log TRACE "=======start borg_init()======="
    start_ts
    log INFO "Checking borg repo..."

    if [[ "$BACKUP_MODE" == "local" ]]; then
        # Check if the directory exists AND is a valid borg repo
        if borg list "$BORG_REPO" >/dev/null 2>&1; then
            log INFO "Borg repo already exists and is valid"
        else
            log TRACE "Borg repo does not exist; initializing..."
            if [[ -d "$BORG_REPO" && ! -z "$(ls -A "$BORG_REPO")" ]]; then
                log ERROR "Directory '$BORG_REPO' already exists but is not a valid Borg repo."
                log ERROR "Please remove directory contents, or use a different path."
                exit 1
            else
                log TRACE "Path exists as directory but is empty; proceeding with init..."
            fi

            log INFO "Initializing borg repo at $BORG_REPO"
            log DEBUG "borg init args: --encryption=${BORG_ENCRYPTION}"
            
            if borg init --encryption="$BORG_ENCRYPTION" "$BORG_REPO" 2>&1 | tee -a "$LOG_PATH"; then
                chown_repo
                log INFO "Borg repo initialized successfully"
            else
                log ERROR "Failed to initialize Borg repo"
                exit 1
            fi
        fi
    fi

    end_ts

    log TRACE "borg init --encryption="$BORG_ENCRYPTION" "$BORG_REPO", passphrase_set=$( [[ -n "${BORG_REPO_PASSPHRASE:-}" ]] && echo yes || echo no ), duration=$((end_ts-start_ts))"
    log TRACE "=======end borg_init()======="
}

makeCopy(){
    log TRACE "=======start makeCopy()======="
    local archiveName=$1 # name of the backup archive
    local borg_opts=()

    # Prepare Borg options
    ## Compression
    if [[ -n "$BORG_COMPRESSION" ]]; then
        log TRACE "Adding compression option: --compression=$BORG_COMPRESSION"
        borg_opts+=( "--compression" "$BORG_COMPRESSION" )
    fi

    ## Exclusions
    for skip in "${EXCLUDE_PATTERNS[@]}"; do
        log TRACE "Adding exclude pattern: --exclude=sh:$skip"
        borg_opts+=( "--exclude" "sh:$skip" )
    done

    ## Stats
    if [[ "$BORG_STATS" == "true" ]]; then
        log TRACE "Adding stats option: --stats"
        borg_opts+=( "--stats" )
    fi

    ## Progress bar
    if [[ "$BORG_PROGRESS_BAR" == "true" ]]; then
        log TRACE "Adding progress option: --progress"
        borg_opts+=( "--progress" )
    fi

    ## List files
    if [[ "$BORG_LIST" == "true" ]]; then
        log TRACE "Adding list option: --list"
        borg_opts+=( "--list" )
    fi

    log INFO "Starting Borg snapshot for $BACKUP_SOURCE"
    log DEBUG "Borg options count: ${#borg_opts[@]}; excludes=${#EXCLUDE_PATTERNS[@]}"
    if [[ "$LOG_LEVEL" == "TRACE" ]]; then
        log TRACE "borg create ${borg_opts[*]} ${BORG_REPO}::${archiveName}-$TIMESTAMP ${BACKUP_SOURCE}"
    fi

    # Execute the backup
    start_ts
    borg create "${borg_opts[@]}" "${BORG_REPO}::${archiveName}-$TIMESTAMP" "${BACKUP_SOURCE}" 2>&1 | tee -a "$LOG_PATH"
    status=$?
    end_ts
    log TRACE "borg create finished exit=${status}, duration=$((end_ts-start_ts))s"
    
    
    cleanupOldBackups

    log INFO "Backup complete: ${archiveName}-$TIMESTAMP"
    log TRACE "=======end makeCopy()======="
}

chown_repo(){
    log TRACE "=======start chown_repo()======="
    log INFO "Setting ownership on borg repo..."
    if [[ "$CHOWN_AFTER" == "true" ]]; then
        log DEBUG "Chowning borg repo to ${OWNER_UID}:${OWNER_GID}"
            log TRACE "chown -R $OWNER_UID:$OWNER_GID $BORG_REPO"
            start_ts
            chown -R $OWNER_UID:$OWNER_GID "$BORG_REPO"
            local status=$?
            end_ts
            if [[ $status -ne 0 ]]; then
                log ERROR "Failed to chown borg repo with UID=$OWNER_UID GID=$OWNER_GID"
            fi
            log TRACE "chown completed exit=${status}, duration=$((end_ts-start_ts))s"
    else
        log DEBUG "CHOWN_AFTER is false; skipping chown"
    fi
    log DEBUG "chown_repo completed"
    log TRACE "=======end chown_repo()======="
}

chown_logs(){
    # not logging this function to avoid overwriting log file ownership
    if [[ "$CHOWN_AFTER" == "true" ]]; then
        chown -R $OWNER_UID:$OWNER_GID "$LOG_DIR"
        local status=$?
        end_ts
        if [[ $status -ne 0 ]]; then
            log ERROR "Failed to chown borg repo with UID=$OWNER_UID GID=$OWNER_GID"
        fi
    fi
}

cleanupOldBackups() {
    log TRACE "=======start cleanupOldBackups()======="
    log INFO "Pruning old backups..."
    # Keep the last 7 backups, regardless of time
    # run prune with SMART stderr handling (docker/compose/borg emit warnings/status on stderr)
    log TRACE "Starting borg prune: borg prune -v --list --keep-last 7 ${BORG_REPO}"
    borg prune -v --list --keep-last 7 "$BORG_REPO" 2>&1 | tee -a "$LOG_PATH"
    log TRACE "borg prune completed"
    
    # Crucial: Prune marks data for deletion, Compact actually frees the space
    log TRACE "Starting borg compact: borg compact ${BORG_REPO}"
    borg compact "$BORG_REPO" 2>&1 | tee -a "$LOG_PATH"

    log DEBUG "cleanupOldBackups completed"
    log TRACE "=======end cleanupOldBackups()======="
}

docker_compose() {
    # dc.sh is a shell script to perform `docker-compose [args]` in each child folder
    log TRACE "=======start docker_compose()======="
    arg=$1
    local dc=$DC_BATCH_CONTROLLER

    if [[ -z "$DC_BATCH_CONTROLLER" ]]; then
        log TRACE "DC_BATCH_CONTROLLER not set: skipping docker_compose $arg"
        return
    fi

    log INFO "Bringing stacks '$arg'"
    log TRACE "$dc $arg"

    start_ts
    bash "$dc" "$arg" 2>&1 | tee -a "$LOG_PATH"
    status=$?
    end_ts

    log TRACE "dc.sh $arg exit=${status}, duration=$((end_ts-start_ts))"
    log DEBUG "docker_compose $arg completed"
    log TRACE "=======end docker_compose()======="
}

start_ts() {
    start_ts=$(date +%s)
}

end_ts() {
    end_ts=$(date +%s)
}

flush_log_buffer() {
    if [[ "$SAVE_LOGS" == "true" ]]; then
        for line in "${LOG_BUFFER[@]}"; do
            echo "$line" >> "$LOG_PATH"
        done
        LOG_BUFFER=()
    fi
}

healthcheck() {
    log TRACE "=======start healthcheck()======="
    start_ts
    # ping healthcheck
    if [[ "$PERFORM_URL_HEALTHCHECK" == "true" ]]; then
        if [[ "$HEALTHCHECK_DELAY" -gt 0 ]]; then
            log DEBUG "Waiting for HEALTHCHECK_DELAY $HEALTHCHECK_DELAY seconds before pinging healthcheck URL"
            sleep "$HEALTHCHECK_DELAY"
        fi

        
        log DEBUG "Pinging healthcheck URL: $HEALTHCHECK_URL"
        if [[ "$LOG_LEVEL" == "TRACE" ]]; then
            curl -s "$HEALTHCHECK_URL" 2>&1 | tee -a "$LOG_PATH"

            local status=$?
            end_ts
            log TRACE "curl -s $HEALTHCHECK_URL exit=${status}, duration=$((end_ts-start_ts))"
        else
            curl -s "$HEALTHCHECK_URL" > /dev/null

            local status=$?
            end_ts
            log TRACE "curl -s $HEALTHCHECK_URL exit=${status}, duration=$((end_ts-start_ts))"
        fi
        if [[ $status -ne 0 ]]; then
            log ERROR "Healthcheck ping failed with exit code $status"
        else
            log INFO "Healthcheck ping successful"
        fi
    else
        log DEBUG "PERFORM_URL_HEALTHCHECK is false; skipping healthcheck ping"
    fi

    log DEBUG "Healthcheck completed"
    log TRACE "=======end healthcheck()======="
}

# Self-update: replace this script with the version from the main branch
# Usage: backup.sh --update
if [[ "${1:-}" == "--update" ]]; then
    UPDATE_URL="https://raw.githubusercontent.com/kyle-mckay/docker-template/refs/heads/main/backup.sh"
    # Determine the current script path
    SELF_PATH="${BASH_SOURCE[0]}"
    if [[ "${SELF_PATH:0:1}" != "/" ]]; then
        SELF_PATH="$SCRIPT_DIR/$(basename "${SELF_PATH}")"
    fi

    echo "Updating $SELF_PATH from $UPDATE_URL..."

    tmpfile=$(mktemp /tmp/backup.sh.XXXXXX) || {
        echo "Failed to create temporary file for update." >&2
        exit 1
    }

    if curl -fsSL "$UPDATE_URL" -o "$tmpfile"; then
        # Basic validation: file should start with a shebang
        if head -n1 "$tmpfile" | grep -q '^#!'; then
            chmod +x "$tmpfile" || true
            if mv "$tmpfile" "$SELF_PATH"; then
                echo "Update applied to $SELF_PATH"
                exit 0
            else
                echo "Failed to move updated file into place." >&2
                rm -f "$tmpfile"
                exit 1
            fi
        else
            echo "Downloaded file looks invalid (missing shebang). Aborting." >&2
            rm -f "$tmpfile"
            exit 1
        fi
    else
        echo "Failed to download update from $UPDATE_URL" >&2
        rm -f "$tmpfile"
        exit 1
    fi
fi


#endregion Functions

#region Main Script
log DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
log DEBUG "                Starting backup script"
log DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
s_start=$(date +%s)

preflight
borg_init

# Ensure the target directory exists before proceeding
if [[ ! -d "$BACKUP_SOURCE" ]]; then
    log ERROR "Source directory '$BACKUP_SOURCE' does not exist. Aborting."
    exit 1
fi

cd "$BACKUP_SOURCE"
docker_compose "down"

makeCopy $BORG_ARCHIVE_NAME

if [[ "$DC_PULL" == true ]]; then
    docker_compose pull
fi
docker_compose "up"

chown_repo

healthcheck

s_end=$(date +%s)
log DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
log DEBUG "Backup script completed"
log TRACE "Script duration: $((s_end-s_start)) seconds"
log DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

if [[ "$CHOWN_AFTER" == "true" ]]; then
    chown_logs
fi

#endregion Main Script
