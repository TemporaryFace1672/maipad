# MaiPad
Use an iPad as the maimai DX (segatools) touch panel and buttons on PC: 34-sensor touch ring, Select / Test / Service / Coin / Card.

## Parts
- `Sources/` + `project.yml` - native iPad app (Swift). Listens on TCP 24870; the PC reaches it over the USB cable through Apple's usbmuxd.
  GitHub Actions (`.github/workflows/build.yml`) builds an unsigned `MaiPad.ipa` artifact; sideload it (e.g. Sideloadly).
- `pc/MaiTouchBridge.cs` - PC bridge. Emulates the maimai touch board on a com0com port (COM5, paired with the game's COM3), talks to the app over USB (or serves `pc/ipad.html` over Wi-Fi as a fallback) and presses the ring keys (W E D C X Z A Q) plus select/test/service/coin/card while the game window "Sinmai" is in front.
- `pc/start_ipad.bat` - example launcher (adjust paths).

## Build the bridge
```
C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe /optimize /out:MaiTouchBridge.exe MaiTouchBridge.cs
```
Needs com0com pairs COM3<->COM5 (and COM4<->COM6) and `DummyTouchPanel=0` in mai2.ini. Requires iTunes / Apple Devices (Apple Mobile Device Service) for the USB route.
Protocol: text lines `S` + 34 bits (A1-8,B1-8,C1-2,D1-8,E1-8) and `B` + 5 bits (select,test,service,coin,card).
