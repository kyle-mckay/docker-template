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
# You can override these by renaming the `.env` template to `.env` and editing the file
BACKUP_SOURCE="$SCRIPT_DIR"
LOG_LEVEL=INFO
LOG_TIMESTAMP_FORMAT="%F %T"
LOG_ENABLE_COLORS=true
BACKUP_MODE="local"
BORG_REPO="$SCRIPT_DIR/borg-backup"
BORG_ENCRYPTION="none"
BORG_COMPRESSION="lz4"
BORG_STATS=true

# Load environment variables from .env file if it exists

if [ -f "$SCRIPT_DIR/.env" ]; then
    source "$SCRIPT_DIR/.env"
fi

# Timestamp used for archive names. Format: YYYY-MM-DD_HH-MM-SS
TIMESTAMP=$(date +%F_%H-%M-%S)


#region Functions

#region Pre-flight verifications
# Performs a selftest of various functions
preflight() {
    log TRACE "=======preflight()======="
    log TRACE "Starting selftest..."

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
}

verify_variable_conflicts() {
    log TRACE "=======verify_variable_conflicts()======="
    log TRACE "Verifying variable conflicts..."

    if [[ "$BORG_ENCRYPTION" != "none" && "$BORG_ENCRYPTION" != "repokey" ]]; then
        log ERROR "BORG_ENCRYPTION '$BORG_ENCRYPTION' is not a valid option. Use 'none' or 'repokey'."
        exit 1
    else
        log TRACE "BORG_ENCRYPTION is valid: set to '$BORG_ENCRYPTION'"
        if [[ -z "$BORG_REPO_PASSPHRASE" && "$BORG_ENCRYPTION" == "repokey" ]]; then
            log ERROR "BORG_REPO_PASSPHRASE must be set when using repokey encryption."
            exit 1
        else
            if [[ "$BORG_ENCRYPTION" == "repokey" ]]; then
                log TRACE "BORG_REPO_PASSPHRASE is set: length ${#BORG_REPO_PASSPHRASE} chars."
            fi
            log TRACE "BORG_ENCRYPTION PASSED"
        fi
    fi


    if [[ "$BACKUP_MODE" != "local" ]]; then
        log ERROR "BACKUP_MODE '$BACKUP_MODE' not supported in this script."
        exit 1
    else
        log TRACE "No conflicts with BACKUP_MODE value."
    fi

    if [[ "$CHOWN_AFTER" == "true" && ( -z "$OWNER_UID" || -z "$OWNER_GID" ) ]]; then
        log ERROR "CHOWN_AFTER is true but OWNER_UID or OWNER_GID is not set."
        exit 1
    elif [[ "$CHOWN_AFTER" == "true" ]]; then
        log TRACE "CHOWN_AFTER PASSED: OWNER_UID=${OWNER_UID}, OWNER_GID=${OWNER_GID}"
    else
        log TRACE "CHOWN_AFTER PASSED: Enabled: $CHOWN_AFTER"
    fi

    if [[ "$PERFORM_URL_HEALTHCHECK" == "true" && -z "$HEALTHCHECK_URL" ]]; then
        log WARN "PERFORM_URL_HEALTHCHECK is true but HEALTHCHECK_URL is not set."
    elif [[ "$PERFORM_URL_HEALTHCHECK" == "true" ]]; then
        log TRACE "PERFORM_URL_HEALTHCHECK PASSED: Enabled for $HEALTHCHECK_URL"
    else 
        log TRACE "PERFORM_URL_HEALTHCHECK PASSED: Enabled: $PERFORM_URL_HEALTHCHECK"
    fi

    if [[ "$LOG_LEVEL" != "TRACE" && "$LOG_LEVEL" != "DEBUG" && "$LOG_LEVEL" != "INFO" && "$LOG_LEVEL" != "WARN" && "$LOG_LEVEL" != "WARNING" && "$LOG_LEVEL" != "ERROR" ]]; then
        log WARN "LOG_LEVEL '$LOG_LEVEL' is not a valid option. Resetting to INFO for this session."
        LOG_LEVEL="INFO"
    fi

    log TRACE "Variable conflict checks completed."
}

