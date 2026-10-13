# Token Meter tray: native shell with a single WebView2 panel.
param([string]$NodePath, [switch]$Show, [switch]$Verify, [switch]$VerifyMotion)
. (Join-Path $PSScriptRoot 'scripts\startup.ps1')
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -Path (Join-Path $PSScriptRoot 'native\GlassEffects.cs') -ReferencedAssemblies System.Drawing
Add-Type -Path (Join-Path $PSScriptRoot 'native\ScreenshotGuard.cs')
Add-Type -Name U32 -Namespace U -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr h);
[DllImport("user32.dll")] public static extern System.IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern System.IntPtr GetAncestor(System.IntPtr h, uint gaFlags);
[DllImport("user32.dll")] public static extern bool IsChild(System.IntPtr parent, System.IntPtr child);
[DllImport("user32.dll")] public static extern int SetWindowRgn(System.IntPtr h, System.IntPtr rgn, bool redraw);
[DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);
[DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
[DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr h, out uint pid);
[DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
[DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
[DllImport("gdi32.dll")] public static extern System.IntPtr CreateRoundRectRgn(int l, int t, int r, int b, int rw, int rh);
[DllImport("gdi32.dll")] public static extern System.IntPtr CreateRectRgn(int l, int t, int r, int b);
[DllImport("gdi32.dll")] public static extern bool DeleteObject(System.IntPtr h);
[StructLayout(LayoutKind.Sequential)]
public struct POINT { public int X; public int Y; }
'@
[U.U32]::SetProcessDPIAware() | Out-Null
$_g = [Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
$script:dpi = $_g.DpiX / 96
$_g.Dispose()

$dir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$verifyNative = $Verify
$port = 3080
if ($env:TOKEN_METER_PORT) { $port = [int]$env:TOKEN_METER_PORT }
else {
  $configPath = Join-Path $dir 'config.json'
  if ($env:TOKEN_METER_CONFIG) { $configPath = $env:TOKEN_METER_CONFIG; if (-not [IO.Path]::IsPathRooted($configPath)) { $configPath = Join-Path $dir $configPath } }
  if (Test-Path -LiteralPath $configPath) {
    $startupConfig = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($null -ne $startupConfig.port) { $port = [int]$startupConfig.port }
  }
}
if ($port -lt 1 -or $port -gt 65535) { throw 'Invalid Token Meter port.' }
$showSignal = New-Object Threading.EventWaitHandle($false, [Threading.EventResetMode]::AutoReset, "Local\TokenMeter-Show-$port")
$mutex = New-Object Threading.Mutex($false, "Local\TokenMeter-$port")
if (-not $mutex.WaitOne(0, $false)) {
  if ($Show) { [void]$showSignal.Set() }
  $mutex.Dispose(); $showSignal.Dispose()
  return
}
$readySignal = New-Object Threading.EventWaitHandle($false, [Threading.EventResetMode]::ManualReset, "Local\TokenMeter-Ready-$port")
[void]$readySignal.Reset()
$script:baseW = 380
$script:baseH = 680
$script:scale = 1.0
$script:glass = 0.8
$script:blur = 50
$cfgPath = Join-Path $dir 'ui-settings.json'
if (Test-Path -LiteralPath $cfgPath) {
  try {
    $cfg = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($cfg.scale) { $script:scale = [Math]::Min(1.4, [Math]::Max(0.8, [double]$cfg.scale)) }
    if ($cfg.glass) { $script:glass = [Math]::Min(0.9, [Math]::Max(0.15, [double]$cfg.glass)) }
    if ($null -ne $cfg.blur) { $script:blur = [int][Math]::Round([Math]::Min(100.0, [Math]::Max(0.0, [double]$cfg.blur))) }
  } catch {}
}

$sdk = Join-Path $dir 'lib\webview2\pkg'
$native = Join-Path $sdk 'runtimes\win-x64\native'
Add-Type -Path (Join-Path $sdk 'lib\net462\Microsoft.Web.WebView2.Core.dll')
Add-Type -Path (Join-Path $sdk 'lib\net462\Microsoft.Web.WebView2.WinForms.dll')
[Microsoft.Web.WebView2.Core.CoreWebView2Environment]::SetLoaderDllFolderPath($native)
try { [Microsoft.Web.WebView2.Core.CoreWebView2Environment]::GetAvailableBrowserVersionString($null) | Out-Null }
catch { throw 'WebView2 Runtime is missing. Install Microsoft Evergreen WebView2 Runtime, then rerun scripts\setup.ps1.' }
Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;
public class AcrylicForm : Form {
  [DllImport("dwmapi.dll")]
  static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int attrValue, int attrSize);
  [DllImport("dwmapi.dll")]
  static extern int DwmExtendFrameIntoClientArea(IntPtr hwnd, ref MARGINS m);
  [StructLayout(LayoutKind.Sequential)]
  struct MARGINS { public int l, r, t, b; }
  protected override void OnHandleCreated(EventArgs e) {
    base.OnHandleCreated(e);
    RefreshNativeFrame();
  }
  public void RefreshNativeFrame() {
    int dark = 1;
    DwmSetWindowAttribute(Handle, 20, ref dark, 4);
    int pref = 1;
    DwmSetWindowAttribute(Handle, 33, ref pref, 4);
  }
  protected override void OnPaintBackground(PaintEventArgs e) { }
}
'@

function Test-Server {
  try { (New-Object Net.Sockets.TcpClient('127.0.0.1', $port)).Close(); $true } catch { $false }
}
$script:node = $null
if (-not (Test-Server)) {
  $nodeExecutable = if ($NodePath) { $NodePath } else { (Get-Command node.exe -ErrorAction Stop).Source }
  $script:node = New-Object Diagnostics.Process
  $script:node.StartInfo = New-TokenMeterProcessStartInfo $nodeExecutable 'server.mjs' $dir
  if (-not $script:node.Start()) { throw 'Token Meter server could not be started.' }
  for ($i = 0; $i -lt 40 -and -not (Test-Server); $i++) { Start-Sleep -Milliseconds 300 }
  if (-not (Test-Server)) { throw 'Token Meter server did not start. Check Node.js and config.json.' }
}

$form = New-Object AcrylicForm
$form.Text = 'Token Meter'
$form.AutoScaleMode = 'None'
$form.FormBorderStyle = 'None'; $form.ShowInTaskbar = $false
$form.TopMost = $true; $form.StartPosition = 'Manual'
$form.Size = New-Object Drawing.Size([int]($script:baseW * $script:dpi * $script:scale), [int]($script:baseH * $script:dpi * $script:scale))
$form.BackColor = [Drawing.Color]::Black
$form.Opacity = 0
$form.KeyPreview = $true
$form.add_KeyDown({ param($s,$e) if ($e.KeyCode -eq 'Escape') { Hide-Panel } })

$script:outsideArmed = $false
$script:mouseWasDown = $false
$script:panelReady = $false
$script:openRequested = $false
$script:reducedMotion = $false
$script:visibilityProgress = 0.0
$script:motionSamples = New-Object 'Collections.Generic.List[object]'
function Hide-Panel {
  if (-not $script:openRequested) { return }
  $script:openRequested = $false
  $script:outsideArmed = $false
  if (-not $script:panelReady) { $form.Hide(); $script:captureGuard.Resume(); return }
  Start-PanelMotion 0
}
function Test-OurWindow([IntPtr]$h) {
  if ($h -eq [IntPtr]::Zero) { return $false }
  $root = [U.U32]::GetAncestor($h, 2)
  return ($h -eq $form.Handle) -or ($root -eq $form.Handle) -or [U.U32]::IsChild($form.Handle, $h)
}
$focusTimer = New-Object Windows.Forms.Timer
$focusTimer.Interval = 50
$focusTimer.add_Tick({
  $script:captureGuard.PollAutomatic()
  if ($VerifyMotion) { return } # Keep synthetic open/close tests independent of outside clicks.
  if (-not $script:openRequested -or -not $script:panelReady -or -not $form.Visible -or -not $form.IsHandleCreated) { $script:outsideArmed = $false; $script:mouseWasDown = $false; return }
  $down = ([U.U32]::GetAsyncKeyState(0x01) -band 0x8000) -ne 0
  if (-not $script:outsideArmed) {
    if (-not $down) { $script:outsideArmed = $true }
    $script:mouseWasDown = $down
    return
  }
  if ($down -and -not $script:mouseWasDown) {
    $pt = New-Object U.U32+POINT
    [void][U.U32]::GetCursorPos([ref]$pt)
    $hit = [U.U32]::WindowFromPoint($pt)
    if ($script:captureGuard.Suspended) {
      # The snipping overlay can select anywhere without closing this panel.
      # Auto mode ends with the capture overlay. Manual mode stays explicit.
      if (Test-OurWindow $hit) { $script:captureGuard.Resume(); $script:bgSig = ''; $script:bgNextAt = 0 }
      elseif ($script:captureGuard.CanDismissOutside) { $script:captureGuard.Resume(); Hide-Panel }
    } elseif (-not (Test-OurWindow $hit)) { Hide-Panel }
  }
  $script:mouseWasDown = $down
})
$focusTimer.Start()

$wv = New-Object Microsoft.Web.WebView2.WinForms.WebView2
$wv.Dock = 'Fill'
$wv.DefaultBackgroundColor = [Drawing.Color]::FromArgb(0, 0, 0, 0)
$wv.CreationProperties = New-Object Microsoft.Web.WebView2.WinForms.CoreWebView2CreationProperties
$wv.CreationProperties.UserDataFolder = Join-Path $env:LOCALAPPDATA 'token-meter\webview'
$wv.add_CoreWebView2InitializationCompleted({
  param($s, $e)
  if (-not $e.IsSuccess) {
    [void][Windows.Forms.MessageBox]::Show("WebView2 initialization failed: $($e.InitializationException.Message)", 'Token Meter', 'OK', 'Error')
    [Windows.Forms.Application]::Exit()
    return
  }
  $s.CoreWebView2.Settings.AreDefaultContextMenusEnabled = $false
  $s.CoreWebView2.Settings.AreDevToolsEnabled = $false
  $s.CoreWebView2.Settings.IsWebMessageEnabled = $true
  $s.CoreWebView2.Settings.IsZoomControlEnabled = $false
  $s.CoreWebView2.Settings.IsStatusBarEnabled = $false
  $s.CoreWebView2.add_WebMessageReceived({
    param($sender, $ev)
    try {
      $msg = $ev.WebMessageAsJson | ConvertFrom-Json
      if ($null -ne $msg.scale) { Set-WindowScale ([double]$msg.scale) }
      if ($null -ne $msg.blur) {
        $script:blur = [int][Math]::Round([Math]::Min(100.0, [Math]::Max(0.0, [double]$msg.blur)))
        $script:bgNextAt = 0
      }
      if ($msg.hide -or $msg.quit) { Hide-Panel }
      if ($null -ne $msg.reducedMotion) { $script:reducedMotion = [bool]$msg.reducedMotion }
      if ($msg.ready) {
        $script:panelReady = $true
        if ($script:openRequested) { Start-PanelMotion 1 }
        try { Update-Backdrop $true } catch {}
        if ($VerifyMotion) { $script:verifyMotionTimer.Start() }
      }
      if ($msg.diagnostics -and $verifyNative) {
        $result = @{ layout=$msg.diagnostics; formVisible=$form.Visible; width=$form.ClientSize.Width; height=$form.ClientSize.Height; dpi=$script:dpi; motion=$script:motionSamples.ToArray(); opacity=$form.Opacity; blur=$script:blur; glassPerformance=$script:bgStats; verificationComplete=(-not $VerifyMotion -or ($script:verifyMotionPhase -ge 4 -and -not $script:motionT.Enabled -and $script:visibilityProgress -eq 1)) }
        [IO.File]::WriteAllText((Join-Path $dir 'native-verification.json'), ($result | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
      }
    } catch {}
  })
  Set-Round
})
$form.Controls.Add($wv)
$script:captureGuard = New-Object ScreenshotGuard($form.Handle)
$wv.add_NavigationCompleted({
  param($s,$e)
  if ($e.IsSuccess -and $verifyNative) {
    [void]$s.CoreWebView2.ExecuteScriptAsync(@'
window.__nativeDiagnostics=function(){var glass=document.querySelector('.glass-image.ready');chrome.webview.postMessage({diagnostics:{ready:document.getElementById('total').textContent,scrolls:Array.from(document.querySelectorAll('*')).filter(function(e){return getComputedStyle(e).overflowY==='auto'&&e.scrollHeight>e.clientHeight+1}).map(function(e){return e.id}),footer:document.querySelector('.footer').getBoundingClientRect().bottom,viewport:innerHeight,devicePixelRatio:devicePixelRatio,glassBlur:glass?getComputedStyle(glass).filter:'none',glassImage:!!glass&&getComputedStyle(glass).backgroundImage!=='none',glassPreblurred:!!glass&&glass.classList.contains('preblurred'),glassLayers:document.querySelectorAll('.glass-image').length,errors:document.getElementById('status').textContent}})};setTimeout(window.__nativeDiagnostics,5500)
'@)
  }
})
$wv.Source = New-Object Uri ("http://127.0.0.1:{0}/panel?embed=1&scale={1}" -f $port, $script:scale)

$script:bgSig = ''
$script:bgTask = $null
$script:bgTaskEpoch = 0
$script:bgNextAt = 0
$script:bgStats = @{ captured=0; published=0; unchanged=0; discarded=0; errors=0; maxWorkerMs=0.0; maxUiMs=0.0; totalUiMs=0.0; uiCalls=0; uiThread=[Threading.Thread]::CurrentThread.ManagedThreadId; workerThread=0 }
function Set-CaptureExclude([bool]$on) {
  $script:captureGuard.SetExcluded($on)
}
function Push-BackdropImage([string]$dataUrl) {
  if (-not $wv.CoreWebView2) { return }
  # The worker constructs JPEG base64, whose alphabet contains no JS quotes.
  # Avoid serializing image-sized strings with PowerShell's JSON serializer.
  $js = "if(window.__paintBg)window.__paintBg('$dataUrl',true);"
  [void]$wv.CoreWebView2.ExecuteScriptAsync($js)
}
function Update-Backdrop([bool]$force) {
  if (-not $script:panelReady -or -not $form.Visible -or -not $script:openRequested) { return }
  if ($script:captureGuard.Suspended) { return } # Freeze glass while screenshots include this window.
  $clock = [Diagnostics.Stopwatch]::StartNew()
  try {
    $animating = $script:motionT.Enabled -or $script:resizeT.Enabled
    # Finished frames wait until motion completes; never repaint the glass mid-fold.
    if (-not $animating -and $script:bgTask -and $script:bgTask.IsCompleted) {
      $task = $script:bgTask
      $script:bgTask = $null
      try {
        if ($task.IsFaulted) { throw $task.Exception.GetBaseException() }
        if ($task.IsCanceled) { throw 'Background capture canceled.' }
        $frame = $task.Result
        $script:bgStats.captured++
        $script:bgStats.workerThread = $frame.WorkerThreadId
        $script:bgStats.maxWorkerMs = [Math]::Max($script:bgStats.maxWorkerMs, $frame.WorkMilliseconds)
        if ($script:bgTaskEpoch -ne $script:captureGuard.Epoch -or -not $frame.Bounds.Equals($form.Bounds) -or $frame.BlurStrength -ne $script:blur) { $script:bgStats.discarded++ }
        elseif ($frame.Fingerprint -ne $script:bgSig) {
          Push-BackdropImage $frame.DataUrl
          $script:bgSig = $frame.Fingerprint
          $script:bgStats.presentedBlur = $frame.BlurStrength
          $script:bgStats.published++
        } else { $script:bgStats.unchanged++ }
      } catch { $script:bgStats.errors++; $script:bgStats.lastError = $_.Exception.Message }
      finally { $task.Dispose() }
    }
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    # One in-flight task only. Hidden windows stop, and unchanged frames do not repaint.
    if (-not $script:bgTask -and ($force -or (-not $animating -and $now -ge $script:bgNextAt))) {
      $script:bgTaskEpoch = $script:captureGuard.Epoch
      $script:bgTask = [GlassEffects]::CaptureAsync($form.Bounds, $script:dpi, $script:blur)
      $script:bgNextAt = $now + 200
    }
  } finally {
    $elapsed = $clock.Elapsed.TotalMilliseconds
    $script:bgStats.maxUiMs = [Math]::Max($script:bgStats.maxUiMs, $elapsed)
    $script:bgStats.totalUiMs += $elapsed
    $script:bgStats.uiCalls++
  }
}

function Set-Round {
  if (-not $form.IsHandleCreated) { return }
  # Keep the full WebView viewport stable. Only its native visible region unfolds
  # upward from the fixed bottom edge, so text and glass never scale or reflow.
  $script:visibleHeight = [int][Math]::Round($form.Height * $script:visibilityProgress)
  $script:revealTop = $form.Height - $script:visibleHeight
  if ($script:visibleHeight -eq 0) {
    $hrgn = [U.U32]::CreateRectRgn(0, 0, 0, 0)
  } else {
    $r = [Math]::Min(($script:visibleHeight / 2.0), [Math]::Max(16, [int](28 * $script:dpi * $script:scale)))
    $hrgn = [U.U32]::CreateRoundRectRgn(0, $script:revealTop, ($form.Width + 1), ($form.Height + 1), [int]($r * 2), [int]($r * 2))
  }
  # Windows owns a successfully assigned region; release it only on failure.
  $script:regionApplied = [U.U32]::SetWindowRgn($form.Handle, $hrgn, $true) -ne 0
  if (-not $script:regionApplied) { [void][U.U32]::DeleteObject($hrgn) }
}
$script:resizeT = New-Object Windows.Forms.Timer
$script:resizeT.Interval = 16
$script:resizeClock = New-Object Diagnostics.Stopwatch
$script:resizeT.add_Tick({
  $p = [Math]::Min(1.0, $script:resizeClock.Elapsed.TotalMilliseconds / 360.0)
  $e = 1 - [Math]::Pow(1 - $p, 4)
  $w = [int]($script:fromW + ($script:toW - $script:fromW) * $e)
  $h = [int]($script:fromH + ($script:toH - $script:fromH) * $e)
  $form.SetBounds(($script:anchorRight - $w), ($script:anchorBottom - $h), $w, $h)
  Set-Round
  if ($p -ge 1 -or -not $form.Visible) { $script:resizeT.Stop(); $script:resizeClock.Stop(); $script:restTop = $form.Top }
})
function Set-WindowScale([double]$scale) {
  if ($script:motionT -and $script:motionT.Enabled) {
    $script:motionT.Stop()
    $script:visibilityProgress = if ($script:openRequested) { 1.0 } else { 0.0 }
    $form.Opacity = $script:visibilityProgress
    if (-not $script:openRequested) { $form.Hide(); $script:captureGuard.Resume() }
  }
  $script:scale = [Math]::Max(0.8, [Math]::Min(1.4, $scale))
  $wa = [Windows.Forms.Screen]::FromPoint([Windows.Forms.Cursor]::Position).WorkingArea
  $script:toW = [Math]::Min(($wa.Width - 24), [int]($script:baseW * $script:dpi * $script:scale))
  $script:toH = [Math]::Min(($wa.Height - 24), [int]($script:baseH * $script:dpi * $script:scale))
  $script:anchorRight = $wa.Right - 12
  $script:anchorBottom = $wa.Bottom - 12
  if ($form.Visible) {
    $script:fromW = $form.Width; $script:fromH = $form.Height
    $script:resizeClock.Restart(); $script:resizeT.Start()
  } else {
    $form.SetBounds(($script:anchorRight - $script:toW), ($script:anchorBottom - $script:toH), $script:toW, $script:toH)
    Set-Round
  }
  $script:bgSig = ''
}
$script:motionT = New-Object Windows.Forms.Timer
$script:motionT.Interval = 16
$script:motionClock = New-Object Diagnostics.Stopwatch
function Set-PanelProgress([double]$progress) {
  $script:visibilityProgress = [Math]::Max(0.0, [Math]::Min(1.0, $progress))
  Set-Round
  $form.Opacity = if ($script:visibilityProgress -gt 0) { 1.0 } else { 0.0 }
  if ($verifyNative -and $script:motionSamples.Count -lt 120) {
    $script:motionSamples.Add(@{ progress=$script:visibilityProgress; opacity=$form.Opacity; top=$form.Top; bottom=$form.Bottom; visibleHeight=$script:visibleHeight; revealTop=$script:revealTop; regionApplied=$script:regionApplied; target=$script:motionTo; ms=$script:motionClock.Elapsed.TotalMilliseconds })
  }
}
function Start-PanelMotion([double]$target) {
  $script:motionFrom = $script:visibilityProgress
  $script:motionTo = $target
  $script:motionDuration = [Math]::Max(1.0, (240 * [Math]::Abs($target - $script:motionFrom)))
  $script:motionClock.Restart()
  if ($wv.CoreWebView2) { [void]$wv.CoreWebView2.ExecuteScriptAsync(('document.getElementById("panel").style.pointerEvents="{0}"' -f $(if ($target -eq 1) { 'auto' } else { 'none' }))) }
  $script:motionT.Start()
}
$script:motionT.add_Tick({
  $p = if ($script:reducedMotion) { 1.0 } else { [Math]::Min(1.0, $script:motionClock.Elapsed.TotalMilliseconds / $script:motionDuration) }
  $e = [GlassEffects]::Ease($p)
  Set-PanelProgress ($script:motionFrom + ($script:motionTo - $script:motionFrom) * $e)
  if ($p -ge 1) {
    $script:motionT.Stop(); $script:motionClock.Stop()
    if ($script:motionTo -eq 0) { $form.Hide(); $script:captureGuard.Resume(); Set-CaptureExclude $false }
    else {
      # Do not steal focus from a capture overlay invoked during unfolding.
      if (-not $script:captureGuard.Suspended) { Set-ForegroundForce $form.Handle }
      if ($VerifyMotion -and $script:verifyMotionPhase -ge 4 -and $wv.CoreWebView2) {
        [void]$wv.CoreWebView2.ExecuteScriptAsync('window.__nativeDiagnostics && window.__nativeDiagnostics()')
      }
    }
  }
})
function Set-ForegroundForce([IntPtr]$hwnd) {
  $pidFg = [uint32]0
  $cur = [U.U32]::GetCurrentThreadId()
  $fg = [U.U32]::GetForegroundWindow()
  $fgThread = [U.U32]::GetWindowThreadProcessId($fg, [ref]$pidFg)
  $attached = $false
  if ($fgThread -ne 0 -and $fgThread -ne $cur) {
    $attached = [U.U32]::AttachThreadInput($fgThread, $cur, $true)
  }
  [void][U.U32]::SetForegroundWindow($hwnd)
  $form.Activate()
  if ($attached) { [void][U.U32]::AttachThreadInput($fgThread, $cur, $false) }
}
function Show-Panel {
  if ($script:openRequested) { Hide-Panel; return }
  $script:openRequested = $true
  if (-not $form.Visible) {
    Set-WindowScale $script:scale
    $script:restTop = $form.Top
    Set-PanelProgress 0
  }
  $script:outsideArmed = $false
  $script:mouseWasDown = $true
  $form.Show()
  Set-Round
  Set-CaptureExclude $true
  Set-ForegroundForce $form.Handle
  if ($wv.CoreWebView2) { [void]$wv.CoreWebView2.ExecuteScriptAsync('window.__panelShown && window.__panelShown()') }
  if ($script:panelReady) { Start-PanelMotion 1 }
  try { Update-Backdrop $true } catch {}
}

$iconPath = Join-Path $dir 'assets\token-meter.ico'
$trayIconSize = [int][Math]::Round(16 * $script:dpi)
$icon = New-Object Drawing.Icon($iconPath, $trayIconSize, $trayIconSize)
$form.Icon = $icon

$menu = New-Object Windows.Forms.ContextMenuStrip
$menu.Items.Add('显示面板') | Out-Null
$screenshotItem = $menu.Items.Add('手动截图模式（点回小窗恢复）')
$menu.Items.Add('-') | Out-Null
$menu.Items.Add('退出') | Out-Null
$menu.add_ItemClicked({
  param($s, $e)
  switch ($e.ClickedItem.Text) {
    '显示面板' { Show-Panel }
    '手动截图模式（点回小窗恢复）' {
      if ($script:captureGuard.Suspended) { $script:captureGuard.Resume() }
      else {
        if (-not $script:openRequested) { Show-Panel }
        $script:captureGuard.Suspend()
      }
    }
    '退出' {
      $notify.Visible = $false
      if ($script:node -and -not $script:node.HasExited) { Stop-Process -Id $script:node.Id -Force }
      [Windows.Forms.Application]::Exit()
    }
  }
})

$notify = New-Object Windows.Forms.NotifyIcon
$notify.Icon = $icon
$notify.Text = 'token-meter'
$notify.ContextMenuStrip = $menu
$notify.Visible = $true
[void]$readySignal.Set()
if (Get-Command Write-StartupLog -ErrorAction SilentlyContinue) { Write-StartupLog ('tray ready; screenshot hook='+$script:captureGuard.HookInstalled+' hookError='+$script:captureGuard.HookInstallationError) }
$notify.add_MouseDown({
  param($s, $e)
  if ($e.Button -ne 'Left') { return }
  Show-Panel
})

Set-Round
$live = New-Object Windows.Forms.Timer
$live.Interval = 33
$live.add_Tick({
  $screenshotItem.Checked = $script:captureGuard.Suspended
  try { Update-Backdrop $false } catch {}
})
$live.Start()

$openTimer = New-Object Windows.Forms.Timer
$openTimer.Interval = 100
$openTimer.add_Tick({ if ($showSignal.WaitOne(0)) { if (-not $form.Visible) { Show-Panel } } })
$openTimer.Start()
$script:verifyMotionPhase = 0
$script:verifyMotionTimer = New-Object Windows.Forms.Timer
$script:verifyMotionTimer.Interval = 1400
$script:verifyMotionTimer.add_Tick({
  switch ($script:verifyMotionPhase) {
    0 { Hide-Panel }
    1 { Show-Panel }
    2 { Hide-Panel; $script:verifyMotionTimer.Interval = 80 }
    3 { Show-Panel; $script:verifyMotionTimer.Stop() }
  }
  $script:verifyMotionPhase++
})

if ($Show) { Show-Panel }
[Windows.Forms.Application]::Run()
$notify.Dispose()
$script:captureGuard.Dispose()
$readySignal.Dispose()
$icon.Dispose()
$mutex.ReleaseMutex()
$mutex.Dispose()
$showSignal.Dispose()
