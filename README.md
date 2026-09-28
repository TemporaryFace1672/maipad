# MaiPad

an iPad controller for maimai DX

- 34-sensor touch ring with multi-touch, plus Select / Test / Service / Coin / Card buttons
- Game picture (the circle screen) streamed to the iPad at up to native 1080x1080, about 60 fps
- One Settings menu: picture size/quality, overlay opacity, ring size, left-handed layout, touch sensitivity, tap sound,
  latency readout
- Everything runs over the USB cable (no Wi-Fi needed, no firewall prompts)

> Not affiliated with SEGA. No game files, keychips or keys are included or needed from this repo. You must supply your own obtained setup. Refrain from asking for game data in discussions
> This project only emulates the *input device*.

created with the help of Claude
## How it works

```
iPad (MaiPad app)  <--USB / usbmuxd-->  MaiTouchBridge.exe  <--COM5 (com0com pair)-->  COM3  maimai DX (sinmai.exe)
   touch + buttons  ----------------->   keyboard keys for ring/buttons ------------->  game window
   game picture     <-----------------   screen capture of the circle ---------------  game window
```

- The **app** listens on TCP port 24870. The PC bridge reaches it through Apple's USB multiplexer (the same thing iTunes uses).
- The **bridge** pretends to be the maimai touch board on a virtual serial port, and presses the ring keys
  (W E D C X Z A Q) plus Select (3), Test (7), Service (9), Coin (F3) and Card scan (Enter) while the game window is in front.
- The **picture** is a JPEG stream of the bottom (circle) square of the game window.

## What you need

**PC (Windows 10/11)**
- maimai DX already running with segatools, for example a MuNET/AquaDX-style setup, using **AquaMai** (its default key map is
  what the bridge presses: W E D C X Z A Q / 3)
