Option Explicit
Dim shell, folder, powershell, command, showPanel, arg
Set shell = CreateObject("Wscript.Shell")
folder = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName)
powershell = shell.ExpandEnvironmentStrings("%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe")
showPanel = True
For Each arg In WScript.Arguments
  If LCase(arg) = "--background" Then showPanel = False
Next
command = """" & powershell & """ -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & folder & "\scripts\start.ps1"""
If showPanel Then command = command & " -Show"
shell.Run command, 0, False
