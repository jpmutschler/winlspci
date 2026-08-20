@{
    # Lint settings for the module, CLI and tests. Run locally with
    #   Invoke-ScriptAnalyzer -Path . -Recurse -Settings .\PSScriptAnalyzerSettings.psd1
    # and in CI (.github\workflows\tests.yml).
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # The test runner and the CLI write to the console on purpose; they
        # are not pipelines. Write-Host is the right tool there.
        'PSAvoidUsingWriteHost'
        # $args is how bin\lspci.ps1 receives its command line by design (the
        # script parses lspci-style flags itself; see its header comment).
        'PSAvoidUsingDoubleQuoteForConstantString'
        # PS 5.1 target: ShouldProcess is on Update-PciIds where it matters;
        # the analyzer's heuristics flag formatters that only emit text.
        'PSUseShouldProcessForStateChangingFunctions'
        # Plural nouns: Get-PciDevice returns many devices, as Get-Process does.
        'PSUseSingularNouns'
        # False positives: Format-PciTree's $Numeric and the test runner's
        # $Quiet are read inside NESTED functions (Write-Node, It) through
        # PowerShell's dynamic scoping, which the analyzer does not follow.
        'PSReviewUnusedParameter'
    )
}
