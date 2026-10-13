@echo off
setlocal enabledelayedexpansion

rem Env name keeps the legacy "paddle" (the app starts this service via
rem "conda run -n paddle"; existing users already have that env). This is
rem the SERVICE env only -- no paddle packages here. Recognition engines
rem live in their own isolated envs: Kraken in "kraken" (install_kraken.bat)
rem and PaddleOCR in "paddleocr" (install_paddleocr.bat).
rem NOTE: keep this file pure-ASCII. Batch files with UTF-8 Chinese text get
rem mis-decoded as GBK by cmd on Chinese Windows, shredding rem/set lines.
set ENV_NAME=paddle
set PYPI_INDEX=https://pypi.tuna.tsinghua.edu.cn/simple
set PIP_OPTIONS=--timeout 120 --retries 5
if "%USE_CHINA_MIRROR%"=="" set "USE_CHINA_MIRROR=1"
if "%USE_CHINA_MIRROR%"=="1" set "PIP_OPTIONS=%PIP_OPTIONS% -i %PYPI_INDEX%"

cd /d %~dp0

echo [install] Runtime target: conda environment "%ENV_NAME%".
echo [install] Use China mirror: %USE_CHINA_MIRROR%
if "%USE_CHINA_MIRROR%"=="1" echo [install] General PyPI index: %PYPI_INDEX%
if not "%USE_CHINA_MIRROR%"=="1" echo [install] General PyPI index: official pip default

set "CONDA_CMD=conda"
if not "%CONDA_EXE_PATH%"=="" set "CONDA_CMD=%CONDA_EXE_PATH%"

echo [install] Checking conda...
if not "%CONDA_EXE_PATH%"=="" (
  if not exist "%CONDA_EXE_PATH%" (
    echo [install:error] CONDA_EXE_PATH does not exist: %CONDA_EXE_PATH%
    pause
    exit /b 1
  )
  echo [install] Using conda executable: %CONDA_EXE_PATH%
) else (
  where conda >nul 2>nul
  if errorlevel 1 (
    echo [install:error] conda was not found in PATH.
    echo Please install Miniconda from the startup page first, then reopen the app.
    pause
    exit /b 1
  )
)

rem CUDA detection only matters when INSTALL_PYTORCH=1 (model training).
rem Inside the block, vars set in the same block MUST use !VAR! (delayed
rem expansion): %VAR% expands when the whole block is parsed (still empty),
rem which made the old "Could not detect CUDA Version" fire unconditionally.
rem The regex matches both old and new nvidia-smi header formats:
rem   old: "CUDA Version: 12.6"   new: "CUDA UMD Version: 13.4"
if "%INSTALL_PYTORCH%"=="1" (
  echo [install] Checking NVIDIA CUDA runtime through nvidia-smi...
  where nvidia-smi >nul 2>nul
  if errorlevel 1 (
    echo [install:error] nvidia-smi was not found. GPU PyTorch requires NVIDIA driver.
    pause
    exit /b 1
  )

  set CUDA_VERSION=
  for /f "usebackq delims=" %%v in (`powershell -NoProfile -ExecutionPolicy Bypass -Command "$text = nvidia-smi | Out-String; if ($text -match 'CUDA(?:\s+UMD)?\s+Version:\s*([0-9]+\.[0-9]+)') { $matches[1] }"`) do set CUDA_VERSION=%%v
  if "!CUDA_VERSION!"=="" (
    echo [install:error] Could not detect CUDA Version from nvidia-smi.
    echo [install:error] Please run nvidia-smi manually and check its CUDA version field.
    pause
    exit /b 1
  )

  echo [install] Detected CUDA Version: !CUDA_VERSION!
  set PYTORCH_DEVICE=
  set PYTORCH_INDEX=
  if not "%PADDLE_DEVICE_CHOICE%"=="" set PYTORCH_DEVICE=%PADDLE_DEVICE_CHOICE%
  set CUDA_MAJOR=
  set CUDA_MINOR=
  for /f "tokens=1,2 delims=." %%a in ("!CUDA_VERSION!") do (
    set CUDA_MAJOR=%%a
    set CUDA_MINOR=%%b
  )
  if "!CUDA_MAJOR!"=="" goto unsupported_cuda
  if "!CUDA_MINOR!"=="" goto unsupported_cuda
  if "!CUDA_MAJOR!"=="13" if "!PYTORCH_DEVICE!"=="" set PYTORCH_DEVICE=cu130
  if "!CUDA_MAJOR!"=="12" if "!PYTORCH_DEVICE!"=="" if !CUDA_MINOR! GEQ 9 set PYTORCH_DEVICE=cu129
  if "!CUDA_MAJOR!"=="12" if "!PYTORCH_DEVICE!"=="" if !CUDA_MINOR! GEQ 6 set PYTORCH_DEVICE=cu126
  if "!CUDA_MAJOR!"=="11" if "!PYTORCH_DEVICE!"=="" if !CUDA_MINOR! GEQ 8 set PYTORCH_DEVICE=cu118

  if "!PYTORCH_DEVICE!"=="cu130" set PYTORCH_INDEX=https://download.pytorch.org/whl/cu130
  if "!PYTORCH_DEVICE!"=="cu129" set PYTORCH_INDEX=https://download.pytorch.org/whl/cu129
  if "!PYTORCH_DEVICE!"=="cu126" set PYTORCH_INDEX=https://download.pytorch.org/whl/cu126
  if "!PYTORCH_DEVICE!"=="cu118" set PYTORCH_INDEX=https://download.pytorch.org/whl/cu118
  if "!PYTORCH_DEVICE!"=="" goto unsupported_cuda

  echo [install] Selected PyTorch CUDA runtime: !PYTORCH_DEVICE!
  echo [install] Selected PyTorch index: !PYTORCH_INDEX!
)

