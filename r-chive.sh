#!/bin/sh

# ==============================================================================
# CONFIGURATION & ARGUMENT PARSING
# ==============================================================================

# --- Initialize variables ---
CONFIG_FILE=""
DRY_RUN_MODE="no"
RSYNC_EXTRA_OPTS=""

# --- Loop through all arguments to find config file and options ---
for arg in "$@"; do
    case "$arg" in
        --dry-run)
            DRY_RUN_MODE="yes"
            RSYNC_EXTRA_OPTS="-n"
            ;;
        *)
            # This is not an option, so it could be a file path
            if [ -f "$arg" ]; then
                # Check if we've already found a config file
                if [ -n "$CONFIG_FILE" ]; then
                    echo "ERROR: More than one configuration file specified. Please provide only one." >&2
                    echo "Found: '$CONFIG_FILE' and '$arg'" >&2
                    exit 1
                fi
                CONFIG_FILE="$arg"
            fi
            ;;
    esac
done

# --- Configuration File Validation ---
if [ -z "$CONFIG_FILE" ]; then
    NON_OPTION_ARG=""
    for arg in "$@"; do
        if [ "$arg" != "--dry-run" ]; then
            NON_OPTION_ARG="$arg"
            break
        fi
    done

    if [ -n "$NON_OPTION_ARG" ]; then
         echo "ERROR: Configuration file not found at '$NON_OPTION_ARG'" >&2
    else
         echo "ERROR: No configuration file specified." >&2
    fi
    echo "Usage: $0 <path_to_config_file> [--dry-run]" >&2
    exit 1
fi

# --- Source Configuration ---
echo "INFO: Using configuration file: ${CONFIG_FILE}"
. "${CONFIG_FILE}"

# Announce dry run mode if enabled
if [ "$DRY_RUN_MODE" = "yes" ]; then
    echo "--- DRY RUN MODE ENABLED ---"
fi

LOG_FILE="${LOG_DIR}/backup-$(date +'%Y-%m-%d').log"

# --- Lock File Management ---
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

echo $$ > "${LOCK_FILE}"
trap 'rm -f "${LOCK_FILE}"' EXIT HUP INT QUIT TERM

# ==============================================================================
# HELPER FUNCTIONS
# ==============================================================================

log_message() {
    local message="$1"
    echo "$(date +'%Y-%m-%d %H:%M:%S') - ${message}" | tee -a "${LOG_FILE}"
}

# ==============================================================================
# MAIN SCRIPT LOGIC
# ==============================================================================

START_TIME=$(date +%s)
OVERALL_STATUS="SUCCESS"
REPORT_BODY=""
PROCESSED_TARGETS_LIST=""

ICON_SUCCESS="✅"
ICON_FAIL="❌"
ICON_INFO="ℹ️"
ICON_CLOCK="⏱️"
ICON_TARGET="🎯"
ICON_ARCHIVE="📦"

if [ ! -d "$LOG_DIR" ]; then
    mkdir -p "$LOG_DIR" || {
        echo "ERROR: Failed to create log directory."
        exit 1
    }
fi

log_message "================== Starting Rsync Backup Process =================="
REPORT_BODY="Rsync Backup Report - $(date +'%Y-%m-%d %H:%M:%S')\n\n"

PROCESSED_TARGETS=$(echo "${BACKUP_TARGETS}" | grep -v '^[[:space:]]*#' | grep -v '^[[:space:]]*$')

if [ -z "${PROCESSED_TARGETS}" ]; then
    log_message "No backup targets defined. Exiting."
    exit 0
fi

JOB_DIR=$(mktemp -d)
trap 'rm -rf "${JOB_DIR}"' EXIT HUP INT QUIT TERM

GLOBAL_PROCESS_STATUS="SUCCESS"
UNIQUE_HOSTS=$(echo "${PROCESSED_TARGETS}" | cut -d':' -f1 | cut -d'@' -f2 | sort -u)

