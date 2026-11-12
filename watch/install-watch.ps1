$d = "$env:USERPROFILE\Documents\PC-Diagnostika-src\watch"
schtasks /delete /tn BTT-Watch /f 2>$null | Out-Null
schtasks /create /tn BTT-Watch /tr "powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$d\btt-watch.ps1`"" /sc onlogon /ru EQ /it /rl highest /f | Out-Null
schtasks /run /tn BTT-Watch | Out-Null
Start-Sleep 4
(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match 'btt-watch' }).Count
