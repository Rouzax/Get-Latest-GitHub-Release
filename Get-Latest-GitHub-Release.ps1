<#
.SYNOPSIS
  Fetch latest GitHub Release and copy to local folder.
.DESCRIPTION
  Script to fetch the latest release from specified GitHub Repo if it is newer than the local copy
  and extract the content to local folder while stopping and starting a service.
.PARAMETER Name
    Name of the GitHub project (will be used to create directory in $RootPath)
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
.INPUTS
  None
.OUTPUTS
  .\Versions\<name>.json Created_at from GitHub Release to compare if there is a newer version
.NOTES
  Version:        2.0
  Author:         Rouzax
  Creation Date:  2020-12-14
  Last Modified:  2026-05-27
  Purpose/Change: Major robustness improvements for unattended execution

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

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$serviceStopped = $false
$pathZip = $null
$tempExtract = $null
$exitCode = 0

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
            Write-Host $($localCreatedDate) -ForegroundColor DarkCyan
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
        $Result = @($apiResponse)[0].assets
    } else {
        $Result = $apiResponse.assets
    }

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
    Write-Host $($LatestOnline) -ForegroundColor DarkCyan

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

    # Stop service only after download and extraction succeed, minimizing downtime
    if ($RestartService) {
        Write-Log "Stopping $RestartService and dependents"
        Stop-Service -Name $RestartService -Force
        $serviceStopped = $true
    }

    # Deploy validated files to target
    Write-Log "Deploying to: $pathExtract"
    $sourceItems = Join-Path $tempExtract '*'
    Copy-Item -Path $sourceItems -Destination $pathExtract -Recurse -Force

    # Restart service immediately after files are in place
    if ($serviceStopped) {
        Start-GitService -StartService $RestartService
        $serviceStopped = $false
    }

    # Write version file only after successful deployment
    $LatestOnlineIso = $LatestOnline.ToString("yyyy-MM-ddTHH:mm:ssZ")
    $LatestOnlineIso | ConvertTo-Json | Set-Content -Path $versionFile -Force
    Write-Log "Version information saved to: $versionFile"

    Write-Log "Update completed successfully. New release date: $LatestOnline"
} catch {
    Write-Log $_.Exception.Message -Level Error
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

    # Clean up temp files
    if ($pathZip -and (Test-Path $pathZip)) {
        Remove-Item $pathZip -Force -ErrorAction SilentlyContinue
    }
    if ($tempExtract -and (Test-Path $tempExtract)) {
        Remove-Item $tempExtract -Recurse -Force -ErrorAction SilentlyContinue
    }
}

exit $exitCode
