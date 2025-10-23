# r-chive.sh

## 1. Overview

`r-chive.sh` is a flexible shell script for automating backups from multiple remote servers using `rsync`. It is designed to be robust, easy to configure, and provides detailed feedback through logs and email reports.

The script's core philosophy is a job-based system. You define a list of backup "jobs," and for each job, you specify a source and a list of exclusion patterns. This provides highly granular control over your backups.

It performs a "mirror" backup for each specified host. Thanks to `rsync`'s `--relative` (`-R`) option, the full source path is recreated within a `Live` directory at the destination. After a successful sync, it can create compressed archives for each backup job and/or space-efficient, point-in-time snapshots at the **host level**.

## 2. Features

- **Job-Based Configuration**: A clean, powerful system where you define backup jobs and control them from a master list.
- **Strict Job Name Validation**: Job names are validated to ensure they only contain letters, numbers, and underscores, preventing common configuration errors.
- **Comprehensive Rsync Options**: Utilizes `rsync -aHAXxv` (archive mode, preserve hardlinks, ACLs, extended attributes, one-filesystem, verbose) for robust and complete system backups, ensuring full fidelity for restore operations.
- **Path-Preserving Backups**: Uses `rsync`'s relative path feature to automatically replicate the source directory structure at the destination.
- **Per-Job Exclusions**: Easily specify a list of files and directories to exclude for each backup job individually via the config file.
- **Global Excludes**: A command-line `--exclude` parameter allows you to add temporary, global exclusion patterns for a single run.
- **Efficient SSH Port Pre-check**: Automatically checks if the remote SSH port is open **once per host**, providing faster feedback on connectivity issues.
- **Host-Level Snapshots**: Creates space-efficient, point-in-time snapshots of an entire host's backup directory using hard links.
- **Granular Archiving**: Creates a separate, clean `.tar.zst` archive for each individual backup job.
- **Advanced Logging**: 
    - A clean, high-level global log file (`r-chive.log`).
    - Optional, detailed per-host logs organized into subdirectories (`HOST/DATE.log`).
    - **Live Console Logging**: When run in an interactive terminal, all log output is streamed to the console in real-time with color-coding for readability (Errors in red, success in green, etc.).
    - **Monitor Mode** (`LOG_VERBOSE=yes`): View real-time transfer progress in the per-host log, perfect for `tail -f`.
- **Flexible Email Reports**: Choose between a concise summary report or a summary with a detailed log file as an attachment. The attached log is always clean, even in monitor mode.
- **Flexible Disk Usage Reporting**: Optionally include the total size of each backup job in the email report. This can be disabled for performance on very large filesystems.
- **Selectable `du` Tool**: Choose between the standard `du` command or a faster alternative like `gdu` for disk usage calculation.
- **Start Notification Emails**: Sends an email notification when a backup process for a host begins, providing immediate confirmation that the job has started.
- **Improved Error Reporting**: Robustly captures and logs the specific `stderr` output from critical commands (`rsync`, `tar`, `cp`), ensuring no error goes unnoticed. Failed jobs include an actionable error message in the global log and email body.
- **Parallel Backups**: Executes backups for all jobs on a single host concurrently, significantly reducing total backup time.
- **Efficient Localhost Backups**: Intelligently detects `localhost` as a target and performs a direct local `rsync` (without SSH) for maximum efficiency.
- **Custom SSH Port Support**: Specify a custom SSH port directly in the job's source string.
- **Flexible Retention Policies**: Clean up old archives and snapshots based on time (days) or count.
- **Configuration-Specific Locking**: A robust lock file mechanism prevents multiple instances using the same configuration from running simultaneously, while allowing parallel execution of different backup configurations.
- **Dry Run Mode**: A `--dry-run` mode allows you to test your configuration safely.
- **Robust Interrupt Handling**: Gracefully terminates all running jobs and performs a clean exit when interrupted (e.g., via `Ctrl+C`).

## 3. Prerequisites

- **On the Backup Server**: `rsync`, `zstd`, `nc` (netcat), a configured MTA (like `sendmail`), and an SSH client. **Optional**: `gdu` for faster disk usage calculation.
- **On ALL Remote Servers**: `rsync` must be installed.

## 4. Configuration

Configuration is managed via a `.conf` file passed as an argument to the script.

