@echo off
rem Developer / console launcher for BYOB Explorer (edge-ops pattern).
rem Visible console + pause so startup errors stay on screen.
rem First run on Windows: also creates Explorer.lnk (the normal no-console launcher) next to this file.
if not exist "%~dp0Explorer.lnk" %SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\New-ToolShortcut.ps1" -Root "%~dp0." -Name Explorer -Script src\Start-Explorer.ps1 -Description "BYOB Explorer"
%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0src\Start-Explorer.ps1" %*
pause
