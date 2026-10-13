@echo off
rem NOTE: keep this file pure ASCII (see run_backend_console.cmd).
chcp 65001 >nul
title OCR Logs (read-only)
cd /d "%~dp0logs"
powershell -NoExit -ExecutionPolicy Bypass -Command "Get-Content -Wait -Encoding UTF8 app_console.log,service_console.log"
