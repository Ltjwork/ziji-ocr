@echo off
setlocal enabledelayedexpansion

rem -- PaddleOCR recognition engine env install (fully isolated from the
rem    service env, same pattern as install_kraken.bat). Usage:
rem      install_paddleocr.bat                          GPU paddle (default, cu126)
rem      set PADDLE_PADDLE=cpu && install_paddleocr.bat  CPU paddle (smaller download)
rem NOTE: the service env is named "paddle" for legacy reasons but contains
rem       NO paddle packages -- PaddleOCR lives here in env "paddleocr".
rem NOTE: keep this file pure-ASCII. Batch files with UTF-8 Chinese text get
rem       mis-decoded as GBK by cmd on Chinese Windows, shredding rem/set lines.

set ENV_NAME=paddleocr
set PYPI_INDEX=https://pypi.tuna.tsinghua.edu.cn/simple
set PIP_OPTIONS=--timeout 120 --retries 5
if "%USE_CHINA_MIRROR%"=="" set "USE_CHINA_MIRROR=1"
if "%USE_CHINA_MIRROR%"=="1" set "PIP_OPTIONS=%PIP_OPTIONS% -i %PYPI_INDEX%"

rem GPU wheels of paddlepaddle are NOT on PyPI mirrors; they come from the
rem official PaddlePaddle package index (cu126 build).
set PADDLE_GPU_INDEX=https://www.paddlepaddle.org.cn/packages/stable/cu126/

cd /d %~dp0

set "CONDA_CMD=conda"
if not "%CONDA_EXE_PATH%"=="" set "CONDA_CMD=%CONDA_EXE_PATH%"

echo [paddle-install] Checking conda...
where conda >nul 2>nul
if errorlevel 1 (
  if "%CONDA_EXE_PATH%"=="" (
    echo [paddle-install:error] conda not found in PATH.
    pause
    exit /b 1
  )
)

echo [paddle-install] Checking conda environment: %ENV_NAME%
call "%CONDA_CMD%" env list | findstr /R /C:"^%ENV_NAME% " >nul 2>nul
if errorlevel 1 (
  echo [paddle-install] Creating conda environment: %ENV_NAME%
  call "%CONDA_CMD%" create -y -n %ENV_NAME% python=3.10
  if errorlevel 1 goto failed
) else (
  echo [paddle-install] Conda environment "%ENV_NAME%" already exists.
)

echo [paddle-install] Installing paddlepaddle...
if /i "%PADDLE_PADDLE%"=="cpu" (
  echo [paddle-install] paddle variant: CPU
  call "%CONDA_CMD%" run -n %ENV_NAME% python -m pip install paddlepaddle %PIP_OPTIONS%
  if errorlevel 1 goto failed
) else (
  echo [paddle-install] paddle variant: GPU cu126
  call "%CONDA_CMD%" run -n %ENV_NAME% python -m pip install paddlepaddle-gpu -i %PADDLE_GPU_INDEX% --timeout 120 --retries 5
  if errorlevel 1 goto failed
)

echo [paddle-install] Installing paddleocr ^(^>=3.7, ships PP-OCRv6 models^)...
call "%CONDA_CMD%" run -n %ENV_NAME% python -m pip install "paddleocr>=3.7" %PIP_OPTIONS%
if errorlevel 1 goto failed

echo [paddle-install] Verifying paddleocr...
call "%CONDA_CMD%" run -n %ENV_NAME% python -c "from paddleocr import TextRecognition; import paddle; from importlib.metadata import version; print('[paddle-install] paddleocr', version('paddleocr'), '| paddle', paddle.__version__, '| cuda', paddle.device.is_compiled_with_cuda())"
if errorlevel 1 goto failed

echo.
echo [paddle-install] Done.
echo [paddle-install] PP-OCRv6 models download automatically on first use,
echo [paddle-install] or pre-download via the app's Paddle model picker
echo [paddle-install] ^(download/test button^).
pause
exit /b 0

:failed
echo.
echo [paddle-install:error] Installation failed. See messages above.
pause
exit /b 1
