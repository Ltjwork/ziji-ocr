@echo off
setlocal enabledelayedexpansion

rem -- Kraken recognition engine env install (fully isolated from the
rem    service env). Usage:
rem      install_kraken.bat                       GPU torch (default, cu126)
rem      set KRKEN_TORCH=cpu && install_kraken.bat   CPU torch (smaller download)
rem NOTE: keep this file pure-ASCII. Batch files with UTF-8 Chinese text get
rem mis-decoded as GBK by cmd on Chinese Windows, shredding rem/set lines.

set ENV_NAME=kraken
set PYPI_INDEX=https://pypi.tuna.tsinghua.edu.cn/simple
set PIP_OPTIONS=--timeout 120 --retries 5
if "%USE_CHINA_MIRROR%"=="" set "USE_CHINA_MIRROR=1"
if "%USE_CHINA_MIRROR%"=="1" set "PIP_OPTIONS=%PIP_OPTIONS% -i %PYPI_INDEX%"

cd /d %~dp0

set "CONDA_CMD=conda"
if not "%CONDA_EXE_PATH%"=="" set "CONDA_CMD=%CONDA_EXE_PATH%"

echo [kraken-install] Checking conda...
where conda >nul 2>nul
if errorlevel 1 (
  if "%CONDA_EXE_PATH%"=="" (
    echo [kraken-install:error] conda not found in PATH.
    pause
    exit /b 1
  )
)

echo [kraken-install] Checking conda environment: %ENV_NAME%
call "%CONDA_CMD%" env list | findstr /R /C:"^%ENV_NAME% " >nul 2>nul
if errorlevel 1 (
  echo [kraken-install] Creating conda environment: %ENV_NAME%
  call "%CONDA_CMD%" create -y -n %ENV_NAME% python=3.10
  if errorlevel 1 goto failed
) else (
  echo [kraken-install] Conda environment "%ENV_NAME%" already exists.
)

echo [kraken-install] Installing PyTorch...
if /i "%KRKEN_TORCH%"=="cpu" (
  echo [kraken-install] torch variant: CPU
  call "%CONDA_CMD%" run -n %ENV_NAME% python -m pip install torch torchvision %PIP_OPTIONS%
  if errorlevel 1 goto failed
) else (
  echo [kraken-install] torch variant: GPU cu126
  call "%CONDA_CMD%" run -n %ENV_NAME% python -m pip install torch torchvision --index-url https://download.pytorch.org/whl/cu126 --timeout 120 --retries 5
  if errorlevel 1 goto failed
)

echo [kraken-install] Installing kraken...
call "%CONDA_CMD%" run -n %ENV_NAME% python -m pip install kraken %PIP_OPTIONS%
if errorlevel 1 goto failed

echo [kraken-install] Verifying kraken...
call "%CONDA_CMD%" run -n %ENV_NAME% python -c "import kraken.rpred, kraken.blla; import torch; from importlib.metadata import version; print('[kraken-install] kraken', version('kraken'), '| torch', torch.__version__, '| cuda', torch.cuda.is_available())"
if errorlevel 1 goto failed

echo.
echo [kraken-install] Done.
echo [kraken-install] Kraken models are downloaded automatically on first recognition.
pause
exit /b 0

:failed
echo.
echo [kraken-install:error] Installation failed. See messages above.
pause
exit /b 1
