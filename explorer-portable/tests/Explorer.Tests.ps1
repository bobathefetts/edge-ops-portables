# Pester 5 smoke tests for BYOB Explorer (Windows PowerShell 5.1).
# Run: Invoke-Pester -Path .\tests -Output Detailed
# The plain-assertion suites (no Pester needed) are tests\Run-CoreTests.ps1 and tests\Run-HostSmoke.ps1.
BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
}

Describe 'BYOB Explorer structure and PS 5.1 compatibility' {
    It 'has the required files and zero native EXEs/DLLs' {
        foreach ($f in @('VERSION', 'LICENSE', 'THIRD-PARTY-NOTICES.md', 'README.md', 'CHANGELOG.md', 'Explorer-Dev.bat',
                'src\Start-Explorer.ps1', 'src\LoopbackPort.ps1', 'src\NetGate.ps1', 'src\CredStore.ps1', 'src\ExplorerTools.ps1',
                'src\ExplorerAgent.ps1', 'src\PluginHost.ps1', 'src\ByobLlm.ps1', 'src\ByobTools.ps1', 'src\ui\index.html',
                'config\settings.json', 'plugins\README.md', 'plugins\sample-portscan\byob-plugin.json')) {
            Test-Path (Join-Path $script:Root $f) | Should -BeTrue
        }
        $bins = @(Get-ChildItem -Path $script:Root -Include '*.exe', '*.dll', '*.pyd' -Recurse -ErrorAction SilentlyContinue)
        $bins.Count | Should -Be 0
    }

    It 'all PowerShell scripts parse cleanly on Windows PowerShell 5.1' {
        $files = Get-ChildItem -Path $script:Root -Include '*.ps1', '*.psm1', '*.psd1' -Recurse |
            Where-Object { $_.FullName -notmatch '\\temp\\|\\data\\' }
        foreach ($file in $files) {
            $tokens = $null
            $errors = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
            $errors.Count | Should -Be 0 -Because "$($file.FullName) should have zero PS 5.1 syntax errors"
        }
    }

    It 'passes -CheckOnly' {
        $entry = Join-Path $script:Root 'src\Start-Explorer.ps1'
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $entry -CheckOnly
        $LASTEXITCODE | Should -Be 0
    }

    It 'passes the core assertion suite' {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:Root 'tests\Run-CoreTests.ps1')
        $LASTEXITCODE | Should -Be 0
    }
}
