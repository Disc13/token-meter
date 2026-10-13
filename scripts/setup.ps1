param([switch]$AutoStart, [switch]$RemoveAutoStart, [switch]$StartNow)
$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'startup.ps1')
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
if ($AutoStart -and $RemoveAutoStart) { throw 'Choose -AutoStart or -RemoveAutoStart, not both.' }
if ($RemoveAutoStart) {
  if ($StartNow) { throw '-StartNow cannot be combined with -RemoveAutoStart.' }
  Remove-ItemProperty -LiteralPath $runKey -Name 'TokenMeter' -ErrorAction SilentlyContinue
  Write-Output 'Token Meter sign-in startup removed for this user.'
  exit 0
}
if (-not [Environment]::Is64BitProcess -or $env:PROCESSOR_ARCHITECTURE -ne 'AMD64') {
  throw 'This tray build requires Windows x64 and 64-bit Windows PowerShell.'
}
$nodeCommand = Get-Command node.exe -ErrorAction SilentlyContinue
$node = if ($nodeCommand) { $nodeCommand.Source } else { Join-Path $env:ProgramFiles 'nodejs\node.exe' }
if (-not (Test-Path -LiteralPath $node)) { throw 'Install Node.js 22.13+ first: https://nodejs.org/' }
$version = & $node -p 'process.versions.node'
if ($LASTEXITCODE -ne 0 -or [version]$version -lt [version]'22.13.0') { throw 'Node.js 22.13+ is required.' }
& $node --no-warnings -e "import('node:sqlite').catch(()=>process.exit(1))"
if ($LASTEXITCODE -ne 0) { throw 'This Node.js build cannot load node:sqlite. Install current Node.js LTS.' }
$port = & $node (Join-Path $project 'config.mjs') --port
if ($LASTEXITCODE -ne 0) { throw 'Invalid configuration. Check config.json or TOKEN_METER_CONFIG before deployment.' }
$sdkVersion = '1.0.4191.47'
$sdkParent = Join-Path $project 'lib\webview2'
$sdk = Join-Path $sdkParent 'pkg'
$required = @('lib\net462\Microsoft.Web.WebView2.Core.dll', 'lib\net462\Microsoft.Web.WebView2.WinForms.dll', 'runtimes\win-x64\native\WebView2Loader.dll')
$sdkReady = $true
foreach ($relative in $required) { if (-not (Test-Path -LiteralPath (Join-Path $sdk $relative))) { $sdkReady = $false } }
if (-not $sdkReady) {
  New-Item -ItemType Directory -Path $sdkParent -Force | Out-Null
  $package = Join-Path $sdkParent "microsoft.web.webview2.$sdkVersion.nupkg"
  $url = "https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2/$sdkVersion/microsoft.web.webview2.$sdkVersion.nupkg"
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  Write-Output "Downloading official Microsoft.Web.WebView2 SDK $sdkVersion..."
  Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $package
  # Pinned SHA512 from the official NuGet catalog for this exact release.
  $expectedHash = 'rfkb2hpx2GDAmM0OQmtaI44Yfqc8aUgy+P3jaAmpFl/aiET8nCufyKhwsNpTzZ65fsFA2aLxBKIoMB/66EHbjA=='
  $hasher = [Security.Cryptography.SHA512]::Create()
  $stream = [IO.File]::OpenRead($package)
  try { $actualHash = [Convert]::ToBase64String($hasher.ComputeHash($stream)) }
  finally { $stream.Dispose(); $hasher.Dispose() }
  if ($actualHash -ne $expectedHash) { throw 'Downloaded SDK checksum mismatch; installation stopped.' }
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  if (Test-Path -LiteralPath $sdk) { throw 'An incomplete SDK folder exists. Repair or remove lib\webview2\pkg, then rerun setup.' }
  [IO.Compression.ZipFile]::ExtractToDirectory($package, $sdk)
}
foreach ($relative in $required) { if (-not (Test-Path -LiteralPath (Join-Path $sdk $relative))) { throw "SDK file missing: $relative" } }
Add-Type -Path (Join-Path $sdk 'lib\net462\Microsoft.Web.WebView2.Core.dll')
[Microsoft.Web.WebView2.Core.CoreWebView2Environment]::SetLoaderDllFolderPath((Join-Path $sdk 'runtimes\win-x64\native'))
try {
  $runtimeVersion = [Microsoft.Web.WebView2.Core.CoreWebView2Environment]::GetAvailableBrowserVersionString($null)
  Write-Output "WebView2 Runtime: $runtimeVersion"
} catch { throw 'Install Microsoft Evergreen WebView2 Runtime: https://developer.microsoft.com/microsoft-edge/webview2/' }
if ($AutoStart -or $StartNow) {
  $scriptHost = Join-Path $env:SystemRoot 'System32\wscript.exe'
  if (-not (Test-Path -LiteralPath $scriptHost) -or -not (Test-Path -LiteralPath (Join-Path $project 'token-meter.vbs'))) { throw 'The silent Windows Script Host launcher is missing.' }
  foreach ($hostKey in @('HKCU:\Software\Microsoft\Windows Script Host\Settings','HKLM:\Software\Microsoft\Windows Script Host\Settings')) {
    if (Test-Path -LiteralPath $hostKey) {
      $hostSettings=Get-ItemProperty -LiteralPath $hostKey
      if ($hostSettings.PSObject.Properties['Enabled'] -and $hostSettings.Enabled -eq 0) { throw 'Windows Script Host is disabled. Enable it before using silent deployment or sign-in startup.' }
    }
  }
}
if ($AutoStart) {
  $command = Get-TokenMeterStartupCommand $project $scriptHost
  if (-not (Test-Path -LiteralPath $runKey)) { New-Item -Path $runKey -Force | Out-Null }
  New-ItemProperty -LiteralPath $runKey -Name 'TokenMeter' -PropertyType String -Value $command -Force | Out-Null
  $approvalKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
  if (Test-Path -LiteralPath $approvalKey) {
    $approval = Get-ItemProperty -LiteralPath $approvalKey -ErrorAction Stop
    if ($approval.PSObject.Properties['TokenMeter']) {
      # Reset only this app's stale disabled state. Do not fabricate undocumented
      # StartupApproved binary records or change any other startup application.
      Remove-ItemProperty -LiteralPath $approvalKey -Name 'TokenMeter' -ErrorAction Stop
    }
  }
  $registered=(Get-ItemProperty -LiteralPath $runKey -Name TokenMeter).TokenMeter
  if ($registered -cne $command) { throw 'Startup registration read-back failed.' }
  Write-Output "Verified sign-in startup command: $registered"
  Write-Output 'Token Meter will start silently at sign-in for this user (tray only, no popup).'
}
if ($StartNow) {
  $arguments='//B //Nologo "'+(Join-Path $project 'token-meter.vbs')+'" --background'
  $ready = New-Object Threading.EventWaitHandle($false, [Threading.EventResetMode]::ManualReset, "Local\TokenMeter-Ready-$port")
  try {
    $launchInfo=New-TokenMeterProcessStartInfo $scriptHost $arguments $project
    $launchProcess=[Diagnostics.Process]::Start($launchInfo)
    $launchProcess.Dispose()
    if (-not $ready.WaitOne(30000)) { throw 'Tray did not become ready within 30 seconds. See %LOCALAPPDATA%\token-meter\startup.log.' }
    Write-Output 'Tray readiness confirmed. See tray (including hidden icons) and %LOCALAPPDATA%\token-meter\startup.log.'
  } finally { $ready.Dispose() }
}
Write-Output 'Ready. Double-click token-meter.vbs to open the tray panel.'
