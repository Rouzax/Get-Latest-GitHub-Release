<#
.SYNOPSIS
  Fetch latest GitHub Release and copy to local folder.
.DESCRIPTION
  Script to fetch the latest release from specified GitHub Repo if it is newer than the local copy
  and extract the content to local folder while stopping and starting a service.

  Features:
  - Version comparison via GitHub releases API
  - Handles both .zip release assets and unpacked binaries (e.g. a bare .exe)
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
    Assets ending in .zip are extracted. Any other asset is deployed as a single file
    under its released name, which covers projects that publish a bare executable.
    Archive formats that cannot be extracted (.7z, .tar, .gz, ...) are rejected.
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
.PARAMETER MaxLogs
    Number of log files to retain per project. Overrides value from config file. Default: 10.
.INPUTS
  None
.OUTPUTS
  .\Versions\<name>.json  - Release created_at, tag, asset name and install time, used for
                            version comparison. Files written by versions before 3.3 hold a
                            bare date string instead and are still read.
  .\Backups\<name>\*.zip  - ZIP backups of previous installations
  .\Logs\<name>\*.log     - Per-run log files with timestamps
.NOTES
  Version:        3.3
  Author:         Rouzax
  Creation Date:  2020-12-14
  Last Modified:  2026-08-20
  Purpose/Change: Support unpacked binary assets, not just .zip; fix -preRelease (releases
                  API URL, leaked [datetime] type constraint); report release tag and
                  upgrade path in Pushover notifications

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
      "MaxBackups": 3,
      "MaxLogs": 10
  }

.EXAMPLE
  # Basic usage with wildcard pattern
  Get-Latest-GitHub-Release.ps1 -Name 'FileBrowser' -repo 'filebrowser/filebrowser' -filenamePattern 'windows-amd64-filebrowser.zip' -RootPath 'C:\Github' -RestartService 'FileBrowser'

  # Using regex pattern for version-specific matching
  Get-Latest-GitHub-Release.ps1 -Name 'SubtitleEdit' -repo 'SubtitleEdit/subtitleedit' -filenamePattern '^SE\d+\.zip$' -RootPath 'C:\GitHub' -UseRegex

  # Unpacked asset: this project publishes a bare filebrowser.exe rather than a zip
  Get-Latest-GitHub-Release.ps1 -Name 'FileBrowserQuantum' -repo 'gtsteffaniak/filebrowser' -filenamePattern 'filebrowser.exe' -RootPath 'C:\GitHub' -RestartService 'FileBrowserQuantum'

  # Task Scheduler usage (pwsh.exe -File does not process single quotes;
  # they become literal characters in parameter values, so omit them):
  #   Program: pwsh.exe
  #   Arguments: -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "C:\Github\Get-Latest-GitHub-Release\Get-Latest-GitHub-Release.ps1" -Name FileBrowser -repo filebrowser/filebrowser -filenamePattern windows-amd64-filebrowser.zip -RootPath C:\GitHub -RestartService FileBrowser
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
    [int] $MaxBackups = 0,
    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 100)]
    [int] $MaxLogs = 0
)