echo [install] Checking conda environment: %ENV_NAME%
call "%CONDA_CMD%" env list | findstr /R /C:"^%ENV_NAME% " >nul 2>nul
if errorlevel 1 (
  echo [install] Creating conda environment: %ENV_NAME%
  call "%CONDA_CMD%" create -y -n %ENV_NAME% python=3.10
  if errorlevel 1 goto failed
) else (
  echo [install] Conda environment already exists: %ENV_NAME%
)

echo [install] Checking Python inside conda environment...
call "%CONDA_CMD%" run -n %ENV_NAME% python -c "import sys, platform; print('[install] Python:', sys.version); print('[install] Arch:', platform.architecture()[0], platform.machine()); raise SystemExit(0 if sys.version_info[:2] == (3, 10) else 1)"
if errorlevel 1 (
  echo [install:error] Conda environment "%ENV_NAME%" is not Python 3.10.
  echo [install:error] Please remove it manually: conda env remove -n %ENV_NAME%
  pause
  exit /b 1
)

echo [install] Upgrading pip in conda environment...
call "%CONDA_CMD%" run -n %ENV_NAME% python -m pip install --upgrade pip %PIP_OPTIONS%
if errorlevel 1 goto failed

if "%INSTALL_PYTORCH%"=="1" (
  echo [install] Installing PyTorch GPU packages from: %PYTORCH_INDEX%
  call "%CONDA_CMD%" run -n %ENV_NAME% python -m pip install torch torchvision torchaudio --index-url %PYTORCH_INDEX% --timeout 120 --retries 5
  if errorlevel 1 goto failed
)

echo [install] Installing OCR service dependencies in conda environment...
call "%CONDA_CMD%" run -n %ENV_NAME% python -m pip install -r requirements.txt %PIP_OPTIONS%
if errorlevel 1 goto failed

echo [install] Verifying service imports...
call "%CONDA_CMD%" run -n %ENV_NAME% python -c "import cv2, fastapi, ultralytics; print('[install] service deps ok')"
if errorlevel 1 (
  echo [install:error] Service dependency verification failed.
  pause
  exit /b 1
)

echo.
echo [install] Done.
echo [install] Run backend with: conda run -n %ENV_NAME% python main.py
echo [install] Flutter will also use conda environment "%ENV_NAME%" automatically.
echo [install] Kraken engine env: run install_kraken.bat to create the separate "kraken" env.
pause
exit /b 0

:unsupported_cuda
echo [install:error] Unsupported CUDA Version: %CUDA_VERSION%
echo [install:error] Supported GPU wheels: cu118, cu126, cu129, cu130.
pause
exit /b 1

:failed
echo.
echo [install:error] Installation failed.
pause
exit /b 1
