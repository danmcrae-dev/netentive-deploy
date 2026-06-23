# Creates a Windows scheduled task that runs netentive-start.sh in WSL on login
$action = New-ScheduledTaskAction -Execute "wsl" -Argument "-e bash $env:USERPROFILE\netentive\netentive-start.sh"
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName "NetentiveAutoStart" -Action $action -Trigger $trigger -Settings $settings -Force
Write-Host "Auto-start installed — Netentive will start when you log into Windows"