$ErrorActionPreference = "Stop"

$distro = $env:KT68_DISTRO
$script = $env:KT68_SCRIPT
$user = $env:KT68_USER
if (-not $distro -or -not $script -or -not $user) {
    throw "missing KT68_DISTRO, KT68_SCRIPT or KT68_USER"
}

$action = New-ScheduledTaskAction -Execute "wsl.exe" -Argument "-d `"$distro`" -e $script"
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -Hidden
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName "KT68Clock" -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
Start-ScheduledTask -TaskName "KT68Clock"
Write-Output "KT68Clock ativo para $user"
