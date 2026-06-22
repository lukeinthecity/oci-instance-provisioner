@{
    # CI gates on Error + Warning. Information-level rules (e.g. trailing whitespace) are
    # surfaced by editors but don't block the build.
    Severity = @('Error', 'Warning')

    # Rules excluded with rationale. These are all cmdlet/module-authoring conventions that
    # don't apply to a standalone *script* tool invoked as `.\OciProvisioner.ps1`.
    ExcludeRules = @(
        # PSAvoidUsingWriteHost — intentional. This is an interactive console utility, and
        # Write-Log mirrors every message to a durable log file for headless/scheduled runs.
        # Switching to Write-Output/Write-Information would change stream semantics and break
        # both the console UX and the test harness's output capture.
        'PSAvoidUsingWriteHost',

        # PSUseApprovedVerbs — only 'Exit-Fatal' trips this. It's an internal fail-fast helper
        # (clean message + exit 1), not a public cmdlet anyone imports; the name is chosen for
        # readability over verb conformance.
        'PSUseApprovedVerbs',

        # PSUseShouldProcessForStateChangingFunctions — the New-* helpers in the test harness
        # are in-script fixtures, not cmdlets meant to support -WhatIf/-Confirm.
        'PSUseShouldProcessForStateChangingFunctions'
    )
}
