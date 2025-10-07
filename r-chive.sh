#!/usr/local/bin/bash

# MIT License
#
# Copyright (c) 2025 alifgufron
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.


# ==============================================================================
# CONFIGURATION & ARGUMENT PARSING
# ==============================================================================

# --- Initialize variables ---
CONFIG_FILE=""
DRY_RUN_MODE="no"
RSYNC_EXTRA_OPTS=""
CMD_LINE_EXCLUDES=()

# --- Loop through all arguments to find config file and options ---
while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run)
            DRY_RUN_MODE="yes"
            RSYNC_EXTRA_OPTS="-n"
            shift # past argument
            ;;
        --exclude)
            if [ -n "$2" ]; then
                CMD_LINE_EXCLUDES+=("$2")
                shift 2 # past argument and value
            else
                echo "ERROR: --exclude requires an argument." >&2
                exit 1
            fi
            ;;
        *)
            # This should be the config file
            if [ -f "$1" ]; then
                if [ -n "$CONFIG_FILE" ]; then
                    echo "ERROR: More than one configuration file specified. Please provide only one." >&2
                    echo "Found: '$CONFIG_FILE' and '$1'" >&2
                    exit 1
                fi
                CONFIG_FILE="$1"
                shift # past argument
            else
                # Unknown option
                echo "ERROR: Unknown option or configuration file not found: $1" >&2
                echo "Usage: $0 <path_to_config_file> [--dry-run] [--exclude PATTERN]..." >&2
                exit 1
            fi
            ;;
    esac
done

# --- Configuration File Validation ---
if [ -z "$CONFIG_FILE" ]; then
    echo "ERROR: No configuration file specified." >&2
    echo "Usage: $0 <path_to_config_file> [--dry-run] [--exclude PATTERN]..." >&2
    exit 1
fi

# --- Source Configuration ---
echo "INFO: Using configuration file: ${CONFIG_FILE}"
. "${CONFIG_FILE}"

# Announce dry run mode if enabled
if [ "$DRY_RUN_MODE" = "yes" ]; then
    echo "--- DRY RUN MODE ENABLED ---"
fi

# --- Console Mode & Color Initialization ---
CONSOLE_MODE="no"
# Check if stdout is a terminal
if [ -t 1 ]; then
    CONSOLE_MODE="yes"
fi

# Define colors, but only if in console mode
if [ "${CONSOLE_MODE}" = "yes" ]; then
    COLOR_RED='\033[0;31m'
    COLOR_GREEN='\033[0;32m'
    COLOR_YELLOW='\033[0;33m'
    COLOR_BLUE='\033[0;34m'
    COLOR_NC='\033[0m' # No Color
else
    # If not in console mode, make color variables empty
    COLOR_RED=''
    COLOR_GREEN=''
    COLOR_YELLOW=''
    COLOR_BLUE=''
    COLOR_NC=''
fi

LOG_FILE="${LOG_DIR}/r-chive.log"

# --- Lock File Management ---
LOCK_DIR="/var/run/r-chive"
if [ ! -d "${LOCK_DIR}" ]; then
    mkdir -p "${LOCK_DIR}" || { 
        echo "ERROR: Failed to create lock directory ${LOCK_DIR}. Please check permissions."
        exit 1
    }
fi
CONFIG_BASENAME=$(basename "${CONFIG_FILE}")
LOCK_FILE="${LOCK_DIR}/${CONFIG_BASENAME}.lock"

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

# ==============================================================================
# HELPER FUNCTIONS
# ==============================================================================

