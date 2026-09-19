@echo off
chcp 65001 >nul
title iFudan.stu Auto Login Installer
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install.ps1"
echo.
pause
