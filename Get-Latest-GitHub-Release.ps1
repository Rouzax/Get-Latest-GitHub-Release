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
    Filename pattern that will be looked for in the releases page. By default uses PowerShell wildcards (-like operator).
    When -UseRegex is specified, uses regular expressions (-match operator).
.PARAMETER RootPath
    The Root folder where the project need to be replicated to.
.PARAMETER preRelease
    Needed if pre releases are to be downloaded.
.PARAMETER RestartService
    If specified will stop Service and dependents as specified before copy action, will start all services afterwards.
.PARAMETER UseRegex
    When specified, treats filenamePattern as a regular expression instead of a wildcard pattern.
    Useful for complex matching patterns.
.INPUTS
  None
.OUTPUTS
  .\Versions\<name>.json Created_at from GitHub Release to compare if there is a newer version
.NOTES
  Version:        1.5
  Author:         Rouzax
  Creation Date:  2020-12-14
  Last Modified:  2024-01-13
  Purpose/Change: Added regex support for filename matching, improved error handling
  
.EXAMPLE
  # Basic usage with wildcard pattern
  Get-Latest-GitHub-Release.ps1 -Name 'FileBrowser' -repo 'filebrowser/filebrowser' -filenamePattern 'windows-amd64-filebrowser.zip' -RootPath 'C:\Github' -RestartService 'FileBrowser'

  # Using pre-release with service restart
  Get-Latest-GitHub-Release.ps1 -Name 'Jackett' -repo 'Jackett/Jackett' -filenamePattern 'Jackett.Binaries.Windows.zip' -RootPath 'C:\Github' -preRelease -RestartService 'Jackett'

  # Simple wildcard pattern
  Get-Latest-GitHub-Release.ps1 -Name 'MailSend-Go' -repo 'muquit/mailsend-go' -filenamePattern '*windows-64bit.zip' -RootPath 'C:\GitHub' 

  # Using regex pattern for version-specific matching
  Get-Latest-GitHub-Release.ps1 -Name 'SubtitleEdit' -repo 'SubtitleEdit/subtitleedit' -filenamePattern '^SE\d+\.zip$' -RootPath 'C:\GitHub' -UseRegex
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $Name, 
    [Parameter(Mandatory = $true)]
    [string] $repo,
    [Parameter(Mandatory = $true)]
    [string] $filenamePattern,
    [Parameter(Mandatory = $false)]
    [switch] $UseRegex,
    [Parameter(Mandatory = $true)]
    [string] $RootPath,
    [Parameter(Mandatory = $false)]
    [switch] $preRelease,
    [Parameter(Mandatory = $false)]
    [string] $RestartService
)

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('Info', 'Warning', 'Error')]
        [string]$Level = 'Info',
        [switch]$NoNewline
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] ${Level}: $Message"
    
    switch ($Level) {
        'Info' { 
            if ($NoNewline) {
                Write-Host $logMessage -NoNewline
            } else {
                Write-Host $logMessage
            }
        }
        'Warning' {
            Write-Host $logMessage -ForegroundColor Yellow 
        }
        'Error' {
            Write-Host $logMessage -ForegroundColor Red 
        }
    }
}

function Start-GitService {
    <#
    .SYNOPSIS
    Start service and dependencies.
    .DESCRIPTION
    Will first start the dependencies and then the named service.
    .PARAMETER StartService
    Name of service to start.
    .EXAMPLE
    Start-GitService -StartService 'netlogon'
    #>
    param (
        [Parameter(Mandatory = $true)]
        [string] $StartService
    )
    Write-Log "Starting $StartService and dependents"
    try {
        $Dependencies = Get-Service -Name $StartService -DependentServices
        foreach ($Service in $Dependencies.name) {
            Get-Service -Name $Service | Start-Service
            Write-Log "Started dependent service: $Service"
        }
        Get-Service -Name $StartService | Start-Service
        Write-Log "Started main service: $StartService"
    } catch {
        throw "Failed to start services: $($_.Exception.Message)"
    }
}

function Write-ErrorAndExit {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ErrorMessage
    )
    Write-Log $ErrorMessage -Level Error
    exit 1
}

