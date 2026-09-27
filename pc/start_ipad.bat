@echo off
setlocal enabledelayedexpansion
set OPENSSL_ia32cap=:~0x20000000

pushd %~dp0

rem iPad mode: MaiTouchBridge plays the touch panel on COM5 (COM3<->COM5 com0com pair) and serves the iPad page.
rem Do not run it together with MaiDXR (only one program can own COM5).
powershell -NoProfile -Command "(Get-Content mai2.ini) -replace '^DummyTouchPanel=.*','DummyTouchPanel=0' -replace '^DummyLED=.*','DummyLED=1' | Set-Content mai2.ini"

rem Native 1080x1920 window (sharpest picture for the iPad video). It is taller than most monitors, so while the iPad
rem is streaming, MaiTouchBridge slides the window up so the bottom (circle) square stays fully on screen, then puts it back.
set SW=1080
set SH=1920
echo Game window: !SW!x!SH!

start "MaiTouchBridge" /min "%~dp0MaiTouchBridge\MaiTouchBridge.exe"
timeout /t 2 /nobreak >nul
echo.
echo Open one of these addresses in Safari on the iPad (also saved in MaiTouchBridge\url.txt):
type "%~dp0MaiTouchBridge\url.txt"
echo.

rem Keep the game window focused for the whole session (the bridge presses the ring buttons as keyboard keys).
start "" /min powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0MaiTouchBridge\focus_game.ps1" -Keep
start "AM Daemon" /min inject -d -k mai2hook.dll amdaemon.exe -f -c config_common.json config_server.json config_client.json config_hook.json
inject -d -k mai2hook.dll sinmai -screen-fullscreen 0 -popupwindow -screen-width !SW! -screen-height !SH!

taskkill /f /im amdaemon.exe
taskkill /f /im MaiTouchBridge.exe >nul 2>&1
