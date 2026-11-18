# Third-Party Notices

This portable Edge-Ops package ships or wraps the following open-source software:

## 1. Yap
- **Version:** 0.2.1
- **Upstream URL:** https://github.com/bobathefetts/yap
- **License:** MIT
- **Location:** `src\app\yap\` and `assets\yap.ico`
- **Changes:** Adapted `config.py`, `assets.py`, `startup.py`, `engine.py`, `tray.py`, and `app.py` for portable Edge-Ops operation (`YAP_PORTABLE=1`, storing settings/history/logs in `.\data\`, skipping Start Menu shortcuts and HKCU registry writes, and exposing live status + dashboard hooks).

## 2. Standalone Python Runtime & Pip Dependencies
- **Upstream URLs:** https://github.com/astral-sh/python-build-standalone , https://pypi.org/
- **Licenses:** PSF-2.0 (Python), MIT (faster-whisper, ctranslate2, sounddevice, pystray, pyperclip), BSD-3-Clause (numpy, Pillow), LGPL-3.0 (pynput)
- **Location:** `runtime\python\`
- **Changes:** Bundled unmodified into `runtime\python\` for zero-install execution.

## 3. llama.cpp & Qwen 3.5 (downloaded on first launch or pre-bundled)
- **Upstream URLs:** https://github.com/ggml-org/llama.cpp (MIT), https://huggingface.co/unsloth (Qwen 3.5, Apache-2.0)
- **Location:** `engine\` and `models\llm\`

## 4. FleetHacker Edge-Ops Templates
- **Upstream URL:** https://github.com/fleethacker-data-crucible/edge-ops
- **License:** MIT
- **Location:** `src\LoopbackPort.ps1`, `scripts\New-ToolShortcut.ps1`, `tests\LoopbackPort.Tests.ps1`, `PSScriptAnalyzerSettings.psd1`
- **Changes:** Adapted test path in `tests\LoopbackPort.Tests.ps1`.