- [com0com](https://com0com.sourceforge.net/) with two pairs: **COM3 <-> COM5** and **COM4 <-> COM6**
  (the game opens COM3/COM4, the bridge opens COM5/COM6)
- **iTunes** or **Apple Devices** (Microsoft Store) installed, which provides *Apple Mobile Device Service*
- The .NET Framework 4 compiler (`csc.exe`, already part of Windows) to build the bridge

**iPad**
- An iPad on iPadOS 13 or later, plus a USB cable
- [Sideloadly](https://sideloadly.io/) (or AltStore) and a free Apple ID to install the app
- Developer Mode on (Settings > Privacy & Security), needed on iOS 16 and later

## Rough setup

### 1. Get the app onto the iPad
1. Open this repo's **Actions** tab, open the latest **Build MaiPad IPA** run, and download the **MaiPad-ipa** artifact
   (GitHub asks you to sign in). Unzip it to get `MaiPad.ipa`.
   Or fork the repo and let Actions build it; a build takes about 5 minutes.
2. Plug the iPad in, unlock it, tap **Trust**, then install `MaiPad.ipa` with Sideloadly.
3. On the iPad: **Settings > General > VPN & Device Management** > your Apple ID > **Trust**.
4. Free Apple IDs expire the app after **7 days**; just sideload it again.

### 2. Build the bridge
From the `pc` folder:
```
C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe /optimize /r:System.Drawing.dll /out:MaiTouchBridge.exe MaiTouchBridge.cs
```
Copy `MaiTouchBridge.exe`, `ipad.html` and `focus_game.ps1` into a folder called `MaiTouchBridge` inside your game's `Package` folder.

### 3. Point the game at the virtual touch panel
- In `mai2.ini`: `DummyTouchPanel=0` (the launcher below sets this for you)
- In `segatools.ini`: keep the segatools `[touch]` emulation **off** (`p1Enable=0`, `p2Enable=0`), because the bridge is the touch panel now
- Make sure the com0com pairs above exist

### 4. Launch
Copy `pc/start_ipad.bat` into the same `Package` folder as `sinmai.exe`, and adjust it if your launcher differs
(it starts the bridge, a focus helper, `amdaemon` and the game with `inject -d -k mai2hook.dll`).

1. Open **MaiPad** on the iPad, plugged in and unlocked, and leave it open.
2. Run `start_ipad.bat`.
3. The bridge log (`MaiTouchBridge\MaiTouchBridge.log`) should say `iPad app connected over USB`, and the app shows **PC connected**.
4. Tap **COIN**, then **CARD** (scans the card number in `DEVICE\aime.txt`), and play.

### 5. Tune
Tap **SETTINGS** in the app. Turn on the latency readout and adjust the game's audio/input timing (see the notes below).

## Side notes and troubleshooting

**Latency and timing**
- Expect roughly 40-70 ms between the game drawing a frame and it showing on the iPad. The settings readout shows the parts
  it can measure and an estimate of the total.
- The picture trails the sound and your presses land late. In the game's timing adjustment, delay the **music** offset and shift
  the **input** offset by about the same amount as the video delay. Do it by ear and by the on-screen test, not by numbers from here.
  With Bluetooth headphones the audio is already late and may cancel most of it.
- If the picture stutters, lower the picture size or quality in Settings.

**Window handling**
- While video is on, the bridge resizes the game window to a true 9:16 (1080x1920) and slides it up so the circle screen is fully
  on your monitor; it puts it back when the video stops. Unity refuses to open a window taller than the monitor by itself.
- So on your PC monitor you will only see the lower (circle) half of the game while streaming.

**Keys and focus**
- maimai only reads the ring buttons while its window has keyboard focus, so `focus_game.ps1` keeps the game window in front.
  The bridge also refuses to press keys unless the window titled `Sinmai` is in front, so it never types into other apps.
- Only one program can own COM5. Do not run MaiDXR (VR) together with this bridge.

**USB problems**
- Bridge log says `no iPad on USB`: unlock the iPad, unplug and replug, tap **Trust**. If it persists, restart
  *Apple Mobile Device Service* (admin PowerShell: `Restart-Service "Apple Mobile Device Service"`).
- `iPad found but app not open on the iPad`: open MaiPad and keep it in the foreground.
- "Untrusted developer" on the iPad: see step 3 of the setup. It needs internet once, and a VPN or private DNS on the iPad can block the check.

**Optional Wi-Fi web page**
- The bridge also serves `ipad.html` on port 8765 (address printed in `MaiTouchBridge\url.txt`). It has the touch ring only, no video.
  Safari may try to upgrade the address to HTTPS and fail; the USB app avoids that problem entirely. Allow the Windows Firewall prompt
  only if you want to use it.

**Bridge options**
`--port 8765 --p1 COM5 --p2 COM6 --usb-port 24870 --token xxx --any-window --no-keys --no-usb` (`--no-usb` turns the USB link off)

**Not done yet / ideas**
- Streaming audio to the iPad, streaming the top screen, 2P support

## Repository layout

| Path | What |
|---|---|
| `Sources/`, `project.yml` | iPad app (Swift, generated with XcodeGen) |
| `.github/workflows/build.yml` | Builds an unsigned `MaiPad.ipa` on GitHub (macOS runner) |
| `pc/MaiTouchBridge.cs` | PC bridge (touch panel emulation, USB link, keys, video capture) |
| `pc/ipad.html` | Wi-Fi fallback page |
| `pc/start_ipad.bat`, `pc/focus_game.ps1` | Example launcher and focus helper |
| `pc/CaptureBench.cs` | Measures screen-capture and JPEG cost |

## Protocol (for hackers)

Touch panel side (game <-> bridge, 9600 baud): the game sends 6-byte `{....}` commands, the bridge answers `r`/`k` with `(` + 4 bytes + `)`
and, after `{STAT}`, streams 9-byte frames `(` + 7 bytes + `)` holding 34 sensor bits (5 per byte, order A1-A8, B1-B8, C1-C2, D1-D8, E1-E8).

App <-> bridge (TCP 24870 over usbmuxd). App to PC, text lines: `S` + 34 bits, `B` + 5 bits (select, test, service, coin, card),
`V<size>,<quality>` (`V0` = off), `P<id>` ping. PC to app: `[uint32 LE length][bytes]`; a length with the top bit set carries a short
text message (`O<id>` ping answer, `T<ms>,<fps>` capture timing), otherwise the bytes are a JPEG.
