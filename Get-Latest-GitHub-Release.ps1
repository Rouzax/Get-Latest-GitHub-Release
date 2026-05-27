<#
.SYNOPSIS
  Fetch latest GitHub Release and copy to local folder.
.DESCRIPTION
  Script to fetch the latest release from specified GitHub Repo if it is newer than the local copy
  and extract the content to local folder while stopping and starting a service.

  Features:
  - Version comparison via GitHub releases API
  - ZIP backup of current installation with automatic rollback on failure
  - Optional Pushover notifications for success and failure
  - Configuration file for shared settings across scheduled tasks
.PARAMETER Name
    Name of the GitHub project (will be used to create directory in $RootPath).
.PARAMETER repo
    Github Repository to target (format: owner/repository).
.PARAMETER filenamePattern
    Filename pattern that will be looked for in the releases page. By default uses PowerShell wildcards (-like operator).
    When -UseRegex is specified, uses regular expressions (-match operator).
.PARAMETER RootPath
    The Root folder where the project need to be replicated to.
.PARAMETER preRelease
    Needed if pre releases are to be downloaded.
.PARAMETER RestartService
    If specified will stop Service and dependents before copy action, will start all services afterwards.
.PARAMETER UseRegex
    When specified, treats filenamePattern as a regular expression instead of a wildcard pattern.
.PARAMETER PushoverUserKey
    Pushover user/group key. Overrides value from config file. If neither provides credentials, notifications are skipped.
.PARAMETER PushoverApiToken
    Pushover application API token. Overrides value from config file.
.PARAMETER PushoverDevice
    Pushover device name to target. Overrides value from config file.
.PARAMETER MaxBackups
    Number of backup ZIPs to retain per project. Overrides value from config file. Default: 3.
.INPUTS
  None
.OUTPUTS
  .\Versions\<name>.json  - Created_at from GitHub Release for version comparison
  .\Backups\<name>\*.zip  - ZIP backups of previous installations
.NOTES
  Version:        3.0
  Author:         Rouzax
  Creation Date:  2020-12-14
  Last Modified:  2026-05-27
  Purpose/Change: Added Pushover notifications, backup/rollback, config file support

  CONFIGURATION FILE (optional):
  Create Config\config.json next to the script:
  {
      "Pushover": {
          "UserKey": "your-user-key",
          "ApiToken": "your-api-token",
          "Device": "optional-device-name",
          "Notifications": {
              "Success":  { "Priority": -1, "Sound": "none", "Ttl": 0 },
              "Failed":   { "Priority":  1, "Sound": "none", "Ttl": 0 },
              "Rollback": { "Priority":  1, "Sound": "none", "Ttl": 0 },
              "Info":     { "Priority": -1, "Sound": "none", "Ttl": 0 }
          }
      },
      "MaxBackups": 3
  }

.EXAMPLE
  # Basic usage with wildcard pattern
  Get-Latest-GitHub-Release.ps1 -Name 'FileBrowser' -repo 'filebrowser/filebrowser' -filenamePattern 'windows-amd64-filebrowser.zip' -RootPath 'C:\Github' -RestartService 'FileBrowser'

  # Using regex pattern for version-specific matching
  Get-Latest-GitHub-Release.ps1 -Name 'SubtitleEdit' -repo 'SubtitleEdit/subtitleedit' -filenamePattern '^SE\d+\.zip$' -RootPath 'C:\GitHub' -UseRegex
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $Name,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[^/]+/[^/]+$')]
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
    [string] $RestartService,
    [Parameter(Mandatory = $false)]
    [string] $PushoverUserKey,
    [Parameter(Mandatory = $false)]
    [string] $PushoverApiToken,
    [Parameter(Mandatory = $false)]
    [string] $PushoverDevice,
    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 20)]
    [int] $MaxBackups = 0
)

#region -- Functions ----------------------------------------------------------

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
    param (
        [Parameter(Mandatory = $true)]
        [string] $StartService
    )
    Write-Log "Starting $StartService and dependents"
    $Dependencies = Get-Service -Name $StartService -DependentServices
    foreach ($Dep in $Dependencies.Name) {
        Get-Service -Name $Dep | Start-Service
        Write-Log "Started dependent service: $Dep"
    }
    Get-Service -Name $StartService | Start-Service
    Write-Log "Started main service: $StartService"
}