log_message() {
    local message="$1"
    local color="${COLOR_NC}" # Default to no color

    # Determine color based on message content
    # Using `case` for efficient string matching
    case "${message}" in
        ERROR* | FATAL* | FAILED*) color="${COLOR_RED}" ;;
        SUCCESS*) color="${COLOR_GREEN}" ;;
        WARN* | WARNING*) color="${COLOR_YELLOW}" ;;
        INFO* | Starting* | Executing* | Waiting* | Processing* | Constructing*) color="${COLOR_BLUE}" ;;
    esac

    local timestamp
    timestamp=$(date +' %Y-%m-%d %H:%M:%S')
    local plain_message="${timestamp} - ${message}"
    local colorized_message="${timestamp} - ${color}${message}${COLOR_NC}"

    # Log to files
    echo "${plain_message}" >> "${LOG_FILE}"
    if [ "${LOG_PER_HOST}" = "yes" ] && [ -n "${CURRENT_HOST_LOG_FILE}" ]; then
        echo "${plain_message}" >> "${CURRENT_HOST_LOG_FILE}"
    fi

    # Also log to console if in interactive mode
    if [ "${CONSOLE_MODE}" = "yes" ]; then
        echo -e "${colorized_message}"
    fi
}

send_host_start_notification_email() {
    local host="$1"
    # The second argument is the list of jobs, passed as a single string
    local host_jobs_list="$2"

    # Check if email reporting is enabled at all or if this feature is turned off
    if [ -z "${REPORT_EMAIL}" ] || [ "${SEND_START_NOTIFICATION}" != "yes" ]; then
        return
    fi

    local from_email="backup-starter@$(hostname)"
    local email_subject="${ICON_START} [Backup Started] For Host: ${host} - From $(hostname)"
    local job_details_body=""

    # Loop through the job names to build the details
    for job_name in ${host_jobs_list}; do
        local src_var_name="${job_name}_SRC"
        local src_value="${!src_var_name}"
        job_details_body+="  - Job: ${job_name}\n"
        job_details_body+="    Source: ${src_value}\n\n"
    done

    # If there are no jobs, don't send an email
    if [ -z "${job_details_body}" ]; then
        return
    fi

    local email_body=""
    email_body+="A backup process has been initiated for host: ${host}\n\n"
    email_body+="The following jobs will be executed:\n"
    email_body+="${job_details_body}"
    email_body+="Time: $(date +'%Y-%m-%d %H:%M:%S')\n"

    (
        echo "From: ${from_email}";
        echo "To: ${REPORT_EMAIL}";
        echo "Subject: ${email_subject}";
        echo "MIME-Version: 1.0";
        echo "Content-Type: text/plain; charset=UTF-8";
        echo "";
        echo -e "${email_body}";
    ) | /usr/sbin/sendmail -t
}

# --- Cleanup and Signal Handling ---
cleanup() {
    log_message "CLEANUP: Removing lock file and temporary directory."
    rm -f "${LOCK_FILE}"
    rm -rf "${JOB_DIR}"
}

handle_interrupt() {
    echo "" # Add a newline in the console for cleaner output
    log_message "INTERRUPT: Signal received. Shutting down child processes."
    # Kill all background PIDs that have been tracked
    if [ -n "${PID_LIST}" ]; then
        kill ${PID_LIST} 2>/dev/null
    fi
    # Exit with code 130 (standard for Ctrl+C)
    # The EXIT trap will handle the actual file cleanup.
    exit 130
}

# ==============================================================================
# MAIN SCRIPT LOGIC
# ==============================================================================

START_TIME=$(date +%s)

ICON_SUCCESS="✅"
ICON_FAIL="❌"
ICON_INFO="ℹ️"
ICON_START="🚀"
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

if [ -z "${BACKUP_JOBS}" ]; then
    log_message "No backup jobs defined in BACKUP_JOBS. Exiting."
    exit 0
fi

JOB_DIR=$(mktemp -d)
# Set traps: cleanup on exit, handle_interrupt on INT/QUIT/TERM
trap cleanup EXIT
trap handle_interrupt INT QUIT TERM

GLOBAL_PROCESS_STATUS="SUCCESS"

# --- Validate Jobs and Build a list of unique hosts ---
UNIQUE_HOSTS=""
CONFIG_IS_VALID="yes"