#region -- Functions ----------------------------------------------------------

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('Info', 'Warning', 'Error')]
        [string]$Level = 'Info'
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] ${Level}: $Message"

    switch ($Level) {
        'Info'    { Write-Host $logMessage }
        'Warning' { Write-Host $logMessage -ForegroundColor Yellow }
        'Error'   { Write-Host $logMessage -ForegroundColor Red }
    }

    if ($Script:LogFile) {
        Add-Content -Path $Script:LogFile -Value $logMessage -ErrorAction SilentlyContinue
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
        MaxLogs          = 10
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
            if ($null -ne $fileConfig.MaxLogs) {
                $config.MaxLogs = [int]$fileConfig.MaxLogs
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
    if ($MaxLogs -gt 0)    { $config.MaxLogs          = $MaxLogs }

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

# Initialize log file
try {
    $logsRoot = Join-Path $PSScriptRoot (Join-Path 'Logs' $Name)
    if (-not (Test-Path $logsRoot)) {
        New-Item -ItemType Directory -Path $logsRoot -Force | Out-Null
    }
    $Script:LogFile = Join-Path $logsRoot "$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
} catch {
    Write-Host "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] Warning: Could not initialize log file: $($_.Exception.Message)" -ForegroundColor Yellow
}

Write-Log "=== Get-Latest-GitHub-Release started ==="
Write-Log "PowerShell: $($PSVersionTable.PSVersion)"
Write-Log "OS: $(if ($PSVersionTable.OS) { $PSVersionTable.OS } else { [System.Environment]::OSVersion.VersionString })"
Write-Log "Script: $PSCommandPath"
Write-Log "Parameters: Name=$Name, Repo=$repo, Pattern=$filenamePattern, UseRegex=$UseRegex, RootPath=$RootPath, PreRelease=$preRelease, RestartService=$RestartService"

$Script:Config = Get-ScriptConfig

Write-Log "Effective config: MaxBackups=$($Script:Config.MaxBackups), MaxLogs=$($Script:Config.MaxLogs), Pushover=$(if ($Script:Config.PushoverUserKey) { 'configured' } else { 'disabled' })"

# Prune old log files
if ($Script:LogFile) {
    $allLogs = @(Get-ChildItem -Path $logsRoot -Filter '*.log' -File | Sort-Object Name -Descending)
    if ($allLogs.Count -gt $Script:Config.MaxLogs) {
        $allLogs | Select-Object -Skip $Script:Config.MaxLogs | ForEach-Object {
            Write-Log "Pruning old log: $($_.Name)"
            Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
        }
    }
}

$serviceStopped = $false
$pathZip = $null
$tempExtract = $null
$backupZip = $null
$exitCode = 0
$errorMessage = $null
$downloadUri = $null
$releaseUrl = $null
$releaseTag = $null
$isPreRelease = $false
$localTag = $null

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

    # Read version file, recovering gracefully from corruption.
    # Two shapes are accepted: a bare ISO date string, written by versions before
    # 3.3, and the current object form. Reading the bare string keeps existing
    # installs from looking like fresh ones after the script is upgraded.
    $PreviousVersionFound = $false
    $localCreatedDate = $null
    if (Test-Path $versionFile) {
        try {
            $CurrentInstall = Get-Content $versionFile -Raw | ConvertFrom-Json
            # Detect the shape by property, not by type: ConvertFrom-Json turns the
            # bare ISO string of the old format straight into a [datetime], so a
            # string test never matches it.
            if ($CurrentInstall.PSObject.Properties.Name -contains 'CreatedAt') {
                $localCreatedDate = [datetime]$CurrentInstall.CreatedAt
                $localTag = $CurrentInstall.Tag
            } else {
                $localCreatedDate = [datetime]$CurrentInstall
            }
            if ($localCreatedDate.Kind -ne "UTC") {
                $localCreatedDate = $localCreatedDate.ToUniversalTime()
            }
            $PreviousVersionFound = $true
            $localDesc = $localCreatedDate.ToString('yyyy-MM-ddTHH:mm:ssZ')
            if ($localTag) { $localDesc = "$localTag ($localDesc)" }
            Write-Log "Local version: $localDesc"
        } catch {
            Write-Log "Version file is corrupt, treating as fresh install" -Level Warning
            Remove-Item $versionFile -Force -ErrorAction SilentlyContinue
        }
    } else {
        Write-Log "No previous version found"
    }

    # Build API URL
    if ($preRelease) {
        $releasesUri = "https://api.github.com/repos/$repo/releases"
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
    $releaseTag = $releaseObj.tag_name
    $isPreRelease = [bool]$releaseObj.prerelease
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
    $LatestOnline = [datetime]$selectedAsset.created_at
    if ($LatestOnline.Kind -ne "UTC") {
        $LatestOnline = $LatestOnline.ToUniversalTime()
    }
    Write-Log "Online version Created Date: $($LatestOnline.ToString('yyyy-MM-ddTHH:mm:ssZ'))"

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

    # Stage into a temp directory first so a corrupt download never touches the target.
    # Zip assets are extracted; projects that publish an unpacked binary (a bare .exe)
    # are staged as a single file under the name GitHub released it as.
    $tempExtract = Join-Path ([System.IO.Path]::GetTempPath()) "$Name-extract-$(Get-Random)"
    New-Item -ItemType Directory -Path $tempExtract -Force | Out-Null

    $assetExtension = [System.IO.Path]::GetExtension($selectedAsset.name)

    if ($assetExtension -eq '.zip') {
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
    } else {
        # Refuse archive formats we cannot open rather than deploying them verbatim,
        # which would leave an unusable .tar.gz sitting where the binary should be.
        $unsupportedArchives = @('.7z', '.gz', '.tgz', '.bz2', '.xz', '.rar', '.tar')
        if ($unsupportedArchives -contains $assetExtension) {
            throw "Asset '$($selectedAsset.name)' is an archive format this script cannot extract. Only .zip archives and unpacked files are supported."
        }

        Write-Log "Asset is not an archive, staging as a single file: $($selectedAsset.name)"
        Copy-Item -Path $pathZip -Destination (Join-Path $tempExtract $selectedAsset.name) -Force
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
                    -Title "$Name rolled back" `
                    -Message (
                        "<b>$Name</b> ($repo) failed to start after update." +
                        "<br><b>Attempted:</b> $(if ($releaseTag) { $releaseTag } else { 'new release' })" +
                        "<br><b>Restored:</b> $(if ($localTag) { $localTag } else { 'previous version' })" +
                        "<br><b>Service:</b> $RestartService" +
                        "<br><b>Asset:</b> $($selectedAsset.name)" +
                        "<br><b>Backup:</b> $backupZip"
                    ) `
                    -Url $releaseUrl -UrlTitle 'Release Notes'
            }
            throw
        }
    }

    # Write version file only after successful deployment. Tag is stored so the
    # next run can report the upgrade as "old tag -> new tag" rather than dates.
    $LatestOnlineIso = $LatestOnline.ToString("yyyy-MM-ddTHH:mm:ssZ")
    [PSCustomObject]@{
        CreatedAt = $LatestOnlineIso
        Tag       = $releaseTag
        Asset     = $selectedAsset.name
        Installed = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    } | ConvertTo-Json | Set-Content -Path $versionFile -Force
    Write-Log "Version information saved to: $versionFile"

    Write-Log "Update completed successfully. New release date: $($LatestOnline.ToString('yyyy-MM-ddTHH:mm:ssZ'))"

    # Notification detail: lead with the tag, which is what a reader recognises,
    # and fall back to release dates for repos that publish untagged releases.
    $notifyTitle = if ($releaseTag) { "$Name updated to $releaseTag" } else { "$Name updated" }
    $versionLine = if ($releaseTag -and $localTag) {
        "<br><b>Version:</b> $localTag -&gt; $releaseTag"
    } elseif ($releaseTag) {
        "<br><b>Version:</b> $releaseTag"
    } else {
        ""
    }
    $channelLine = if ($isPreRelease) { "<br><b>Channel:</b> Pre-release" } else { "<br><b>Channel:</b> Stable" }
    $serviceLine = if ($RestartService) { "<br><b>Service:</b> $RestartService restarted" } else { "" }
    $assetSizeMB = [math]::Round($selectedAsset.size / 1MB, 1)

    Send-PushoverNotification -Type 'Success' `
        -Title $notifyTitle `
        -Message (
            "<b>$Name</b> ($repo)" +
            $versionLine +
            $channelLine +
            "<br><b>Released:</b> $($LatestOnline.ToString('yyyy-MM-dd HH:mm')) UTC" +
            "<br><b>Asset:</b> $($selectedAsset.name) (${assetSizeMB}MB)" +
            "<br><b>Path:</b> $pathExtract" +
            $serviceLine
        ) `
        -Url $releaseUrl -UrlTitle 'Release Notes'
} catch {
    $errorMessage = $_.Exception.Message
    Write-Log $errorMessage -Level Error
    Write-Log "Stack trace: $($_.ScriptStackTrace)" -Level Error
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
        $failTargetLine = if ($releaseTag) { "<br><b>Target:</b> $releaseTag" } else { "" }
        $failLogLine = if ($Script:LogFile) { "<br><b>Log:</b> $($Script:LogFile)" } else { "" }

        Send-PushoverNotification -Type 'Failed' `
            -Title "$Name update failed" `
            -Message (
                "<b>$Name</b> ($repo) update failed." +
                $failTargetLine +
                "<br><b>Error:</b> $errorMessage" +
                $failLogLine
            ) `
            -Url $releaseUrl -UrlTitle 'Release Notes'
    }

    # Clean up temp files
    if ($pathZip -and (Test-Path $pathZip)) {
        Remove-Item $pathZip -Force -ErrorAction SilentlyContinue
    }
    if ($tempExtract -and (Test-Path $tempExtract)) {
        Remove-Item $tempExtract -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Log "=== Script finished (exit code: $exitCode) ==="
}

exit $exitCode

#endregion
