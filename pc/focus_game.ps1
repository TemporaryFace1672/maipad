param(
  [switch]$Keep,            # VR mode: keep the game focused for as long as it runs
  [int]$BootSeconds = 100,  # keyboard mode: keep pulling focus to the game for this long after its window appears
  [int]$WaitSeconds = 240   # give up if the game window never appears
)

# maimai only reads the ring/select buttons while its window has real keyboard focus (posted or
# unfocused key presses are ignored). Windows usually does not give focus to a window started from a
# batch file, and MaiDXR/VR can take it away later, so this puts the game window in front and,
# depending on the mode, keeps it there. It never reads or logs any keystrokes.

$log = Join-Path $PSScriptRoot 'focus_game.log'
function Log($m) { try { Add-Content -Path $log -Value ("{0:HH:mm:ss.fff}  {1}" -f (Get-Date), $m) } catch { } }
Set-Content -Path $log -Value ''
Log ("start  keep={0}  bootSeconds={1}" -f $Keep.IsPresent, $BootSeconds)

Add-Type @"
using System; using System.Text; using System.Diagnostics; using System.Runtime.InteropServices;
public class FocusGame {
  delegate bool EP(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumWindows(EP p, IntPtr l);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] static extern bool AttachThreadInput(uint a, uint b, bool f);
  [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();

  public static IntPtr FindGame() {
    IntPtr found = IntPtr.Zero;
    EnumWindows(delegate(IntPtr h, IntPtr l) {
      if (!IsWindowVisible(h)) return true;
      StringBuilder sb = new StringBuilder(256); GetWindowText(h, sb, 256);
      if (sb.ToString() != "Sinmai") return true;
      uint pid; GetWindowThreadProcessId(h, out pid);
      try { if (!string.Equals(Process.GetProcessById((int)pid).ProcessName, "Sinmai", StringComparison.OrdinalIgnoreCase)) return true; } catch { return true; }
      found = h; return false;
    }, IntPtr.Zero);
    return found;
  }

  public static bool Focus(IntPtr game) {
    if (IsIconic(game)) ShowWindow(game, 9);
    uint pid; uint ft = GetWindowThreadProcessId(GetForegroundWindow(), out pid);
    uint me = GetCurrentThreadId();
    AttachThreadInput(me, ft, true);
    BringWindowToTop(game);
    bool ok = SetForegroundWindow(game);
    AttachThreadInput(me, ft, false);
    return ok;
  }
}
"@

$game = [IntPtr]::Zero
$deadline = (Get-Date).AddSeconds($WaitSeconds)
while ((Get-Date) -lt $deadline) {
  $game = [FocusGame]::FindGame()
  if ($game -ne [IntPtr]::Zero) { break }
  Start-Sleep -Milliseconds 500
}
if ($game -eq [IntPtr]::Zero) { Log 'game window never appeared, exiting'; return }
Log 'game window found'

$seen = Get-Date
$takes = 0
while ($true) {
  if (-not (Get-Process Sinmai -ErrorAction SilentlyContinue)) { Log 'game exited, stopping'; break }
  if (-not $Keep -and ((Get-Date) - $seen).TotalSeconds -gt $BootSeconds) { Log 'boot period over, stopping'; break }
  $g = [FocusGame]::FindGame()
  if ($g -ne [IntPtr]::Zero -and [FocusGame]::GetForegroundWindow() -ne $g) {
    $ok = [FocusGame]::Focus($g)
    $takes++
    if ($takes -le 15) { Log ("focused the game window (ok={0})" -f $ok) }
  }
  Start-Sleep -Milliseconds 300
}
Log ("finished, focus taken {0} times" -f $takes)
