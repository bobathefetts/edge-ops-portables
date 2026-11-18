# Changelog

## 0.2.1-edgeops.1 (2026-11-18)
- Initial portable Edge-Ops conversion of `bobathefetts/yap` v0.2.1.
- Replaced Inno Setup installer and `%USERPROFILE%\.yap` / Start Menu / HKCU registry writes with a self-contained folder (`data\`, `models\`, `engine\`, `cuda\`, `logs\`, `temp\`).
- Bundled relocatable standalone Python runtime under `runtime\python\`.
- Added Windows PowerShell 5.1 host (`src\Start-Yap.ps1`) with loopback control/status UI (`src\ui\index.html`) on port block `8835-8837`, `/__fleethacker/id`, `/__fleethacker/shutdown`, `-CheckOnly`, headless `Yap.lnk`, Pester tests, and zip + SHA-256 packager.
