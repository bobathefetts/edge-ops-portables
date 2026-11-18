# Pester 5 smoke tests for BYOB Portable (Windows PowerShell 5.1).
BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
}

Describe 'BYOB Portable structure and PS 5.1 compatibility' {
    It 'has required edge-ops root files' {
        foreach ($f in @('VERSION', 'LICENSE', 'THIRD-PARTY-NOTICES.md', 'README.md', 'CHANGELOG.md', 'BYOB-Dev.bat', 'src\Start-BYOB.ps1', 'src\LoopbackPort.ps1', 'src\ProxyServer.cs', 'config\settings.json', 'plugins\outlook-classic\byob-plugin.json', 'plugins\outlook-classic\backend.ps1', 'plugins\outlook-classic\outlook_com.ps1')) {
            Test-Path (Join-Path $script:Root $f) | Should -BeTrue
        }
    }

    It 'all PowerShell scripts parse cleanly on Windows PowerShell 5.1' {
        $files = Get-ChildItem -Path $script:Root -Include '*.ps1', '*.psm1', '*.psd1' -Recurse |
            Where-Object { $_.FullName -notmatch '\\temp\\|\\data\\|\\bin\\' }
        foreach ($file in $files) {
            $tokens = $null
            $errors = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
            $errors.Count | Should -Be 0 -Because "$($file.FullName) should have zero PS 5.1 syntax errors"
        }
    }

    It 'compiles ProxyServer.cs cleanly against .NET Framework' {
        $cs = Join-Path $script:Root 'src\ProxyServer.cs'
        { Add-Type -Path $cs } | Should -Not -Throw
    }

    It 'passes -CheckOnly when bin\byob.exe is present' {
        $bin = Join-Path $script:Root 'bin\byob.exe'
        if (-not (Test-Path $bin)) {
            Set-ItResult -Skipped -Because 'bin\byob.exe not populated yet (run scripts\Build-Portable.ps1)'
            return
        }
        $entry = Join-Path $script:Root 'src\Start-BYOB.ps1'
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $entry -CheckOnly
        $LASTEXITCODE | Should -Be 0
    }
}
