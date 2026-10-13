# Shared, side-effect-free command construction for setup and tests.
function Get-TokenMeterStartupCommand([string]$Project, [string]$ScriptHostPath) {
  $launcher=Join-Path ([IO.Path]::GetFullPath($Project)) 'token-meter.vbs'
  if ($launcher.Contains('"') -or $ScriptHostPath.Contains('"')) { throw 'Invalid quote in startup path.' }
  # wscript is a GUI executable: no console exists before PowerShell can hide it.
  # Reuse the daily launcher, but never show the panel at sign-in.
  $command='"'+$ScriptHostPath+'" //B //Nologo "'+$launcher+'" --background'
  if ($command.Length -gt 260) { throw 'Startup command exceeds Windows Run limit. Move Token Meter to a shorter path and rerun deployment.' }
  return $command
}

function New-TokenMeterProcessStartInfo([string]$FileName, [string]$Arguments, [string]$WorkingDirectory, [switch]$CaptureOutput) {
  $info=New-Object Diagnostics.ProcessStartInfo
  $info.FileName=$FileName
  $info.Arguments=$Arguments
  $info.WorkingDirectory=$WorkingDirectory
  $info.UseShellExecute=$false
  $info.CreateNoWindow=$true
  $info.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
  if ($CaptureOutput) { $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true }
  return $info
}
