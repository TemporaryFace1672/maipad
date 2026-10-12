@echo off
setlocal enabledelayedexpansion
set OPENSSL_ia32cap=:~0x20000000

pushd %~dp0

rem Controller-only iPad mode: MaiPad is just the touch panel + buttons (no game picture is streamed to it),
rem and the game is played on the PC monitor at full native resolution (same sizing as start.bat).
rem Do not run it together with MaiDXR (only one program can own COM5).
powershell -NoProfile -Command "(Get-Content mai2.ini) -replace '^DummyTouchPanel=.*','DummyTouchPanel=0' -replace '^DummyLED=.*','DummyLED=1' | Set-Content mai2.ini"

rem Screen size (physical pixels of the primary monitor).
set MW=
set MH=
for /f %%a in ('powershell -NoProfile -Command "Add-Type -AssemblyName System.Windows.Forms; $b=[Windows.Forms.Screen]::PrimaryScreen.Bounds; $b.Width; $b.Height"') do (
  if not defined MW (set MW=%%a) else set MH=%%a
)

rem If the monitor is 9:16 (portrait, e.g. 1440x2560), run true fullscreen at its native size.
rem Otherwise fall back to the largest exact 9:16 window that fits the usable desktop height (max 1080x1920).
set FS=0
set SW=1080
set SH=1920
if defined MW if defined MH (
  set /a CHK=MW*16-MH*9
  if !CHK! GEQ -16 if !CHK! LEQ 16 (
    set FS=1
    set SW=!MW!
    set SH=!MH!
  )
)
if !FS!==0 (
  set WH=
  for /f %%a in ('powershell -NoProfile -Command "Add-Type -AssemblyName System.Windows.Forms; [Windows.Forms.Screen]::PrimaryScreen.WorkingArea.Height"') do set WH=%%a
  if defined WH (
    set /a SH=WH/32*32
    set /a SW=SH/32*18
    if !SH! GTR 1920 (
      set SH=1920
      set SW=1080
    )
  )
)
echo Screen: !MW!x!MH!  -^>  game: !SW!x!SH!  fullscreen=!FS!

start "MaiTouchBridge" /min "%~dp0MaiTouchBridge\MaiTouchBridge.exe" --no-video
timeout /t 2 /nobreak >nul
echo.
echo Open MaiPad on the iPad (plugged in, unlocked). Wi-Fi fallback addresses are in MaiTouchBridge\url.txt.
echo.

rem Keep the game window focused for the whole session (the bridge presses the ring buttons as keyboard keys).
start "" /min powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0MaiTouchBridge\focus_game.ps1" -Keep
start "AM Daemon" /min inject -d -k mai2hook.dll amdaemon.exe -f -c config_common.json config_server.json config_client.json config_hook.json
if !FS!==1 (
  inject -d -k mai2hook.dll sinmai -screen-fullscreen 1 -screen-width !SW! -screen-height !SH!
) else (
  inject -d -k mai2hook.dll sinmai -screen-fullscreen 0 -popupwindow -screen-width !SW! -screen-height !SH!
)

taskkill /f /im amdaemon.exe
taskkill /f /im MaiTouchBridge.exe >nul 2>&1
