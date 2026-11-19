@echo off
rem Build a self-contained edge-ops zip package in dist\ (Explorer-v<VERSION>.zip + .sha256).
%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Package-Explorer.ps1" %*
pause
