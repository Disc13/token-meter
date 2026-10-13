param()
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'startup.ps1')
$exe='C:\Windows\System32\wscript.exe'
foreach ($project in @('D:\token-meter', 'D:\Apps with spaces\token-meter')) {
  $command=Get-TokenMeterStartupCommand $project $exe
  $expected='"'+$exe+'" //B //Nologo "'+$project+'\token-meter.vbs" --background'
  if ($command -cne $expected) { throw "Unexpected command: $command" }
  if ($command.Contains('-Show') -or $command.Contains('powershell.exe') -or $command.Contains('cmd.exe') -or $command.Contains('cscript.exe')) { throw 'Run must use a GUI host and not open a console or panel.' }
}
$rejected=$false
try { Get-TokenMeterStartupCommand ('D:\'+('x'*240)) $exe | Out-Null } catch { $rejected=$true }
if (-not $rejected) { throw 'Run commands above 260 characters must be rejected.' }
$rejected=$false
try { Get-TokenMeterStartupCommand 'D:\bad"path' $exe | Out-Null } catch { $rejected=$true }
if (-not $rejected) { throw 'Quoted paths must be rejected.' }
$project=Split-Path -Parent $PSScriptRoot
$scripts=@(Join-Path $project 'tray.ps1') + @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' | ForEach-Object FullName)
foreach ($path in $scripts) {
  $errors=$null; $tokens=$null
  [Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors) | Out-Null
  if ($errors.Count) { throw ($errors | Out-String) }
}

# Test actual native compilation without globally suppressing warnings/errors.
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $project 'tray.ps1'),[ref]$null,[ref]$null)
$compile=$ast.Find({param($item) $item -is [Management.Automation.Language.CommandAst] -and $item.GetCommandName() -eq 'Add-Type' -and $item.Extent.Text.Contains('public class AcrylicForm')},$true)
$warnings=@()
Add-Type -ReferencedAssemblies System.Windows.Forms,System.Drawing -TypeDefinition $compile.CommandElements[-1].Value -WarningVariable warnings
if ($warnings.Count) { throw ('Native form emitted warnings: '+($warnings | Out-String)) }
if (-not [AcrylicForm].GetMethod('RefreshNativeFrame')) { throw 'Native frame configuration must be public.' }

# CreateNoWindow must prevent console allocation, not just hide it afterwards.
$probe=@'
Add-Type -Name ConsoleProbe -Namespace TokenMeterTests -MemberDefinition '[System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern System.IntPtr GetConsoleWindow();'
[TokenMeterTests.ConsoleProbe]::GetConsoleWindow().ToInt64()
[Console]::Error.WriteLine('stderr-capture-check')
exit 7
'@
$encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($probe))
$powershell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$info=New-TokenMeterProcessStartInfo $powershell ('-NoProfile -STA -EncodedCommand '+$encoded) $project -CaptureOutput
if ($info.UseShellExecute -or -not $info.CreateNoWindow -or -not $info.RedirectStandardOutput -or -not $info.RedirectStandardError) { throw 'Silent process settings are invalid.' }
$child=New-Object Diagnostics.Process
$child.StartInfo=$info
try {
  if (-not $child.Start()) { throw 'Console probe failed to start.' }
  $stdout=$child.StandardOutput.ReadToEndAsync();$stderr=$child.StandardError.ReadToEndAsync()
  if (-not $child.WaitForExit(10000)) { $child.Kill(); throw 'Console probe timed out.' }
  if ($stdout.Result.Trim() -ne '0') { throw 'Child allocated a console.' }
  if ($child.ExitCode -ne 7 -or -not $stderr.Result.Contains('stderr-capture-check')) { throw 'Silent mode lost exit status or diagnostic output.' }
} finally { $child.Dispose() }
Write-Output 'PASS: GUI-host startup, quoting, length limit, PowerShell syntax, warning-free native form, and no-console child with captured errors.'
