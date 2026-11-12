# Скорость интернета через Speedtest by Ookla (CLI). Основной замер; старый тест в body.ps1 — запасной.
$TOOLS.Speedtest = @{ Url = 'https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-win64.zip'; Sha = '13E3D888B845D301A556419E31F14AB9BFF57E3F06089EF2FD3BDC9BA6841EFA'; Dir = 'Speedtest'; Exe = 'Speedtest\speedtest.exe' }
$STEPKEYS['Сеть: скорость интернета (Speedtest by Ookla)'] = 'net'
$G.SpeedtestOk = $false
$G.SpeedtestResult = $null
Step 'Сеть: скорость интернета (Speedtest by Ookla)' {
    $s = New-Section 'Скорость интернета (Speedtest by Ookla)'
    $exe = Get-Tool 'Speedtest'
    if (-not $exe) { Add-Row $s 'Speedtest' 'не удалось получить утилиту (нет интернета?) — будет использован встроенный упрощённый тест'; return }
    $outF = Join-Path $G.Temp 'speedtest_out.json'
    $errF = Join-Path $G.Temp 'speedtest_err.txt'
    Remove-Item $outF, $errF -Force -ErrorAction SilentlyContinue
    Info 'Замер скорости (до 2 минут)...'
    $p = $null
    try {
        $p = Start-Process $exe -ArgumentList '--accept-license --accept-gdpr -f json -p no' -PassThru -WindowStyle Hidden -RedirectStandardOutput $outF -RedirectStandardError $errF
        if (-not $p.WaitForExit(120000)) { try { $p.Kill() } catch {}; Add-Row $s 'Speedtest' 'превышено время ожидания (120 с)' 'warn' }
    } catch { Add-Row $s 'Speedtest' ('не удалось запустить: ' + $_.Exception.Message) 'warn'; return }
    $r = $null
    if (Test-Path $outF) {
        $lines = @(Get-Content $outF -Encoding UTF8 -ErrorAction SilentlyContinue | Where-Object { $_ -and $_.Trim().StartsWith('{') })
        for ($i = $lines.Count - 1; $i -ge 0; $i--) {
            $o = $null
            try { $o = $lines[$i] | ConvertFrom-Json -ErrorAction Stop } catch { continue }
            if ($o -and $o.type -eq 'result') { $r = $o; break }
        }
    }
    if (-not $r -or -not $r.download -or -not $r.upload) {
        $why = ''
        if (Test-Path $errF) { $why = ((Get-Content $errF -ErrorAction SilentlyContinue | Select-Object -First 1) -join '') }
        Add-Row $s 'Speedtest' ('замер не удался' + $(if ($why) { ': ' + $why } else { '' }) + ' — будет использован встроенный упрощённый тест') 'warn'
        $G.Log.Add('Speedtest failed: ' + $why)
        return
    }
    $down = [math]::Round([double]$r.download.bandwidth / 125000, 1)
    $up = [math]::Round([double]$r.upload.bandwidth / 125000, 1)
    $ping = $null; $jit = $null; $lo = $null; $hi = $null; $loaded = $null; $loss = $null
    if ($r.ping) { $ping = [double]$r.ping.latency; $jit = [double]$r.ping.jitter; if ($null -ne $r.ping.low) { $lo = [double]$r.ping.low }; if ($null -ne $r.ping.high) { $hi = [double]$r.ping.high } }
    if ($r.download.latency -and $null -ne $r.download.latency.iqm) { $loaded = [double]$r.download.latency.iqm }
    if ($null -ne $r.packetLoss) { $loss = [double]$r.packetLoss }

    Add-Row $s 'Загрузка (скачивание)' ('{0:N1} Мбит/с' -f $down) 'ok'
    Add-Row $s 'Отдача (выгрузка)' ('{0:N1} Мбит/с' -f $up) 'ok'
    if ($null -ne $ping) {
        $pt = '{0:N1} мс' -f $ping
        if ($null -ne $lo -and $null -ne $hi) { $pt += ' (мин {0:N1} / макс {1:N1})' -f $lo, $hi }
        Add-Row $s 'Пинг (в покое)' $pt $(if ($ping -gt 100) { 'warn' } else { 'ok' })
        Add-Row $s 'Джиттер (разброс пинга)' ('{0:N1} мс' -f $jit) $(if ($jit -gt 30) { 'warn' } else { 'ok' })
    }
    if ($null -ne $loaded) { Add-Row $s 'Пинг под нагрузкой (загрузка)' ('{0:N1} мс' -f $loaded) '' }
    if ($null -ne $loss) { Add-Row $s 'Потери пакетов' ('{0:N1} %' -f $loss) $(if ($loss -gt 5) { 'crit' } elseif ($loss -gt 1) { 'warn' } else { 'ok' }) }
    else { Add-Row $s 'Потери пакетов' 'сервер не сообщил' '' }
    if ($r.isp) { Add-Row $s 'Провайдер' "$($r.isp)" }
    if ($r.server) { Add-Row $s 'Сервер теста' ('{0}, {1}' -f $r.server.name, $r.server.location) }
    if ($r.interface -and $r.interface.isVpn) { Add-Row $s 'VPN' 'замер идёт через VPN — скорость может быть ниже реальной' 'warn' }
    if ($r.result -and $r.result.url) { Add-Row $s 'Страница результата' "$($r.result.url)" }

    if ($null -ne $loss -and $loss -gt 1) {
        $sev = 'warn'; if ($loss -gt 5) { $sev = 'crit' }
        Add-Issue $sev 'Сеть' ('потери пакетов {0:N1} %' -f $loss) 'потери пакетов: нестабильное подключение — кабель/роутер/провайдер.'
    }
    if ($null -ne $jit -and $jit -gt 30) {
        Add-Issue 'warn' 'Сеть' ('высокий джиттер {0:N0} мс' -f $jit) 'Пинг сильно «скачет»: проверьте Wi-Fi (сигнал, помехи), по возможности подключитесь кабелем; при кабеле — роутер/провайдер.'
    }
    if ($null -ne $loaded -and $null -ne $ping -and ($loaded - $ping) -gt 100) {
        Add-Issue 'info' 'Сеть' ('под нагрузкой пинг растёт с {0:N0} до {1:N0} мс' -f $ping, $loaded) 'bufferbloat: при загрузке канала растёт пинг — настройте QoS/SQM на роутере.'
    }

    $G.Summary['Интернет'] = '{0:N0} / {1:N0} Мбит/с (загрузка / отдача)' -f $down, $up
    $G.Bench['Интернет: загрузка / отдача (Speedtest)'] = '{0:N0} / {1:N0} Мбит/с' -f $down, $up
    $G.Num.net_down_mbps = $down
    $G.Num.net_up_mbps = $up
    if ($null -ne $ping) { $G.Num.net_ping_ms = $ping; $G.Num.net_jitter_ms = $jit }
    if ($null -ne $loss) { $G.Num.net_loss_pct = $loss }
    $G.SpeedtestResult = [pscustomobject]@{ Down = $down; Up = $up; Ping = $ping; Jitter = $jit; Loss = $loss }
    $G.SpeedtestOk = $true
}
