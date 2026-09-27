// MaiTouchBridge: lets an iPad (or any browser) act as the maimai DX touch panel + buttons.
//  - Emulates the maimai touch sensor board on a com0com port (default COM5, the far end of the game's COM3),
//    exactly like MaiDXR / WpfMaiTouchEmulator: 6-byte commands from the game, 9-byte "(" + 7 bytes + ")" frames back.
//  - Serves a small web page and a WebSocket over the LAN; the page sends the 34 sensor states and a few buttons.
//  - Ring buttons: touching sensor A1..A8 also presses W E D C X Z A Q (same as WpfMaiTouchEmulator), but only
//    while the game window ("Sinmai") is the foreground window, so keystrokes can never land in another app.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.IO.Ports;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Threading;

namespace MaiTouchBridgeApp
{
    class TouchPort
    {
        public readonly string Name;
        SerialPort sp;
        public volatile bool Streaming;
        public volatile bool IsOpen;
        readonly object wlock = new object();
        int cmdCount = 0;
        public TouchPort(string name) { Name = name; }

        public bool Open(out string error)
        {
            error = null;
            try
            {
                sp = new SerialPort(Name, 9600, Parity.None, 8, StopBits.One);
                sp.ReadTimeout = 300;
                sp.WriteTimeout = 200;
                sp.Open();
                IsOpen = true;
                Thread t = new Thread(ReadLoop);
                t.IsBackground = true;
                t.Start();
                return true;
            }
            catch (Exception e) { error = e.Message; return false; }
        }

        void ReadLoop()
        {
            List<byte> buf = new List<byte>();
            byte[] tmp = new byte[64];
            while (IsOpen)
            {
                int n;
                try { n = sp.Read(tmp, 0, tmp.Length); }
                catch (TimeoutException) { continue; }
                catch (Exception e) { Program.Log(Name + " read error: " + e.Message); IsOpen = false; break; }
                for (int i = 0; i < n; i++) buf.Add(tmp[i]);
                while (buf.Count > 0 && buf[0] != 0x7B) buf.RemoveAt(0);
                while (buf.Count >= 6)
                {
                    if (buf[5] == 0x7D)
                    {
                        byte[] cmd = buf.GetRange(0, 6).ToArray();
                        buf.RemoveRange(0, 6);
                        Handle(cmd);
                    }
                    else
                    {
                        buf.RemoveAt(0);
                        while (buf.Count > 0 && buf[0] != 0x7B) buf.RemoveAt(0);
                    }
                }
            }
        }

        void Handle(byte[] c)
        {
            if (cmdCount++ < 40) Program.Log(Name + " <- game command " + Encoding.ASCII.GetString(c));
            switch (c[3])
            {
                case 76: case 69:            // {HALT} / {RSET}: stop streaming
                    Streaming = false; break;
                case 114: case 107:          // sensitivity read/write: echo the value back
                    Write(new byte[] { 40, c[1], c[2], c[3], c[4], 41 }); break;
                case 65:                     // {STAT}: start streaming
                    Streaming = true; Program.Log(Name + " streaming ON"); break;
            }
        }

        void Write(byte[] b)
        {
            if (!IsOpen) return;
            lock (wlock)
            {
                try { sp.Write(b, 0, b.Length); }
                catch (Exception e) { Program.Log(Name + " write error: " + e.Message); }
            }
        }

        public void SendState(bool[] s)
        {
            if (!IsOpen || !Streaming) return;
            byte[] frame = new byte[9];
            frame[0] = 40; frame[8] = 41;
            if (s != null)
                for (int i = 0; i < 34; i++)
                    if (s[i]) frame[1 + i / 5] |= (byte)(1 << (i % 5));
            Write(frame);
        }
    }

    // Talks to Apple's usbmuxd (Apple Mobile Device Service listens on 127.0.0.1:27015) so the PC can open a TCP
    // connection to a port on a USB-connected iPad, like iTunes / Brokenithm's bridge do.
    static class UsbMux
    {
        const int MuxPort = 27015;

        static string Request(string type, int deviceId, int devicePort)
        {
            StringBuilder sb = new StringBuilder();
            sb.Append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\"><dict>");
            sb.Append("<key>MessageType</key><string>" + type + "</string>");
            sb.Append("<key>ClientVersionString</key><string>MaiTouchBridge</string><key>ProgName</key><string>MaiTouchBridge</string><key>kLibUSBMuxVersion</key><integer>3</integer>");
            if (deviceId >= 0)
            {
                int swapped = ((devicePort & 0xFF) << 8) | ((devicePort >> 8) & 0xFF);
                sb.Append("<key>DeviceID</key><integer>" + deviceId + "</integer><key>PortNumber</key><integer>" + swapped + "</integer>");
            }
            sb.Append("</dict></plist>\n");
            return sb.ToString();
        }