try {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'

    # The constructed path of the local GitHub Project
    $pathExtract = Join-Path $RootPath $Name
    $versionsPath = Join-Path $PSScriptRoot "Versions"
    $versionFile = Join-Path $versionsPath "$Name.json"

    # Test File paths and create if not exist
    @($versionsPath, $pathExtract) | ForEach-Object {
        if (-not (Test-Path $_)) {
            Write-Log "Creating directory: $_"
            New-Item -ItemType Directory -Force -Path $_ | Out-Null
        }
    }

    # Check to see if there is an older release install date to compare to
    if (Test-Path $versionFile) { 
        $CurrentInstall = Get-Content $versionFile -Raw | ConvertFrom-Json
        $PreviousVersionFound = $true 
        [datetime]$localCreatedDate = $CurrentInstall
        if ($localCreatedDate.Kind -ne "UTC") {
            $localCreatedDate = $localCreatedDate.ToUniversalTime()
        }
        Write-Log "Local version Created Date: " -NoNewline
        Write-Host $($localCreatedDate) -ForegroundColor DarkCyan
    } else { 
        $PreviousVersionFound = $false 
        Write-Log "No previous version found"
    }

    # Install pre-release or latest stable
    if ($preRelease) {
        $releasesUri = "https://api.github.com/repos/$repo/releases/"
    } else {
        $releasesUri = "https://api.github.com/repos/$repo/releases/latest"
    }
    Write-Log "Fetching from: $releasesUri"
    
    if ($preRelease) {
        $Result = (Invoke-RestMethod -Method GET -Uri $releasesUri)[0].assets
    } else {
        $Result = (Invoke-RestMethod -Method GET -Uri $releasesUri).assets
    }

    # Get the created_at from latest GitHub result
    $latestAsset = if ($UseRegex) {
        $Result.Where({ $_.name -match $filenamePattern })
    } else {
        $Result.Where({ $_.name -like $filenamePattern })
    }
    if ($latestAsset.Count -eq 0) {
        Write-Log "Available assets:" -Level Warning
        $Result | ForEach-Object { Write-Log "- $($_.name)" -Level Warning }
        Write-ErrorAndExit "No asset found matching pattern: '$filenamePattern'"
    }

    # Explicitly parse the date string to a DateTime object and specify the timezone as UTC
    [datetime]$LatestOnline = $latestAsset.created_at
    if ($LatestOnline.Kind -ne "UTC") {
        $LatestOnline = $LatestOnline.ToUniversalTime()
    }
    Write-Log "Online version Created Date: " -NoNewline
    Write-Host $($LatestOnline) -ForegroundColor DarkCyan

    # Only initiate download and upgrade if online is newer or no local install date is found
    if ($PreviousVersionFound -and $LatestOnline -gt $localCreatedDate) {
        Write-Log "Current install is older than on GitHub - Updating"
        $downloadUri = $latestAsset.browser_download_url
    } elseif (!$PreviousVersionFound) {
        Write-Log "No previous version found - Updating"
        $downloadUri = $latestAsset.browser_download_url
    } else {
        Write-Log "Local and online version have the same Created Date"
        Write-Log "Exiting..."
        exit 0
    }

    # Download the latest release
    $pathZip = Join-Path -Path $([System.IO.Path]::GetTempPath()) -ChildPath $(Split-Path -Path $downloadUri -Leaf)
    Write-Log "Downloading from: $downloadUri"
    Invoke-WebRequest -Uri $downloadUri -OutFile $pathZip

    # If a service is defined, stop it and its dependencies
    if ($RestartService) {
        Write-Log "Stopping $RestartService and dependents"
        Stop-Service -Name $RestartService -Force
    }

    # Extract and copy the online GitHub Project to local folder
    Write-Log "Extracting to: $pathExtract"
    Expand-Archive -Path $pathZip -DestinationPath $pathExtract -Force

    # Check if there's only one directory in the extracted folder
    $extractedItems = Get-ChildItem -Path $pathExtract
    if ($extractedItems.Count -eq 1 -and $extractedItems[0].PSIsContainer) {
        $innerDirectory = $extractedItems[0].FullName
        Write-Log "Moving contents from inner directory: $innerDirectory"

        # Move contents of the inner directory (including subdirectories) to the target directory
        Get-ChildItem -Path $innerDirectory -Recurse | Move-Item -Destination $pathExtract -Force

        # Remove the extracted inner directory
        Remove-Item -Path $innerDirectory -Force -Recurse -ErrorAction SilentlyContinue
    }

    # Write local created_at date to file for comparison on next run
    $LatestOnline | ConvertTo-Json | Set-Content -Path $versionFile -Force
    Write-Log "Version information saved to: $versionFile"

    # Delete downloaded zip file
    Remove-Item $pathZip -Force
    Write-Log "Temporary zip file removed"

    # If a service is defined, start it and its dependencies
    if ($RestartService) {
        Start-GitService -StartService $RestartService
    }

    Write-Log "Upgrade completed successfully. New release date: $LatestOnline"
} catch {
    Write-ErrorAndExit $_.Exception.Message
}