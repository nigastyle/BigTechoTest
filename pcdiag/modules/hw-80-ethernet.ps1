# Тест сетевого кабеля (без ключа, быстрый): скорость линка против максимума адаптера, дуплекс, ошибки при 20-с обмене с шлюзом,
# обрывы линка в журнале. Прямых «кабельных диагностик» (TDR) Intel/Realtek через PowerShell/WMI не отдают — не проверяется.
Step 'Сеть: проверка кабеля Ethernet' {
    $s = New-Section 'Сеть: проверка кабеля Ethernet'
    $ads = @()
    try { $ads = @(Get-NetAdapter -Physical -ErrorAction Stop | Where-Object { $_.MediaType -match '802\.3' -or $_.PhysicalMediaType -match '802\.3' }) } catch { }
    if (-not $ads.Count) { Add-Row $s 'Ethernet' 'проводных сетевых адаптеров нет'; return }
    # события обрыва линка за 30 дней
    $flapBy = @{}
    try {
        $evs = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 27, 4201, 4202; StartTime = (Get-Date).AddDays(-30) } -ErrorAction SilentlyContinue)
        foreach ($e in $evs) {
            $pn = "$($e.ProviderName)"
            if ($e.Id -eq 27 -and $pn -notmatch '^(e1|e2|rt|Netwtw|Netwbw|b57|bxnd|nvm|igb|ixg|msk|sk|L1|L2|Atheros|vm|Rt)') { continue }
            if ($pn -match 'Netwtw|Netwbw') { continue }   # Wi-Fi
            if ($e.Id -eq 27 -and "$($e.Message)" -notmatch '(?i)link|disconnect|отключ|разъедин|линк|соедин') { continue }
            if (-not $flapBy.ContainsKey($pn)) { $flapBy[$pn] = 0 }
            $flapBy[$pn]++
        }
    } catch { }
    $flaps = 0; foreach ($v in $flapBy.Values) { $flaps += $v }
    foreach ($a in $ads) {
        $nm = "$($a.Name) ($($a.InterfaceDescription))"
        $up = ("$($a.Status)" -eq 'Up')
        Add-Row $s ("Адаптер: $($a.Name)") "$($a.InterfaceDescription), состояние: $($a.Status)"
        if (-not $up) { continue }
        $bps = 0.0; try { $bps = [double]$a.ReceiveLinkSpeed } catch { }
        if ($bps -le 0) { try { $bps = [double]$a.Speed } catch { } }
        $mbps = $bps / 1e6
        # максимум скорости адаптера: допустимые значения *SpeedDuplex, иначе по названию
        $maxM = 0.0
        try {
            $sd = Get-NetAdapterAdvancedProperty -Name $a.Name -RegistryKeyword '*SpeedDuplex' -ErrorAction Stop
            foreach ($d in (AsArr $sd.ValidDisplayValues)) {
                $m = [regex]::Match("$d", '(?i)(\d+(?:[.,]\d+)?)\s*(Gbps|Gb|G|Mbps|Mb)')
                if ($m.Success) {
                    $n = [double]::Parse(($m.Groups[1].Value -replace ',', '.'), $IC)
                    if ($m.Groups[2].Value -match '(?i)^G') { $n = $n * 1000 }
                    if ($n -gt $maxM) { $maxM = $n }
                }
            }
        } catch { }
        $desc = "$($a.InterfaceDescription)"
        if ($maxM -lt 1000 -and $desc -match '(?i)gigabit|\bGbE\b|GBE|1000|I2[12]\d|I219|I211|RTL81(68|11)|Killer E2') { $maxM = [math]::Max($maxM, 1000) }
        if ($desc -match '(?i)2\.5\s*G|2500|I225|I226|RTL8125') { $maxM = [math]::Max($maxM, 2500) }
        if ($desc -match '(?i)10\s*G(b|igabit)|X5\d\d|AQC|RTL8127') { $maxM = [math]::Max($maxM, 10000) }
        $dup = if ($a.FullDuplex -eq $true) { 'полный' } elseif ($a.FullDuplex -eq $false) { 'ПОЛУдуплекс' } else { '—' }
        Add-Row $s '  Скорость / дуплекс' ('{0:N0} Мбит/с, {1}{2}' -f $mbps, $dup, $(if ($maxM -gt 0) { ", максимум адаптера ~{0:N0}" -f $maxM } else { '' })) $(if ($a.FullDuplex -eq $false) { 'warn' } else { 'ok' })
        if ($a.FullDuplex -eq $false) { Add-Issue 'warn' 'Сеть' "$($a.Name): полудуплекс" 'Полудуплекс — несовпадение настроек порта или плохой кабель. Поставьте Auto-Negotiation и замените кабель.' }
        if ($maxM -ge 1000 -and $mbps -gt 0 -and $mbps -le 100) {
            Add-Row $s '  Кабель' 'линк только 100 Мбит/с на гигабитном адаптере' 'warn'
            Add-Issue 'warn' 'Сеть' ("$($a.Name): линк {0:N0} Мбит/с вместо {1:N0}" -f $mbps, $maxM) 'Кабель/разъём: работает только 2 пары из 4 — замените кабель (Cat5e+), проверьте обжим и розетку. (Или порт роутера 100 Мбит/с.)'
        } elseif ($maxM -ge 2500 -and $mbps -gt 0 -and $mbps -lt 2500 -and $mbps -ge 1000) {
            Add-Row $s '  Кабель' '1 Гбит/с на адаптере 2.5 Гбит/с — возможно, порт/свитч 1G или кабель Cat5 (нужен Cat5e/6)' ''
        }
        # счётчики ошибок + обмен с шлюзом
        $gw = $null
        try { $gw = (Get-NetRoute -InterfaceIndex $a.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop | Sort-Object RouteMetric | Select-Object -First 1).NextHop } catch { }
        if (-not $gw -or $gw -eq '0.0.0.0') { Add-Row $s '  Шлюз' 'шлюза на этом адаптере нет — обмен не проверялся'; continue }
        $st0 = $null; try { $st0 = Get-NetAdapterStatistics -Name $a.Name -ErrorAction Stop } catch { }
        $pr0 = @(CIM 'Win32_PerfRawData_Tcpip_NetworkInterface') | Where-Object { $_.Name -replace '[^A-Za-z0-9]', '' -eq ($desc -replace '[^A-Za-z0-9]', '') } | Select-Object -First 1
        Info ("обмен с шлюзом $gw, 20 с (200 запросов)...")
        $png = New-Object System.Net.NetworkInformation.Ping
        $rt = New-Object System.Collections.Generic.List[double]; $lost = 0
        for ($i = 1; $i -le 200; $i++) {
            $t1 = Get-Date
            $r = $null; try { $r = $png.Send($gw, 500) } catch { }
            if ($r -and $r.Status -eq 'Success') { $rt.Add([double]$r.RoundtripTime) } else { $lost++ }
            if ($i % 10 -eq 0) { Write-Host -NoNewline ("`r    {0,3} из 200 | потери {1}   " -f $i, $lost) }
            if (Stop-Requested) { break }
            $sl = 100 - [int]((Get-Date) - $t1).TotalMilliseconds
            if ($sl -gt 0) { Start-Sleep -Milliseconds $sl }
        }
        Write-Host ''
        $sent = $i; if ($sent -gt 200) { $sent = 200 }
        $loss = 100.0 * $lost / [math]::Max(1, $sent)
        $avg = $null; $jit = $null
        if ($rt.Count -ge 2) {
            $avg = ($rt | Measure-Object -Average).Average
            $dsum = 0.0; for ($j = 1; $j -lt $rt.Count; $j++) { $dsum += [math]::Abs($rt[$j] - $rt[$j - 1]) }
            $jit = $dsum / ($rt.Count - 1)
        }
        $lst = 'ok'; if ($loss -ge 5) { $lst = 'crit' } elseif ($loss -ge 1) { $lst = 'warn' }
        Add-Row $s '  Потери / задержка до шлюза' ('{0:N1} % потерь ({1} из {2}), среднее {3}, джиттер {4}' -f $loss, $lost, $sent, $(if ($null -ne $avg) { '{0:N1} мс' -f $avg } else { '—' }), $(if ($null -ne $jit) { '{0:N1} мс' -f $jit } else { '—' })) $lst
        $errs = 0; $errTxt = 'счётчики недоступны'
        $st1 = $null; try { $st1 = Get-NetAdapterStatistics -Name $a.Name -ErrorAction Stop } catch { }
        if ($st0 -and $st1) {
            $re = [double]$st1.ReceivedPacketErrors - [double]$st0.ReceivedPacketErrors
            $rd = [double]$st1.ReceivedDiscardedPackets - [double]$st0.ReceivedDiscardedPackets
            $oe = [double]$st1.OutboundPacketErrors - [double]$st0.OutboundPacketErrors
            $errs = $re + $oe
            $errTxt = 'за тест: ошибок приёма {0:N0}, отброшено {1:N0}, ошибок отправки {2:N0}; всего с загрузки: {3:N0} / {4:N0} / {5:N0}' -f $re, $rd, $oe, $st1.ReceivedPacketErrors, $st1.ReceivedDiscardedPackets, $st1.OutboundPacketErrors
        }
        $pr1 = @(CIM 'Win32_PerfRawData_Tcpip_NetworkInterface') | Where-Object { $_.Name -replace '[^A-Za-z0-9]', '' -eq ($desc -replace '[^A-Za-z0-9]', '') } | Select-Object -First 1
        if ($pr0 -and $pr1) { $pe = [double]$pr1.PacketsReceivedErrors - [double]$pr0.PacketsReceivedErrors; $errTxt += '; PerfRaw ошибок приёма за тест: {0:N0}' -f $pe; $errs += $pe }
        $tot = 0.0; if ($st1) { $tot = [double]$st1.ReceivedPacketErrors + [double]$st1.OutboundPacketErrors }
        $est = 'ok'; if ($errs -gt 0) { $est = 'warn' } elseif ($tot -gt 1000) { $est = 'warn' }
        Add-Row $s '  Ошибки пакетов' $errTxt $est
        if ($loss -ge 1 -or $errs -gt 0) {
            Add-Issue 'warn' 'Сеть' ("$($a.Name): потери до шлюза {0:N1} %, ошибок пакетов за тест {1:N0}" -f $loss, $errs) 'Плохой кабель/разъём/порт: замените патч-корд (Cat5e+), проверьте обжим и розетку, попробуйте другой порт роутера.'
        }
        $G.Num.eth_loss = [math]::Round($loss, 1)
        # EEE / Green Ethernet при обрывах
        $eee = @()
        foreach ($kw in '*EEE', 'EEELinkAdvertisement', 'EnableGreenEthernet', 'GreenEthernet', 'AdvancedEEE', 'EEE') {
            try { $p = Get-NetAdapterAdvancedProperty -Name $a.Name -RegistryKeyword $kw -ErrorAction Stop; if ($p -and "$($p.DisplayValue)" -match '(?i)enab|вкл|on|1') { $eee += "$($p.DisplayName)" } } catch { }
        }
        if ($eee.Count) {
            $hint = $(if ($flaps -ge 2 -or $loss -ge 1) { 'ВКЛЮЧЕНО и есть обрывы/потери — отключите в свойствах адаптера (Дополнительно)' } else { 'включено (при обрывах линка отключите)' })
            Add-Row $s '  Энергосбережение Ethernet' (($eee -join ', ') + ': ' + $hint) $(if ($flaps -ge 2 -or $loss -ge 1) { 'warn' } else { '' })
        }
    }
    $fs = 'ok'; if ($flaps -ge 5) { $fs = 'crit' } elseif ($flaps -ge 2) { $fs = 'warn' }
    $det = ''; if ($flaps) { $det = ' (' + (($flapBy.Keys | ForEach-Object { "$_ : $($flapBy[$_])" }) -join ', ') + ')' }
    Add-Row $s 'Обрывы линка за 30 дней' ("$flaps$det") $fs
    if ($flaps -ge 2) { Add-Issue 'warn' 'Сеть' "обрывы проводного линка за 30 дней: $flaps" 'Кабель/разъём/порт роутера или энергосбережение адаптера (EEE/Green Ethernet): замените кабель, отключите EEE.' }
    $G.Num.eth_flaps = $flaps
    Add-Row $s 'Диагностика кабеля (TDR)' 'встроенная диагностика Intel/Realtek через PowerShell/WMI недоступна — длина и обрыв пар не измеряются'
}
