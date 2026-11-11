@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # Interactive console tool: coloured output via Write-Host is intended.
        'PSAvoidUsingWriteHost',
        # Internal helper functions; -WhatIf/-Confirm would add no value here.
        'PSUseShouldProcessForStateChangingFunctions',
        # Settings are plain script variables that are read by the functions (and by the config file).
        'PSUseDeclaredVarsMoreThanAssignments'
    )
}
