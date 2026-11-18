# Pester 5 smoke tests for Yap Portable (Windows PowerShell 5.1).
BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
}

Describe 'Yap Portable structure and PS 5.1 compatibility' {
    It 'has required edge-ops root files' {
        foreach ($f in @('VERSION', 'LICENSE', 'THIRD-PARTY-NOTICES.md', 'README.md', 'CHANGELOG.md', 'Yap-Dev.bat', 'src\Start-Yap.ps1', 'src\LoopbackPort.ps1', 'src\ui\index.html', 'src\app\yap.pyw', 'config\settings.json')) {
            Test-Path (Join-Path $script:Root $f) | Should -BeTrue
        }
    }

    It 'all PowerShell scripts parse cleanly on Windows PowerShell 5.1' {
        $files = Get-ChildItem -Path $script:Root -Include '*.ps1', '*.psm1', '*.psd1' -Recurse |
            Where-Object { $_.FullName -notmatch '\\temp\\|\\data\\|\\runtime\\' }
        foreach ($file in $files) {
            $tokens = $null
            $errors = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
            $errors.Count | Should -Be 0 -Because "$($file.FullName) should have zero PS 5.1 syntax errors"
        }
    }

    It 'passes -CheckOnly when runtime\python\python.exe is present' {
        $py = Join-Path $script:Root 'runtime\python\python.exe'
        if (-not (Test-Path $py)) {
            Set-ItResult -Skipped -Because 'runtime\python\python.exe not populated yet (run scripts\Build-Portable.ps1)'
            return
        }
        $entry = Join-Path $script:Root 'src\Start-Yap.ps1'
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $entry -CheckOnly
        $LASTEXITCODE | Should -Be 0
    }
}
