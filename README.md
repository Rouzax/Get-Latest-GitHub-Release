# Get-Latest-GitHub-Release
Fetch latest GitHub Release and copy to local folder  
Caveat: I'm not a programmer so use at own risk :)

DESCRIPTION  
This PowerShell script fetches the latest release from a specified GitHub repository, compares it with the local copy, and extracts the content to a local folder. Additionally, it can stop and start a service before and after the copy action.

## Features

- **Automatic Update**: Automatically fetches the latest release from GitHub and updates the local copy if a newer version is available.
- **Service Management**: Optionally stops and starts a service before and after the update process.
- **Flexible Configuration**: Supports pre-release versions, customizable filename patterns, and inner directory extraction.

## Usage

```powershell
.\Get-Latest-GitHub-Release.ps1 -Name 'YourProjectName' -repo 'yourusername/yourrepository' -filenamePattern 'YourFileNamePattern.zip' -RootPath 'C:\Your\Local\Path' -preRelease -RestartService 'YourServiceName'
``` 

## Parameters

- **name**: Name of the GitHub project (used to create a directory in `$RootPath`).
- **repo**: GitHub Repository to target.
- **filenamePattern**: Filename pattern to look for in the releases page (supports PowerShell wildcards).
- **RootPath**: The root folder where the project needs to be replicated.
- **preRelease**: Needed if pre-releases are to be downloaded (optional).
- **RestartService**: Specifies the service to stop and start before and after the copy action (optional).

## Examples
```powershell
.\Get-Latest-GitHub-Release.ps1 -Name 'FileBrowser' -repo 'filebrowser/filebrowser' -filenamePattern 'windows-amd64-filebrowser.zip' -RootPath 'C:\Github' -RestartService 'FileBrowser'

.\Get-Latest-GitHub-Release.ps1 -Name 'Jackett' -repo 'Jackett/Jackett' -filenamePattern 'Jackett.Binaries.Windows.zip' -RootPath 'C:\Github' -preRelease -RestartService 'Jackett'

.\Get-Latest-GitHub-Release.ps1 -Name 'MailSend-Go' -repo 'muquit/mailsend-go' -filenamePattern '*windows-64bit.zip' -RootPath 'C:\GitHub'

.\Get-Latest-GitHub-Release.ps1 -Name 'SubtitleEdit' -repo 'SubtitleEdit/subtitleedit' -filenamePattern 'SE[0-9][0-9][0-9].zip' -RootPath 'C:\GitHub'
```
