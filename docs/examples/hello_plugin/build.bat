@echo off
rem Build hello example plugin package (.zjplugin = zip, then rename).
setlocal
cd /d "%~dp0"
if exist hello-1.0.0.zjplugin del hello-1.0.0.zjplugin
if exist hello-1.0.0.zip del hello-1.0.0.zip
powershell -NoProfile -Command "Compress-Archive -Path manifest.json, main.js, page.html -DestinationPath 'hello-1.0.0.zip' -Force"
move /y hello-1.0.0.zip hello-1.0.0.zjplugin >nul
echo Built hello-1.0.0.zjplugin
endlocal