        static void SendPacket(NetworkStream ns, string plist, int tag)
        {
            byte[] body = Encoding.UTF8.GetBytes(plist);
            byte[] pkt = new byte[16 + body.Length];
            BitConverter.GetBytes(pkt.Length).CopyTo(pkt, 0);
            BitConverter.GetBytes(1).CopyTo(pkt, 4);   // version 1 = plist
            BitConverter.GetBytes(8).CopyTo(pkt, 8);   // message type 8 = plist payload
            BitConverter.GetBytes(tag).CopyTo(pkt, 12);
            Buffer.BlockCopy(body, 0, pkt, 16, body.Length);
            ns.Write(pkt, 0, pkt.Length);
        }

        // returns null on timeout / closed
        static string ReadPacket(NetworkStream ns)
        {
            byte[] hd = new byte[16];
            if (!Fill(ns, hd, 16)) return null;
            int len = BitConverter.ToInt32(hd, 0) - 16;
            if (len < 0 || len > 1 << 20) return null;
            byte[] body = new byte[len];
            if (len > 0 && !Fill(ns, body, len)) return null;
            return Encoding.UTF8.GetString(body);
        }

        static bool Fill(NetworkStream ns, byte[] b, int n)
        {
            int got = 0;
            try
            {
                while (got < n) { int r = ns.Read(b, got, n - got); if (r <= 0) return false; got += r; }
                return true;
            }
            catch { return false; }
        }

        static int ResultNumber(string plist)
        {
            System.Text.RegularExpressions.Match m = System.Text.RegularExpressions.Regex.Match(plist ?? "", "<key>Number</key>\\s*<integer>(\\d+)</integer>");
            return m.Success ? int.Parse(m.Groups[1].Value) : -1;
        }

        // Asks the daemon which iPhones/iPads are attached over USB.
        public static List<int> ListUsbDevices(out string error)
        {
            error = null;
            List<int> ids = new List<int>();
            try
            {
                using (TcpClient c = new TcpClient())
                {
                    c.Connect(IPAddress.Loopback, MuxPort);
                    NetworkStream ns = c.GetStream();
                    SendPacket(ns, Request("Listen", -1, 0), 1);
                    if (ResultNumber(ReadPacket(ns)) != 0) { error = "usbmuxd refused Listen"; return ids; }
                    ns.ReadTimeout = 500;   // existing devices are reported immediately as 'Attached' events
                    for (int i = 0; i < 16; i++)
                    {
                        string p = ReadPacket(ns);
                        if (p == null) break;
                        if (p.IndexOf("<string>Attached</string>") < 0) continue;
                        System.Text.RegularExpressions.Match m = System.Text.RegularExpressions.Regex.Match(p, "<key>DeviceID</key>\\s*<integer>(\\d+)</integer>");
                        if (!m.Success) continue;
                        if (p.IndexOf("<key>ConnectionType</key>") >= 0 && p.IndexOf("<string>USB</string>") < 0) continue;
                        ids.Add(int.Parse(m.Groups[1].Value));
                    }
                }
            }
            catch (Exception e) { error = e.Message; }
            return ids;
        }

