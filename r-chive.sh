#!/bin/sh

# ==============================================================================
# CONFIGURATION
# All settings are now in 'backup.conf'. This script will load it.
# ==============================================================================

# Get the directory where the script is located.
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
CONFIG_FILE="${SCRIPT_DIR}/backup.conf"

# Check if the configuration file exists and source it.
if [ -f "${CONFIG_FILE}" ]; then
    # shellcheck source=backup.conf
    . "${CONFIG_FILE}"
else
    echo "ERROR: Configuration file not found!"
    echo "Please ensure 'backup.conf' exists in the same directory as the script."
    exit 1
fi

# Log file is defined here, using LOG_DIR from the config file.
LOG_FILE="${LOG_DIR}/backup-$(date +'%Y-%m-%d').log"

# --- Argument Parsing ---
DRY_RUN_MODE="no"
RSYNC_EXTRA_OPTS=""
if [ "$1" = "--dry-run" ]; then
    DRY_RUN_MODE="yes"
    RSYNC_EXTRA_OPTS="-n"
    echo "--- DRY RUN MODE ENABLED ---"
fi

# --- Lock File Management ---
# Ensures only one instance of the script runs at a time.
LOCK_FILE="/tmp/backup_rsync.lock"

if [ -e "${LOCK_FILE}" ]; then
    LOCKED_PID=$(cat "${LOCK_FILE}" 2>/dev/null)
    if [ -n "${LOCKED_PID}" ] && ps -p "${LOCKED_PID}" > /dev/null; then
        echo "ERROR: Another instance of the script is already running with PID ${LOCKED_PID}. Exiting."
        exit 1
    else
        echo "WARNING: Found a stale lock file. Removing it."
    fi
fi

# Create the lock file with the current PID and set a trap to clean it up on any exit.
echo $$ > "${LOCK_FILE}"
trap 'rm -f "${LOCK_FILE}"' EXIT HUP INT QUIT TERM

# ==============================================================================
# HELPER FUNCTIONS
# Do not modify this section unless you know what you are doing.
# ==============================================================================

# Function to log messages to both console and the log file.
log_message() {
    local message="$1"
    # Using `tee` to write to both stdout and the log file.
    echo "$(date +'%Y-%m-%d %H:%M:%S') - ${message}" | tee -a "${LOG_FILE}"
}

# ==============================================================================
# MAIN SCRIPT LOGIC
# ==============================================================================

# --- Initialization ---
START_TIME=$(date +%s)
OVERALL_STATUS="SUCCESS"
REPORT_BODY=""
PROCESSED_TARGETS_LIST=""

# Define icons for the report
ICON_SUCCESS="✅"
ICON_FAIL="❌"
ICON_INFO="ℹ️"
ICON_CLOCK="⏱️"
ICON_TARGET="🎯"
ICON_ARCHIVE="📦"

# Ensure the log directory exists and is writable.
if [ ! -d "$LOG_DIR" ]; then
    echo "Creating log directory: ${LOG_DIR}"
    # This script might need to be run with sudo if the user lacks permissions.
    mkdir -p "$LOG_DIR"
    if [ $? -ne 0 ]; then
        echo "ERROR: Failed to create log directory. Please ensure you have the correct permissions."
        exit 1
    fi
fi

log_message "================== Starting Rsync Backup Process =================="
REPORT_BODY="Rsync Backup Report - $(date +'%Y-%m-%d %H:%M:%S')\n\n"

# Process the backup targets to allow for multi-line and comments in the config.
# This filters out lines starting with '#' and any empty lines.
PROCESSED_TARGETS=$(echo "${BACKUP_TARGETS}" | grep -v '^[[:space:]]*#' | grep -v '^[[:space:]]*$')

# Check if there are any targets to process after filtering.
if [ -z "${PROCESSED_TARGETS}" ]; then
    log_message "No backup targets are defined or all are commented out. Exiting."
    exit 0
fi

# Create a temporary directory to store job outputs and PIDs
JOB_DIR=$(mktemp -d)
trap 'rm -rf "${JOB_DIR}"' EXIT HUP INT QUIT TERM

