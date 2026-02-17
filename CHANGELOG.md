# Changelog

## Version 1.2.0 - 2026-02-18

### 🎉 Major Enhancements

#### 1. Accurate Error Detection
- **Problem**: Script previously reported SUCCESS even when rsync encountered errors (e.g., "Permission denied") if exit code was 0
- **Solution**: Added comprehensive error pattern detection that scans rsync output for 10+ error types
- **Impact**: Email reports now accurately reflect backup status, even when rsync exit code is 0

**Detected Error Patterns:**
- Permission denied
- Operation failed
- IO error
- Directory access failed (opendir failed)
- Skipping file deletion
- Some files/attributes were not transferred
- Connection reset by peer
- Broken pipe
- Unexpected server error
- Rsync error reported

#### 2. Enhanced Email Reports
- **Status Icons in Subject**: Email subjects now include ✅ or ❌ for quick visual identification
  - Example: `✅ [Backup Daily Finished] Report for server1 - Status: SUCCESS`
  - Example: `❌ [Backup Daily Finished] Report for server1 - Status: ERROR`
- **UTF-8 Encoding**: Proper MIME base64 encoding ensures emojis display correctly across all email clients
- **Detailed Error Reporting**: Error details now shown in email body, not just in attachments

#### 3. Permission Denied Solutions
Added comprehensive documentation and configuration examples for handling permission errors:

**Solution 1: Skip Extended Attributes** (Recommended)
```bash
RSYNC_CUSTOM_OPTS="--no-xattrs --no-acls"
```

**Solution 2: Exclude Sensitive Files**
```bash
job_name_EXCLUDES="
  master.passwd
  spwd.db
  ssh/*_key*
  ssl/private/*
"
```

**Solution 3: Use sudo on Remote Server** (Advanced)
- Configure passwordless sudo for rsync
- Create rsync wrapper script

**Solution 4: Combined Approach** (Best Practice)
- Use both RSYNC_CUSTOM_OPTS and exclusions

### 📝 Documentation Updates

#### README.md
- Added **Section 2.1: Troubleshooting: Permission Denied Errors** with 4 solutions
- Updated **Configuration Variables** table with RSYNC_CUSTOM_OPTS tip
- Enhanced **Step 2: Create Config File** with system backup example
- Added **Section 7: Understanding Email Reports** explaining new features
- Updated **Features list** with error detection and email enhancements

#### backup.conf.sample
- Updated RSYNC_CUSTOM_OPTS default to `"--no-xattrs --no-acls"`
- Added example job for backing up /etc with sensitive file exclusions
- Added detailed comments explaining common use cases

### 🔧 Technical Changes

#### r-chive.sh
- **Lines ~750-802**: Added error pattern detection logic
- **Lines ~804-807**: Updated status determination (FAILED if exit code ≠ 0 OR error pattern detected)
- **Lines ~853-879**: Enhanced error reporting in email body
- **Lines ~994-1000**: Added status icon to email subject
- **Lines ~194-200**: Added status icon to start notification
- **Lines ~1000 & ~200**: Implemented MIME base64 encoding with `base64 -w 0`
- **Lines ~1035-1065**: Added Content-Transfer-Encoding: 8bit headers

### 📊 Before vs After

| Feature | Before ❌ | After ✅ |
|---------|-----------|----------|
| Error Detection | Exit code only | Exit code + 10+ error patterns |
| Email Subject | `[Backup Finished] ... Status: SUCCESS` (even with errors) | `❌ [Backup Finished] ... Status: ERROR` (accurate) |
| Emoji Rendering | `âŒ` (broken characters) | `✅` `❌` `🚀` (correct) |
| Status Consistency | Subject: SUCCESS, Log: ERROR | All consistent: ERROR ✅ |
| Error Details | Only in attachment | Shown in email body |
| Permission Error Solutions | Not documented | 4 solutions documented |

### 🎯 Use Case Example

**Scenario**: Backing up /etc directory with non-root user

**Before**:
```
Email Subject: [Backup Finished] Status: SUCCESS
Email Body: ✅ Job: backup_etc - Status: SUCCESS
Attachment Log: Permission denied (13) ❌
```
User confused because subject says SUCCESS but backup had errors.

**After**:
```
Email Subject: ❌ [Backup Finished] Status: ERROR
Email Body: ❌ Job: backup_etc - Status: FAILED
  Error Detail:
  Detected Issues:
    - Permission denied encountered
    - IO error encountered
```
User immediately knows there's a problem + sees exact errors.

**Solution Applied**:
```bash
RSYNC_CUSTOM_OPTS="--no-xattrs --no-acls"
backup_etc_EXCLUDES="master.passwd spwd.db ssh/*_key*"
```

Result:
```
Email Subject: ✅ [Backup Finished] Status: SUCCESS
Email Body: ✅ Job: backup_etc - Status: SUCCESS
```

### 🚀 Migration Guide

No breaking changes! Existing configurations will continue to work.

**Recommended Actions:**
1. Update to get latest script version
2. Review your config files for system directory backups
3. Add `RSYNC_CUSTOM_OPTS="--no-xattrs --no-acls"` if backing up /etc or similar
4. Update exclusions for sensitive files as needed

### 📧 Email Format Changes

**Old Format:**
```
Subject: [Backup Daily Finished] Report for server1 - Status: SUCCESS
```

**New Format:**
```
Subject: ✅ [Backup Daily Finished] Report for server1 - Status: SUCCESS
         or
Subject: ❌ [Backup Daily Finished] Report for server1 - Status: ERROR
```

### 🔒 Security Notes

- Extended attributes and ACLs are now skipped by default in sample config
- Sensitive files (master.passwd, ssh keys, etc.) should be excluded
- Consider using sudo wrapper for complete system backups if needed

---

**Full Changelog**: https://github.com/alifgufron/r-chive.sh/compare/v1.1.3...v1.2.0