verify_required_variables() {
    log TRACE "=======verify_required_variables()======="
    log TRACE "Verifying required environment variables..."

    if [[ -z "$BACKUP_SOURCE" ]]; then
        log ERROR "BACKUP_SOURCE is not set."
        exit 1
    else
        log TRACE "BACKUP_SOURCE PASSED: set to '$BACKUP_SOURCE'"
    fi

    if [[ -z "$BORG_REPO" ]]; then
        log ERROR "BORG_REPO is not set."
        exit 1
    else
        log TRACE "BORG_REPO PASSED: set to '$BORG_REPO'"
    fi

    if [[ "$BORG_COMPRESSION" != "lz4" && "$BORG_COMPRESSION" != "zstd,[1-9]" && "$BORG_COMPRESSION" != "zlib,[0-9]" && "$BORG_COMPRESSION" != "none" ]]; then
        log WARN "BORG_COMPRESSION '$BORG_COMPRESSION' is not a valid option. Setting to 'lz4' for this session."
        BORG_COMPRESSION="lz4"
    else
        log TRACE "BORG_COMPRESSION PASSED: set to '$BORG_COMPRESSION'"
    fi


    log TRACE "All required environment variables verified."

}

#endregion Selftests

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

borg_init(){
    log TRACE "=======borg_init()======="
    log INFO "Initializing Borg backup environment..."
    # Initialize the repository
    if [[ "$BACKUP_MODE" == "local" ]]; then
        # Create parent dir if it doesnt exist
        mkdir -p "$(dirname "$BORG_REPO")"
        if [[ ! -d "$BORG_REPO" ]]; then
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

}

makeCopy(){
    log TRACE "=======makeCopy()======="
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
    # show first few excludes for trace
    log TRACE "Excludes (sample): ${EXCLUDE_PATTERNS[@]:0:5}"

    # Execute the backup
    log TRACE "borg create ${borg_opts[*]} ${BORG_REPO}::${archiveName}-$TIMESTAMP ${BACKUP_SOURCE}"
    start_ts
    borg create "${borg_opts[@]}" "${BORG_REPO}::${archiveName}-$TIMESTAMP" "${BACKUP_SOURCE}"
    local status=$?
    end_ts
    log TRACE "borg create finished exit=${status}, duration=$((end_ts-start_ts))s"

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
    fi

    cleanupOldBackups

    log INFO "Backup complete: ${archiveName}-$TIMESTAMP"
}

cleanupOldBackups() {
    log TRACE "=======cleanupOldBackups()======="
    log INFO "Pruning old backups..."
    # Keep the last 7 backups, regardless of time
    # run prune with SMART stderr handling (docker/compose/borg emit warnings/status on stderr)
    log TRACE "Starting borg prune: borg prune -v --list --keep-last 7 ${BORG_REPO}"
    borg prune -v --list --keep-last 7 "$BORG_REPO"
    log TRACE "borg prune completed"
    
    # Crucial: Prune marks data for deletion, Compact actually frees the space
    log TRACE "Starting borg compact: borg compact ${BORG_REPO}"
    borg compact "$BORG_REPO"
    log TRACE "borg compact completed"
}

docker_compose() {
    # dc.sh is a shell script to perform `docker-compose [args]` in each child folder
    log TRACE "=======docker_compose()======="
    arg=$1
    log INFO "Bringing stacks $arg"
    log TRACE "dc.sh $arg"

    start_ts
    bash "$BACKUP_SOURCE/dc.sh" $arg
    local status=$?
    end_ts

    log TRACE "dc.sh $arg exit=${status}, duration=$((end_ts-start_ts))"
    log TRACE "dc.sh $arg completed"
}

start_ts() {
    start_ts=$(date +%s)
}

end_ts() {
    end_ts=$(date +%s)
}
#endregion Functions

#region Main Script

preflight
borg_init

# Ensure the target directory exists before proceeding
if [[ ! -d "$BACKUP_SOURCE" ]]; then
    log ERROR "Source directory '$BACKUP_SOURCE' does not exist. Aborting."
    exit 1
fi

cd "$BACKUP_SOURCE"
docker_compose "down"
makeCopy "Docker-Stack"
docker_compose "up"

# ping healthcheck
if [[ "$PERFORM_URL_HEALTHCHECK" == "true" ]]; then
    curl -s "$HEALTHCHECK_URL" > /dev/null || log WARN "Healthcheck ping failed"
fi 

#endregion Main Script