# --- Main Loop: Process server by server ---
GLOBAL_PROCESS_STATUS="SUCCESS"
UNIQUE_HOSTS=$(echo "${PROCESSED_TARGETS}" | cut -d':' -f1 | cut -d'@' -f2 | sort -u)

for HOST in ${UNIQUE_HOSTS}; do
    HOST_START_TIME=$(date +%s)
    log_message "================== Starting Backup for Host: ${HOST} =================="

    # --- Start all backup jobs for the current host in parallel ---
    HOST_TARGETS=$(echo "${PROCESSED_TARGETS}" | grep "@${HOST}:")
    PID_LIST=""
    for target in ${HOST_TARGETS}; do
        JOB_ID=$(echo "${target}" | md5)
        
        # Run the backup for each target in a subshell in the background
        ( 
            # Parse the target string: user@host:/path/source
            USER_HOST=$(echo "${target}" | cut -d':' -f1)
            REMOTE_SOURCE=$(echo "${target}" | cut -d':' -f2-)

            log_message "Starting backup for target: ${target}"

            # Clean the remote path by removing trailing slashes so basename/dirname work reliably.
            REMOTE_SOURCE_CLEAN=$(echo "${REMOTE_SOURCE}" | sed 's:/*$::')
            REMOTE_BASENAME=$(basename "${REMOTE_SOURCE_CLEAN}")
            REMOTE_DIRNAME=$(dirname "${REMOTE_SOURCE_CLEAN}")

            # The rsync destination is the *parent* directory.
            RSYNC_DEST="${BACKUP_DEST}/${HOST}${REMOTE_DIRNAME}"
            RSYNC_SOURCE="${USER_HOST}:${REMOTE_SOURCE_CLEAN}"
            TARGET_DEST="${RSYNC_DEST}/${REMOTE_BASENAME}"

            mkdir -p "${RSYNC_DEST}"
            RSYNC_OUTPUT_FILE="${JOB_DIR}/${JOB_ID}.output"

            SSH_OPTIONS=""
            [ -n "$SSH_KEY_PATH" ] && SSH_OPTIONS="-i ${SSH_KEY_PATH}"

            # Execute rsync
            rsync -az --delete --stats --itemize-changes ${RSYNC_EXTRA_OPTS} \
                  -e "ssh ${SSH_OPTIONS}" \
                  "${RSYNC_SOURCE}" \
                  "${RSYNC_DEST}" > "${RSYNC_OUTPUT_FILE}" 2>&1
            
            echo $? > "${JOB_DIR}/${JOB_ID}.exitcode"

        ) & # Run in background

        PID_LIST="${PID_LIST} $!"
    done

    # --- Wait for all jobs for THIS HOST to complete ---
    log_message "Waiting for all backup jobs on host ${HOST} to complete..."
    for pid in ${PID_LIST}; do
        wait "${pid}"
    done
    HOST_END_TIME=$(date +%s)
    log_message "All backup jobs for host ${HOST} have finished."

    # --- Process results and send report for the current host ---
    log_message "Processing results for host: ${HOST}"
    HOST_OVERALL_STATUS="SUCCESS"
    HOST_REPORT_BODY="Rsync Backup Report for Host: ${HOST} - $(date +'%Y-%m-%d %H:%M:%S')\n\n"
    HOST_PROCESSED_TARGETS_LIST=""

    for target in ${HOST_TARGETS}; do
        JOB_ID=$(echo "${target}" | md5)
        REMOTE_SOURCE=$(echo "${target}" | cut -d':' -f2-)

        REMOTE_SOURCE_CLEAN=$(echo "${REMOTE_SOURCE}" | sed 's:/*$::')
        REMOTE_BASENAME=$(basename "${REMOTE_SOURCE_CLEAN}")
        REMOTE_DIRNAME=$(dirname "${REMOTE_SOURCE_CLEAN}")
        TARGET_DEST="${BACKUP_DEST}/${HOST}${REMOTE_DIRNAME}/${REMOTE_BASENAME}"

        RSYNC_EXIT_CODE=$(cat "${JOB_DIR}/${JOB_ID}.exitcode")
        RSYNC_STATS=$(cat "${JOB_DIR}/${JOB_ID}.output")
        HOST_REPORT_BODY="${HOST_REPORT_BODY}--------------------------------------------------\n"

        if [ ${RSYNC_EXIT_CODE} -eq 0 ]; then
            log_message "Backup for target ${target} SUCCESS."
            HOST_REPORT_BODY="${HOST_REPORT_BODY}${ICON_SUCCESS} Target: ${target}\n"
            HOST_REPORT_BODY="${HOST_REPORT_BODY}Status: SUCCESS\n"

            if [ "${CREATE_ARCHIVE}" = "yes" ]; then
                log_message "--- Starting Archive Creation for target ${target} ---"
                SANITISED_FILENAME_PART=$(basename "${REMOTE_SOURCE}")
                YEAR=$(date +'%Y'); MONTH=$(date +'%m')
                ARCHIVE_DIR="${ARCHIVE_DEST}/${HOST}/${YEAR}/${MONTH}"
                mkdir -p "${ARCHIVE_DIR}"
                ARCHIVE_FILE="${ARCHIVE_DIR}/${SANITISED_FILENAME_PART}-$(date +'%Y-%m-%d_%H%M%S').tar.zst"
                log_message "Creating compressed archive: ${ARCHIVE_FILE}"
                tar --zstd -cf "${ARCHIVE_FILE}" -C "${TARGET_DEST}" .

                if [ $? -eq 0 ]; then
                    ARCHIVE_SIZE=$(du -h "${ARCHIVE_FILE}" | cut -f1)
                    log_message "Archive for target ${target} created successfully. Size: ${ARCHIVE_SIZE}"
                    HOST_REPORT_BODY="${HOST_REPORT_BODY}Archive Status: SUCCESS - ${ARCHIVE_FILE} (Size: ${ARCHIVE_SIZE})\n"

                    if [ -n "${ARCHIVE_RETENTION_DAYS}" ] && [ "${ARCHIVE_RETENTION_DAYS}" -gt 0 ]; then
                        log_message "Retention Policy: Deleting archives for target '${target}' older than ${ARCHIVE_RETENTION_DAYS} days."
                        find "${ARCHIVE_DEST}/${HOST}" -name "${SANITISED_FILENAME_PART}-*.tar.zst" -type f -mtime "+${ARCHIVE_RETENTION_DAYS}" -print -delete | while IFS= read -r f; do [ -n "$f" ] && log_message "Retention (by day): Deleted old archive: $f"; done
                    elif [ -n "${ARCHIVE_RETENTION_COUNT}" ] && [ "${ARCHIVE_RETENTION_COUNT}" -gt 0 ]; then
                        ARCHIVES_FOUND=$(find "${ARCHIVE_DEST}/${HOST}" -name "${SANITISED_FILENAME_PART}-*.tar.zst" -type f)
                        COUNT=$(echo "${ARCHIVES_FOUND}" | wc -l)
                        if [ "$COUNT" -gt "$ARCHIVE_RETENTION_COUNT" ]; then
                            NUM_TO_DELETE=$((COUNT - ARCHIVE_RETENTION_COUNT))
                            log_message "Retention Policy (by count): Found ${COUNT} archives, limit is ${ARCHIVE_RETENTION_COUNT}. Deleting ${NUM_TO_DELETE} oldest."
                            find "${ARCHIVE_DEST}/${HOST}" -name "${SANITISED_FILENAME_PART}-*.tar.zst" -type f -exec stat -f '%m %N' {} + | sort -n | head -n "${NUM_TO_DELETE}" | cut -d' ' -f2- | while IFS= read -r f; do [ -n "$f" ] && log_message "Retention (by count): Deleting old archive: $f" && rm -f "$f"; done
                        fi
                    fi
                else
                    log_message "ERROR: Failed to create archive for target ${target}."
                    HOST_REPORT_BODY="${HOST_REPORT_BODY}Archive Status: FAILED\n"
                fi
            fi
        else
            log_message "ERROR: Backup for target ${target} FAILED with exit code ${RSYNC_EXIT_CODE}."
            HOST_OVERALL_STATUS="ERROR"
            GLOBAL_PROCESS_STATUS="ERROR"
            HOST_REPORT_BODY="${HOST_REPORT_BODY}${ICON_FAIL} Target: ${target}\n"
            HOST_REPORT_BODY="${HOST_REPORT_BODY}Status: FAILED (Code: ${RSYNC_EXIT_CODE})\n"
        fi

        HOST_REPORT_BODY="${HOST_REPORT_BODY}\nChange Details & Statistics:\n${RSYNC_STATS}\n\n"
        HOST_PROCESSED_TARGETS_LIST="${HOST_PROCESSED_TARGETS_LIST}  ${ICON_TARGET} ${target}\n"
    done

    # --- Finalize and send email for THIS HOST ---
    HOST_DURATION=$((HOST_END_TIME - HOST_START_TIME))
    H_DAYS=$((HOST_DURATION / 86400)); H_HOURS=$(( (HOST_DURATION % 86400) / 3600 )); H_MINUTES=$(( (HOST_DURATION % 3600) / 60 )); H_SECONDS=$((HOST_DURATION % 60))
    HOST_FORMATTED_DURATION=$(printf "%d days, %02d hours, %02d minutes, %02d seconds" ${H_DAYS} ${H_HOURS} ${H_MINUTES} ${H_SECONDS})

    SUBJECT_TAG=""; DRY_RUN_HEADER=""
    if [ "${DRY_RUN_MODE}" = "yes" ]; then
        SUBJECT_TAG="[DRY RUN] "
        DRY_RUN_HEADER="⚠️ WARNING: DRY RUN MODE ENABLED. NO CHANGES WERE MADE. ⚠️\n\n"
    fi

    FINAL_STATUS_ICON="${ICON_SUCCESS}"
    if [ "${HOST_OVERALL_STATUS}" = "ERROR" ]; then FINAL_STATUS_ICON="${ICON_FAIL}"; fi

    REPORT_HEADER="${DRY_RUN_HEADER}"
    REPORT_HEADER="${REPORT_HEADER}${ICON_INFO} Backup Summary for Host: ${HOST}\n"
    REPORT_HEADER="${REPORT_HEADER}${FINAL_STATUS_ICON} Overall Status: ${HOST_OVERALL_STATUS}\n"
    REPORT_HEADER="${REPORT_HEADER}${ICON_CLOCK} Total Duration for Host: ${HOST_FORMATTED_DURATION}\n"
    REPORT_HEADER="${REPORT_HEADER}\nProcessed Targets on this Host:\n${HOST_PROCESSED_TARGETS_LIST}\n"

    log_message "Constructing and sending email report for host ${HOST}..."
    FROM_EMAIL="backup-reporter@$(hostname)"
    EMAIL_SUBJECT="Rsync Backup Report for ${HOST} from $(hostname) - ${SUBJECT_TAG}Status: ${HOST_OVERALL_STATUS} ${FINAL_STATUS_ICON}"

    (   echo "From: ${FROM_EMAIL}"; echo "To: ${REPORT_EMAIL}"; echo "Subject: ${EMAIL_SUBJECT}";
        echo "MIME-Version: 1.0"; echo "Content-Type: text/plain; charset=UTF-8"; echo "";
        echo -e "${REPORT_HEADER}${HOST_REPORT_BODY}"
    ) | /usr/sbin/sendmail -t

    log_message "Email report command executed for host ${HOST} to ${REPORT_EMAIL}."
done

# --- Finalization ---
END_TIME=$(date +%s)
TOTAL_DURATION=$((END_TIME - START_TIME))
DAYS=$((TOTAL_DURATION / 86400)); HOURS=$(( (TOTAL_DURATION % 86400) / 3600 )); MINUTES=$(( (TOTAL_DURATION % 3600) / 60 )); SECONDS=$((TOTAL_DURATION % 60))
FORMATTED_DURATION=$(printf "%d days, %02d hours, %02d minutes, %02d seconds" ${DAYS} ${HOURS} ${MINUTES} ${SECONDS})

log_message "================== Entire Backup Process Finished =================="
log_message "Global Status: ${GLOBAL_PROCESS_STATUS}"
log_message "Total Process Time: ${FORMATTED_DURATION}"

exit 0
