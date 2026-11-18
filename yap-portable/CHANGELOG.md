# Changelog

## 0.3.0 (2026-11-18)
- **Full Python-free, zero-EXE Edge-Ops rewrite:** removed Python runtime, `faster-whisper`, and `llama-server.exe` so Yap runs strictly on Windows PowerShell 5.1 + .NET Framework 4.x (`src\YapNative.cs`) + Edge/Chrome Whisper WASM (`src\ui\vendor\voice\`, pinned by SHA-256 in `config\voice-assets.json`).
- Implemented Win32 `WH_KEYBOARD_LL` push-to-talk hook (`Ctrl+Win`), WinMM `winmm.dll` 16 kHz mic capture, topmost WinForms pill overlay, and `SendInput` clipboard paste in C# 5 (`src\YapNative.cs`), with graceful pure-Edge `AudioWorklet` + `System.Speech` fallback if `Add-Type` is blocked.
- Ported rule-based cleanup, spoken formatting, and word-lock guard into `src\YapCleanup.ps1`, plus optional local OpenAI/Ollama endpoint support.

## 0.2.1-edgeops.1 (2026-11-18)
- Initial portable wrapper around Python Yap.
