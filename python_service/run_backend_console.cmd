@echo off
rem NOTE: keep this file pure ASCII. Non-ASCII comments get mis-decoded by
rem cmd (GBK vs UTF-8) and fragments of them execute as commands.
chcp 65001 >nul
title OCR Backend Console
cd /d "%~dp0"
set PYTHONUTF8=1
set PYTHONIOENCODING=utf-8
rem ComfyUI-style backend console, launched by the app via:
rem   cmd /c start /D <python_service_dir> run_backend_console.cmd
rem The launch command must live in this batch file: compound commands
rem passed directly as start arguments break (Dart auto-quotes arguments
rem containing spaces; cmd quote-stripping fails on metacharacters).
conda run -n paddle python main.py
echo.
echo ===== backend exited (window kept for inspection, press any key to close) =====
pause >nul
