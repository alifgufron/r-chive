# r-chive.sh

## 1. Overview

`r-chive.sh` is a simple, lightweight, and flexible shell script for automating backups from multiple remote servers to a central backup server using `rsync`. It is designed to be robust, easy to configure, and provides detailed feedback through logs and email reports.

The script performs a "mirror" backup for each specified host into a `Live` directory. After a successful sync, it can create granular, compressed archives for each backup task and/or space-efficient, point-in-time snapshots at the **host level**. This results in a clean, browsable backup history with a clear separation between the live backup and its historical snapshots (e.g., `.../HOST/Live`, `.../HOST/Snapshot.0`, etc.).

## 2. Features

- **Host-Level Snapshots**: Creates space-efficient, point-in-time snapshots of the entire host's backup directory using hard links. This provides a browsable backup history that consumes minimal extra space.
- **Clean Directory Structure**: Organizes backups for each host into a `Live` directory (the most recent state) and historical `Snapshot.X` directories.
- **Explicit Configuration**: Requires a configuration file to be passed as a command-line argument, preventing ambiguity and allowing multiple, independent backup jobs to be configured.
- **Parallel Backups**: Executes backups for all targets on a host concurrently, significantly reducing the total backup time.
- **Optional SSH Port**: Specify a custom SSH port directly in the backup target string (e.g., `user@host:port:/path`).
- **Granular Archiving**: Creates a separate, clean `.tar.zst` archive for each individual backup target, making restorations fast and specific.
- **Flexible Retention Policy**: Supports two methods for cleaning up old archives and snapshots:
  - **By Time (Recommended for Archives)**: Keep archives for a specific number of days.
  - **By Count (For Archives and Snapshots)**: Keep a specific number of the most recent backups.
- **Structured Archive Storage**: Organizes archives into a `HOST/YEAR/MONTH` directory structure.
- **Multi-Target Backups**: Back up multiple directories from multiple remote servers in a single run.
- **Singleton Execution**: A robust lock file mechanism prevents the script from running multiple times simultaneously.
- **Dry Run Mode**: A `--dry-run` mode allows you to test your configuration safely.
- **Rsync Efficiency**: Uses `rsync` for fast, incremental backups.
- **Detailed Logging & Email Reports**: Provides comprehensive feedback on every step of the process, with accurate duration metrics.

## 3. Prerequisites

#### On the Backup Server

1.  **`rsync`**: The `rsync` utility must be installed.
2.  **`cp -al` support**: Your filesystem must support hard links for the snapshot feature to work. Most standard filesystems (UFS, ZFS, EXT4, etc.) support this.
3.  **`zstd`**: The Zstandard compression utility is required for the archiving feature. On FreeBSD, install with `sudo pkg install zstd`.
4.  **`sendmail`**: A configured Mail Transfer Agent (MTA) like `sendmail` is required for sending email reports.
5.  **SSH Client**: Required to connect to remote servers.

#### On ALL Remote Servers

1.  **`rsync`**: Must also be installed on every remote server you intend to back up. `rsync` works by communicating between the client and server programs.

## 4. Configuration

All configuration is done in a `.conf` file (e.g., `backup.conf`). This file **must** be passed as an argument to the script.

| Variable                      | Description                                                                                                                                                                                                                                                                                            |
| ----------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `BACKUP_DEST`                 | **Parent Backup Destination.** This is the top-level directory where host-specific folders (e.g., `10.11.1.121/`) will be created. The script will automatically create `Live` and `Snapshot.X` subdirectories inside each host's folder.                                                                  |
| `BACKUP_TARGETS`              | A space-separated list of backup sources. Format is `"user@host:/path/to/source"` or `"user@host:PORT:/path/to/source"` for non-standard SSH ports.                                                                                                                                                  |
| `SSH_KEY_PATH`                | (Optional) Absolute path to the **private** SSH key (e.g., `id_rsa`). Leave empty to use the default key of the user running the script.                                                                                                                                                              |
| `REPORT_EMAIL`                | The destination email address for backup reports.                                                                                                                                                                                                                                                   |
| `LOG_DIR`                     | The directory where log files will be stored.                                                                                                                                                                                                                                                             |
| `CREATE_ARCHIVE`              | Set to `"yes"` to enable per-target archive creation.                                                                                                                                                                                                                                     |
| `ARCHIVE_DEST`                | **Historical Archive Destination.** The parent directory for storing all versioned archives.                                                                                                                                                                                                                              |
| `ARCHIVE_RETENTION_DAYS`      | **(Recommended)** **Number of days to keep archives.** If set to a value greater than `0` (e.g., `30`), the script will delete any archive older than that many days. This policy **takes precedence** over `ARCHIVE_RETENTION_COUNT`.                                                                              |
| `ARCHIVE_RETENTION_COUNT`     | **(Fallback)** **Number of archives to keep per target.** This is only used if `ARCHIVE_RETENTION_DAYS` is set to `0`. It keeps the specified number of the most recent archives and deletes older ones.                                                                                                   |
| `CREATE_SNAPSHOT`             | Set to `"yes"` to enable space-efficient, hard-link based snapshot creation **per host**.                                                                                                                                                                                          |
| `SNAPSHOT_RETENTION_COUNT`    | **Number of snapshots to keep per host.** Keeps the specified number of the most recent snapshots and deletes older ones.                                                                                                   |