for HOST in ${UNIQUE_HOSTS}; do
    HOST_START_TIME=$(date +%s)
    log_message "================== Starting Backup for Host: ${HOST} =================="

    HOST_TARGETS=$(echo "${PROCESSED_TARGETS}" | grep "@${HOST}:")
    PID_LIST=""
    for target in ${HOST_TARGETS}; do
        JOB_ID=$(echo "${target}" | md5)

        (
            # --- parse with optional port ---
            USER_HOST=$(echo "${target}" | cut -d':' -f1)
            REST=$(echo "${target}" | cut -d':' -f2-)
            FIRST_PART=$(echo "${REST}" | cut -d':' -f1)
            if echo "${FIRST_PART}" | grep -Eq '^[0-9]+$'; then
                PORT="${FIRST_PART}"
                REMOTE_SOURCE=$(echo "${REST}" | cut -d':' -f2-)
            else
                PORT=""
                REMOTE_SOURCE="${REST}"
            fi
            # -------------------------------

            log_message "Starting backup for target: ${target}"

            REMOTE_SOURCE_CLEAN=$(echo "${REMOTE_SOURCE}" | sed 's:/*$::')
            REMOTE_BASENAME=$(basename "${REMOTE_SOURCE_CLEAN}")
            REMOTE_DIRNAME=$(dirname "${REMOTE_SOURCE_CLEAN}")

            RSYNC_DEST="${BACKUP_DEST}/${HOST}/Live${REMOTE_DIRNAME}"
            RSYNC_SOURCE="${USER_HOST}:${REMOTE_SOURCE_CLEAN}"
            TARGET_DEST=$(echo "${RSYNC_DEST}/${REMOTE_BASENAME}" | sed 's://*:/:g')

            mkdir -p "${RSYNC_DEST}"
            RSYNC_OUTPUT_FILE="${JOB_DIR}/${JOB_ID}.output"

            # simpan target path untuk dipakai archive
            echo "${TARGET_DEST}" > "${JOB_DIR}/${JOB_ID}.target"

            SSH_OPTIONS=""
            [ -n "$SSH_KEY_PATH" ] && SSH_OPTIONS="-i ${SSH_KEY_PATH}"
            [ -n "$PORT" ] && SSH_OPTIONS="${SSH_OPTIONS} -p ${PORT}"

            RSYNC_OPTS="-azh --delete --stats --itemize-changes ${RSYNC_EXTRA_OPTS}"
            if [ "${LOG_VERBOSE}" = "yes" ]; then
                RSYNC_OPTS="-avzh --delete --stats --itemize-changes ${RSYNC_EXTRA_OPTS}"
            fi

            rsync ${RSYNC_OPTS} \
                  -e "ssh ${SSH_OPTIONS}" \
                  "${RSYNC_SOURCE}" \
                  "${RSYNC_DEST}" > "${RSYNC_OUTPUT_FILE}" 2>&1

            echo $? > "${JOB_DIR}/${JOB_ID}.exitcode"

        ) &

        PID_LIST="${PID_LIST} $!"
    done

    log_message "Waiting for all backup jobs on host ${HOST} to complete..."
    for pid in ${PID_LIST}; do
        wait "${pid}"
    done
    log_message "All backup jobs for host ${HOST} have finished."

    log_message "Processing results for host: ${HOST}"
    HOST_OVERALL_STATUS="SUCCESS"
    HOST_REPORT_BODY="Rsync Backup Report for Host: ${HOST} - $(date +'%Y-%m-%d %H:%M:%S')\n\n"
    HOST_PROCESSED_TARGETS_LIST=""

    for target in ${HOST_TARGETS}; do
        JOB_ID=$(echo "${target}" | md5)

        # ambil target dest yg dipakai rsync
        TARGET_DEST=$(cat "${JOB_DIR}/${JOB_ID}.target")

        RSYNC_EXIT_CODE=$(cat "${JOB_DIR}/${JOB_ID}.exitcode")
        RSYNC_STATS=$(cat "${JOB_DIR}/${JOB_ID}.output")
        HOST_REPORT_BODY="${HOST_REPORT_BODY}--------------------------------------------------\n"

        if [ ${RSYNC_EXIT_CODE} -eq 0 ]; then
            log_message "Backup for target ${target} SUCCESS."
            HOST_REPORT_BODY="${HOST_REPORT_BODY}${ICON_SUCCESS} Target: ${target}\n"
            HOST_REPORT_BODY="${HOST_REPORT_BODY}Status: SUCCESS\n"

            if [ "${CREATE_ARCHIVE}" = "yes" ]; then
                if [ "${DRY_RUN_MODE}" = "yes" ]; then
                    log_message "--- Archive creation SKIPPED for target ${target} (Dry Run Mode) ---"
                    HOST_REPORT_BODY="${HOST_REPORT_BODY}Archive Status: SKIPPED (Dry Run)\n"
                else
                    log_message "--- Starting Archive Creation for target ${target} ---"
                    SANITISED_FILENAME_PART=$(basename "${TARGET_DEST}")
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
                        HOST_OVERALL_STATUS="ERROR"
                        GLOBAL_PROCESS_STATUS="ERROR"
                    fi
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

    # --- HOST-LEVEL Snapshot Creation ---
    if [ "${CREATE_SNAPSHOT}" = "yes" ] && [ "${SNAPSHOT_RETENTION_COUNT}" -gt 0 ]; then
        if [ "${DRY_RUN_MODE}" = "yes" ]; then
            log_message "--- Host-level snapshot creation SKIPPED for host ${HOST} (Dry Run Mode) ---"
            HOST_REPORT_BODY="${HOST_REPORT_BODY}--------------------------------------------------\n"
            HOST_REPORT_BODY="${HOST_REPORT_BODY}Snapshot Status (Host ${HOST}): SKIPPED (Dry Run)\n"
        else
            log_message "--- Starting Host-level Snapshot Creation for host ${HOST} ---"
            HOST_BACKUP_DIR="${BACKUP_DEST}/${HOST}/Live"
            HOST_SNAPSHOT_BASE_DIR="${BACKUP_DEST}/${HOST}"

            if [ ! -d "${HOST_BACKUP_DIR}" ]; then
                log_message "WARNING: Host backup directory ${HOST_BACKUP_DIR} does not exist. Skipping snapshot."
                HOST_REPORT_BODY="${HOST_REPORT_BODY}--------------------------------------------------\n"
                HOST_REPORT_BODY="${HOST_REPORT_BODY}Snapshot Status (Host ${HOST}): SKIPPED (No Source)\n"
            else
                # 1. Delete the oldest snapshot if it exists
                OLDEST_INDEX=$((SNAPSHOT_RETENTION_COUNT - 1))
                OLDEST_SNAPSHOT="${HOST_SNAPSHOT_BASE_DIR}/Snapshot.${OLDEST_INDEX}"
                if [ -d "${OLDEST_SNAPSHOT}" ]; then
                    log_message "Snapshot Retention: Deleting oldest snapshot: ${OLDEST_SNAPSHOT}"
                    rm -rf "${OLDEST_SNAPSHOT}"
                fi

                # 2. Rotate the intermediate snapshots
                i=$((SNAPSHOT_RETENTION_COUNT - 2))
                while [ "$i" -ge 0 ]; do
                    SRC_SNAPSHOT="${HOST_SNAPSHOT_BASE_DIR}/Snapshot.${i}"
                    DEST_SNAPSHOT="${HOST_SNAPSHOT_BASE_DIR}/Snapshot.$((i + 1))"
                    if [ -d "${SRC_SNAPSHOT}" ]; then
                        log_message "Snapshot Retention: Rotating snapshot ${SRC_SNAPSHOT} to ${DEST_SNAPSHOT}"
                        mv "${SRC_SNAPSHOT}" "${DEST_SNAPSHOT}"
                    fi
                    i=$((i - 1))
                done

                # 3. Create the new snapshot from the live rsync directory
                NEW_SNAPSHOT="${HOST_SNAPSHOT_BASE_DIR}/Snapshot.0"
                log_message "Creating new snapshot: ${NEW_SNAPSHOT} from ${HOST_BACKUP_DIR}"
                cp -al "${HOST_BACKUP_DIR}" "${NEW_SNAPSHOT}"
                if [ $? -eq 0 ]; then
                    log_message "Snapshot for host ${HOST} created successfully."
                    HOST_REPORT_BODY="${HOST_REPORT_BODY}--------------------------------------------------\n"
                    HOST_REPORT_BODY="${HOST_REPORT_BODY}Snapshot Status (Host ${HOST}): SUCCESS\n"
                else
                    log_message "ERROR: Failed to create snapshot for host ${HOST}."
                    HOST_REPORT_BODY="${HOST_REPORT_BODY}--------------------------------------------------\n"
                    HOST_REPORT_BODY="${HOST_REPORT_BODY}Snapshot Status (Host ${HOST}): FAILED\n"
                    HOST_OVERALL_STATUS="ERROR"
                    GLOBAL_PROCESS_STATUS="ERROR"
                fi
            fi
        fi
    fi

    HOST_END_TIME=$(date +%s)
    HOST_DURATION=$((HOST_END_TIME - HOST_START_TIME))
    H_DAYS=$((HOST_DURATION / 86400)); H_HOURS=$(( (HOST_DURATION % 86400) / 3600 )); H_MINUTES=$(( (HOST_DURATION % 3600) / 60 )); H_SECONDS=$((HOST_DURATION % 60))
    HOST_FORMATTED_DURATION=$(printf "%d days, %02d hours, %02d minutes, %02d seconds" ${H_DAYS} ${H_HOURS} ${H_MINUTES} ${H_SECONDS})

    FINAL_STATUS_ICON="${ICON_SUCCESS}"
    if [ "${HOST_OVERALL_STATUS}" = "ERROR" ]; then FINAL_STATUS_ICON="${ICON_FAIL}"; fi

    REPORT_HEADER="${ICON_INFO} Backup Summary for Host: ${HOST}\n"
    REPORT_HEADER="${REPORT_HEADER}${FINAL_STATUS_ICON} Overall Status: ${HOST_OVERALL_STATUS}\n"
    REPORT_HEADER="${REPORT_HEADER}${ICON_CLOCK} Total Duration for Host: ${HOST_FORMATTED_DURATION}\n"
    REPORT_HEADER="${REPORT_HEADER}\nProcessed Targets on this Host:\n${HOST_PROCESSED_TARGETS_LIST}\n"

    log_message "Constructing and sending email report for host ${HOST}..."
    FROM_EMAIL="backup-reporter@$(hostname)"
    EMAIL_SUBJECT="Rsync Backup Report for ${HOST} from $(hostname) - Status: ${HOST_OVERALL_STATUS} ${FINAL_STATUS_ICON}"

    (
        echo "From: ${FROM_EMAIL}"; echo "To: ${REPORT_EMAIL}"; echo "Subject: ${EMAIL_SUBJECT}";
        echo "MIME-Version: 1.0"; echo "Content-Type: text/plain; charset=UTF-8"; echo "";
        echo -e "${REPORT_HEADER}${HOST_REPORT_BODY}"
    ) | /usr/sbin/sendmail -t

    log_message "Email report command executed for host ${HOST} to ${REPORT_EMAIL}."
done

END_TIME=$(date +%s)
TOTAL_DURATION=$((END_TIME - START_TIME))
DAYS=$((TOTAL_DURATION / 86400)); HOURS=$(( (TOTAL_DURATION % 86400) / 3600 )); MINUTES=$(( (TOTAL_DURATION % 3600) / 60 )); SECONDS=$((TOTAL_DURATION % 60))
FORMATTED_DURATION=$(printf "%d days, %02d hours, %02d minutes, %02d seconds" ${DAYS} ${HOURS} ${MINUTES} ${SECONDS})

log_message "================== Entire Backup Process Finished =================="
log_message "Global Status: ${GLOBAL_PROCESS_STATUS}"
log_message "Total Process Time: ${FORMATTED_DURATION}"

exit 0