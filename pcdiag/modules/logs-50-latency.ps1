# Задержки DPC/ISR: драйверы, которые «душат» процессор прерываниями (хрипы звука, фризы).
# Данные берутся из WMI (Win32_PerfFormattedData_Counters_ProcessorInformation) — не зависит от языка Windows.
$STEPKEYS['Система: задержки DPC/ISR (звук, фризы)'] = 'logs'
Step 'Система: задержки DPC/ISR (звук, фризы)' {
    $s = New-Section 'Задержки DPC/ISR (звук, фризы)'
    $cls = 'Win32_PerfFormattedData_Counters_ProcessorInformation'
    $probe = @(CIM $cls)
    if (-not $probe.Count) { Add-Row $s 'DPC/ISR' 'счётчики производительности недоступны на этом ПК — пропущено'; return }
    $n = 30
    $dpc = New-Object System.Collections.Generic.List[double]
    $isr = New-Object System.Collections.Generic.List[double]
    $dpcQ = New-Object System.Collections.Generic.List[double]
    $intr = New-Object System.Collections.Generic.List[double]
    $coreDpcMax = @{}; $coreIsrMax = @{}
    for ($i = 1; $i -le $n; $i++) {
        $t0 = Get-Date
        $rows = @(CIM $cls)
        foreach ($r in $rows) {
            if ($r.Name -eq '_Total') {
                $dpc.Add([double]$r.PercentDPCTime); $isr.Add([double]$r.PercentInterruptTime)
                $dpcQ.Add([double]$r.DPCsQueuedPersec); $intr.Add([double]$r.InterruptsPersec)
            } elseif ($r.Name -notmatch '_Total$') {
                $k = "$($r.Name)"
                if (-not $coreDpcMax.ContainsKey($k) -or $coreDpcMax[$k] -lt [double]$r.PercentDPCTime) { $coreDpcMax[$k] = [double]$r.PercentDPCTime }
                if (-not $coreIsrMax.ContainsKey($k) -or $coreIsrMax[$k] -lt [double]$r.PercentInterruptTime) { $coreIsrMax[$k] = [double]$r.PercentInterruptTime }
            }
        }
        $dl = $dpc.Count - 1
        if ($dl -ge 0) { Write-Host -NoNewline ("`r    {0,3} с из {1} | DPC {2,5:N1} % | ISR {3,5:N1} %" -f $i, $n, $dpc[$dl], $isr[$dl]) }
        $sl = 1000 - [int]((Get-Date) - $t0).TotalMilliseconds
        if ($sl -gt 0) { Start-Sleep -Milliseconds $sl }
    }
    Write-Host ''
    if ($dpc.Count -lt 5) { Add-Row $s 'DPC/ISR' 'не удалось собрать данные'; return }
    $dAvg = ($dpc | Measure-Object -Average).Average; $dMax = ($dpc | Measure-Object -Maximum).Maximum
    $iAvg = ($isr | Measure-Object -Average).Average; $iMax = ($isr | Measure-Object -Maximum).Maximum
    $qAvg = ($dpcQ | Measure-Object -Average).Average; $qMax = ($dpcQ | Measure-Object -Maximum).Maximum
    $nAvg = ($intr | Measure-Object -Average).Average; $nMax = ($intr | Measure-Object -Maximum).Maximum
    $coreD = 0.0; $coreDn = ''; foreach ($k in $coreDpcMax.Keys) { if ($coreDpcMax[$k] -gt $coreD) { $coreD = $coreDpcMax[$k]; $coreDn = $k } }
    $coreI = 0.0; $coreIn = ''; foreach ($k in $coreIsrMax.Keys) { if ($coreIsrMax[$k] -gt $coreI) { $coreI = $coreIsrMax[$k]; $coreIn = $k } }

    $tbl = @(
        [pscustomobject]@{ 'Показатель' = 'Время в DPC, %'; 'Среднее' = '{0:N2}' -f $dAvg; 'Максимум' = '{0:N2}' -f $dMax; 'Худшее ядро (макс)' = '{0:N1} (ядро {1})' -f $coreD, $coreDn }
        [pscustomobject]@{ 'Показатель' = 'Время в прерываниях (ISR), %'; 'Среднее' = '{0:N2}' -f $iAvg; 'Максимум' = '{0:N2}' -f $iMax; 'Худшее ядро (макс)' = '{0:N1} (ядро {1})' -f $coreI, $coreIn }
        [pscustomobject]@{ 'Показатель' = 'DPC в очереди, /с'; 'Среднее' = '{0:N0}' -f $qAvg; 'Максимум' = '{0:N0}' -f $qMax; 'Худшее ядро (макс)' = '—' }
        [pscustomobject]@{ 'Показатель' = 'Прерываний, /с'; 'Среднее' = '{0:N0}' -f $nAvg; 'Максимум' = '{0:N0}' -f $nMax; 'Худшее ядро (макс)' = '—' }
    )
    Add-Table $s 'Замер за 30 с (в покое обычно меньше 1 %)' $tbl
    $dSt = 'ok'; if ($dAvg -gt 3 -or $dMax -gt 10) { $dSt = 'warn' }
    $iSt = 'ok'; if ($iAvg -gt 3) { $iSt = 'warn' }
    Add-Row $s 'DPC, среднее / максимум' ('{0:N2} % / {1:N1} %' -f $dAvg, $dMax) $dSt
    Add-Row $s 'Прерывания, среднее' ('{0:N2} %' -f $iAvg) $iSt
    $G.Num.dpc_avg_pct = [math]::Round($dAvg, 2)
    $G.Num.dpc_max_pct = [math]::Round($dMax, 1)
    $G.Num.isr_avg_pct = [math]::Round($iAvg, 2)

    if ($dSt -eq 'warn') {
        Add-Issue 'warn' 'Устройства' ('высокое время DPC: в среднем {0:N1} %, пик {1:N1} %' -f $dAvg, $dMax) 'Высокие задержки DPC: возможны хрипы звука, фризы — виноват драйвер (часто сеть/Wi-Fi, звук, видео, USB). Обновите эти драйверы; для поиска виновника — LatencyMon (resplendence.com).'
    }
    if ($iSt -eq 'warn') {
        Add-Issue 'warn' 'Устройства' ('много времени уходит на аппаратные прерывания: {0:N1} %' -f $iAvg) 'Какое-то устройство или драйвер «заваливает» процессор прерываниями (Wi-Fi, USB, звук, контроллер диска). Отключите лишние устройства по одному, обновите драйверы; виновника покажет LatencyMon (resplendence.com).'
    }
    if ($dSt -eq 'ok' -and $iSt -eq 'ok' -and ($coreD -gt 25 -or $coreI -gt 25)) {
        Add-Row $s 'Отдельное ядро' ('ядро {0} кратковременно перегружено DPC/прерываниями (до {1:N0} %)' -f $(if ($coreD -ge $coreI) { $coreDn } else { $coreIn }), [math]::Max($coreD, $coreI)) 'warn'
    }
    if ($dSt -eq 'ok' -and $iSt -eq 'ok') { Add-Row $s 'Вывод' 'задержки в норме' 'ok' }
    else { Add-Row $s 'Как найти виновника' 'утилита LatencyMon (resplendence.com) покажет драйвер с самыми долгими DPC/ISR' }
    Add-Row $s 'Примечание' 'Замер сделан на простаивающей системе; если параллельно что-то работало, цифры могут быть выше.'
}
