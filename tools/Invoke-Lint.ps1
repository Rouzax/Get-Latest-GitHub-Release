<#
.SYNOPSIS
  Run PSScriptAnalyzer over the repository's PowerShell files.
.DESCRIPTION
  Called by the pre-commit hook, and safe to run by hand at any time.

  Fails on Error severity only. Warnings are printed but do not block, which keeps the
  gate green while the warning baseline documented in PSScriptAnalyzerSettings.psd1 is
  worked down. Pass -FailOn Warning to tighten it, and once the repository is clean at
  that level, make it the default here and record the new baseline in the settings file.
.PARAMETER Path
  Files to analyse. The pre-commit hook passes the staged .ps1 files. When omitted,
  every .ps1 in the repository is analysed, excluding tools\ itself.
.PARAMETER FailOn
  Lowest severity that fails the run. Error (default) or Warning.
.EXAMPLE
  .\tools\Invoke-Lint.ps1
  Analyse the whole repository, failing only on errors.
.EXAMPLE
  .\tools\Invoke-Lint.ps1 -FailOn Warning
  Check whether the repository is ready for the gate to be tightened.
.NOTES
  PSScriptAnalyzer is pinned so the hook, a manual run, and any future CI all report
  the same findings. Bump RequiredVersion deliberately, and re-record the baseline in
  PSScriptAnalyzerSettings.psd1 in the same change if the numbers move.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
    Justification = 'This is a console reporter run by a git hook. Its findings must reach the terminal in colour and must not be capturable as pipeline output, which is precisely what Write-Host is for.')]
[CmdletBinding()]
param(
    # Position 0 so the pre-commit hook's trailing filenames land here. -FailOn is
    # named-only: a ValueFromRemainingArguments parameter drops out of positional
    # binding altogether, which sent the first filename to -FailOn and failed its
    # ValidateSet. The hook passes -Path explicitly for the same reason.
    [Parameter(Position = 0)]
    [string[]] $Path,

    [Parameter()]
    [ValidateSet('Error', 'Warning')]
    [string] $FailOn = 'Error'
)

$ErrorActionPreference = 'Stop'

$RequiredVersion = '1.25.0'
$repoRoot = Split-Path -Parent $PSScriptRoot
$settings = Join-Path $repoRoot 'PSScriptAnalyzerSettings.psd1'

try {
    Import-Module PSScriptAnalyzer -RequiredVersion $RequiredVersion -ErrorAction Stop
} catch {
    Write-Host "PSScriptAnalyzer $RequiredVersion is not available." -ForegroundColor Red
    Write-Host "  Install-PSResource -Name PSScriptAnalyzer -Version $RequiredVersion -Scope CurrentUser -TrustRepository" -ForegroundColor Yellow
    Write-Host "If you deliberately moved to a newer version, bump RequiredVersion in this script." -ForegroundColor Yellow
    exit 2
}

# No -Path given means a manual whole-repository run. tools\ is included, so that a
# manual run and the hook cover exactly the same files.
if (-not $Path) {
    $Path = @(Get-ChildItem -Path $repoRoot -Filter '*.ps1' -Recurse -File |
            Select-Object -ExpandProperty FullName)
}

# pre-commit hands over staged paths; a deleted or renamed file can no longer be read.
$Path = @($Path | Where-Object { Test-Path -LiteralPath $_ })
if (-not $Path) {
    Write-Host 'No PowerShell files to analyse.' -ForegroundColor DarkGray
    exit 0
}

# Parse every file ourselves before linting. The analyzer does report unparseable
# files, but only as ParseError severity, which a Severity filter in the settings can
# silently drop. A broken script must never pass the gate on a configuration detail,
# so syntax is checked here where nothing can filter it away.
$parseFailures = 0
foreach ($file in $Path) {
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$parseErrors) | Out-Null
    foreach ($pe in $parseErrors) {
        $parseFailures++
        Write-Host ("[ParseError] {0}:{1} {2}" -f (Split-Path -Leaf $file), $pe.Extent.StartLineNumber, $pe.Message) -ForegroundColor Red
    }
}

# -Path binds a single string, so feed it one file at a time rather than the array.
$findings = @(foreach ($file in $Path) { Invoke-ScriptAnalyzer -Path $file -Settings $settings })

foreach ($f in $findings | Where-Object Severity -ne 'ParseError' | Sort-Object Severity -Descending) {
    $colour = if ($f.Severity -eq 'Error') { 'Red' } else { 'Yellow' }
    Write-Host ("[{0}] {1}:{2} {3}" -f $f.Severity, (Split-Path -Leaf $f.ScriptName), $f.Line, $f.RuleName) -ForegroundColor $colour
    Write-Host ("         {0}" -f $f.Message) -ForegroundColor DarkGray
}

# ParseError findings from the analyzer duplicate what the parser pass above already
# reported, so count them there only.
$errors = @($findings | Where-Object Severity -eq 'Error').Count
$warnings = @($findings | Where-Object Severity -eq 'Warning').Count
Write-Host ("PSScriptAnalyzer {0}: {1} parse error(s), {2} error(s), {3} warning(s) across {4} file(s). Gate: fail on {5}." -f
    $RequiredVersion, $parseFailures, $errors, $warnings, $Path.Count, $FailOn)

# A parse error always blocks, whatever -FailOn says: an unparseable script cannot run.
$blocking = $parseFailures + $errors
if ($FailOn -eq 'Warning') { $blocking += $warnings }
if ($blocking -gt 0) {
    Write-Host "Blocked: $blocking finding(s)." -ForegroundColor Red
    exit 1
}

exit 0
