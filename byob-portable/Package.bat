@echo off
rem Build a self-contained edge-ops zip package in dist\.
%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Package-BYOB.ps1" %*
pause
