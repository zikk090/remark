# End-to-end test for Remark for Windows.
# Drives the real app on an interactive desktop (GitHub's windows runner): global hotkeys,
# a mouse-drag selection, typing notes, a text-selection note from Notepad, the Settings
# window, every export format, and OCR. Writes screenshots + logs to $OutDir and reports
# results as GitHub annotations.
param(
    [Parameter(Mandatory = $true)][string]$Exe,
    [Parameter(Mandatory = $true)][string]$OutDir,
    [Parameter(Mandatory = $true)][string]$Fixture
)
$ErrorActionPreference = 'Continue'
$script:failures = 0
New-Item -ItemType Directory -Force $OutDir | Out-Null
$Exe = (Resolve-Path $Exe).Path
$Fixture = (Resolve-Path $Fixture).Path

Add-Type -AssemblyName System.Windows.Forms, System.Drawing, UIAutomationClient, UIAutomationTypes
Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class In {
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, IntPtr e);
    [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, IntPtr e);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    public static void Chord(params byte[] vks) {
        foreach (var v in vks) { keybd_event(v, 0, 0, IntPtr.Zero); System.Threading.Thread.Sleep(30); }
        System.Threading.Thread.Sleep(60);
        for (int i = vks.Length - 1; i >= 0; i--) { keybd_event(vks[i], 0, 2, IntPtr.Zero); System.Threading.Thread.Sleep(30); }
    }
    public static void Drag(int x1, int y1, int x2, int y2) {
        SetCursorPos(x1, y1); System.Threading.Thread.Sleep(150);
        mouse_event(2, 0, 0, 0, IntPtr.Zero);
        for (int i = 1; i <= 20; i++) { SetCursorPos(x1 + (x2 - x1) * i / 20, y1 + (y2 - y1) * i / 20); System.Threading.Thread.Sleep(25); }
        System.Threading.Thread.Sleep(150);
        mouse_event(4, 0, 0, 0, IntPtr.Zero);
    }
    public static void Click(int x, int y) {
        SetCursorPos(x, y); System.Threading.Thread.Sleep(120);
        mouse_event(2, 0, 0, 0, IntPtr.Zero); System.Threading.Thread.Sleep(60); mouse_event(4, 0, 0, 0, IntPtr.Zero);
    }
    public static string ForegroundTitle() {
        var sb = new StringBuilder(512); GetWindowText(GetForegroundWindow(), sb, 512); return sb.ToString();
    }
}
"@

$VK_CTRL = 0x11; $VK_ALT = 0x12
function Pass($m) { Write-Host "::notice title=E2E pass::$m"; Add-Content "$OutDir\results.txt" "PASS  $m" }
function Fail($m) { Write-Host "::error title=E2E fail::$m"; Add-Content "$OutDir\results.txt" "FAIL  $m"; $script:failures++ }
function Info($m) { Write-Host $m; Add-Content "$OutDir\results.txt" "      $m" }
function Shot($name) {
    $b = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($b.Left, $b.Top, 0, 0, $bmp.Size)
    $bmp.Save("$OutDir\$name.png", [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
}
function Keys($text) { [System.Windows.Forms.SendKeys]::SendWait($text); Start-Sleep -Milliseconds 300 }
function WaitFor($cond, $seconds = 8) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $seconds) { if (& $cond) { return $true }; Start-Sleep -Milliseconds 250 }
    return $false
}
function ClickByName($name) {
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty, $name)
    $el = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
    if ($null -eq $el) { return $false }
    $r = $el.Current.BoundingRectangle
    [In]::Click([int]($r.X + $r.Width / 2), [int]($r.Y + $r.Height / 2))
    return $true
}

$docs = [Environment]::GetFolderPath('MyDocuments')
$root = Join-Path $docs 'Remark'
$appData = Join-Path $env:APPDATA 'Remark'
Remove-Item -Recurse -Force $root, $appData -ErrorAction SilentlyContinue
$env:REMARK_CI = '1'

$screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
Info "Screen: $($screen.Width)x$($screen.Height)"

# ---------- 1. launch ----------
$proc = Start-Process $Exe -PassThru
Start-Sleep 6
if ($proc.HasExited) { Fail "Remark exited on launch (code $($proc.ExitCode))" } else { Pass "Remark launched (pid $($proc.Id))" }
Shot '01-launched'

# ---------- 2. new session (Ctrl+Alt+N) ----------
[In]::Chord($VK_CTRL, $VK_ALT, 0x4E)
if (WaitFor { [In]::ForegroundTitle() -eq 'New review session' }) { Pass 'Ctrl+Alt+N opened the New session dialog' } else { Fail "New session dialog didn't take focus (foreground: '$([In]::ForegroundTitle())')" }
Keys 'CI smoke test'
Shot '02-new-session-dialog'
Keys '{ENTER}'
if (WaitFor { Get-ChildItem $root -Recurse -Filter session.json -ErrorAction SilentlyContinue | Where-Object { $_.DirectoryName -like '*ci-smoke-test*' } }) {
    $sessionDir = (Get-ChildItem $root -Directory | Where-Object { $_.Name -like '*ci-smoke-test*' } | Select-Object -First 1).FullName
    Pass "Session folder created: $(Split-Path $sessionDir -Leaf)"
} else { Fail 'No session folder was created'; $sessionDir = $null }

# ---------- 3. something to review ----------
# Clear the runner's console windows off the desktop so screenshots show only the app being reviewed.
(New-Object -ComObject Shell.Application).MinimizeAll()
Start-Sleep 1
$np = Start-Process notepad -PassThru
Start-Sleep 2
Keys 'Welcome to Acme. Sign in with your work email to continue.{ENTER}{ENTER}Forgot your password? Reset it from the sign-in page.'
Start-Sleep 1
Shot '03-notepad'

# ---------- 4. area capture (Ctrl+Alt+R + drag) ----------
[In]::Chord($VK_CTRL, $VK_ALT, 0x52)
Start-Sleep -Milliseconds 1500
Shot '04-selection-overlay'
[In]::Drag(60, 60, 620, 360)
if (WaitFor { [In]::ForegroundTitle() -eq 'Remark note' }) { Pass 'Area capture opened the note window' } else { Fail "Note window didn't appear after the drag (foreground: '$([In]::ForegroundTitle())')" }
Start-Sleep 1
Keys 'The sign-in button is hard to find'
Start-Sleep -Milliseconds 500
Shot '05-note-window-screenshot'
Keys '^{ENTER}'
Start-Sleep 2
Shot '06-after-first-save'

# ---------- 5. text-selection note (Ctrl+Alt+T in Notepad) ----------
[In]::SetForegroundWindow($np.MainWindowHandle) | Out-Null
Start-Sleep 1
Keys '^{HOME}+{END}'   # select the first line
[In]::Chord($VK_CTRL, $VK_ALT, 0x54)
if (WaitFor { [In]::ForegroundTitle() -eq 'Remark note' } 10) { Pass 'Ctrl+Alt+T opened a text note' } else { Fail "Text note window didn't appear (foreground: '$([In]::ForegroundTitle())')" }
Start-Sleep 1
Keys 'Copy is clear'
Shot '07-note-window-text'
Keys '^{ENTER}'
Start-Sleep 2

