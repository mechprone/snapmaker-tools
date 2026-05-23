@echo off
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Import-SnapmakerOrcaFilaments.ps1"
echo.
pause
