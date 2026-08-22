@{
    # PSScriptAnalyzer configuration for Get-Latest-GitHub-Release.
    # Run it with tools\Invoke-Lint.ps1, which the pre-commit hook also calls.
    #
    # THE GATE
    # --------
    # Error severity blocks a commit. Warnings are printed but do not block, so the
    # gate is green today and the warning count can come down over time instead of
    # in one sweep.
    #
    # Baseline at v3.4.1 (2026-08-22): 0 parse errors, 0 errors, 12 warnings, across
    # both .ps1 files in the repository. All 12 are in Get-Latest-GitHub-Release.ps1;
    # tools\Invoke-Lint.ps1 is clean, having suppressed PSAvoidUsingWriteHost at its
    # own param block with a justification. That is the pattern to copy.
    # Target: 0 warnings, then switch the hook's default to -FailOn Warning and
    # record the new baseline here. Do not lower either number to make a change pass.
    #
    # NO RULE IS EXCLUDED GLOBALLY
    # ----------------------------
    # Every warning below is a real observation about this script, including the ones
    # whose verdict is "intentional". Excluding the rule would hide future genuine
    # instances and erase the baseline. Suppress a specific finding at its own call
    # site with [Diagnostics.CodeAnalysis.SuppressMessageAttribute] and a justification.
    #
    # THE CURRENT 12, SO NOBODY RE-DIAGNOSES THEM
    # -------------------------------------------
    # PSReviewUnusedParameter x5 (PushoverUserKey, PushoverApiToken, PushoverDevice,
    #   MaxBackups, MaxLogs). All false positives, one cause. The rule evaluates each
    #   scope on its own, and these five script parameters are read inside
    #   Get-ScriptConfig, which picks them up from the parent scope rather than taking
    #   them as arguments. Verified against a minimal probe: a parameter used only
    #   inside a function is flagged, the same parameter used at top level is not.
    #   Passing them in explicitly would clear the warnings and remove an implicit
    #   parent-scope read, but that is a refactor, not a lint fix.
    #
    # PSAvoidUsingWriteHost x4 (Write-Log, and the banner at the end of the run).
    #   Deliberate. Write-Log writes to the console and the log file, and the console
    #   half wants colour by severity when a human runs the script by hand.
    #
    # PSAvoidOverwritingBuiltInCmdlets x1 (Write-Log). The rule's cmdlet inventory for
    #   core-6.1.0-windows lists a Write-Log; nothing in this script's supported hosts
    #   ships one. Renaming the function would touch every logging call, so it waits
    #   for a reason better than a lint warning.
    #
    # PSUseShouldProcessForStateChangingFunctions x2 (Start-GitService,
    #   New-InstallationBackup). Fair for a published module. This is an unattended
    #   script whose whole purpose is to change state, and -WhatIf on an internal
    #   helper would not be wired to anything.

    IncludeDefaultRules = $true

    # ParseError MUST stay in this list. PSScriptAnalyzer reports unparseable files as
    # ParseError severity, and Severity is a filter: listing only Error and Warning
    # makes a syntactically broken script return zero findings and sail through the
    # gate. Worse, it does so invisibly, because the analyzer auto-discovers this file
    # for any script beside it, so even a bare Invoke-ScriptAnalyzer in the repo root
    # is silently filtered. Found the hard way; tools\Invoke-Lint.ps1 now runs the
    # parser itself as well, so the gate no longer depends on getting this line right.
    #
    # What blocks a commit is the hook's -FailOn switch, not this list. Warnings are
    # reported here so the baseline above stays visible.
    Severity            = @('ParseError', 'Error', 'Warning')
}
