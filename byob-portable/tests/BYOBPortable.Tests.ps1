# Pester 5 smoke tests for BYOB Edge-Ops Edition (Windows PowerShell 5.1).
BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
}

Describe 'BYOB Edge-Ops structure and PS 5.1 compatibility' {
    It 'has required edge-ops root files and zero native EXEs/DLLs' {
        foreach ($f in @('VERSION', 'LICENSE', 'THIRD-PARTY-NOTICES.md', 'README.md', 'CHANGELOG.md', 'BYOB-Dev.bat', 'src\Start-BYOB.ps1', 'src\LoopbackPort.ps1', 'src\ByobLlm.ps1', 'src\ByobTools.ps1', 'src\ui\index.html', 'config\settings.json', 'plugins\outlook-classic\outlook_com.ps1')) {
            Test-Path (Join-Path $script:Root $f) | Should -BeTrue
        }
        $bins = @(Get-ChildItem -Path $script:Root -Include '*.exe','*.dll','*.pyd' -Recurse -ErrorAction SilentlyContinue)
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
        $entry = Join-Path $script:Root 'src\Start-BYOB.ps1'
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $entry -CheckOnly
        $LASTEXITCODE | Should -Be 0
    }
}
