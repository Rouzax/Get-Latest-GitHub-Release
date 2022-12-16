<#
.SYNOPSIS
  Fetch latest GitHub Release and copy to local folder.
.DESCRIPTION
  Script to fetch the latest release from specified GitHub Repo if it is newer than the local copy 
  and extract the content to local folder while stopping and starting a service.
.PARAMETER name
    Name of the GitHub project (will be used to create directory in $RootPath)
.PARAMETER repo
    Github Repository to target.
.PARAMETER filenamePattern
    Filename pattern that will be looked for in the releases page, does except Powershell wildcards
.PARAMETER RootPath
    The Root folder where the project need to be replicated to.
.PARAMETER innerDirectory
    Needed it the project is zipped into a rootfolder.
.PARAMETER preRelease
    Needed if pre releases are to be downloaded.
.PARAMETER RestartService
    If specified will stop Service and dependents as specified before copy action, will start all services afterwards.
.INPUTS
  None
.OUTPUTS
  .\Versions\<name>.xml Created_at from GitHub Release to compare if there is a newer version
.NOTES
  Version:        1.2
  Author:         Rouzax
  Creation Date:  2020-12-14
  Purpose/Change: Added comments to explain working
  
.EXAMPLE
  Get-Latest-GitHub-Release.ps1 -Name 'FileBrowser' -repo 'filebrowser/filebrowser' -filenamePattern 'windows-amd64-filebrowser.zip' -RootPath 'C:\Github' -innerDirectory $false -preRelease $false -RestartService 'FileBrowser'
  Get-Latest-GitHub-Release.ps1 -Name 'Jackett' -repo 'Jackett/Jackett' -filenamePattern 'Jackett.Binaries.Windows.zip' -RootPath 'C:\Github' -innerDirectory -preRelease -RestartService 'Jackett'
  Get-Latest-GitHub-Release.ps1 -Name 'MailSend-Go' -repo 'muquit/mailsend-go' -filenamePattern '*windows-64bit.zip' -RootPath 'C:\GitHub' -innerDirectory
  Get-Latest-GitHub-Release.ps1 -Name 'SubtitleEdit' -repo 'SubtitleEdit/subtitleedit' -filenamePattern 'SE[0-9][0-9][0-9][0-9].zip' -RootPath 'C:\GitHub'
#>

param(
    [Parameter(mandatory = $true)]
    [string] $Name, 
    [Parameter(mandatory = $true)]
    [string] $repo,
    [Parameter(mandatory = $true)]
    [string] $filenamePattern,
    [Parameter(mandatory = $true)]
    [string] $RootPath,
    [Parameter(mandatory = $false)]
    [switch] $innerDirectory,
    [Parameter(mandatory = $false)]
    [switch] $preRelease,
    [Parameter(mandatory = $false)]
    [string] $RestartService
)

function Start-GitService {
    <#
    .SYNOPSIS
    Start service and dependencies.
    .DESCRIPTION
    Will first start the dependencies and then the named service.
    .PARAMETER RestartService
    Name of service to start.
    .EXAMPLE
    Start-GitService -StartService 'netlogon'
    #>
    param (
        [Parameter(Mandatory = $true)]
        [string] $StartService
    )
    Write-Host "Starting $StartService and dependents"
    $Dependencies = Get-Service -Name $StartService -DependentServices
    foreach ($Service in $Dependencies.name) {
        Get-Service -Name $Service | Start-Service
    }
    Get-Service -Name $StartService | Start-Service
}

# Disable progressbar on download to speed up the download
$ProgressPreference = 'SilentlyContinue'

# The constrocuted path of the local GitHub Project
$pathExtract = "$RootPath\$Name"

# Test File paths and create if not exist
If (!(Test-Path $PSScriptRoot\Versions)) {
    New-Item -ItemType Directory -Force -Path $PSScriptRoot\Versions | Out-Null
}
If (!(Test-Path $pathExtract)) {
    New-Item -ItemType Directory -Force -Path $pathExtract | Out-Null
}

# Check to see if there is an older release install date to compatre to
if (Test-Path $PSScriptRoot\Versions\$Name.xml) { 
    $CurrentInstall = Import-Clixml $PSScriptRoot\Versions\$Name.xml
    $PreviousVersionFound = $true 
    Write-Host "Current version Created Date: $CurrentInstall"
}
else { 
    $PreviousVersionFound = $false 
}

# Install pre release or latest stable
if ($preRelease) {
    $releasesUri = "https://api.github.com/repos/$repo/releases"
    $Result = (Invoke-RestMethod -Method GET -Uri $releasesUri)[0].assets
}
else {
    $releasesUri = "https://api.github.com/repos/$repo/releases/latest"
    $Result = (Invoke-RestMethod -Method GET -Uri $releasesUri).assets
}

# Get the created_at from latest GitHub result
[datetime]$LatestOnline = $Result.Where( { $_.name -Like $filenamePattern } ).created_at

# Only initiate download and upgrade if online is newer or no local install date is found
if (($PreviousVersionFound) -and $LatestOnline -gt $CurrentInstall) {
    Write-Host "Current install is older than on GitHub - Updating"        
    $downloadUri = $Result.Where( { $_.name -Like $filenamePattern }).browser_download_url
}
elseif (!$PreviousVersionFound) {
    Write-Host "No previous version found - Updating"        
    $downloadUri = $Result.Where( { $_.name -Like $filenamePattern }).browser_download_url
}
else {
    Write-Host "Online version Created Date: $CurrentInstall"
    Write-Host "Exiting..."
    Exit
}

# Download the latest release
$pathZip = Join-Path -Path $([System.IO.Path]::GetTempPath()) -ChildPath $(Split-Path -Path $downloadUri -Leaf)
try {
    Invoke-WebRequest -Uri $downloadUri -Out $pathZip
}
catch {
    Write-Host "Exception:" $_.Exception.Message
    exit 1
}

# It there is a service defined stop it and it dependencies
if ($RestartService -ne "") {
    Write-Host "Stopping $RestartService and dependents"
    Stop-Service -Name $RestartService -Force
}

# Extract and copy the online GitHub Project to local folder
# If -innerDirectory is defined copy contents of the online root folder to local project
# Otherwise extacrt the zip file directy to local folder
if ($innerDirectory) {
    try {
        $tempExtract = Join-Path -Path $([System.IO.Path]::GetTempPath()) -ChildPath $((New-Guid).Guid) -ErrorAction Stop
        Expand-Archive -Path $pathZip -DestinationPath $tempExtract -Force -ErrorAction Stop
        $RootFolders = (Get-ChildItem -Path $tempExtract -Directory -Force).fullname
        foreach ($Folder in $RootFolders) {
            Copy-Item -Path "$Folder\*" -Destination $pathExtract -Force -Recurse -ErrorAction Stop 
        }
        Remove-Item -Path $tempExtract -Force -Recurse -ErrorAction SilentlyContinue
    }
    catch {
        Write-Host "Exception:" $_.Exception.Message
        exit 1
    }
}
else {
    try {
        Expand-Archive -Path $pathZip -DestinationPath $pathExtract -Force -ErrorAction Stop
    }
    catch {
        Write-Host "Exception:" $_.Exception.Message
        exit 1
    }
}

# Write local created_at date to file for comparison on nect run
$LatestOnline | Export-Clixml $PSScriptRoot\Versions\$Name.xml

# Delete downloaded zip file
Remove-Item $pathZip -Force

# It there is a service defined start it and it dependencies
if ($RestartService -ne "") {
    Start-GitService -RestartService $RestartService
}

Write-Host "Upgrade done, new release date: $LatestOnline"
