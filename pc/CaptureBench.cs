// CaptureBench: measures how expensive it is to grab the bottom (circle) half of the maimai window and turn it into JPEG frames.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

static class CaptureBench
{
    delegate bool EP(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EP p, IntPtr l);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr h, ref POINT p);
    [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr h);
    [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr h, IntPtr dc);
    [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr h, IntPtr dc, uint flags);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr dc);
    [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleBitmap(IntPtr dc, int w, int h);
    [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr dc, IntPtr o);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr o);
    [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr dc);
    [DllImport("gdi32.dll")] static extern bool BitBlt(IntPtr dst, int x, int y, int w, int h, IntPtr src, int sx, int sy, uint rop);
    [DllImport("gdi32.dll")] static extern bool StretchBlt(IntPtr dst, int x, int y, int w, int h, IntPtr src, int sx, int sy, int sw, int sh, uint rop);
    [DllImport("gdi32.dll")] static extern int SetStretchBltMode(IntPtr dc, int mode);
    [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int L, T, R, B; }
    [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }
    const uint SRCCOPY = 0x00CC0020, CAPTUREBLT = 0x40000000;

    static IntPtr Find(string title)
    {
        IntPtr f = IntPtr.Zero;
        EnumWindows(delegate(IntPtr h, IntPtr l)
        {
            if (!IsWindowVisible(h)) return true;
            StringBuilder sb = new StringBuilder(256); GetWindowText(h, sb, 256);
            if (sb.ToString() == title) { f = h; return false; }
            return true;
        }, IntPtr.Zero);
        return f;
    }

    static string Stats(List<double> v)
    {
        v.Sort();
        double sum = 0; foreach (double d in v) sum += d;
        return string.Format("avg {0:F2} ms  p50 {1:F2}  p95 {2:F2}  max {3:F2}", sum / v.Count, v[v.Count / 2], v[(int)(v.Count * 0.95)], v[v.Count - 1]);
    }

    static ImageCodecInfo Jpeg()
    {
        foreach (ImageCodecInfo c in ImageCodecInfo.GetImageEncoders()) if (c.MimeType == "image/jpeg") return c;
        return null;
    }

    static int Main(string[] args)
    {
        SetProcessDPIAware();
        int outSize = 800, frames = 300, quality = 70;
        string save = null;
        for (int i = 0; i < args.Length; i++)
        {
            if (args[i] == "--size") outSize = int.Parse(args[++i]);
            else if (args[i] == "--frames") frames = int.Parse(args[++i]);
            else if (args[i] == "--quality") quality = int.Parse(args[++i]);
            else if (args[i] == "--save") save = args[++i];
        }
        IntPtr g = Find("Sinmai");
        if (g == IntPtr.Zero) { Console.WriteLine("game window 'Sinmai' not found"); return 1; }
        RECT cr; GetClientRect(g, out cr);
        POINT org = new POINT(); ClientToScreen(g, ref org);
        int cw = cr.R - cr.L, ch = cr.B - cr.T;
        int side = cw;                       // the circle screen is the bottom cw x cw square
        int sy = ch - side;
        Console.WriteLine("client {0}x{1} at screen {2},{3}; capturing bottom square {4}x{4} -> {5}x{5} JPEG q{6}; foreground is game: {7}",
            cw, ch, org.X, org.Y, side, outSize, quality, GetForegroundWindow() == g);

        IntPtr screen = GetDC(IntPtr.Zero);
        IntPtr memFull = CreateCompatibleDC(screen), bmpFull = CreateCompatibleBitmap(screen, side, side);
        SelectObject(memFull, bmpFull);
        IntPtr memSmall = CreateCompatibleDC(screen), bmpSmall = CreateCompatibleBitmap(screen, outSize, outSize);
        SelectObject(memSmall, bmpSmall);

        ImageCodecInfo jpeg = Jpeg();
        EncoderParameters ep = new EncoderParameters(1);
        ep.Param[0] = new EncoderParameter(System.Drawing.Imaging.Encoder.Quality, (long)quality);

        // Method A: BitBlt from the screen (needs game on top), full size then StretchBlt down
        // Method B: StretchBlt straight from the screen into the small bitmap (one step)
        string[] names = { "A screen BitBlt full + StretchBlt(halftone)", "B screen StretchBlt direct (colorOnColor)", "C screen StretchBlt direct (halftone)" };
        for (int mode = 0; mode < 3; mode++)
        {
            List<double> tCap = new List<double>(), tEnc = new List<double>(), tAll = new List<double>();
            long bytes = 0;
            Stopwatch sw = new Stopwatch();
            for (int f = 0; f < frames; f++)
            {
                sw.Restart();
                if (mode == 0)
                {
                    BitBlt(memFull, 0, 0, side, side, screen, org.X, org.Y + sy, SRCCOPY);
                    SetStretchBltMode(memSmall, 4);
                    StretchBlt(memSmall, 0, 0, outSize, outSize, memFull, 0, 0, side, side, SRCCOPY);
                }
                else
                {
                    SetStretchBltMode(memSmall, mode == 1 ? 3 : 4);
                    StretchBlt(memSmall, 0, 0, outSize, outSize, screen, org.X, org.Y + sy, side, side, SRCCOPY);
                }
                double c = sw.Elapsed.TotalMilliseconds;
                using (Bitmap bm = Image.FromHbitmap(bmpSmall))
                using (MemoryStream ms = new MemoryStream(64 * 1024))
                {
                    bm.Save(ms, jpeg, ep);
                    bytes += ms.Length;
                    if (save != null && f == 0) File.WriteAllBytes(save + "_" + mode + ".jpg", ms.ToArray());
                }
                double all = sw.Elapsed.TotalMilliseconds;
                tCap.Add(c); tEnc.Add(all - c); tAll.Add(all);
                // pace roughly at 60 fps so we measure under realistic conditions (game keeps rendering)
                double wait = 16.6 - all; if (wait > 1) Thread.Sleep((int)wait);
            }
            Console.WriteLine("{0}\n   capture+scale: {1}\n   hbitmap+jpeg:  {2}\n   total:         {3}\n   avg frame {4} KB  -> {5:F1} MB/s at 60 fps", names[mode], Stats(tCap), Stats(tEnc), Stats(tAll), bytes / frames / 1024, bytes / (double)frames * 60 / 1048576);
        }
        ReleaseDC(IntPtr.Zero, screen);
        return 0;
    }
}
