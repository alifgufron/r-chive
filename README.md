# r-chive.sh

## 1. Overview

`r-chive.sh` is a simple, lightweight, and flexible shell script for automating backups from multiple remote servers to a central backup server using `rsync`. It is designed to be robust, easy to configure, and provides detailed feedback through logs and email reports.

The script performs a "mirror" backup for each specified target. After a successful sync, it creates a granular, compressed archive for **each individual target**, allowing for highly efficient and specific restorations.

## 2. Features

- **Parallel Backups**: Executes backups for all targets concurrently, significantly reducing the total backup time.
- **Granular Archiving**: Creates a separate, clean `.tar.zst` archive for each individual backup target, making restorations fast and specific.
- **Flexible Retention Policy**: Supports two methods for cleaning up old archives:
  - **By Time (Recommended)**: Keep archives for a specific number of days (e.g., delete all archives older than 30 days).
  - **By Count**: Keep a specific number of the most recent archives.
- **Structured Archive Storage**: Organizes archives into a `HOST/YEAR/MONTH` directory structure.
- **External Configuration**: All settings are managed in a separate `backup.conf` file.
- **Multi-Target Backups**: Back up multiple directories from multiple remote servers in a single run.
- **Singleton Execution**: A robust lock file mechanism prevents the script from running multiple times simultaneously.
- **Dry Run Mode**: A `--dry-run` mode allows you to test your configuration safely.
- **Rsync Efficiency**: Uses `rsync` for fast, incremental backups.
- **Detailed Logging & Email Reports**: Provides comprehensive feedback on every step of the process.

## 3. Prerequisites

#### On the Backup Server

1.  **`rsync`**: The `rsync` utility must be installed.
2.  **`zstd`**: The Zstandard compression utility is required. On FreeBSD, install with `sudo pkg install zstd`.
3.  **`sendmail`**: A configured Mail Transfer Agent (MTA) like `sendmail` is required for sending email reports.
4.  **SSH Client**: Required to connect to remote servers.

#### On ALL Remote Servers

1.  **`rsync`**: Must also be installed on every remote server you intend to back up. `rsync` works by communicating between the client and server programs.

## 4. Configuration

All configuration is done by editing the `backup.conf` file, which must be in the same directory as `backup_rsync.sh`.

| Variable                  | Description                                                                                                                                                                                                                                                                                            |
| ------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `BACKUP_DEST`             | **Live Backup Destination.** This is the live mirror directory of your data. `rsync` syncs files here. Its content is always changing to match the source. Useful for quick restores to the latest state.                                                                  |
| `BACKUP_TARGETS`          | A space-separated list of backup sources. Format: `"user@host:/path/to/source"`.                                                                                                                                                                                                                |
| `SSH_KEY_PATH`            | (Optional) Absolute path to the **private** SSH key (e.g., `id_rsa`), not the public key (`id_rsa.pub`). Leave empty to use the default key of the user running the script. Use this if you must run the script as `root`.                                                               |
| `REPORT_EMAIL`            | The destination email address for backup reports.                                                                                                                                                                                                                                                   |
| `LOG_DIR`                 | The directory where log files will be stored.                                                                                                                                                                                                                                                             |
| `CREATE_ARCHIVE`          | Set to `"yes"` to enable per-target archive creation.                                                                                                                                                                                                                                     |
| `ARCHIVE_DEST`            | **Historical Archive Destination.** The parent directory for storing all versioned archives.                                                                                                                                                                                                                              |
| `ARCHIVE_RETENTION_DAYS`  | **(Recommended)** **Number of days to keep archives.** If set to a value greater than `0` (e.g., `30`), the script will delete any archive older than that many days. This policy **takes precedence** over `ARCHIVE_RETENTION_COUNT`.                                                                              |
| `ARCHIVE_RETENTION_COUNT` | **(Fallback)** **Number of archives to keep per target.** This is only used if `ARCHIVE_RETENTION_DAYS` is set to `0`. It keeps the specified number of the most recent archives and deletes older ones. Set to `0` to disable all retention.                                                                                                   |

## 5. Setup and Usage (Recommended)

The method described here is the security **best practice**, which involves running the script as a dedicated, non-root user.

### Step 1-3: Initial Setup
1.  **Place Files**: Copy `r-chive.sh` and `backup.conf.sample` to a suitable location (e.g., `/path/to/r-chive/`).
2.  **Create `backup.conf`**: In the same directory, create your configuration by copying the sample file.
    ```bash
    cp backup.conf.sample backup.conf
    ```
3.  **Edit `backup.conf`**: Open `backup.conf` and fill it with your server details, paths, and email address.
4.  **Make it Executable**: `chmod +x /path/to/r-chive/r-chive.sh`

### Step 4: User and SSH Key Configuration (Crucial!)
This workflow involves two user roles:
- **Backup User**: An account on the **Backup Server** that will run the script (e.g., `userbackup`).
- **Remote User**: An account on the **Remote Server** whose data will be accessed (e.g., `remoteadmin`).

1.  **On the Backup Server**: Create the `userbackup` (`adduser userbackup`) and generate an SSH key for them (`sudo -u userbackup ssh-keygen ...` or `su -m userbackup -c "..."`). Leave the passphrase empty.
2.  **On the Remote Server**: Ensure the `remoteadmin` user exists and has read permissions for the target directories.
3.  **Connect Them**: From the Backup Server, copy the Backup User's public key to the Remote User on the remote server. Using the `-i` flag is best practice:
    ```bash
    sudo -u userbackup ssh-copy-id -i /home/userbackup/.ssh/id_rsa.pub remoteadmin@server-remote.com
    ```

### Step 5: Run a Manual Test

-   **Dry Run (Required First!)**: `sudo /path/to/r-chive/r-chive.sh --dry-run`
-   **Live Test**: `sudo /path/to/r-chive/r-chive.sh`

### Step 6: Schedule with Cron
Schedule the script using the `cron` of the **Backup User** (`userbackup`), not `root`.

1.  Open the crontab for the backup user: `sudo crontab -e -u userbackup`
    30 2 * * * /path/to/r-chive/r-chive.sh

## 6. Advanced Usage & FAQ

- **Running as `root`**: Not recommended, but if you must, set the `SSH_KEY_PATH` in `backup.conf` to the path of another user's private key (e.g., `/home/userbackup/.ssh/id_rsa`).
- **`ssh` as `root` vs `su`**: `ssh` run by `root` looks for keys in `/root/.ssh/`. `cron` scheduled for `userbackup` runs as `userbackup` and correctly finds keys in `/home/userbackup/.ssh/`.
- **Meaning of `f++++++++++` output**: This is from `rsync --itemize-changes`. `f` means file, and `++++++++++` means it is a 100% **new** file.

## 7. Troubleshooting

- **`rsync: command not found` (on remote)**: Ensure `rsync` is installed on all remote servers.
- **`Permission Denied (SSH)`**: Redo step 4c to ensure the SSH key was copied correctly.
