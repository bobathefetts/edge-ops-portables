# Third-Party Notices

## 1. Yap (design, cleanup rules & icon)
- **Version:** adapted from 0.2.1
- **Upstream URL:** https://github.com/bobathefetts/yap
- **License:** MIT
- **Location:** `src\YapCleanup.ps1`, `assets\yap.ico`
- **Changes:** Reimplemented in Windows PowerShell 5.1, C# 5 (`src\YapNative.cs`), and browser Whisper WASM with zero Python or external executables.

## 2. Whisper ONNX WASM Speech-Input Assets
- **Upstream URLs:**
  - `@huggingface/transformers` 3.8.1 (Apache-2.0): `transformers.min.js`, `ort-wasm-simd-threaded.jsep.mjs`, `ort-wasm-simd-threaded.jsep.wasm`
  - `Xenova/whisper-tiny.en` (MIT): quantized ONNX model & tokenizer files
  - SHA-256 manifest & `voice-worklet.js` / `voice-worker.js` pattern from `fleethacker-data-crucible/PacketRat` (MIT)
- **Location:** `src\ui\vendor\voice\`, `src\ui\voice-worklet.js`, `src\ui\voice-worker.js`, `config\voice-assets.json`

## 3. FleetHacker Edge-Ops Templates
- **Upstream URL:** https://github.com/fleethacker-data-crucible/edge-ops
- **License:** MIT
- **Location:** `src\LoopbackPort.ps1`, `scripts\New-ToolShortcut.ps1`, `tests\LoopbackPort.Tests.ps1`, `PSScriptAnalyzerSettings.psd1`
