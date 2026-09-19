@echo off
chcp 65001 >nul
title iFudan.stu Auto Login Uninstaller
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Uninstall.ps1"
echo.
pause