function Get-ScriptConfig {
    $configPath = Join-Path $PSScriptRoot (Join-Path 'Config' 'config.json')

    # Defaults for notification types: priority, sound, ttl
    $defaultNotifications = @{
        'Success'  = @{ Priority = -1; Sound = 'none'; Ttl = 0 }
        'Failed'   = @{ Priority = 1;  Sound = 'none'; Ttl = 0 }
        'Rollback' = @{ Priority = 1;  Sound = 'none'; Ttl = 0 }
        'Info'     = @{ Priority = -1; Sound = 'none'; Ttl = 0 }
    }

    $config = @{
        PushoverUserKey  = $null
        PushoverApiToken = $null
        PushoverDevice   = $null
        Notifications    = $defaultNotifications
        MaxBackups       = 3
    }

    if (Test-Path $configPath) {
        try {
            $fileConfig = Get-Content $configPath -Raw | ConvertFrom-Json
            if ($fileConfig.Pushover) {
                if ($fileConfig.Pushover.UserKey)  { $config.PushoverUserKey  = $fileConfig.Pushover.UserKey }
                if ($fileConfig.Pushover.ApiToken) { $config.PushoverApiToken = $fileConfig.Pushover.ApiToken }
                if ($fileConfig.Pushover.Device)   { $config.PushoverDevice   = $fileConfig.Pushover.Device }
                if ($fileConfig.Pushover.Notifications) {
                    foreach ($type in @('Success', 'Failed', 'Rollback', 'Info')) {
                        $notif = $fileConfig.Pushover.Notifications.$type
                        if ($notif) {
                            if ($null -ne $notif.Priority) { $config.Notifications[$type].Priority = [int]$notif.Priority }
                            if ($notif.Sound)              { $config.Notifications[$type].Sound    = $notif.Sound }
                            if ($null -ne $notif.Ttl)      { $config.Notifications[$type].Ttl      = [int]$notif.Ttl }
                        }
                    }
                }
            }
            if ($null -ne $fileConfig.MaxBackups) {
                $config.MaxBackups = [int]$fileConfig.MaxBackups
            }
            Write-Log "Loaded configuration from: $configPath"
        } catch {
            Write-Log "Failed to read config file, using defaults: $($_.Exception.Message)" -Level Warning
        }
    }

    # Command-line parameters override config file
    if ($PushoverUserKey)  { $config.PushoverUserKey  = $PushoverUserKey }
    if ($PushoverApiToken) { $config.PushoverApiToken = $PushoverApiToken }
    if ($PushoverDevice)   { $config.PushoverDevice   = $PushoverDevice }
    if ($MaxBackups -gt 0) { $config.MaxBackups       = $MaxBackups }

    return $config
}

