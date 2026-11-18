# Pester 5 smoke tests for Yap Edge-Ops Edition (Windows PowerShell 5.1).
BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
}

Describe 'Yap Edge-Ops structure and PS 5.1 compatibility' {
    It 'has required edge-ops root files and zero Python dependencies' {
        foreach ($f in @('VERSION', 'LICENSE', 'THIRD-PARTY-NOTICES.md', 'README.md', 'CHANGELOG.md', 'Yap-Dev.bat', 'src\Start-Yap.ps1', 'src\LoopbackPort.ps1', 'src\YapNative.cs', 'src\YapCleanup.ps1', 'src\ui\index.html', 'src\ui\voice-worker.js', 'src\ui\voice-worklet.js', 'config\settings.json', 'config\voice-assets.json')) {
            Test-Path (Join-Path $script:Root $f) | Should -BeTrue
        }
        Test-Path (Join-Path $script:Root 'runtime') | Should -BeFalse
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

    It 'compiles YapNative.cs cleanly against .NET Framework' {
        $cs = Join-Path $script:Root 'src\YapNative.cs'
        { Add-Type -Path $cs -ReferencedAssemblies System.Windows.Forms, System.Drawing } | Should -Not -Throw
    }

    It 'cleans fillers, stutters, and applies spoken formatting' {
        . (Join-Path $script:Root 'src\YapCleanup.ps1')
        Invoke-YapBasicCleanup -Text 'um hello, hello world. new paragraph this is a test' | Should -Be "Hello world.`n`nThis is a test"
        Test-YapOutputGuard -Raw 'What is two plus two?' -Out '4.' | Should -Not -BeNullOrEmpty
        Test-YapOutputGuard -Raw 'um hello world' -Out 'Hello world.' | Should -BeNullOrEmpty
    }

    It 'passes -CheckOnly when Whisper WASM assets are staged' {
        $entry = Join-Path $script:Root 'src\Start-Yap.ps1'
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $entry -CheckOnly
        $LASTEXITCODE | Should -Be 0
    }
}
