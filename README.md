# Get-Latest-GitHub-Release
Fetch latest GitHub Release and copy to local folder  
Caveat: I'm not a programmer so use at own risk :)

DESCRIPTION  
Script to fetch the latest release from specified GitHub Repo if it is newer than the local copy 
and extract the content to local folder while stopping and starting a service.

PARAMETER name  
Name of the GitHub project (will be used to create directory in $RootPath)

PARAMETER repo  
Github Repository to target.

PARAMETER filenamePattern  
Filename pattern that will be looked for in the releases page, does except Powershell wildcards

PARAMETER RootPath  
The Root folder where the project need to be replicated to.

PARAMETER innerDirectory  
Needed it the project is zipped into a rootfolder.

PARAMETER preRelease  
Needed if pre releases are to be downloaded.

PARAMETER RestartService  
If specified will stop Service and dependents as specified before copy action, will start all services afterwards.

INPUTS  
None
  
OUTPUTS  
.\Versions\<name>.xml Created_at from GitHub Release to compare if there is a newer version

EXAMPLE  
```
Get-Latest-GitHub-Release.ps1 -Name 'FileBrowser' -repo 'filebrowser/filebrowser' -filenamePattern 'windows-amd64-filebrowser.zip' -RootPath 'C:\Github' -innerDirectory $false -preRelease $false -RestartService 'FileBrowser'
Get-Latest-GitHub-Release.ps1 -Name 'Jackett' -repo 'Jackett/Jackett' -filenamePattern 'Jackett.Binaries.Windows.zip' -RootPath 'C:\Github' -innerDirectory -preRelease -RestartService 'Jackett'
Get-Latest-GitHub-Release.ps1 -Name 'MailSend-Go' -repo 'muquit/mailsend-go' -filenamePattern '*windows-64bit.zip' -RootPath 'C:\GitHub' -innerDirectory
Get-Latest-GitHub-Release.ps1 -Name 'SubtitleEdit' -repo 'SubtitleEdit/subtitleedit' -filenamePattern 'SE[0-9][0-9][0-9][0-9].zip' -RootPath 'C:\GitHub'
```