function Send-PushoverNotification {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Success', 'Failed', 'Rollback', 'Info')]
        [string]$Type,

        [Parameter(Mandatory)]
        [string]$Title,

        [Parameter(Mandatory)]
        [string]$Message,

        [string]$Url,
        [string]$UrlTitle
    )

    if (-not $Script:Config.PushoverUserKey -or -not $Script:Config.PushoverApiToken) {
        return
    }

    $notifConfig = $Script:Config.Notifications[$Type]

    $body = @{
        token    = $Script:Config.PushoverApiToken
        user     = $Script:Config.PushoverUserKey
        title    = $Title
        message  = $Message
        html     = 1
        priority = $notifConfig.Priority
        sound    = $notifConfig.Sound
    }

    if ($notifConfig.Ttl -gt 0) {
        $body['ttl'] = $notifConfig.Ttl
    }

    if ($Script:Config.PushoverDevice) {
        $body['device'] = $Script:Config.PushoverDevice
    }

    if ($Url) {
        $body['url'] = $Url
        if ($UrlTitle) {
            $body['url_title'] = $UrlTitle
        }
    }

    try {
        $null = Invoke-RestMethod -Uri 'https://api.pushover.net/1/messages.json' `
            -Method Post -Body $body -TimeoutSec 15 -ErrorAction Stop
        Write-Log "Pushover notification sent: $Type"
    } catch {
        Write-Log "Pushover notification failed: $($_.Exception.Message)" -Level Warning
    }
}

function New-InstallationBackup {
    param(
        [Parameter(Mandatory)]
        [string]$SourcePath,

        [Parameter(Mandatory)]
        [string]$ProjectName
    )

    # Nothing to back up if target is empty or missing
    if (-not (Test-Path $SourcePath)) { return $null }
    $contents = @(Get-ChildItem -Path $SourcePath)
    if ($contents.Count -eq 0) { return $null }

    $backupRoot = Join-Path $PSScriptRoot (Join-Path 'Backups' $ProjectName)
    if (-not (Test-Path $backupRoot)) {
        New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
    }

    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $backupZip = Join-Path $backupRoot "$timestamp.zip"

    Write-Log "Creating backup: $backupZip"
    Compress-Archive -Path (Join-Path $SourcePath '*') -DestinationPath $backupZip -Force

    $sizeMB = [math]::Round((Get-Item $backupZip).Length / 1MB, 1)
    Write-Log "Backup created: ${sizeMB}MB"

    # Prune old backups
    $allBackups = @(Get-ChildItem -Path $backupRoot -Filter '*.zip' -File | Sort-Object Name -Descending)
    if ($allBackups.Count -gt $Script:Config.MaxBackups) {
        $allBackups | Select-Object -Skip $Script:Config.MaxBackups | ForEach-Object {
            Write-Log "Pruning old backup: $($_.Name)"
            Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
        }
    }

    return $backupZip
}

function Restore-FromBackup {
    param(
        [Parameter(Mandatory)]
        [string]$BackupZip,

        [Parameter(Mandatory)]
        [string]$TargetPath
    )

    if (-not (Test-Path $BackupZip)) {
        Write-Log "Backup file not found: $BackupZip" -Level Error
        return $false
    }

    Write-Log "Rolling back from backup: $BackupZip"

    try {
        # Clear the target directory
        Get-ChildItem -Path $TargetPath -Force | Remove-Item -Recurse -Force

        # Extract backup
        Expand-Archive -Path $BackupZip -DestinationPath $TargetPath -Force
        Write-Log "Rollback complete: files restored"
        return $true
    } catch {
        Write-Log "Rollback failed: $($_.Exception.Message)" -Level Error
        return $false
    }
}

#endregion

#region -- Main ---------------------------------------------------------------

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Script:Config = Get-ScriptConfig

$serviceStopped = $false
$pathZip = $null
$tempExtract = $null
$backupZip = $null
$exitCode = 0
$errorMessage = $null
$downloadUri = $null
$releaseUrl = $null

try {
    # Validate service exists before doing any work
    if ($RestartService) {
        $svc = Get-Service -Name $RestartService -ErrorAction Stop
        Write-Log "Validated service: $RestartService (Status: $($svc.Status))"
    }

    # Validate regex pattern compiles
    if ($UseRegex) {
        try {
            [regex]::new($filenamePattern) | Out-Null
        } catch {
            throw "Invalid regex pattern '$filenamePattern': $($_.Exception.Message)"
        }
    }

    $pathExtract = Join-Path $RootPath $Name
    $versionsPath = Join-Path $PSScriptRoot "Versions"
    $versionFile = Join-Path $versionsPath "$Name.json"

    @($versionsPath, $pathExtract) | ForEach-Object {
        if (-not (Test-Path $_)) {
            Write-Log "Creating directory: $_"
            New-Item -ItemType Directory -Force -Path $_ | Out-Null
        }
    }

    # Read version file, recovering gracefully from corruption
    $PreviousVersionFound = $false
    $localCreatedDate = $null
    if (Test-Path $versionFile) {
        try {
            $CurrentInstall = Get-Content $versionFile -Raw | ConvertFrom-Json
            [datetime]$localCreatedDate = $CurrentInstall
            if ($localCreatedDate.Kind -ne "UTC") {
                $localCreatedDate = $localCreatedDate.ToUniversalTime()
            }
            $PreviousVersionFound = $true
            Write-Log "Local version Created Date: " -NoNewline
            Write-Host $($localCreatedDate.ToString('yyyy-MM-ddTHH:mm:ssZ')) -ForegroundColor DarkCyan
        } catch {
            Write-Log "Version file is corrupt, treating as fresh install" -Level Warning
            Remove-Item $versionFile -Force -ErrorAction SilentlyContinue
        }
    } else {
        Write-Log "No previous version found"
    }

    # Build API URL
    if ($preRelease) {
        $releasesUri = "https://api.github.com/repos/$repo/releases/"
    } else {
        $releasesUri = "https://api.github.com/repos/$repo/releases/latest"
    }
    Write-Log "Fetching from: $releasesUri"

    $apiParams = @{
        Method     = 'GET'
        Uri        = $releasesUri
        Headers    = @{ 'User-Agent' = 'Get-Latest-GitHub-Release-PS' }
        TimeoutSec = 30
    }

    try {
        $apiResponse = Invoke-RestMethod @apiParams
    } catch {
        $statusCode = $null
        if ($_.Exception.Response) {
            $statusCode = [int]$_.Exception.Response.StatusCode
        }
        if ($statusCode -eq 403) {
            throw "GitHub API rate limit exceeded (60 requests/hour for unauthenticated calls). Try again later."
        } elseif ($statusCode -eq 404) {
            throw "Repository '$repo' not found or has no releases."
        } else {
            throw "GitHub API request failed: $($_.Exception.Message)"
        }
    }

    if ($preRelease) {
        if (-not $apiResponse -or @($apiResponse).Count -eq 0) {
            throw "No releases found for repository '$repo'."
        }
        $releaseObj = @($apiResponse)[0]
    } else {
        $releaseObj = $apiResponse
    }

    $releaseUrl = $releaseObj.html_url
    $Result = $releaseObj.assets

    if (-not $Result -or @($Result).Count -eq 0) {
        throw "Release found but it contains no downloadable assets."
    }

    # Match assets by pattern
    $matchingAssets = @(
        if ($UseRegex) {
            $Result.Where({ $_.name -match $filenamePattern })
        } else {
            $Result.Where({ $_.name -like $filenamePattern })
        }
    )

    if ($matchingAssets.Count -eq 0) {
        Write-Log "Available assets:" -Level Warning
        $Result | ForEach-Object { Write-Log "  - $($_.name)" -Level Warning }
        throw "No asset found matching pattern: '$filenamePattern'"
    }

    if ($matchingAssets.Count -gt 1) {
        Write-Log "Multiple assets match pattern '$filenamePattern':" -Level Warning
        $matchingAssets | ForEach-Object { Write-Log "  - $($_.name)" -Level Warning }
        Write-Log "Using first match: $($matchingAssets[0].name)" -Level Warning
    }

    $selectedAsset = $matchingAssets[0]
    Write-Log "Matched asset: $($selectedAsset.name)"

    # Parse release date
    [datetime]$LatestOnline = $selectedAsset.created_at
    if ($LatestOnline.Kind -ne "UTC") {
        $LatestOnline = $LatestOnline.ToUniversalTime()
    }
    Write-Log "Online version Created Date: " -NoNewline
    Write-Host $($LatestOnline.ToString('yyyy-MM-ddTHH:mm:ssZ')) -ForegroundColor DarkCyan

    # Compare versions
    if ($PreviousVersionFound -and $LatestOnline -le $localCreatedDate) {
        Write-Log "Local version is up to date"
        exit 0
    }

    if ($PreviousVersionFound) {
        Write-Log "Current install is older than on GitHub, updating"
    } else {
        Write-Log "No previous version found, installing"
    }

    $downloadUri = $selectedAsset.browser_download_url
    $expectedSize = $selectedAsset.size

    # Use unique temp filename to avoid collisions between concurrent runs
    $zipLeaf = Split-Path -Path $downloadUri -Leaf
    $pathZip = Join-Path ([System.IO.Path]::GetTempPath()) "$Name-$(Get-Random)-$zipLeaf"

    Write-Log "Downloading: $downloadUri"
    Invoke-WebRequest -Uri $downloadUri -OutFile $pathZip -TimeoutSec 300

    # Verify download completed fully
    $actualSize = (Get-Item $pathZip).Length
    if ($expectedSize -and $actualSize -ne $expectedSize) {
        throw "Download incomplete: expected $expectedSize bytes, got $actualSize bytes."
    }
    Write-Log "Download verified: $actualSize bytes"

    # Extract to temp directory first so a corrupt zip never touches the target
    $tempExtract = Join-Path ([System.IO.Path]::GetTempPath()) "$Name-extract-$(Get-Random)"
    New-Item -ItemType Directory -Path $tempExtract -Force | Out-Null
    Write-Log "Extracting to temporary directory for validation"
    Expand-Archive -Path $pathZip -DestinationPath $tempExtract -Force

    # Flatten single wrapper directory (immediate children only, not -Recurse)
    $extractedItems = @(Get-ChildItem -Path $tempExtract)
    if ($extractedItems.Count -eq 1 -and $extractedItems[0].PSIsContainer) {
        $innerDirectory = $extractedItems[0].FullName
        Write-Log "Flattening wrapper directory: $($extractedItems[0].Name)"
        Get-ChildItem -Path $innerDirectory | Move-Item -Destination $tempExtract -Force
        Remove-Item -Path $innerDirectory -Force -Recurse
    }

    # Stop service before backup so locked files (e.g. database files) can be read
    if ($RestartService) {
        Write-Log "Stopping $RestartService and dependents"
        Stop-Service -Name $RestartService -Force
        $serviceStopped = $true
    }

    # Back up current installation after service is stopped
    $backupZip = New-InstallationBackup -SourcePath $pathExtract -ProjectName $Name

    # Deploy validated files to target
    Write-Log "Deploying to: $pathExtract"
    $sourceItems = Join-Path $tempExtract '*'
    try {
        Copy-Item -Path $sourceItems -Destination $pathExtract -Recurse -Force
    } catch {
        # Deployment failed: roll back if we have a backup
        if ($backupZip) {
            Write-Log "Deployment failed, rolling back: $($_.Exception.Message)" -Level Error
            $null = Restore-FromBackup -BackupZip $backupZip -TargetPath $pathExtract
        }
        throw
    }

    # Restart service immediately after files are in place
    if ($serviceStopped) {
        try {
            Start-GitService -StartService $RestartService
            $serviceStopped = $false
        } catch {
            # Service failed to start with new version: roll back
            if ($backupZip) {
                Write-Log "Service failed to start after update, rolling back" -Level Error
                $null = Restore-FromBackup -BackupZip $backupZip -TargetPath $pathExtract
                try {
                    Start-GitService -StartService $RestartService
                    $serviceStopped = $false
                    Write-Log "Service started successfully after rollback"
                } catch {
                    Write-Log "Service also failed to start after rollback: $($_.Exception.Message)" -Level Error
                }
                Send-PushoverNotification -Type 'Rollback' `
                    -Title "$Name update rolled back" `
                    -Message (
                        "<b>$Name</b> ($repo) failed to start after update." +
                        "<br>Rolled back to previous version." +
                        "<br><b>Asset:</b> $($selectedAsset.name)"
                    ) `
                    -Url $releaseUrl -UrlTitle 'Release Notes'
            }
            throw
        }
    }

    # Write version file only after successful deployment
    $LatestOnlineIso = $LatestOnline.ToString("yyyy-MM-ddTHH:mm:ssZ")
    $LatestOnlineIso | ConvertTo-Json | Set-Content -Path $versionFile -Force
    Write-Log "Version information saved to: $versionFile"

    Write-Log "Update completed successfully. New release date: $($LatestOnline.ToString('yyyy-MM-ddTHH:mm:ssZ'))"

    Send-PushoverNotification -Type 'Success' `
        -Title "$Name updated" `
        -Message (
            "<b>$Name</b> ($repo) updated successfully." +
            "<br><b>Release date:</b> $($LatestOnline.ToString('yyyy-MM-ddTHH:mm:ssZ'))" +
            "<br><b>Asset:</b> $($selectedAsset.name)"
        ) `
        -Url $releaseUrl -UrlTitle 'Release Notes'
} catch {
    $errorMessage = $_.Exception.Message
    Write-Log $errorMessage -Level Error
    $exitCode = 1
} finally {
    # Guarantee service restart even if the script fails after stopping it
    if ($serviceStopped -and $RestartService) {
        Write-Log "Restarting service after failure" -Level Warning
        try {
            Start-GitService -StartService $RestartService
        } catch {
            Write-Log "CRITICAL: Failed to restart service '$RestartService': $($_.Exception.Message)" -Level Error
        }
    }

    # Send failure notification (not for rollbacks, those are sent inline)
    if ($exitCode -ne 0 -and $errorMessage) {
        Send-PushoverNotification -Type 'Failed' `
            -Title "$Name update failed" `
            -Message (
                "<b>$Name</b> ($repo) update failed." +
                "<br><b>Error:</b> $errorMessage"
            )
    }

    # Clean up temp files
    if ($pathZip -and (Test-Path $pathZip)) {
        Remove-Item $pathZip -Force -ErrorAction SilentlyContinue
    }
    if ($tempExtract -and (Test-Path $tempExtract)) {
        Remove-Item $tempExtract -Recurse -Force -ErrorAction SilentlyContinue
    }
}

exit $exitCode

#endregion
