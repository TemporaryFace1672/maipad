@echo off
setlocal enabledelayedexpansion
set OPENSSL_ia32cap=:~0x20000000

pushd %~dp0

rem iPad mode: MaiTouchBridge plays the touch panel on COM5 (COM3<->COM5 com0com pair) and serves the iPad page.
rem Do not run it together with MaiDXR (only one program can own COM5).
powershell -NoProfile -Command "(Get-Content mai2.ini) -replace '^DummyTouchPanel=.*','DummyTouchPanel=0' -replace '^DummyLED=.*','DummyLED=1' | Set-Content mai2.ini"

rem Largest exact 9:16 window that fits the usable desktop height (max 1080x1920 = native).
set WH=
for /f %%a in ('powershell -NoProfile -Command "Add-Type -AssemblyName System.Windows.Forms; [Windows.Forms.Screen]::PrimaryScreen.WorkingArea.Height"') do set WH=%%a
set SW=1080
set SH=1920
if defined WH (
  set /a SH=WH/32*32
  set /a SW=SH/32*18
  if !SH! GTR 1920 (
    set SH=1920
    set SW=1080
  )
)
echo Usable desktop height: !WH!  -^>  game window: !SW!x!SH!  (9:16)

start "MaiTouchBridge" /min "C:\Games\MaiIpad\MaiTouchBridge.exe"
timeout /t 2 /nobreak >nul
echo.
echo Open one of these addresses in Safari on the iPad (also saved in C:\Games\MaiIpad\url.txt):
type "C:\Games\MaiIpad\url.txt"
echo.

rem Keep the game window focused for the whole session (the bridge presses the ring buttons as keyboard keys).
start "" /min powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\Games\MaiDXR\FocusGame\focus_game.ps1" -Keep
start "AM Daemon" /min inject -d -k mai2hook.dll amdaemon.exe -f -c config_common.json config_server.json config_client.json config_hook.json
inject -d -k mai2hook.dll sinmai -screen-fullscreen 0 -popupwindow -screen-width !SW! -screen-height !SH!

taskkill /f /im amdaemon.exe
taskkill /f /im MaiTouchBridge.exe >nul 2>&1
