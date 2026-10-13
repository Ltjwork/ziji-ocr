@echo off
rem ══════════════════════════════════════════════════════════════════
rem 字迹 Windows 安装包一键构建脚本
rem 用法：在任意目录双击或命令行执行本文件即可。
rem 流程：读取版本号 → flutter build windows --release → 调 Inno Setup 打包
rem 产出：installer\output\ziji_setup_<版本号>.exe
rem 依赖：flutter 在 PATH 中；已安装 Inno Setup 6（ISCC.exe）。
rem ══════════════════════════════════════════════════════════════════
setlocal enabledelayedexpansion
cd /d "%~dp0.."

rem ── 读取版本号（flutter_app\pubspec.yaml 的 version: x.y.z+n）──
set "APPVER="
set "FULLVER="
for /f "tokens=2" %%v in ('findstr /b /c:"version:" flutter_app\pubspec.yaml') do set "FULLVER=%%v"
for /f "tokens=1 delims=+" %%v in ("!FULLVER!") do set "APPVER=%%v"
if "!APPVER!"=="" (
  echo [错误] 未能从 flutter_app\pubspec.yaml 读取版本号
  exit /b 1
)
echo [1/3] 版本号: !APPVER!

rem ── 编译 Flutter Release ──
echo [2/3] 执行 flutter build windows --release ...
pushd flutter_app
call flutter build windows --release
if errorlevel 1 (
  popd
  echo [错误] Flutter 编译失败
  exit /b 1
)
popd

rem ── 发版模型包检查（不自动打包：打包是模型管理页「打包发版」的
rem    手动动作，只打包当前启用中的模型）──
if not exist python_service\models_release.zjpack (
  echo [警告] python_service\models_release.zjpack 不存在，本次安装包不含模型：
  echo         用户机首次识别时 Kraken 模型会在线下载，YOLO 层无自训模型可用。
  echo         出正式发行包前请先在应用内「打包发版」。
) else (
  echo [提示] 发版模型包已就位: python_service\models_release.zjpack
)

rem ── 定位 Inno Setup 编译器（ISCC.exe）──
set "ISCC=%ProgramFiles(x86)%\Inno Setup 6\ISCC.exe"
if not exist "!ISCC!" set "ISCC=%ProgramFiles%\Inno Setup 6\ISCC.exe"
if not exist "!ISCC!" set "ISCC=%LOCALAPPDATA%\Programs\Inno Setup 6\ISCC.exe"
if not exist "!ISCC!" set "ISCC="
where ISCC >nul 2>nul && set "ISCC=ISCC"
if not defined ISCC (
  echo [错误] 未找到 Inno Setup 6（ISCC.exe）。
  echo        请从 https://jrsoftware.org/isdl.php 安装后重试。
  exit /b 1
)

rem ── 编译安装包 ──
echo [3/3] 编译安装包: "!ISCC!"
"!ISCC!" /DMyAppVersion=!APPVER! "%~dp0ocr_setup.iss"
if errorlevel 1 (
  echo [错误] Inno Setup 编译失败，请查看上方输出
  exit /b 1
)

echo.
echo 完成！安装包: %~dp0output\ziji_setup_!APPVER!.exe
endlocal