log_message "INFO: Validating job configurations..."
for job_name in ${BACKUP_JOBS}; do
    # 1. Validate job name format for shell variable compatibility
    if ! echo "${job_name}" | grep -qE '^[a-zA-Z0-9_]+$'; then
        log_message "FATAL: Job name '${job_name}' contains invalid characters. Only letters, numbers, and underscores are allowed."
        CONFIG_IS_VALID="no"
        GLOBAL_PROCESS_STATUS="FAILURE"
        continue
    fi

    # 2. Check if the _SRC variable for the job is defined and get host
    src_var_name="${job_name}_SRC"
    src_value="${!src_var_name}"
    if [ -z "${src_value}" ]; then
        log_message "FATAL: Job '${job_name}' is listed in BACKUP_JOBS but its source variable (${src_var_name}) is not defined or is empty."
        CONFIG_IS_VALID="no"
        GLOBAL_PROCESS_STATUS="FAILURE"
    else
        # If valid, add host to list
        host=$(echo "${src_value}" | cut -d':' -f1 | cut -d'@' -f2)
        UNIQUE_HOSTS="${UNIQUE_HOSTS} ${host}"
    fi
done

# If config is invalid, abort before processing
if [ "${CONFIG_IS_VALID}" = "no" ]; then
    log_message "FATAL: Backup process aborted due to invalid configuration. Please fix the errors above."
    # The global status is already set to FAILURE, so the final report will be correct.
    # We need to skip the main processing loop.
    UNIQUE_HOSTS="" # Clear hosts to prevent the next loop from running
fi
UNIQUE_HOSTS=$(echo "${UNIQUE_HOSTS}" | tr ' ' '\n' | sort -u)

