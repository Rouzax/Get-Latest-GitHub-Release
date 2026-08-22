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
- **Release channel pinning**: follow one release track by tag pattern in repositories that publish several in parallel
- **Configuration file**: shared settings (Pushover credentials, backup count, log count) across all scheduled tasks
- **Per-run logging**: timestamped log file per run, pruned to a configurable count
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
| `-UseRegex` | Treat `FilenamePattern` as a regular expression instead of a wildcard. Also applies to `ReleaseTagPattern`, if given. | No |
| `-PreRelease` | Download pre-release versions. | No |
| `-ReleaseTagPattern` | Pin to one release channel by matching the release tag. See [Pinning to a release channel](#pinning-to-a-release-channel) for details. | No |
| `-RestartService` | Windows service to stop before and start after deployment. | No |
| `-PushoverUserKey` | Pushover user/group key. Overrides config file. | No |
| `-PushoverApiToken` | Pushover application API token. Overrides config file. | No |
| `-PushoverDevice` | Target a specific Pushover device. Overrides config file. | No |
| `-MaxBackups` | Number of backup ZIPs to keep per project (1-20). Overrides config file. Default: 3. | No |
| `-MaxLogs` | Number of log files to keep per project (1-100). Overrides config file. Default: 10. | No |

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
    "MaxBackups": 3,
    "MaxLogs": 10
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

**Two tasks from one repository:**

SubtitleEdit ships the GUI and the SeConv command-line converter as separate assets in the
same release. Each needs its own task, differing only by `-Name` and `-FilenamePattern`.
Use distinct `-Name` values: both archives contain `LICENSE` and `libse.xml`, so a shared
name would let the two tasks overwrite each other's files.

```powershell
.\Get-Latest-GitHub-Release.ps1 -Name 'SubtitleEdit' -Repo 'SubtitleEdit/subtitleedit' -FilenamePattern 'SubtitleEdit-Windows-x64.zip' -RootPath 'C:\GitHub'
.\Get-Latest-GitHub-Release.ps1 -Name 'SeConv' -Repo 'SubtitleEdit/subtitleedit' -FilenamePattern 'SeConv-Windows-x64.zip' -RootPath 'C:\GitHub'
```

Prefer exact asset names over wildcards when you can. `'SubtitleEdit-Windows-x64*'` also
matches `SubtitleEdit-Windows-x64-Setup.exe`. Since the installer happens to come first in
GitHub's asset order, that pattern would deploy the installer instead of the archive.

**Regex pattern matching:**

```powershell
.\Get-Latest-GitHub-Release.ps1 -Name 'SubtitleEdit' -Repo 'SubtitleEdit/subtitleedit' -FilenamePattern '^SubtitleEdit-Windows-x64\.zip$' -UseRegex -RootPath 'C:\GitHub'
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

## Pinning to a release channel

Some projects publish several release tracks side by side: a stable line, a beta line, and
sometimes an older maintenance line. By default the script takes whichever release GitHub
considers newest, so an unattended task can drift from one track to another.

`-ReleaseTagPattern` filters releases by tag before any asset is chosen, keeping a task on
the track you picked. `-FilenamePattern` still selects the asset inside that release.

```powershell
# Follow the v5.2.0 beta line, and do not jump tracks when a v5.3.0 beta line opens
.\Get-Latest-GitHub-Release.ps1 -Name 'SubtitleEditBeta' -Repo 'SubtitleEdit/subtitleedit' -FilenamePattern 'SubtitleEdit-Windows-x64.zip' -RootPath 'C:\GitHub' -PreRelease -ReleaseTagPattern 'v5.2.0-beta*'

# Follow the v2 beta line of a repository that maintains v1 and v2 in parallel
.\Get-Latest-GitHub-Release.ps1 -Name 'FileBrowserQuantum' -Repo 'gtsteffaniak/filebrowser' -FilenamePattern 'filebrowser.exe' -RootPath 'C:\GitHub' -PreRelease -ReleaseTagPattern 'v2.*-beta'

# Regex form. -UseRegex applies to the tag pattern and the filename pattern alike
.\Get-Latest-GitHub-Release.ps1 -Name 'FileBrowserQuantum' -Repo 'gtsteffaniak/filebrowser' -FilenamePattern 'filebrowser\.exe' -RootPath 'C:\GitHub' -PreRelease -ReleaseTagPattern '^v2\..*-beta$' -UseRegex
```

**What to expect:**

- Wildcards (`-like`) by default, regular expressions when `-UseRegex` is given.
- Without `-PreRelease`, only stable releases are eligible. A wildcard like `v5.*` matches
  `v5.2.0-beta21` just as readily as `v5.1.0`, so this filter is what keeps a stable pin from
  picking up a beta. Add `-PreRelease` to make prereleases eligible.
- The newest matching release wins, using GitHub's own ordering.
- Only the 100 most recent releases are searched. A project that publishes a prerelease daily
  can push older stable releases past that window.
- If nothing matches, the script logs every candidate tag and exits with an error instead of
  installing something else.

**Switching an existing task to another channel:** change the pattern, nothing else. The
script notices the installed release no longer matches the filters, logs

```
Channel switch: installed v5.2.0-beta21 is no longer in the channel selected by 'v5.*'
Switching channel to v5.1.0, installing regardless of release date
```

and installs the newly selected release even though it is older than the one installed.
Without that check, the ordinary date comparison would report "up to date", and the switch
would silently never happen. The check is membership in the selected set, not a direct match
against the pattern: `v5.2.0-beta21` matches the wildcard `v5.*` just fine; what excludes it
from a stable pin is its prerelease flag. Once switched, later runs compare dates normally,
so the task settles on its new channel instead of reinstalling every run.

**Adding the pattern to a task that predates version 3.3** works the same way, for a different
reason. Those version files record only a date, with no tag to test, so the first run under a
pattern is treated as a switch and installs whatever the pattern selects:

```
Channel switch: version file predates tag tracking, installing v2.0.1-beta to adopt 'v2.*'
```

Falling back to the date comparison here is not merely uninformative, it can be wrong. Dates
are compared on asset upload time, and a project that builds parallel channels in one CI run
uploads them seconds apart in no particular order: `gtsteffaniak/filebrowser` published the
`v2.0.1-beta` binary six seconds *before* the `v1.5.2-stable` one. A task moving from v1.5 to
v2 therefore read its old install as newer and reported "up to date" indefinitely. The switch
fires once; afterwards the version file carries a tag and normal comparison resumes.

**Tag formats are often inconsistent.** SubtitleEdit tags its 5.x releases `v5.1.0` but its
4.x releases `4.0.16`, so `v4.*` matches nothing while `4.*` does. Check the repository's
releases page, or run once and read the candidate tags in the log.

---

## Task Scheduler Setup

Create a scheduled task with:

| Field | Value |
|---|---|
| Program | `powershell.exe` |
| Arguments | `-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "C:\GitHub\Get-Latest-GitHub-Release\Get-Latest-GitHub-Release.ps1" -Name 'FileBrowser' -Repo 'filebrowser/filebrowser' -FilenamePattern 'windows-amd64-filebrowser.zip' -RootPath 'C:\GitHub' -RestartService 'FileBrowser'` |

Pushover credentials, MaxBackups, and MaxLogs can be set once in `Config\config.json` instead of repeating them in every task's arguments.

---

## How It Works

1. Validates inputs (service exists, regex compiles, repo format correct).
2. Reads the local version file. Recovers gracefully if the file is corrupt.
3. Queries the GitHub Releases API for the latest (or pre-release) version.
4. Filters releases by tag when `-ReleaseTagPattern` is given, and selects the newest match.
5. Matches release assets against the filename pattern.
6. Compares release dates. Exits if already up to date, unless the installed release no longer matches `-ReleaseTagPattern`, which forces the switch.
7. Downloads the asset to a temp file. Verifies the file size matches GitHub's reported size.
8. Extracts to a temp directory to validate the ZIP before touching the installation.
9. Stops the service (if specified). Service downtime starts here.
10. Creates a ZIP backup of the current installation (after service stop so locked files can be read).
11. Copies validated files to the target directory.
12. Restarts the service. Service downtime ends here.
13. Writes the version file.
14. Sends a Pushover success notification with a link to the release notes.

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
  Logs/
    FileBrowser/
      20240113_120000.log          # One log file per run (gitignored)
```

---

## Notes

- Uses unauthenticated GitHub API calls, limited to 60 requests per hour.
- Requires PowerShell 5.1 or later.
- Service management requires running as Administrator.
- If multiple assets match the filename pattern, the script uses the first match and logs a warning.
- With `-ReleaseTagPattern`, the same applies to releases: the script uses the newest matching release and logs how many matched.
- Release date comparison uses the matched asset's timestamp, not the release's. A single release can stamp its asset groups minutes apart, so two tasks tracking one repository stay independent.
