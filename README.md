# Get-Latest-GitHub-Release

Automatically fetch the latest GitHub release and deploy it to a local folder. Designed for unattended execution via Windows Task Scheduler.

---

## Features

- **Automated updates** from any public GitHub repository's releases page
- **Backup and rollback**: ZIP backup of the current installation before each update, with automatic rollback if deployment or service restart fails
- **Pushover notifications**: optional alerts on success, failure, or rollback, with configurable priority, sound, and TTL per notification type
- **Service management**: stops and restarts a Windows service around the update, with guaranteed restart even on failure
- **Flexible matching**: wildcard (`-like`) or regex (`-match`) patterns for release asset filenames
- **Pre-release support**: optionally download pre-release versions
- **Configuration file**: shared settings (Pushover credentials, backup count) across all scheduled tasks
- **Robustness**: download size verification, temp extraction before deployment, corrupt version file recovery, input validation, request timeouts

---

## Quick Start

```powershell
.\Get-Latest-GitHub-Release.ps1 -Name 'FileBrowser' -Repo 'filebrowser/filebrowser' -FilenamePattern 'windows-amd64-filebrowser.zip' -RootPath 'C:\GitHub' -RestartService 'FileBrowser'
```

---

## Parameters

| Parameter | Description | Required |
|---|---|---|
| `-Name` | Project name. Creates a subdirectory under `RootPath`. | Yes |
| `-Repo` | GitHub repository in `owner/repo` format. | Yes |
| `-FilenamePattern` | Pattern to match release assets. Uses PowerShell wildcards by default. | Yes |
| `-RootPath` | Root folder for project installations. | Yes |
| `-UseRegex` | Treat `FilenamePattern` as a regular expression instead of a wildcard. | No |
| `-PreRelease` | Download pre-release versions. | No |
| `-RestartService` | Windows service to stop before and start after deployment. | No |
| `-PushoverUserKey` | Pushover user/group key. Overrides config file. | No |
| `-PushoverApiToken` | Pushover application API token. Overrides config file. | No |
| `-PushoverDevice` | Target a specific Pushover device. Overrides config file. | No |
| `-MaxBackups` | Number of backup ZIPs to keep per project (1-20). Overrides config file. Default: 3. | No |

---

## Configuration File

Copy `Config\config.example.json` to `Config\config.json` and fill in your values:

```json
{
    "Pushover": {
        "UserKey": "your-user-key",
        "ApiToken": "your-api-token",
        "Device": "optional-device-name",
        "Notifications": {
            "Success":  { "Priority": -1, "Sound": "none", "Ttl": 0 },
            "Failed":   { "Priority":  1, "Sound": "siren", "Ttl": 0 },
            "Rollback": { "Priority":  1, "Sound": "siren", "Ttl": 0 },
            "Info":     { "Priority": -1, "Sound": "none", "Ttl": 0 }
        }
    },
    "MaxBackups": 3
}
```

All fields are optional. Command-line parameters take precedence over the config file.

**Pushover notification settings per type:**

| Field | Description |
|---|---|
| `Priority` | -2 (lowest), -1 (low), 0 (normal), 1 (high), 2 (emergency) |
| `Sound` | Pushover sound name (e.g., `pushover`, `siren`, `none`). See [Pushover sounds](https://pushover.net/api#sounds). |
| `Ttl` | Seconds before notification auto-dismisses (0 = no auto-dismiss). |

---

## Examples

**Basic usage with service restart:**

```powershell
.\Get-Latest-GitHub-Release.ps1 -Name 'FileBrowser' -Repo 'filebrowser/filebrowser' -FilenamePattern 'windows-amd64-filebrowser.zip' -RootPath 'C:\GitHub' -RestartService 'FileBrowser'
```

**Regex pattern matching:**

```powershell
.\Get-Latest-GitHub-Release.ps1 -Name 'SubtitleEdit' -Repo 'SubtitleEdit/subtitleedit' -FilenamePattern '^SE\d+\.zip$' -UseRegex -RootPath 'C:\GitHub'
```

**Pre-release with service restart:**

```powershell
.\Get-Latest-GitHub-Release.ps1 -Name 'Jackett' -Repo 'Jackett/Jackett' -FilenamePattern 'Jackett.Binaries.Windows.zip' -RootPath 'C:\GitHub' -PreRelease -RestartService 'Jackett'
```

**Wildcard pattern:**

```powershell
.\Get-Latest-GitHub-Release.ps1 -Name 'MailSend-Go' -Repo 'muquit/mailsend-go' -FilenamePattern '*windows-64bit.zip' -RootPath 'C:\GitHub'
```

---

## Task Scheduler Setup

Create a scheduled task with:

| Field | Value |
|---|---|
| Program | `powershell.exe` |
| Arguments | `-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "C:\GitHub\Get-Latest-GitHub-Release\Get-Latest-GitHub-Release.ps1" -Name 'FileBrowser' -Repo 'filebrowser/filebrowser' -FilenamePattern 'windows-amd64-filebrowser.zip' -RootPath 'C:\GitHub' -RestartService 'FileBrowser'` |

Pushover credentials and MaxBackups can be set once in `Config\config.json` instead of repeating them in every task's arguments.

---

## How It Works

1. Validates inputs (service exists, regex compiles, repo format correct).
2. Reads the local version file. Recovers gracefully if the file is corrupt.
3. Queries the GitHub Releases API for the latest (or pre-release) version.
4. Matches release assets against the filename pattern.
5. Compares release dates. Exits if already up to date.
6. Downloads the asset to a temp file. Verifies the file size matches GitHub's reported size.
7. Extracts to a temp directory to validate the ZIP before touching the installation.
8. Creates a ZIP backup of the current installation.
9. Stops the service (if specified). Service downtime starts here.
10. Copies validated files to the target directory.
11. Restarts the service. Service downtime ends here.
12. Writes the version file.
13. Sends a Pushover success notification with a link to the release notes.

If deployment or service restart fails, the script automatically rolls back from the backup ZIP and sends a rollback notification.

The `finally` block guarantees the service is restarted even if the script encounters an unhandled error, and all temp files are cleaned up.

---

## Directory Structure

```
Get-Latest-GitHub-Release/
  Get-Latest-GitHub-Release.ps1   # The script
  Config/
    config.json                    # Shared configuration (gitignored)
  Versions/
    FileBrowser.json               # Version tracking per project (gitignored)
  Backups/
    FileBrowser/
      20240113_120000.zip          # ZIP backups of previous installs (gitignored)
```

---

## Notes

- Uses unauthenticated GitHub API calls, limited to 60 requests per hour.
- Requires PowerShell 5.1 or later.
- Service management requires running as Administrator.
- If multiple assets match the filename pattern, the first match is used and a warning is logged.
