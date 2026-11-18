# Upstream Source Notes for BYOB Portable

The upstream Rust source (`Scronkfinkle/byob` v0.3.9) already honors `BYOB_HOME` in:
- `crates/store/src/paths.rs` (`Paths::resolve()` checks `BYOB_HOME` first and puts both `config_dir` and `data_dir` under that single directory).
- `apps/byob/src/main.rs` (`window_state_in()` stores `window.ron` inside `BYOB_HOME` when set).
- `apps/byob/src/apphost/mod.rs` / `helper.rs` (resolves `byob-artifact-host.exe` from `BYOB_ARTIFACT_HOST` or beside `byob.exe`).

Because `Start-BYOB.ps1` sets `BYOB_HOME=<root>\data`, `BYOB_ARTIFACT_HOST=<root>\bin\byob-artifact-host.exe`, and `TEMP`/`TMP=<root>\temp\sys`, the official signed/CI-built Windows binaries run 100% portably without recompiling Rust.

If you later compile `byob` from source on a machine with Rust (`cargo`), you can also add native `/__fleethacker/id` handling directly in `crates/server/src/lib.rs` (in `handle()` before static asset fallback) so `-Direct` mode also exposes FleetHacker self-detection without the PowerShell/C# loopback proxy.