# ==============================================================================
# PROCESS EACH HOST
# ==============================================================================
for HOST in ${UNIQUE_HOSTS}; do
    HOST_START_TIME=$(date +%s)
    CURRENT_HOST_LOG_FILE=""
    if [ "${LOG_PER_HOST}" = "yes" ]; then
        HOST_LOG_DIR="${LOG_DIR}/${HOST}"
        mkdir -p "${HOST_LOG_DIR}"
        CURRENT_HOST_LOG_FILE="${HOST_LOG_DIR}/$(date +'%Y-%m-%d').log"
    fi

    log_message "================== Starting Backup for Host: ${HOST} =================="

    HOST_JOBS=""
    for job_name in ${BACKUP_JOBS}; do
        src_var_name="${job_name}_SRC"
        src_value="${!src_var_name}"
        host_in_job=$(echo "${src_value}" | cut -d':' -f1 | cut -d'@' -f2)
        if [ "${host_in_job}" = "${HOST}" ]; then
            HOST_JOBS="${HOST_JOBS} ${job_name}"
        fi
    done

    # --- Send Host Start Notification Email ---
    # Fork the email sending process to not slow down the main script
    ( send_host_start_notification_email "${HOST}" "${HOST_JOBS}" ) &

    # --- Host-level SSH Port Pre-check ---
    # We only need to check connectivity once per host.
    FIRST_JOB_FOR_HOST=$(echo "${HOST_JOBS}" | awk '{print $1}')
    if [ -z "${FIRST_JOB_FOR_HOST}" ]; then
        continue # No jobs for this host, skip.
    fi

    # Get connection details from the first job
    first_job_src_var="${FIRST_JOB_FOR_HOST}_SRC"
    first_job_src_val="${!first_job_src_var}"
    REST_CHK=$(echo "${first_job_src_val}" | cut -d':' -f2-)
    FIRST_PART_CHK=$(echo "${REST_CHK}" | cut -d':' -f1)
    if echo "${FIRST_PART_CHK}" | grep -Eq '^[0-9]+$'; then
        PORT_CHK="${FIRST_PART_CHK}"
    else
        PORT_CHK="22" # Default SSH port
    fi

    log_message "Checking SSH connectivity to ${HOST} on port ${PORT_CHK}..."
    nc_output=$(nc -zvw1 "${HOST}" "${PORT_CHK}" 2>&1)
    if [ $? -ne 0 ]; then
        log_message "ERROR: SSH port ${PORT_CHK} on ${HOST} is not open. Skipping all jobs for this host. Detail: ${nc_output}"
        GLOBAL_PROCESS_STATUS="FAILURE"
        continue # Skip to the next host
    else
        log_message "SSH connectivity to ${HOST} on port ${PORT_CHK} successful."
    fi

    PID_LIST=""
    for job_name in ${HOST_JOBS}; do
        (
            src_var_name="${job_name}_SRC"
            excludes_var_name="${job_name}_EXCLUDES"
            
            target="${!src_var_name}"
            excludes="${!excludes_var_name}"

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

            # Destination is the host's Live directory. --relative will create subdirs.
            RSYNC_DEST="${BACKUP_DEST}/${HOST}/Live/"


            log_message "Starting backup for job '${job_name}': ${target}"

            # Source path for rsync. No trailing slash.
            RSYNC_SOURCE="${USER_HOST}:${REMOTE_SOURCE}"

            # TARGET_DEST must point to the final location of the content for other logic (like archiving).
            # It's the base destination + the full remote source path.
            TARGET_DEST="${RSYNC_DEST}${REMOTE_SOURCE}"
            TARGET_DEST=$(echo "${TARGET_DEST}" | sed 's://*:/:g') # Clean up slashes

            mkdir -p "${RSYNC_DEST}"
            RSYNC_OUTPUT_FILE="${JOB_DIR}/${job_name}.output"

            echo "${target}" > "${JOB_DIR}/${job_name}.target_string"
            echo "${TARGET_DEST}" > "${JOB_DIR}/${job_name}.target_dest"

            SSH_OPTIONS=""
            [ -n "$SSH_KEY_PATH" ] && SSH_OPTIONS="-i ${SSH_KEY_PATH}"
            [ -n "$PORT" ] && SSH_OPTIONS="${SSH_OPTIONS} -p ${PORT}"

            RSYNC_OPTS_ARRAY=()
            if [ "${LOG_VERBOSE}" = "yes" ]; then
                # Use -v and --progress for detailed, real-time logging
                RSYNC_OPTS_ARRAY+=("-avzhR" "--progress")
            else
                # Quieter operation
                RSYNC_OPTS_ARRAY+=("-azhR")
            fi
            RSYNC_OPTS_ARRAY+=("--delete" "--stats" "--itemize-changes" ${RSYNC_EXTRA_OPTS})

            # Add excludes from config file
            while IFS= read -r pattern; do
                pattern=$(echo "$pattern" | sed -e 's/^[[:space:]│]*//' -e 's/[[:space:]]*$//')
                if [ -n "$pattern" ] && ! echo "$pattern" | grep -q '^[[:space:]]*#'; then
                    RSYNC_OPTS_ARRAY+=("--exclude=${pattern}")
                fi
            done <<< "${excludes}"

            # Add excludes from command line
            for pattern in "${CMD_LINE_EXCLUDES[@]}"; do
                RSYNC_OPTS_ARRAY+=("--exclude=${pattern}")
            done
            
            # --- Execute Rsync ---
            # The SSH port pre-check has been moved to the host-level loop.
            log_message "Executing rsync for job '${job_name}': ${RSYNC_SOURCE} -> ${RSYNC_DEST}"
            if [ "${LOG_PER_HOST}" = "yes" ] && [ -n "${CURRENT_HOST_LOG_FILE}" ]; then
                # Pipe to tee to get real-time output in the host log, and also save to the temp file for email parsing
                stdbuf -oL rsync "${RSYNC_OPTS_ARRAY[@]}" -e "ssh ${SSH_OPTIONS}" "${RSYNC_SOURCE}" "${RSYNC_DEST}" 2>&1 | tee -a "${CURRENT_HOST_LOG_FILE}" > "${RSYNC_OUTPUT_FILE}"
            else
                # Original behavior if per-host logging is off
                rsync "${RSYNC_OPTS_ARRAY[@]}" -e "ssh ${SSH_OPTIONS}" "${RSYNC_SOURCE}" "${RSYNC_DEST}" > "${RSYNC_OUTPUT_FILE}" 2>&1
            fi
            RSYNC_EXIT_CODE=$?
            log_message "Rsync for job '${job_name}' finished with exit code ${RSYNC_EXIT_CODE}."
            echo "${RSYNC_EXIT_CODE}" > "${JOB_DIR}/${job_name}.exitcode"


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
    HOST_REPORT_BODY=""
    HOST_PROCESSED_TARGETS_LIST=""
    ATTACHMENT_FILE="${JOB_DIR}/${HOST}-details.log"

    for job_name in ${HOST_JOBS}; do
        target_string=$(cat "${JOB_DIR}/${job_name}.target_string")
        TARGET_DEST=$(cat "${JOB_DIR}/${job_name}.target_dest")
        RSYNC_EXIT_CODE=$(cat "${JOB_DIR}/${job_name}.exitcode")
        # For the email report, read the output and strip out the progress lines (which contain carriage returns)
        RSYNC_STATS=$(sed '/\r/d' "${JOB_DIR}/${job_name}.output")
        
        # The full rsync output is now streamed directly to the per-host log in real-time via tee.
        # This block is no longer needed and has been removed to prevent duplicate logging.

        # Format the rsync output for better readability in the attachment
        ITEMIZED_LIST=$(echo "${RSYNC_STATS}" | grep -E '^[.>]' || true)
        STATS_BLOCK=$(echo "${RSYNC_STATS}" | grep -Ev '^[.>]' || true)

        FORMATTED_STATS=""
        if [ -n "${ITEMIZED_LIST}" ]; then
            FORMATTED_STATS="=== Change Details ===\n${ITEMIZED_LIST}\n\n"
        fi
        FORMATTED_STATS="${FORMATTED_STATS}=== Sync Statistics ===\n${STATS_BLOCK}"

        echo "--------------------------------------------------" >> "${ATTACHMENT_FILE}"
        echo "Job: ${job_name} (${target_string})" >> "${ATTACHMENT_FILE}"
        echo "--------------------------------------------------" >> "${ATTACHMENT_FILE}"
        echo -e "${FORMATTED_STATS}\n" >> "${ATTACHMENT_FILE}"

        HOST_REPORT_BODY="${HOST_REPORT_BODY}--------------------------------------------------\n"

        if [ ${RSYNC_EXIT_CODE} -eq 0 ]; then
            log_message "SUCCESS: Backup for job '${job_name}'."
            HOST_REPORT_BODY="${HOST_REPORT_BODY}${ICON_SUCCESS} Job: ${job_name} (${target_string})\n"
            HOST_REPORT_BODY="${HOST_REPORT_BODY}Status: SUCCESS\n"

            if [ "${CREATE_ARCHIVE}" = "yes" ]; then
                if [ "${DRY_RUN_MODE}" = "yes" ]; then
                    log_message "WARNING: Archive creation SKIPPED for job '${job_name}' (Dry Run Mode) ---"
                    HOST_REPORT_BODY="${HOST_REPORT_BODY}Archive Status: SKIPPED (Dry Run)\n"
                else
                    log_message "INFO: Starting Archive Creation for job '${job_name}' ---"
                    SANITISED_FILENAME_PART=$(basename "${TARGET_DEST}")
                    YEAR=$(date +'%Y'); MONTH=$(date +'%m')
                    ARCHIVE_DIR="${ARCHIVE_DEST}/${HOST}/${YEAR}/${MONTH}"
                    mkdir -p "${ARCHIVE_DIR}"
                    ARCHIVE_FILE="${ARCHIVE_DIR}/${SANITISED_FILENAME_PART}-$(date +'%Y-%m-%d_%H%M%S').tar.zst"
                    log_message "INFO: Creating compressed archive: ${ARCHIVE_FILE}"
                    
                    # Execute tar and capture any error output
                    TAR_OUTPUT=$(tar --zstd -cf "${ARCHIVE_FILE}" -C "${TARGET_DEST}" . 2>&1)
                    TAR_EXIT_CODE=$?

                    if [ ${TAR_EXIT_CODE} -eq 0 ]; then
                        ARCHIVE_SIZE=$(du -h "${ARCHIVE_FILE}" | cut -f1)
                        log_message "SUCCESS: Archive for job '${job_name}' created successfully. Size: ${ARCHIVE_SIZE}"
                        HOST_REPORT_BODY="${HOST_REPORT_BODY}Archive Status: SUCCESS - ${ARCHIVE_FILE} (Size: ${ARCHIVE_SIZE})\n"

                        if [ -n "${ARCHIVE_RETENTION_DAYS}" ] && [ "${ARCHIVE_RETENTION_DAYS}" -gt 0 ]; then
                            log_message "INFO: Retention Policy: Deleting archives for job '${job_name}' older than ${ARCHIVE_RETENTION_DAYS} days."
                            find "${ARCHIVE_DEST}/${HOST}" -name "${SANITISED_FILENAME_PART}-*.tar.zst" -type f -mtime "+${ARCHIVE_RETENTION_DAYS}" -print -delete | while IFS= read -r f; do [ -n "$f" ] && log_message "INFO: Retention (by day): Deleted old archive: $f"; done
                        elif [ -n "${ARCHIVE_RETENTION_COUNT}" ] && [ "${ARCHIVE_RETENTION_COUNT}" -gt 0 ]; then
                            ARCHIVES_FOUND=$(find "${ARCHIVE_DEST}/${HOST}" -name "${SANITISED_FILENAME_PART}-*.tar.zst" -type f)
                            COUNT=$(echo "${ARCHIVES_FOUND}" | wc -l)
                            if [ "$COUNT" -gt "${ARCHIVE_RETENTION_COUNT}" ]; then
                                NUM_TO_DELETE=$((COUNT - ARCHIVE_RETENTION_COUNT))
                                log_message "INFO: Retention Policy: (by count) Found ${COUNT} archives, limit is ${ARCHIVE_RETENTION_COUNT}. Deleting ${NUM_TO_DELETE} oldest."
                                find "${ARCHIVE_DEST}/${HOST}" -name "${SANITISED_FILENAME_PART}-*.tar.zst" -type f -exec stat -f '%m %N' {} + | sort -n | head -n "${NUM_TO_DELETE}" | cut -d' ' -f2- | while IFS= read -r f; do [ -n "$f" ] && log_message "INFO: Retention (by count): Deleting old archive: $f" && rm -f "$f"; done
                            fi
                        fi
                    else
                        log_message "ERROR: Failed to create archive for job '${job_name}'. Exit Code: ${TAR_EXIT_CODE}"
                        log_message "ERROR Detail: ${TAR_OUTPUT}"
                        HOST_REPORT_BODY="${HOST_REPORT_BODY}Archive Status: FAILED\n"
                        HOST_OVERALL_STATUS="ERROR"
                        GLOBAL_PROCESS_STATUS="ERROR"
                    fi
                fi
            fi
        else
            # Extract a short error message for global log and email
            if [ "${RSYNC_EXIT_CODE}" -eq 127 ]; then
                # If it's an nc pre-check failure, the RSYNC_OUTPUT_FILE already contains the nc error
                SHORT_ERROR_MESSAGE=$(cat "${JOB_DIR}/${job_name}.output")
            else
                # Otherwise, it's a regular rsync failure, parse the output
                SHORT_ERROR_MESSAGE=$(grep -v "rsync error:" "${JOB_DIR}/${job_name}.output" | head -n 1)
                if [ -z "${SHORT_ERROR_MESSAGE}" ]; then
                    SHORT_ERROR_MESSAGE="No specific error message found in rsync output."
                fi
            fi
            echo "DEBUG: SHORT_ERROR_MESSAGE after initial extraction: [${SHORT_ERROR_MESSAGE}]" >> "${JOB_DIR}/debug_host_report_body_${HOST}.txt"
            
            # Ensure SHORT_ERROR_MESSAGE is a single, trimmed line for email display
            SHORT_ERROR_MESSAGE=$(echo "${SHORT_ERROR_MESSAGE}" | tr -d '\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
            log_message "ERROR: Backup for job '${job_name}' FAILED with exit code ${RSYNC_EXIT_CODE}. Detail: ${SHORT_ERROR_MESSAGE}"
            HOST_OVERALL_STATUS="ERROR"
            GLOBAL_PROCESS_STATUS="ERROR"
            HOST_REPORT_BODY="${HOST_REPORT_BODY}${ICON_FAIL} Job: ${job_name} (${target_string})\n"
            HOST_REPORT_BODY="${HOST_REPORT_BODY}Status: FAILED (Code: ${RSYNC_EXIT_CODE})
"
            HOST_REPORT_BODY="${HOST_REPORT_BODY}Error Detail:
"
            HOST_REPORT_BODY="${HOST_REPORT_BODY}${SHORT_ERROR_MESSAGE}
"
        fi

        HOST_PROCESSED_TARGETS_LIST="${HOST_PROCESSED_TARGETS_LIST}  ${ICON_TARGET} ${job_name} (${target_string})\n"
    done

    if [ "${CREATE_SNAPSHOT}" = "yes" ] && [ "${SNAPSHOT_RETENTION_COUNT}" -gt 0 ]; then
        if [ "${DRY_RUN_MODE}" = "yes" ]; then
            log_message "WARNING: Host-level snapshot creation SKIPPED for host ${HOST} (Dry Run Mode) ---"
            HOST_REPORT_BODY="${HOST_REPORT_BODY}--------------------------------------------------\n"
            HOST_REPORT_BODY="${HOST_REPORT_BODY}Snapshot Status (Host ${HOST}): SKIPPED (Dry Run)\n"
        else
            log_message "INFO: Starting Host-level Snapshot Creation for host ${HOST} ---"
            HOST_BACKUP_DIR="${BACKUP_DEST}/${HOST}/Live"
            HOST_SNAPSHOT_BASE_DIR="${BACKUP_DEST}/${HOST}"

            if [ ! -d "${HOST_BACKUP_DIR}" ]; then
                log_message "WARNING: Host backup directory ${HOST_BACKUP_DIR} does not exist. Skipping snapshot."
                HOST_REPORT_BODY="${HOST_REPORT_BODY}--------------------------------------------------\n"
                HOST_REPORT_BODY="${HOST_REPORT_BODY}Snapshot Status (Host ${HOST}): SKIPPED (No Source)\n"
            else
                OLDEST_INDEX=$((SNAPSHOT_RETENTION_COUNT - 1))
                OLDEST_SNAPSHOT="${HOST_SNAPSHOT_BASE_DIR}/Snapshot.${OLDEST_INDEX}"
                if [ -d "${OLDEST_SNAPSHOT}" ]; then
                    log_message "Snapshot Retention: Deleting oldest snapshot: ${OLDEST_SNAPSHOT}"
                    rm -rf "${OLDEST_SNAPSHOT}"
                fi

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

                NEW_SNAPSHOT="${HOST_SNAPSHOT_BASE_DIR}/Snapshot.0"
                log_message "INFO: Creating new snapshot: ${NEW_SNAPSHOT} from ${HOST_BACKUP_DIR}"
                
                # Execute cp and capture any error output
                CP_OUTPUT=$(cp -al "${HOST_BACKUP_DIR}" "${NEW_SNAPSHOT}" 2>&1)
                CP_EXIT_CODE=$?

                if [ ${CP_EXIT_CODE} -eq 0 ]; then
                    log_message "SUCCESS: Snapshot for host ${HOST} created successfully."
                    HOST_REPORT_BODY="${HOST_REPORT_BODY}--------------------------------------------------\n"
                    HOST_REPORT_BODY="${HOST_REPORT_BODY}Snapshot Status (Host ${HOST}): SUCCESS\n"
                else
                    log_message "ERROR: Failed to create snapshot for host ${HOST}. Exit Code: ${CP_EXIT_CODE}"
                    log_message "ERROR Detail: ${CP_OUTPUT}"
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

    REPORT_HEADER="Rsync Backup Report for Host: ${HOST} - $(date +' %Y-%m-%d %H:%M:%S')\n\n"
    REPORT_HEADER="${REPORT_HEADER}${ICON_INFO} Backup Summary for Host: ${HOST}\n"
    REPORT_HEADER="${REPORT_HEADER}${FINAL_STATUS_ICON} Overall Status: ${HOST_OVERALL_STATUS}\n"
    REPORT_HEADER="${REPORT_HEADER}${ICON_CLOCK} Total Duration for Host: ${HOST_FORMATTED_DURATION}\n"
    REPORT_HEADER="${REPORT_HEADER}\nProcessed Jobs on this Host:\n${HOST_PROCESSED_TARGETS_LIST}\n"

    log_message "Constructing and sending email report for host ${HOST}..."
    FROM_EMAIL="backup-reporter@$(hostname)"
    EMAIL_SUBJECT="[Backup Finished] Report for ${HOST} - From $(hostname) - Status: ${HOST_OVERALL_STATUS}"

    # DEBUG: Print HOST_REPORT_BODY to a file
    echo "${HOST_REPORT_BODY}" > "${JOB_DIR}/debug_host_report_body_${HOST}.txt"

    if [ "${REPORT_EMAIL_VERBOSE}" = "yes" ] && [ -f "${ATTACHMENT_FILE}" ]; then
        BOUNDARY="R-CHIVE-BOUNDARY-$(date +%s)"
        (
            echo "From: ${FROM_EMAIL}";
            echo "To: ${REPORT_EMAIL}";
            echo "Subject: ${EMAIL_SUBJECT}";
            echo "MIME-Version: 1.0";
            echo "Content-Type: multipart/mixed; boundary=\"${BOUNDARY}\""
            echo "";
            echo "--${BOUNDARY}";
            echo "Content-Type: text/plain; charset=UTF-8";
            echo "Content-Disposition: inline";
            echo "";
            echo -e "${REPORT_HEADER}${HOST_REPORT_BODY}";
            echo "";
            echo "--${BOUNDARY}";
            ATTACHMENT_FILENAME="backup-details-${HOST}-$(date +' %Y-%m-%d').log"
            echo "Content-Type: text/plain; charset=UTF-8; name=\"${ATTACHMENT_FILENAME}\""
            echo "Content-Disposition: attachment; filename=\"${ATTACHMENT_FILENAME}\""
            echo "";
            cat "${ATTACHMENT_FILE}";
            echo "";
            echo "--${BOUNDARY}--";
        ) | /usr/sbin/sendmail -t
    else
        (
            echo "From: ${FROM_EMAIL}";
            echo "To: ${REPORT_EMAIL}";
            echo "Subject: ${EMAIL_SUBJECT}";
            echo "MIME-Version: 1.0";
            echo "Content-Type: text/plain; charset=UTF-8";
            echo "";
            echo -e "${REPORT_HEADER}${HOST_REPORT_BODY}";
        ) | /usr/sbin/sendmail -t
    fi

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