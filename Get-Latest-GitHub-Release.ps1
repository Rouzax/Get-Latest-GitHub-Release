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
.PARAMETER preRelease
    Needed if pre releases are to be downloaded.
.PARAMETER RestartService
    If specified will stop Service and dependents as specified before copy action, will start all services afterwards.
.INPUTS
  None
.OUTPUTS
  .\Versions\<name>.json Created_at from GitHub Release to compare if there is a newer version
.NOTES
  Version:        1.3
  Author:         Rouzax
  Creation Date:  2020-12-14
  Purpose/Change: Improved error handling, adhered to PowerShell best practices, switched to JSON for version storage.
  
.EXAMPLE
  Get-Latest-GitHub-Release.ps1 -Name 'FileBrowser' -repo 'filebrowser/filebrowser' -filenamePattern 'windows-amd64-filebrowser.zip' -RootPath 'C:\Github' -preRelease:$false -RestartService 'FileBrowser'
  Get-Latest-GitHub-Release.ps1 -Name 'Jackett' -repo 'Jackett/Jackett' -filenamePattern 'Jackett.Binaries.Windows.zip' -RootPath 'C:\Github' -preRelease:$true -RestartService 'Jackett'
  Get-Latest-GitHub-Release.ps1 -Name 'MailSend-Go' -repo 'muquit/mailsend-go' -filenamePattern '*windows-64bit.zip' -RootPath 'C:\GitHub' 
  Get-Latest-GitHub-Release.ps1 -Name 'SubtitleEdit' -repo 'SubtitleEdit/subtitleedit' -filenamePattern 'SE[0-9][0-9][0-9].zip' -RootPath 'C:\GitHub'
#>

param(
    [Parameter(Mandatory = $true)]
    [string] $Name, 
    [Parameter(Mandatory = $true)]
    [string] $repo,
    [Parameter(Mandatory = $true)]
    [string] $filenamePattern,
    [Parameter(Mandatory = $true)]
    [string] $RootPath,
    [Parameter(Mandatory = $false)]
    [switch] $innerDirectory,
    [Parameter(Mandatory = $false)]
    [switch] $preRelease,
    [Parameter(Mandatory = $false)]
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

# Error handling function
function Write-ErrorAndExit {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ErrorMessage
    )
    Write-Host "Error: $ErrorMessage" -ForegroundColor Red
    exit 1
}

# Disable progress bar on download to speed up the download
$ProgressPreference = 'SilentlyContinue'

# The constructed path of the local GitHub Project
$pathExtract = "$RootPath\$Name"

# Test File paths and create if not exist
If (!(Test-Path $PSScriptRoot\Versions)) {
    New-Item -ItemType Directory -Force -Path $PSScriptRoot\Versions | Out-Null
}
If (!(Test-Path $pathExtract)) {
    New-Item -ItemType Directory -Force -Path $pathExtract | Out-Null
}

# Check to see if there is an older release install date to compare to
$versionFile = "$PSScriptRoot\Versions\$Name.json"
if (Test-Path $versionFile) { 
    $CurrentInstall = Get-Content $versionFile -Raw | ConvertFrom-Json
    $PreviousVersionFound = $true 
    [datetime]$localCreatedDate = $CurrentInstall.value
    if ($localCreatedDate.Kind -ne "UTC") {
        $localCreatedDate = $localCreatedDate.ToUniversalTime()
    }
    Write-Host "Local version Created Date: " -NoNewline
    Write-Host $($localCreatedDate) -ForegroundColor DarkCyan
} else { 
    $PreviousVersionFound = $false 
}

# Install pre-release or latest stable
if ($preRelease) {
    $releasesUri = "https://api.github.com/repos/$repo/releases"
    $Result = (Invoke-RestMethod -Method GET -Uri $releasesUri)[0].assets
} else {
    $releasesUri = "https://api.github.com/repos/$repo/releases/latest"
    $Result = (Invoke-RestMethod -Method GET -Uri $releasesUri).assets
}

# Get the created_at from latest GitHub result
$latestAsset = @()
$latestAsset = $Result.Where({ $_.name -like $filenamePattern })
if ($latestAsset.Count -eq 0) {
    Write-ErrorAndExit "No asset found matching the specified filename pattern: '$filenamePattern'"
}
# Explicitly parse the date string to a DateTime object and specify the timezone as UTC
[datetime]$LatestOnline = $latestAsset.created_at
if ($LatestOnline.Kind -ne "UTC") {
    $LatestOnline = $LatestOnline.ToUniversalTime()
}
Write-host "Online version Created Date: " -NoNewline
Write-host  ($LatestOnline) -ForegroundColor DarkCyan

# Only initiate download and upgrade if online is newer or no local install date is found
if ($PreviousVersionFound -and $LatestOnline -gt $localCreatedDate) {
    Write-Host "Current install is older than on GitHub - Updating"
    $downloadUri = $Result.Where( { $_.name -Like $filenamePattern }).browser_download_url
} elseif (!$PreviousVersionFound) {
    Write-Host "No previous version found - Updating"
    $downloadUri = $Result.Where( { $_.name -Like $filenamePattern }).browser_download_url
} else {
    Write-Host "Local and online version have the same Created Date"
    Write-Host "Exiting..."
    Exit
}

# Download the latest release
$pathZip = Join-Path -Path $([System.IO.Path]::GetTempPath()) -ChildPath $(Split-Path -Path $downloadUri -Leaf)
try {
    Invoke-WebRequest -Uri $downloadUri -OutFile $pathZip -ErrorAction Stop
} catch {
    Write-ErrorAndExit "Failed to download the latest release: $($_.Exception.Message)"
}

# If a service is defined, stop it and its dependencies
if ($RestartService) {
    Write-Host "Stopping $RestartService and dependents"
    try {
        Stop-Service -Name $RestartService -Force -ErrorAction Stop
    } catch {
        Write-ErrorAndExit "Failed to stop the service $($RestartService): $($_.Exception.Message)"
    }
}

# Extract and copy the online GitHub Project to local folder
try {
    Expand-Archive -Path $pathZip -DestinationPath $pathExtract -Force -ErrorAction Stop

    # Check if there's only one directory in the extracted folder
    $extractedItems = Get-ChildItem -Path $pathExtract
    if ($extractedItems.Count -eq 1 -and $extractedItems[0].PSIsContainer) {
        $innerDirectory = $extractedItems[0].FullName

        # Move contents of the inner directory (including subdirectories) to the target directory
        Get-ChildItem -Path $innerDirectory -Recurse | Move-Item -Destination $pathExtract -Force -ErrorAction Stop

        # Remove the extracted inner directory
        Remove-Item -Path $innerDirectory -Force -Recurse -ErrorAction SilentlyContinue
    }
} catch {
    Write-ErrorAndExit "Failed to extract and move the GitHub project: $($_.Exception.Message)"
}

# Write local created_at date to file for comparison on next run
try {
    $LatestOnline | ConvertTo-Json | Set-Content -Path $versionFile -Force -ErrorAction Stop
} catch {
    Write-ErrorAndExit "Failed to save the version information: $($_.Exception.Message)"
}

# Delete downloaded zip file
try {
    Remove-Item $pathZip -Force -ErrorAction Stop
} catch {
    Write-ErrorAndExit "Failed to delete the downloaded zip file: $($_.Exception.Message)"
}

# If a service is defined, start it and its dependencies
if ($RestartService) {
    Start-GitService -StartService $RestartService
}

Write-Host "Upgrade done, new release date: $($LatestOnline)"
