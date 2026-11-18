@echo off
rem Developer / console launcher for BYOB Portable (edge-ops pattern).
rem Visible console + pause so startup errors stay on screen.
rem Users normally launch via BYOB.lnk (headless PowerShell 5.1 host).
%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0src\Start-BYOB.ps1" %*
pause