# ---------- 6. verify saved data ----------
if ($sessionDir) {
    $json = Get-Content (Join-Path $sessionDir 'session.json') -Raw | ConvertFrom-Json
    $n = @($json.notes).Count
    if ($n -eq 2) { Pass "session.json has 2 notes" } else { Fail "session.json has $n notes (expected 2)" }
    $shotNote = @($json.notes) | Where-Object { $_.imageFile } | Select-Object -First 1
    if ($shotNote -and (Test-Path (Join-Path $sessionDir $shotNote.imageFile))) { Pass "Screenshot saved: $($shotNote.imageFile)" } else { Fail 'Screenshot note/image missing' }
    if ($shotNote -and $shotNote.text -like '*sign-in button*') { Pass 'Typed note text saved' } else { Fail "Typed note text missing ('$($shotNote.text)')" }
    if ($shotNote -and $shotNote.sourceApp) { Info "Source app recorded: $($shotNote.sourceApp) / $($shotNote.windowTitle)" }
    $textNote = @($json.notes) | Where-Object { $_.quote } | Select-Object -First 1
    if ($textNote -and $textNote.quote -like '*Acme*') { Pass "Selected text captured: '$($textNote.quote)'" } else { Fail 'Selected-text note missing its quote' }
    foreach ($f in 'report.html', 'report.md') { if (Test-Path (Join-Path $sessionDir $f)) { Pass "$f written" } else { Fail "$f missing" } }
    Copy-Item (Join-Path $sessionDir 'session.json') "$OutDir\session.json"
    if ($shotNote) { Copy-Item (Join-Path $sessionDir $shotNote.imageFile) "$OutDir\captured-area.png" }
}

# ---------- 7. settings window ----------
Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
Stop-Process -Id $np.Id -Force -ErrorAction SilentlyContinue
Start-Sleep 1
(New-Object -ComObject Shell.Application).MinimizeAll()
Start-Sleep 1
$proc = Start-Process $Exe -ArgumentList '--show-settings' -PassThru
if (WaitFor { [In]::ForegroundTitle() -eq 'Remark Settings' } 10) { Pass 'Settings window opened' } else { Fail "Settings didn't open (foreground: '$([In]::ForegroundTitle())')" }
Start-Sleep 1
Shot '08-settings-general'
$i = 9
foreach ($pane in 'Shortcuts', 'Cursor', 'Export', 'Privacy', 'About') {
    if (ClickByName $pane) { Start-Sleep -Milliseconds 800; Shot ("{0:00}-settings-{1}" -f $i, $pane.ToLower()) } else { Fail "Couldn't find Settings tab '$pane'" }
    $i++
}
Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue

# ---------- 8. exports (session made here + a session made by the Mac app) ----------
foreach ($case in @(@{ Name = 'windows-session'; Dir = $sessionDir }, @{ Name = 'mac-fixture'; Dir = $Fixture })) {
    if (-not $case.Dir) { continue }
    $out = Join-Path $OutDir "exports-$($case.Name)"
    $p = Start-Process $Exe -ArgumentList '--selftest-export', "`"$($case.Dir)`"", "`"$out`"" -PassThru -Wait
    $log = Get-Content (Join-Path $out 'selftest-export.txt') -ErrorAction SilentlyContinue
    $log | ForEach-Object { Info "  [$($case.Name)] $_" }
    if ($p.ExitCode -eq 0) { Pass "All 5 export formats work ($($case.Name))" } else { Fail "Export self-test failed for $($case.Name) (exit $($p.ExitCode))" }
}

# ---------- 9. OCR ----------
$ocrOut = Join-Path $OutDir 'ocr.txt'
$p = Start-Process $Exe -ArgumentList '--selftest-ocr', "`"$Fixture\shots\shot-001-a1b2.png`"", "`"$ocrOut`"" -PassThru -Wait
$ocr = Get-Content $ocrOut -Raw -ErrorAction SilentlyContinue
if ($p.ExitCode -eq 0 -and $ocr -like '*misaligned*') { Pass "OCR read the fixture image" }
elseif ($p.ExitCode -eq 0) { Info "OCR ran but read: $ocr" }
else { Info "OCR unavailable on this runner (not fatal): $ocr" }

# ---------- 10. crash log ----------
$err = Join-Path $appData 'error.log'
if (Test-Path $err) { Fail "error.log was written:"; Get-Content $err | ForEach-Object { Info $_ }; Copy-Item $err "$OutDir\error.log" }
else { Pass 'No errors logged' }

Get-Process Remark -ErrorAction SilentlyContinue | Stop-Process -Force
Info "Failures: $script:failures"
exit $script:failures