### Command-Line Arguments

The script accepts the following command-line arguments:

| Argument            | Description                                                                                                                            |
| ------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| `config_file`       | **(Required)** The path to your configuration file.                                                                                    |
| `--dry-run`         | (Optional) Simulates the backup process without making any actual changes.                                                             |
| `--check-conf`      | (Optional) Performs a comprehensive, read-only check of the configuration, connectivity, and paths, then exits. Does not transfer any data. |
| `--exclude PATTERN` | (Optional) Adds a temporary exclusion pattern that applies to all jobs for this run. Can be used multiple times. e.g. `--exclude "*.log"`. |

### How It Works

1.  You define a master list of job names in the `BACKUP_JOBS` array.
2.  For each job name, you define its properties using variables prefixed with that name (e.g., `myjob_SRC`, `myjob_EXCLUDES`).
3.  The script only executes jobs whose names are present in the `BACKUP_JOBS` list.

### Configuration Variables

| Variable                      | Description                                                                                                                                                                                                                                                                                            |
| ----------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `BACKUP_JOBS`                 | **(Required)** A space-separated list of all backup job names you want to **activate**. **Note:** Job names must only contain letters, numbers, and underscores (e.g., `server1_db`, not `server-1-db`).                                                                                                  |
| `[job_name]_SRC`              | **(Required)** The source for a specific backup job. The `[job_name]` prefix must match a name in `BACKUP_JOBS`. <br> - For remote: `"user@host:/path/to/source"` or `"user@host:PORT:/path/to/source"`. <br> - For local: `"localhost:/path/to/source"`. The script will automatically use a direct local copy. |
| `[job_name]_EXCLUDES`         | (Optional) A multi-line string containing file or directory patterns to exclude for this specific job. One pattern per line. These are passed to `rsync`'s `--exclude` option.                                                                                                                            |
| `BACKUP_NAME`                 | (Optional) A descriptive name for this backup set (e.g., "Daily", "Weekly"). This name is automatically formatted and included in email subject lines for better context. Defaults to "General".                                                                                             |
| `BACKUP_DEST`                 | **(Required)** The top-level directory on the backup server where host-specific folders (e.g., `10.11.1.121/`) will be created.                                                                                                                                                                            |
| `SSH_KEY_PATH`                | (Optional) Absolute path to the **private** SSH key. Leave empty to use the default key.                                                                                                                                                                                                               |
| `REPORT_EMAIL`                | The destination email address for backup reports.                                                                                                                                                                                                                                                   |
| `REPORT_EMAIL_VERBOSE`        | Set to `"no"` for a short summary email. Set to `"yes"` to include a detailed log file as an attachment in the email.                                                                                                                                                                                   |
| `SEND_START_NOTIFICATION`     | Set to `"yes"` to send a notification email when a backup for a host begins.                                                                                                                                                                                                                             |
| `REPORT_SHOW_JOB_SIZE`        | Set to `"yes"` to show the total size of each backup job's destination directory in the report. Defaults to `"yes"`. Can be disabled if slow.                                                                                                                                                                 |
| `DU_COMMAND`                  | (Optional) Specify the command to calculate disk usage: `"du"` (default) or `"gdu"`. If `gdu` is selected, it must be installed, and the script will fall back to `du` if it is not found.                                                                                             |
| `MAX_ATTACHMENT_SIZE_MB`      | The maximum size (in MB) for an email attachment. If a detailed log file exceeds this, it won't be attached, and a warning will be added to the email body. Set to `0` to disable.
| `LOG_DIR`                     | The directory where log files will be stored.                                                                                                                                                                                                                                                             |
| `LOG_PER_HOST`                | Set to `"yes"` to create detailed, date-stamped log files inside a per-host subdirectory (e.g., `LOG_DIR/HOST/DATE.log`). Highly recommended.                                                                                                                                                              |
| `LOG_VERBOSE`                 | Set to `"yes"` to enable **Monitor Mode**. This adds `--progress` to `rsync`, showing real-time file transfer progress in the per-host log. Useful for monitoring large backups with `tail -f`. This does not affect the content of the email report.                                                  |
| `CREATE_ARCHIVE`              | Set to `"yes"` to enable per-job archive creation.                                                                                                                                                                                                                                                |
| `ARCHIVE_DEST`                | The parent directory for storing all versioned archives.                                                                                                                                                                                                                                                  |
| `ARCHIVE_RETENTION_DAYS`      | **(Recommended)** Deletes archives older than this many days. Takes precedence over `ARCHIVE_RETENTION_COUNT`.                                                                                                                                                                                           |
| `ARCHIVE_RETENTION_COUNT`     | **(Fallback)** Keeps the specified number of the most recent archives per job. Used only if `ARCHIVE_RETENTION_DAYS` is `0`.                                                                                                                                                                               |
| `CREATE_SNAPSHOT`             | Set to `"yes"` to enable space-efficient, hard-link based snapshots **per host**.                                                                                                                                                                                                                |
| `SNAPSHOT_RETENTION_COUNT`    | Number of snapshots to keep per host.                                                                                                                                                                                                                                                              |