        public static TcpClient Connect(int deviceId, int port, out string error)
        {
            error = null;
            TcpClient c = new TcpClient();
            try
            {
                c.NoDelay = true;
                c.Connect(IPAddress.Loopback, MuxPort);
                NetworkStream ns = c.GetStream();
                ns.ReadTimeout = 3000;
                SendPacket(ns, Request("Connect", deviceId, port), 2);
                int r = ResultNumber(ReadPacket(ns));
                if (r != 0) { error = r == 3 ? "app not open on the iPad" : "usbmuxd connect result " + r; c.Close(); return null; }
                ns.ReadTimeout = System.Threading.Timeout.Infinite;
                return c;
            }
            catch (Exception e) { error = e.Message; try { c.Close(); } catch { } return null; }
        }
    }

    // Streams the bottom (circle) square of the game window to the iPad app as JPEG frames: [uint32 length LE][jpeg bytes].
    // The app switches it on/off with a "V<size>,<quality>" line ("V0" = off). Only this thread writes to the socket.
    class Video
    {
        delegate bool EnumProc(IntPtr h, IntPtr l);
        [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc p, IntPtr l);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
        [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
        [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
        [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr h, out RECT r);
        [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr h, ref POINT p);
        [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr h);
        [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr h, IntPtr dc);
        [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
        [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
        [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int hh, uint flags);
        [DllImport("user32.dll")] static extern int GetSystemMetrics(int i);
        [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr dc);
        [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleBitmap(IntPtr dc, int w, int h);
        [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr dc, IntPtr o);
        [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr o);
        [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr dc);
        [DllImport("gdi32.dll")] static extern bool StretchBlt(IntPtr dst, int x, int y, int w, int h, IntPtr src, int sx, int sy, int sw, int sh, uint rop);
        [DllImport("gdi32.dll")] static extern int SetStretchBltMode(IntPtr dc, int mode);
        [StructLayout(LayoutKind.Sequential)] struct RECT { public int L, T, R, B; }
        [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }

        readonly NetworkStream ns;
        volatile int size = 0, quality = 65;
        volatile bool stop;
        Thread thread;
        readonly object cfgLock = new object();

        public Video(NetworkStream s) { ns = s; }

        public void Configure(string arg)
        {
            string[] p = arg.Split(',');
            int sz = 0, q = 65;
            int.TryParse(p[0], out sz);
            if (p.Length > 1) int.TryParse(p[1], out q);
            if (sz != 0) sz = Math.Max(256, Math.Min(1080, sz));
            q = Math.Max(30, Math.Min(95, q));
            lock (cfgLock)
            {
                size = sz; quality = q;
                if (sz != 0 && thread == null)
                {
                    thread = new Thread(Loop); thread.IsBackground = true; thread.Priority = ThreadPriority.AboveNormal; thread.Start();
                }
            }
            Program.Log("video " + (sz == 0 ? "off" : "on: " + sz + "x" + sz + " q" + q));
        }

        public void Stop() { stop = true; }

        // A full-size (1080x1920) game window is taller than most monitors. The picture we stream is only the bottom
        // square, so while streaming we slide the window up until that square is on screen (SWP_NOSIZE|NOZORDER|NOACTIVATE).
        // Unity clamps a new window to the monitor height, so a 1080-wide window ends up squashed; we resize it to a true
        // 9:16 (cw x cw*16/9) from outside, which the game follows.
        bool moved; int origX, origY, origW, origH;
        bool SlideUp(IntPtr game, int clientTopScreenY, int cw, int ch)
        {
            int screenH = GetSystemMetrics(1);
            int wantH = (int)((long)cw * 16 / 9);
            bool wrongShape = Math.Abs(ch - wantH) > 3;
            int newCh = wrongShape ? wantH : ch;
            int squareTop = clientTopScreenY + newCh - cw;
            bool visible = squareTop >= 0 && squareTop + cw <= screenH;
            if (!wrongShape && visible) return false;
            if (cw > screenH) return false;                                     // cannot fit anyway
            RECT wr; if (!GetWindowRect(game, out wr)) return false;
            if (!moved) { origX = wr.L; origY = wr.T; origW = wr.R - wr.L; origH = wr.B - wr.T; moved = true; }
            int frameH = (wr.B - wr.T) - ch;
            int y = visible ? wr.T : wr.T - squareTop;
            SetWindowPos(game, IntPtr.Zero, wr.L, y, wr.R - wr.L, newCh + frameH, 0x0004 | 0x0010);
            Program.Log("video: game window set to " + cw + "x" + newCh + " and moved so the circle screen is fully on the monitor");
            return true;
        }

        void Restore(IntPtr game)
        {
            if (!moved) return;
            moved = false;
            if (game != IntPtr.Zero) { SetWindowPos(game, IntPtr.Zero, origX, origY, origW, origH, 0x0004 | 0x0010); Program.Log("video: game window put back"); }
        }

        static IntPtr FindGame()
        {
            IntPtr f = IntPtr.Zero;
            EnumWindows(delegate(IntPtr h, IntPtr l)
            {
                if (!IsWindowVisible(h)) return true;
                StringBuilder sb = new StringBuilder(64); GetWindowText(h, sb, 64);
                if (sb.ToString() == "Sinmai") { f = h; return false; }
                return true;
            }, IntPtr.Zero);
            return f;
        }

        void Loop()
        {
            try { SetProcessDPIAware(); } catch { }
            ImageCodecInfo jpeg = null;
            foreach (ImageCodecInfo c in ImageCodecInfo.GetImageEncoders()) if (c.MimeType == "image/jpeg") jpeg = c;
            IntPtr screen = GetDC(IntPtr.Zero);
            IntPtr mem = IntPtr.Zero, bmp = IntPtr.Zero;
            int curSize = 0, curQ = -1;
            EncoderParameters ep = null;
            IntPtr game = IntPtr.Zero;
            Stopwatch sw = new Stopwatch(), stat = Stopwatch.StartNew();
            int frames = 0; long bytes = 0; double capMs = 0, totMs = 0, maxMs = 0;
            byte[] hdr = new byte[4];
            bool waiting = false;
            try
            {
                while (!stop)
                {
                    int sz = size;
                    if (sz == 0) { Restore(game); Thread.Sleep(50); continue; }
                    if (game == IntPtr.Zero || !IsWindowVisible(game)) game = FindGame();
                    RECT cr;
                    if (game == IntPtr.Zero || IsIconic(game) || !GetClientRect(game, out cr) || cr.R - cr.L < 64 || cr.B - cr.T < cr.R - cr.L)
                    {
                        game = IntPtr.Zero;
                        if (!waiting) { waiting = true; Program.Log("video: waiting for the game window"); }
                        Thread.Sleep(200); continue;
                    }
                    waiting = false;
                    int side = cr.R - cr.L;
                    POINT org = new POINT(); ClientToScreen(game, ref org);
                    if (SlideUp(game, org.Y, side, cr.B - cr.T)) { Thread.Sleep(400); continue; }   // give the game a moment to follow the new size, then re-measure
                    if (sz > side) sz = side;    // never upscale
                    if (sz != curSize)
                    {
                        if (bmp != IntPtr.Zero) { SelectObject(mem, IntPtr.Zero); DeleteObject(bmp); }
                        if (mem == IntPtr.Zero) mem = CreateCompatibleDC(screen);
                        bmp = CreateCompatibleBitmap(screen, sz, sz);
                        SelectObject(mem, bmp);
                        SetStretchBltMode(mem, 4);   // HALFTONE: smooth downscale
                        curSize = sz;
                    }
                    if (quality != curQ)
                    {
                        curQ = quality;
                        ep = new EncoderParameters(1);
                        ep.Param[0] = new EncoderParameter(System.Drawing.Imaging.Encoder.Quality, (long)curQ);
                    }
                    sw.Restart();
                    StretchBlt(mem, 0, 0, sz, sz, screen, org.X, org.Y + (cr.B - cr.T) - side, side, side, 0x00CC0020);
                    double cap = sw.Elapsed.TotalMilliseconds;
                    byte[] jpg;
                    using (Bitmap b = Image.FromHbitmap(bmp))
                    using (MemoryStream ms = new MemoryStream(96 * 1024))
                    {
                        b.Save(ms, jpeg, ep);
                        jpg = ms.ToArray();
                    }
                    BitConverter.GetBytes(jpg.Length).CopyTo(hdr, 0);
                    ns.Write(hdr, 0, 4);
                    ns.Write(jpg, 0, jpg.Length);
                    double tot = sw.Elapsed.TotalMilliseconds;
                    frames++; bytes += jpg.Length; capMs += cap; totMs += tot; if (tot > maxMs) maxMs = tot;
                    if (stat.ElapsedMilliseconds >= 5000)
                    {
                        Program.Log(string.Format("video: {0:F1} fps, {1} KB/frame, capture {2:F1} ms, total {3:F1} ms (max {4:F0}), {5:F1} MB/s",
                            frames * 1000.0 / stat.ElapsedMilliseconds, bytes / Math.Max(frames, 1) / 1024, capMs / Math.Max(frames, 1), totMs / Math.Max(frames, 1), maxMs, bytes / 1048576.0 * 1000.0 / stat.ElapsedMilliseconds));
                        frames = 0; bytes = 0; capMs = 0; totMs = 0; maxMs = 0; stat.Restart();
                    }
                    if (tot < 15) Thread.Sleep(1);   // the screen grab already waits for the refresh; this only stops a runaway loop
                }
            }
            catch (Exception e) { Program.Log("video stopped: " + e.Message); }
            finally
            {
                Restore(game);
                if (bmp != IntPtr.Zero) { SelectObject(mem, IntPtr.Zero); DeleteObject(bmp); }
                if (mem != IntPtr.Zero) DeleteDC(mem);
                ReleaseDC(IntPtr.Zero, screen);
            }
        }
    }

    static class Program
    {
        [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
        [DllImport("user32.dll")] static extern uint MapVirtualKey(uint code, uint type);
        [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);

        // sensor order used everywhere: A1..A8, B1..B8, C1,C2, D1..D8, E1..E8  (index 0..33)
        static readonly byte[] RingKeys = { 0x57, 0x45, 0x44, 0x43, 0x58, 0x5A, 0x41, 0x51 }; // W E D C X Z A Q for A1..A8
        // extra buttons: select, test, service, coin, card(enter)
        static readonly byte[] ExtraKeys = { 0x33, 0x37, 0x39, 0x72, 0x0D };

        static string baseDir, logPath, token;
        static int port = 8765, usbPort = 24870;
        static bool noUsb = false;
        static string deviceTcp = null;   // "host:port" - test hook that replaces usbmuxd with a direct TCP connection
        static string com1 = "COM5", com2 = "COM6";
        static bool anyWindow = false, noKeys = false;
        static readonly object sync = new object();
        static readonly object keyLock = new object();
        static readonly object logLock = new object();
        static readonly bool[] sensors = new bool[34];
        static readonly bool[] extra = new bool[5];
        static readonly bool[] held = new bool[256];
        static readonly AutoResetEvent wake = new AutoResetEvent(false);
        static TouchPort p1, p2;
        static int clients = 0, skippedKeys = 0, msgCount = 0;

        public static void Log(string m)
        {
            lock (logLock)
            {
                try { File.AppendAllText(logPath, DateTime.Now.ToString("HH:mm:ss.fff") + "  " + m + "\r\n"); } catch { }
            }
        }

        static int Main(string[] args)
        {
            baseDir = AppDomain.CurrentDomain.BaseDirectory;
            logPath = Path.Combine(baseDir, "MaiTouchBridge.log");
            try { File.WriteAllText(logPath, ""); } catch { }
            for (int i = 0; i < args.Length; i++)
            {
                string a = args[i].ToLowerInvariant();
                if (a == "--port" && i + 1 < args.Length) int.TryParse(args[++i], out port);
                else if (a == "--p1" && i + 1 < args.Length) com1 = args[++i];
                else if (a == "--p2" && i + 1 < args.Length) com2 = args[++i];
                else if (a == "--token" && i + 1 < args.Length) token = args[++i];
                else if (a == "--any-window") anyWindow = true;
                else if (a == "--no-keys") noKeys = true;
                else if (a == "--no-usb") noUsb = true;
                else if (a == "--usb-port" && i + 1 < args.Length) int.TryParse(args[++i], out usbPort);
                else if (a == "--device-tcp" && i + 1 < args.Length) deviceTcp = args[++i];
            }
            LoadToken();

            p1 = new TouchPort(com1);
            string err;
            if (!p1.Open(out err)) { Log("cannot open " + com1 + ": " + err + " (is MaiDXR or another program using it?)"); Console.WriteLine("cannot open " + com1 + ": " + err); return 2; }
            Log("opened " + com1 + " as player 1 touch panel");
            p2 = new TouchPort(com2);
            if (p2.Open(out err)) Log("opened " + com2 + " as player 2 touch panel (always untouched)");
            else { Log(com2 + " not available (fine, only needed to make game start-up faster): " + err); p2 = null; }

            Thread sender = new Thread(SendLoop); sender.IsBackground = true; sender.Priority = ThreadPriority.AboveNormal; sender.Start();
            Thread server = new Thread(ServerLoop); server.IsBackground = true; server.Start();
            if (!noUsb) { Thread usb = new Thread(UsbLoop); usb.IsBackground = true; usb.Start(); }

            StringBuilder urls = new StringBuilder();
            foreach (string ip in LocalIps()) urls.AppendLine("http://" + ip + ":" + port + "/?k=" + token);
            urls.AppendLine("http://localhost:" + port + "/?k=" + token);
            try { File.WriteAllText(Path.Combine(baseDir, "url.txt"), urls.ToString()); } catch { }
            Log("listening on port " + port + "; open one of these on the iPad:\r\n" + urls.ToString());
            Console.WriteLine("MaiTouchBridge running. iPad URL(s):");
            Console.WriteLine(urls.ToString());

            Console.CancelKeyPress += delegate { ReleaseAll(); };
            while (true) Thread.Sleep(1000);
        }

        static void LoadToken()
        {
            string tf = Path.Combine(baseDir, "token.txt");
            if (string.IsNullOrEmpty(token))
            {
                try { if (File.Exists(tf)) token = File.ReadAllText(tf).Trim(); } catch { }
            }
            if (string.IsNullOrEmpty(token))
            {
                byte[] r = new byte[6]; new RNGCryptoServiceProvider().GetBytes(r);
                StringBuilder sb = new StringBuilder();
                foreach (byte b in r) sb.Append("abcdefghjkmnpqrstuvwxyz23456789"[b % 31]);
                token = sb.ToString();
                try { File.WriteAllText(tf, token); } catch { }
            }
        }

        static List<string> LocalIps()
        {
            List<string> withGw = new List<string>(), other = new List<string>();
            try
            {
                foreach (NetworkInterface ni in NetworkInterface.GetAllNetworkInterfaces())
                {
                    if (ni.OperationalStatus != OperationalStatus.Up) continue;
                    if (ni.NetworkInterfaceType == NetworkInterfaceType.Loopback || ni.NetworkInterfaceType == NetworkInterfaceType.Tunnel) continue;
                    IPInterfaceProperties props = ni.GetIPProperties();
                    bool gw = false;
                    foreach (GatewayIPAddressInformation g in props.GatewayAddresses) if (g.Address.AddressFamily == AddressFamily.InterNetwork && !g.Address.Equals(IPAddress.Any)) gw = true;
                    foreach (UnicastIPAddressInformation ua in props.UnicastAddresses)
                    {
                        if (ua.Address.AddressFamily != AddressFamily.InterNetwork) continue;
                        string s = ua.Address.ToString();
                        if (s.StartsWith("169.254")) continue;
                        (gw ? withGw : other).Add(s);
                    }
                }
            }
            catch { }
            withGw.AddRange(other);
            return withGw;
        }

        // ---------- input handling ----------
        static bool GameFocused()
        {
            if (anyWindow) return true;
            StringBuilder sb = new StringBuilder(64);
            GetWindowText(GetForegroundWindow(), sb, 64);
            return sb.ToString() == "Sinmai";
        }

        static void Key(byte vk, bool down)
        {
            if (noKeys) return;
            lock (keyLock)
            {
                if (down)
                {
                    if (held[vk]) return;
                    if (!GameFocused()) { skippedKeys++; if (skippedKeys <= 3) Log("key skipped: the game window is not in front"); return; }
                    held[vk] = true;
                    keybd_event(vk, (byte)MapVirtualKey(vk, 0), 0, UIntPtr.Zero);
                }
                else
                {
                    if (!held[vk]) return;
                    held[vk] = false;
                    keybd_event(vk, (byte)MapVirtualKey(vk, 0), 2, UIntPtr.Zero);
                }
            }
        }

        static void ReleaseAll()
        {
            lock (sync)
            {
                for (int i = 0; i < 34; i++) sensors[i] = false;
                for (int i = 0; i < 5; i++) extra[i] = false;
            }
            lock (keyLock)
            {
                for (int v = 0; v < 256; v++)
                    if (held[v]) { held[v] = false; keybd_event((byte)v, (byte)MapVirtualKey((uint)v, 0), 2, UIntPtr.Zero); }
            }
            wake.Set();
        }

        static void OnSensors(string s)
        {
            if (s.Length < 34) s = s.PadRight(34, '0');
            lock (sync)
            {
                for (int i = 0; i < 34; i++)
                {
                    bool v = s[i] == '1';
                    if (v != sensors[i]) { sensors[i] = v; if (i < 8) Key(RingKeys[i], v); }
                }
            }
            wake.Set();
        }

        static void OnExtra(string s)
        {
            if (s.Length < 5) return;
            lock (sync)
            {
                for (int i = 0; i < 5; i++)
                {
                    bool v = s[i] == '1';
                    if (v != extra[i]) { extra[i] = v; Key(ExtraKeys[i], v); }
                }
            }
        }

        static void SendLoop()
        {
            while (true)
            {
                wake.WaitOne(20);
                bool[] snap;
                lock (sync) { snap = (bool[])sensors.Clone(); }
                if (p1 != null) p1.SendState(snap);
                if (p2 != null) p2.SendState(null);
            }
        }

        // ---------- USB iPad app (MaiPad) via usbmuxd ----------
        static void UsbLoop()
        {
            string lastNote = "";
            while (true)
            {
                TcpClient c = null;
                string err = null, note;
                if (deviceTcp != null)
                {
                    try
                    {
                        string[] hp = deviceTcp.Split(':');
                        c = new TcpClient(); c.NoDelay = true; c.Connect(hp[0], int.Parse(hp[1]));
                    }
                    catch (Exception e) { err = e.Message; c = null; }
                    note = "test device " + deviceTcp + ": " + err;
                }
                else
                {
                    List<int> ids = UsbMux.ListUsbDevices(out err);
                    if (ids.Count == 0) note = err != null ? "USB service not reachable: " + err + " (install iTunes / Apple Devices)" : "no iPad on USB (plug it in, unlock it, tap Trust)";
                    else
                    {
                        note = "iPad found but " + usbPort + ": ";
                        foreach (int id in ids)
                        {
                            c = UsbMux.Connect(id, usbPort, out err);
                            if (c != null) break;
                            note = "iPad found but " + err;
                        }
                    }
                }
                if (c == null)
                {
                    if (note != lastNote) { Log("USB: " + note); lastNote = note; }
                    Thread.Sleep(1200);
                    continue;
                }
                lastNote = "";
                RunUsbSession(c);
                Thread.Sleep(300);
            }
        }

        static void RunUsbSession(TcpClient c)
        {
            Video vid = null;
            int now = Interlocked.Increment(ref clients);
            Log("iPad app connected over USB (" + now + " client(s))");
            try
            {
                NetworkStream ns = c.GetStream();
                c.SendBufferSize = 64 * 1024;   // keep little video queued so it never lags behind the game
                vid = new Video(ns);
                byte[] buf = new byte[256];
                StringBuilder line = new StringBuilder();
                while (true)
                {
                    int n = ns.Read(buf, 0, buf.Length);
                    if (n <= 0) break;
                    for (int i = 0; i < n; i++)
                    {
                        char ch = (char)buf[i];
                        if (ch != '\n') { if (line.Length < 200) line.Append(ch); continue; }
                        string msg = line.ToString(); line.Length = 0;
                        if (msg.Length == 0) continue;
                        msgCount++;
                        if (msgCount <= 12) Log("iPad message: " + msg);
                        if (msg[0] == 'S') OnSensors(msg.Substring(1));
                        else if (msg[0] == 'B') OnExtra(msg.Substring(1));
                        else if (msg[0] == 'V') vid.Configure(msg.Substring(1));
                    }
                }
            }
            catch { }
            finally
            {
                if (vid != null) vid.Stop();
                try { c.Close(); } catch { }
                int left = Interlocked.Decrement(ref clients);
                Log("iPad app disconnected (" + left + " client(s) left)");
                if (left == 0) ReleaseAll();
            }
        }

        // ---------- tiny HTTP + WebSocket server ----------
        static void ServerLoop()
        {
            TcpListener l = new TcpListener(IPAddress.Any, port);
            try { l.Start(); }
            catch (Exception e) { Log("cannot listen on port " + port + ": " + e.Message); Environment.Exit(3); }
            while (true)
            {
                TcpClient c;
                try { c = l.AcceptTcpClient(); } catch { continue; }
                Thread t = new Thread(delegate() { Serve(c); });
                t.IsBackground = true;
                t.Start();
            }
        }

        static string ReadHead(NetworkStream ns)
        {
            byte[] buf = new byte[8192]; int n = 0;
            while (n < buf.Length)
            {
                int r = ns.Read(buf, n, 1);
                if (r <= 0) return null;
                n += r;
                if (n >= 4 && buf[n - 4] == 13 && buf[n - 3] == 10 && buf[n - 2] == 13 && buf[n - 1] == 10) return Encoding.ASCII.GetString(buf, 0, n);
            }
            return null;
        }

        static string GetQuery(string query, string key)
        {
            foreach (string part in query.Split('&'))
            {
                int eq = part.IndexOf('=');
                if (eq > 0 && part.Substring(0, eq) == key) return Uri.UnescapeDataString(part.Substring(eq + 1));
            }
            return "";
        }

        static void Respond(NetworkStream ns, int code, string type, byte[] body)
        {
            string head = "HTTP/1.1 " + code + (code == 200 ? " OK" : code == 403 ? " Forbidden" : " Not Found") + "\r\nContent-Type: " + type + "\r\nContent-Length: " + body.Length + "\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n";
            byte[] h = Encoding.ASCII.GetBytes(head);
            ns.Write(h, 0, h.Length); ns.Write(body, 0, body.Length);
        }

        static void Serve(TcpClient c)
        {
            try
            {
                c.NoDelay = true;
                c.ReceiveTimeout = 8000;
                NetworkStream ns = c.GetStream();
                string head = ReadHead(ns);
                if (head == null) return;
                string[] lines = head.Split(new string[] { "\r\n" }, StringSplitOptions.None);
                string[] rl = lines[0].Split(' ');
                string path = rl.Length > 1 ? rl[1] : "/", query = "";
                int q = path.IndexOf('?');
                if (q >= 0) { query = path.Substring(q + 1); path = path.Substring(0, q); }
                Dictionary<string, string> h = new Dictionary<string, string>();
                for (int i = 1; i < lines.Length; i++)
                {
                    int colon = lines[i].IndexOf(':');
                    if (colon > 0) h[lines[i].Substring(0, colon).Trim().ToLowerInvariant()] = lines[i].Substring(colon + 1).Trim();
                }
                if (GetQuery(query, "k") != token) { Respond(ns, 403, "text/plain", Encoding.ASCII.GetBytes("forbidden")); return; }
                string up;
                if (h.TryGetValue("upgrade", out up) && up.ToLowerInvariant() == "websocket" && h.ContainsKey("sec-websocket-key"))
                    RunWebSocket(ns, h["sec-websocket-key"]);
                else if (path == "/" || path == "/index.html")
                {
                    string f = Path.Combine(baseDir, "ipad.html");
                    if (File.Exists(f)) Respond(ns, 200, "text/html; charset=utf-8", File.ReadAllBytes(f));
                    else Respond(ns, 404, "text/plain", Encoding.ASCII.GetBytes("ipad.html missing"));
                }
                else Respond(ns, 404, "text/plain", Encoding.ASCII.GetBytes("not found"));
            }
            catch { }
            finally { try { c.Close(); } catch { } }
        }

        static bool ReadExact(NetworkStream ns, byte[] b, int n)
        {
            int got = 0;
            while (got < n) { int r = ns.Read(b, got, n - got); if (r <= 0) return false; got += r; }
            return true;
        }

        static void SendText(NetworkStream ns, string text)
        {
            byte[] p = Encoding.UTF8.GetBytes(text);
            byte[] f = new byte[2 + p.Length];
            f[0] = 0x81; f[1] = (byte)p.Length; // messages are always short (< 126 bytes)
            Buffer.BlockCopy(p, 0, f, 2, p.Length);
            ns.Write(f, 0, f.Length);
        }

        static void RunWebSocket(NetworkStream ns, string key)
        {
            string accept = Convert.ToBase64String(SHA1.Create().ComputeHash(Encoding.ASCII.GetBytes(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")));
            byte[] resp = Encoding.ASCII.GetBytes("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " + accept + "\r\n\r\n");
            ns.Write(resp, 0, resp.Length);
            int now = Interlocked.Increment(ref clients);
            Log("iPad connected (" + now + " client(s))");
            try
            {
                SendText(ns, "hi");
                while (true)
                {
                    byte[] hd = new byte[2];
                    if (!ReadExact(ns, hd, 2)) break;
                    int op = hd[0] & 0x0F;
                    bool masked = (hd[1] & 0x80) != 0;
                    long len = hd[1] & 0x7F;
                    if (len == 126) { byte[] e = new byte[2]; if (!ReadExact(ns, e, 2)) break; len = (e[0] << 8) | e[1]; }
                    else if (len == 127) { byte[] e = new byte[8]; if (!ReadExact(ns, e, 8)) break; len = 0; for (int i = 0; i < 8; i++) len = (len << 8) | e[i]; }
                    byte[] mask = new byte[4];
                    if (masked && !ReadExact(ns, mask, 4)) break;
                    if (len > 4096) break;
                    byte[] payload = new byte[len];
                    if (len > 0 && !ReadExact(ns, payload, (int)len)) break;
                    if (masked) for (int i = 0; i < payload.Length; i++) payload[i] ^= mask[i & 3];
                    if (op == 8) { try { ns.Write(new byte[] { 0x88, 0 }, 0, 2); } catch { } break; }
                    if (op == 9) { byte[] pong = new byte[2 + payload.Length]; pong[0] = 0x8A; pong[1] = (byte)payload.Length; Buffer.BlockCopy(payload, 0, pong, 2, payload.Length); ns.Write(pong, 0, pong.Length); continue; }
                    if (op != 1) continue;
                    string msg = Encoding.UTF8.GetString(payload);
                    msgCount++;
                    if (msgCount <= 12 && msg.Length > 0 && msg[0] != 'P') Log("iPad message: " + msg);
                    if (msg.Length == 0) continue;
                    if (msg[0] == 'S') OnSensors(msg.Substring(1));
                    else if (msg[0] == 'B') OnExtra(msg.Substring(1));
                    else if (msg[0] == 'P') SendText(ns, "O" + msg.Substring(1));
                }
            }
            catch { }
            finally
            {
                int left = Interlocked.Decrement(ref clients);
                Log("iPad disconnected (" + left + " client(s) left)");
                if (left == 0) ReleaseAll();
            }
        }
    }
}