## 5. Setup and Usage

### Step 1-3: Initial Setup
1.  **Place Script**: Copy `r-chive.sh` to a suitable location (e.g., `/usr/local/bin/`).
2.  **Create Config File**: Create your configuration file by copying the sample. You can place this anywhere (e.g., `/usr/local/etc/r-chive/main.conf`).
    ```bash
    mkdir -p /usr/local/etc/r-chive
    cp backup.conf.sample /usr/local/etc/r-chive/main.conf
    ```
3.  **Edit Config File**: Open your new config file and fill it with your server details, paths, and email address.
4.  **Make it Executable**: `chmod +x /usr/local/bin/r-chive.sh`

### Step 4: User and SSH Key Configuration (Crucial!)
This workflow involves two user roles:
- **Backup User**: An account on the **Backup Server** that will run the script (e.g., `userbackup`).
- **Remote User**: An account on the **Remote Server** whose data will be accessed (e.g., `remoteadmin`).

1.  **On the Backup Server**: Create the `userbackup` (`adduser userbackup`) and generate an SSH key for them (`sudo -u userbackup ssh-keygen ...` or `su -m userbackup -c "..."`). Leave the passphrase empty.
2.  **On the Remote Server**: Ensure the `remoteadmin` user exists and has read permissions for the target directories.
3.  **Connect Them**: From the Backup Server, copy the Backup User's public key to the Remote User on the remote server.
    ```bash
    sudo -u userbackup ssh-copy-id -i /home/userbackup/.ssh/id_rsa.pub remoteadmin@server-remote.com
    ```

### Step 5: Run a Manual Test

-   **Dry Run (Required First!)**: Test your configuration without making any changes.
    ```bash
    sudo -u userbackup /usr/local/bin/r-chive.sh /usr/local/etc/r-chive/main.conf --dry-run
    ```
-   **Live Test**: Run the script for real.
    ```bash
    sudo -u userbackup /usr/local/bin/r-chive.sh /usr/local/etc/r-chive/main.conf
    ```

### Step 6: Schedule with Cron
Schedule the script using the `cron` of the **Backup User** (`userbackup`), not `root`.

1.  Open the crontab for the backup user: `sudo crontab -e -u userbackup`
2.  Add a line to run the script on a schedule. For example, every day at 2:30 AM:
    ```cron
    30 2 * * * /usr/local/bin/r-chive.sh /usr/local/etc/r-chive/main.conf
    ```

## 6. Advanced Usage & FAQ

- **Running as `root`**: Not recommended, but if you must, set the `SSH_KEY_PATH` in your `.conf` file to the path of another user's private key (e.g., `/home/userbackup/.ssh/id_rsa`).
- **`ssh` as `root` vs `su`**: `ssh` run by `root` looks for keys in `/root/.ssh/`. `cron` scheduled for `userbackup` runs as `userbackup` and correctly finds keys in `/home/userbackup/.ssh/`.
- **Meaning of `f++++++++++` output**: This is from `rsync --itemize-changes`. `f` means file, and `++++++++++` means it is a 100% **new** file.

## 7. Troubleshooting

- **`rsync: command not found` (on remote)**: Ensure `rsync` is installed on all remote servers.
- **`Permission Denied (SSH)`**: Redo step 4c to ensure the SSH key was copied correctly.
- **`ERROR: No configuration file specified`**: You must pass the path to your `.conf` file as the first argument to the script.