## 5. Installation and Usage

### Step 1: Get the Script

There are two primary ways to get `r-chive.sh`.

**Option A: Git Clone (Recommended)**

This is the best way to stay up-to-date with the latest features and bug fixes.

```bash
git clone https://github.com/alifgufron/r-chive.sh.git
cd r-chive.sh
```

**Option B: Download a Release**

If you prefer a stable version, you can download a tagged release from the project's releases page.

1.  Go to the releases page (e.g., `https://github.com/alifgufron/r-chive.sh/releases`).
2.  Download the `.tar.gz` or `.zip` file for the desired version.
3.  Extract the archive.

### Step 2: Create Config File

Copy `backup.conf.sample` to a permanent location (e.g., `/usr/local/etc/r-chive/main.conf`) and edit it. Define your jobs in `BACKUP_JOBS` and create the corresponding `_SRC` and `_EXCLUDES` variables.

**Example `main.conf`:**
```bash
# Activate two jobs for two different servers
BACKUP_JOBS="web_server_www app_server_logs"

# Define job 1: Backup website files from web_server_01
web_server_www_SRC="backup_user@web-server-01.example.com:/var/www/html"
web_server_www_EXCLUDES="
  wp-content/cache/
  *.log
  tmp/
"

# Define job 2: Backup application logs from app_server_01 on a custom SSH port
app_server_logs_SRC="backup_user@app-server-01.example.com:2222:/var/log/my_app"
app_server_logs_EXCLUDES=""

# Define other global settings...
BACKUP_DEST="/mnt/backups"
REPORT_EMAIL="admin@example.com"
LOG_DIR="/var/log/r-chive"
```

### Step 3: Setup SSH Keys

Ensure the user running the script on the backup server has passwordless SSH access to the remote servers. Use `ssh-copy-id` for this.

### Step 4: Install Prerequisites

Ensure `nc` (netcat) is installed on the backup server: `sudo pkg install netcat` (FreeBSD) or `sudo apt install netcat-traditional` (Debian/Ubuntu).

### Step 5: Run a Test

Always perform a dry run first to verify your configuration and connections. You can also add temporary excludes.

```bash
# As the user who owns the SSH keys:
./r-chive.sh /usr/local/etc/r-chive/main.conf --dry-run --exclude "*.tmp"
```

Once satisfied, run it for real:
```bash
./r-chive.sh /usr/local/etc/r-chive/main.conf
```

### Step 6: Schedule with Cron

Edit the crontab for the user that runs the backups (`crontab -e`).

```cron
# Run backup every day at 2:30 AM
30 2 * * * /path/to/r-chive.sh /usr/local/etc/r-chive/main.conf >/dev/null 2>&1
```

## 6. Log Management

The new logging system is designed to work with standard system tools.

-   **Global Log**: The script appends to `/var/log/r-chive/r-chive.log`. You should configure your system's log rotation tool (e.g., `newsyslog.conf` on FreeBSD, `logrotate` on Linux) to manage this file.
-   **Per-Host Logs**: If `LOG_PER_HOST` is `yes`, detailed logs are created daily (e.g., `/var/log/r-chive/server1/2025-10-05.log`). You can use a `find` command in a weekly cron job to clean up old logs, for example:
    ```bash
    # Deletes host-specific logs older than 30 days
    find /var/log/r-chive -type f -name "*.log" -mtime +30 -delete
    ```
