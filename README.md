# Get-Latest-GitHub-Release

Fetch the latest GitHub Release and copy it to a local folder.

*Caveat: I'm not a professional programmer, so use this script at your own risk!*

---

## DESCRIPTION

This PowerShell script automates the process of fetching the latest release from a specified GitHub repository, comparing it with the local copy, and updating the local folder if a new version is available. It also includes features for managing services before and after the update and supports advanced configurations.

---

## Features

- **Automated Updates**: Automatically fetches the latest release from GitHub and updates your local copy if a newer version is detected.
- **Service Management**: Optionally stops and starts a specified service during the update process to ensure seamless integration.
- **Flexible Configurations**:
  - Supports pre-release versions.
  - Customizable filename patterns for targeted downloads.
  - Handles inner directory extraction for more efficient updates.
  - Enhanced logging and error handling.
- **UTF-8 Support**: Ensures proper encoding for configurations and script files.

---

## Usage

```powershell
.\Get-Latest-GitHub-Release.ps1 -Name 'YourProjectName' -Repo 'yourusername/yourrepository' -FilenamePattern 'YourFileNamePattern.zip' -RootPath 'C:\Your\Local\Path' -PreRelease -RestartService 'YourServiceName'
```

---

## Parameters

| Parameter            | Description                                                                         | Mandatory |
| -------------------- | ----------------------------------------------------------------------------------- | --------- |
| **-Name**            | Name of the GitHub project. Used to create a directory in `$RootPath`.              | Yes       |
| **-Repo**            | GitHub repository to target (e.g., `username/repository`).                          | Yes       |
| **-FilenamePattern** | Filename pattern to search for in the releases page. Supports PowerShell wildcards. | Yes       |
| **-UseRegex**        | Use regular expressions for matching filenames instead of PowerShell wildcards.     | No        |
| **-RootPath**        | Root folder where the project will be updated.                                      | Yes       |
| **-PreRelease**      | Include this flag to download pre-release versions (optional).                      | No        |
| **-RestartService**  | Service name to stop and start before and after the update process (optional).      | No        |
| **-Verbose**         | Enable detailed output for troubleshooting (optional).                              | No        |

---

## Examples

1. **Basic Usage**

   ```powershell
   .\Get-Latest-GitHub-Release.ps1 -Name 'FileBrowser' -Repo 'filebrowser/filebrowser' -FilenamePattern 'windows-amd64-filebrowser.zip' -RootPath 'C:\Github' -RestartService 'FileBrowser'
   ```

2. **With Pre-Releases**

   ```powershell
   .\Get-Latest-GitHub-Release.ps1 -Name 'Jackett' -Repo 'Jackett/Jackett' -FilenamePattern 'Jackett.Binaries.Windows.zip' -RootPath 'C:\Github' -PreRelease -RestartService 'Jackett'
   ```

3. **Pattern Matching**

   ```powershell
   .\Get-Latest-GitHub-Release.ps1 -Name 'MailSend-Go' -Repo 'muquit/mailsend-go' -FilenamePattern '*windows-64bit.zip' -RootPath 'C:\GitHub'
   ```

4. **Custom Filename Pattern**

   ```powershell
   .\Get-Latest-GitHub-Release.ps1 -Name 'SubtitleEdit' -Repo 'SubtitleEdit/subtitleedit' -FilenamePattern 'SE[0-9][0-9][0-9].zip' -RootPath 'C:\GitHub'
   ```

5. **Using Regular Expressions**

   ```powershell
   .\Get-Latest-GitHub-Release.ps1 -Name 'RegexExample' -Repo 'example/repo' -FilenamePattern '.*windows.*64.*\.zip' -RootPath 'C:\GitHub' -UseRegex
   ```

---

## Notes

- Ensure that the target GitHub repository has releases matching your filename pattern.
- The script includes error handling and logging to assist in troubleshooting.
- Always test the script in a controlled environment before deploying it in production.