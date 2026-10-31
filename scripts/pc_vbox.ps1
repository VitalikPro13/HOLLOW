# Start or stop the Linux VM (VirtualBox "Ubuntu24") on the PC from an SSH session.
# VBoxManage over plain SSH fails with E_ACCESSDENIED because VBoxSVC lives in the
# desktop session, so the command runs there through a one-shot scheduled task.
#
#   pwsh -File pc_vbox.ps1 start|stop
param([Parameter(Mandatory)][ValidateSet('start', 'stop')][string]$Action)
$ErrorActionPreference = 'Stop'

$vbox = 'C:\Program Files\Oracle\VirtualBox\VBoxManage.exe'
$cmd = if ($Action -eq 'start') { 'startvm Ubuntu24 --type headless' } else { 'controlvm Ubuntu24 acpipowerbutton' }
$dir = 'D:\dev\tmp'
New-Item -ItemType Directory -Force $dir | Out-Null
$vbs = Join-Path $dir 'hollow_ci_vbox.vbs'
$task = 'HollowCiVbox'

Set-Content -Encoding ASCII -Path $vbs -Value "CreateObject(""WScript.Shell"").Run """"""$vbox"""" $cmd"", 0, True"
schtasks /create /tn $task /tr "wscript.exe //B //Nologo $vbs" /sc once /st 23:59 /it /f | Out-Null
schtasks /run /tn $task | Out-Null
Start-Sleep -Seconds 5
schtasks /delete /tn $task /f | Out-Null
Remove-Item -Force $vbs -ErrorAction SilentlyContinue
