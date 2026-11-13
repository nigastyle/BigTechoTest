# Охлаждение по кривой: покой 20 с -> нагрузка на все потоки 120 с -> остывание 90 с (замер раз в секунду).
# Считаем постоянную времени нагрева, установившийся нагрев, тепловое сопротивление °C/Вт и полупериод остывания.
$STEPKEYS['Охлаждение: кривая нагрева и остывания'] = 'coolcurve'
Step 'Охлаждение: кривая нагрева и остывания' {
    $s = New-Section 'Охлаждение: кривая нагрева и остывания'
    if (-not $G.CoreOk) { Add-Row $s 'Тест' 'модуль нагрузки не загрузился' 'warn'; return }
    $k0 = Read-Key
    if ($null -eq $k0.CpuTemp) { Add-Row $s 'Тест' 'нет датчика температуры процессора — пропущено'; return }
    $fanOf = {
        $mx = $null
        foreach ($x in @(Get-AllSensors)) {
            if ($x.Type -eq 'Fan' -and $null -ne $x.Value -and -not [double]::IsNaN([double]$x.Value) -and [double]$x.Value -gt 0 -and [double]$x.Value -lt 20000) {
                if ($null -eq $mx -or [double]$x.Value -gt $mx) { $mx = [double]$x.Value }
            }
        }
        $mx
    }
    $tIdle = 20; $tLoad = 120; $tCool = 90
    $T = New-Object System.Collections.Generic.List[double]
    $P = New-Object System.Collections.Generic.List[double]
    $F = New-Object System.Collections.Generic.List[double]
    $stopped = $false
    $sample = {
        param($phaseName, $sec)
        $t0 = Get-Date
        for ($i = 1; $i -le $sec; $i++) {
            $t1 = Get-Date
            $k = Read-Key
            $T.Add($(if ($null -ne $k.CpuTemp) { [double]$k.CpuTemp } else { [double]::NaN }))
            $P.Add($(if ($null -ne $k.CpuPower) { [double]$k.CpuPower } else { [double]::NaN }))
            $fv = & $fanOf; $F.Add($(if ($null -ne $fv) { $fv } else { [double]::NaN }))
            Write-Host -NoNewline ("`r    {0,-10} {1,4} с из {2} | CPU {3} °C | {4} Вт | {5} об/мин   " -f $phaseName, $i, $sec, $(if ($null -ne $k.CpuTemp) { '{0:N0}' -f $k.CpuTemp } else { '—' }), $(if ($null -ne $k.CpuPower) { '{0:N0}' -f $k.CpuPower } else { '—' }), $(if ($null -ne $fv) { '{0:N0}' -f $fv } else { '—' }))
            if (Stop-Requested) { Write-Host ''; return $false }
            $sl = 1000 - [int]((Get-Date) - $t1).TotalMilliseconds
            if ($sl -gt 0) { Start-Sleep -Milliseconds $sl }
        }
        Write-Host ''
        return $true
    }
    Info ('1/3 покой {0} с (исходный уровень)...' -f $tIdle)
    $ok = & $sample 'покой' $tIdle
    $nIdle = $T.Count
    $nLoadEnd = $nIdle
    if ($ok -and -not (Stop-Requested)) {
        $thr = [Environment]::ProcessorCount
        Info ('2/3 нагрузка на все {0} потоков, {1} с...' -f $thr, $tLoad)
        [DiagCore]::Start($thr, $tLoad + 5)
        $ok = & $sample 'нагрузка' $tLoad
        $nLoadEnd = $T.Count
        try { [DiagCore]::Stop() } catch { }
        try { [DiagCore]::Wait() } catch { }
        if ($ok -and -not (Stop-Requested)) {
            Info ('3/3 остывание {0} с...' -f $tCool)
            $ok = & $sample 'остывание' $tCool
        }
    }
    if (-not $ok -or (Stop-Requested)) { Warn 'тест остановлен'; Add-Row $s 'Тест' 'остановлен досрочно — выводы не делаются' 'warn'; return }

    $good = { param($arr, $a, $b) $r = @(); for ($i = $a; $i -lt $b; $i++) { if (-not [double]::IsNaN($arr[$i])) { $r += $arr[$i] } }; ,$r }
    $avgOf = { param($arr) if ((AsArr $arr).Count) { ((AsArr $arr) | Measure-Object -Average).Average } else { $null } }
    $idleT = & $avgOf (& $good $T 5 $nIdle)
    $idleP = & $avgOf (& $good $P 5 $nIdle)
    $idleF = & $avgOf (& $good $F 0 $nIdle)
    $ssT = & $avgOf (& $good $T ($nLoadEnd - 15) $nLoadEnd)
    $ssP = & $avgOf (& $good $P ($nLoadEnd - 15) $nLoadEnd)
    $ssF = & $avgOf (& $good $F ($nLoadEnd - 15) $nLoadEnd)
    if ($null -eq $idleT -or $null -eq $ssT) { Add-Row $s 'Итог' 'датчик температуры не дал данных' 'warn'; return }
    $peakT = ($T[$nIdle..($T.Count - 1)] | Where-Object { -not [double]::IsNaN($_) } | Measure-Object -Maximum).Maximum
    $rise = $ssT - $idleT
    # постоянная времени нагрева: время до 63 % подъёма
    $tau = $null
    if ($rise -ge 8) {
        $goal = $idleT + 0.632 * $rise
        for ($i = $nIdle; $i -lt $nLoadEnd; $i++) { if (-not [double]::IsNaN($T[$i]) -and $T[$i] -ge $goal) { $tau = $i - $nIdle + 1; break } }
    }
    # полупериод остывания от пика
    $half = $null; $halfTxt = '—'
    if ($peakT - $idleT -ge 8) {
        $gh = $peakT - 0.5 * ($peakT - $idleT)
        for ($i = $nLoadEnd; $i -lt $T.Count; $i++) { if (-not [double]::IsNaN($T[$i]) -and $T[$i] -le $gh) { $half = $i - $nLoadEnd + 1; break } }
        $halfTxt = $(if ($null -ne $half) { '{0} с' -f $half } else { 'больше {0} с' -f $tCool })
    }
    $coolEnd = & $avgOf (& $good $T ($T.Count - 5) $T.Count)
    # реакция вентилятора: через сколько секунд обороты выросли на 10 % и 100+ об/мин
    $fanDelay = $null
    if ($null -ne $idleF) {
        for ($i = $nIdle; $i -lt $nLoadEnd; $i++) { if (-not [double]::IsNaN($F[$i]) -and $F[$i] -ge $idleF * 1.10 -and $F[$i] - $idleF -ge 100) { $fanDelay = $i - $nIdle + 1; break } }
    }
    # тепловое сопротивление
    $rth = $null; $dP = $null
    if ($null -ne $ssP -and $null -ne $idleP) { $dP = $ssP - $idleP }
    if ($null -ne $dP -and $dP -ge 15 -and $rise -ge 5) { $rth = $rise / $dP }

    # --- кривая (ASCII): 20 + 120 + 90 = 230 точек -> ~58 знаков, уровни от покоя до пика
    $chars = ' .:-=+*#'.ToCharArray()
    $step = 4; $line = ''
    $lo = ($T | Where-Object { -not [double]::IsNaN($_) } | Measure-Object -Minimum).Minimum
    $span = [math]::Max(1.0, $peakT - $lo)
    for ($i = 0; $i -lt $T.Count; $i += $step) {
        $seg = @(); for ($j = $i; $j -lt [math]::Min($T.Count, $i + $step); $j++) { if (-not [double]::IsNaN($T[$j])) { $seg += $T[$j] } }
        if (-not $seg.Count) { $line += '?'; continue }
        $lv = [int][math]::Round(7 * (($seg | Measure-Object -Average).Average - $lo) / $span)
        if ($lv -lt 0) { $lv = 0 }; if ($lv -gt 7) { $lv = 7 }
        $line += $chars[$lv]
    }
    $mk = ''.PadLeft([int]($nIdle / $step), '_') + '|' + ''.PadLeft([int](($nLoadEnd - $nIdle) / $step) - 1, '_') + '|' + ''.PadLeft([int]($tCool / $step) - 1, '_')
    Add-Row $s 'Кривая температуры' ('[{0}]  от {1:N0} до {2:N0} °C' -f $line, $lo, $peakT)
    Add-Row $s 'Фазы' ('[{0}]  покой | нагрузка 120 с | остывание 90 с (1 знак = {1} с)' -f $mk, $step)

    $coolClass = 'ПК'
    if ($G.IsLaptop) { $coolClass = 'ноутбук' }
    Add-Row $s 'Температура: покой → нагрузка' ('{0:N0} → {1:N0} °C (пик {2:N0}), подъём +{3:N0} °C' -f $idleT, $ssT, $peakT, $rise)
    Add-Row $s 'Мощность процессора' $(if ($null -ne $ssP) { 'покой {0} Вт, нагрузка {1:N0} Вт' -f $(if ($null -ne $idleP) { '{0:N0}' -f $idleP } else { '—' }), $ssP } else { 'датчик мощности недоступен' })
    Add-Row $s 'Постоянная времени нагрева' $(if ($null -ne $tau) { '{0} с (до 63 % подъёма)' -f $tau } else { 'не определена (малый подъём)' })
    Add-Row $s 'Полупериод остывания' $halfTxt
    Add-Row $s 'Температура через 90 с остывания' ('{0:N0} °C (покой был {1:N0})' -f $coolEnd, $idleT)
    Add-Row $s 'Вентилятор: реакция' $(if ($null -ne $idleF) { '{0:N0} → {1:N0} об/мин, разгон за {2}' -f $idleF, $ssF, $(if ($null -ne $fanDelay) { "$fanDelay с" } else { 'обороты не выросли' }) } else { 'датчик оборотов недоступен' })

    $G.Num.cool_rise = [math]::Round($rise, 1)
    if ($null -ne $tau) { $G.Num.cool_tau = $tau }
    if ($null -ne $half) { $G.Num.cool_half = $half }
    $G.Num.cool_tss = [math]::Round($ssT)

    if ($null -eq $rth) {
        Add-Row $s 'Тепловое сопротивление' 'мощность процессора неизвестна или мала — °C/Вт не посчитано'
    } else {
        $G.Num.cool_rth = [math]::Round($rth, 3)
        $ref = $(if ($G.IsLaptop) { 'ноутбук: обычно 0.6–1.5' } else { 'ПК: боксовый кулер 0.35–0.6, башня 0.15–0.3, СЖО 0.1–0.2' })
        $hi = $(if ($G.IsLaptop) { 1.5 } else { 0.6 })
        $st = 'ok'; if ($rth -gt $hi) { $st = 'warn' }
        Add-Row $s 'Тепловое сопротивление' ('{0:N2} °C/Вт (подъём +{1:N0} °C при +{2:N0} Вт); {3}' -f $rth, $rise, $dP, $ref) $st
        if ($rth -gt $hi) {
            Add-Issue 'warn' 'Охлаждение' ('тепловое сопротивление кулера {0:N2} °C/Вт — выше нормы для класса «{1}»' -f $rth, $coolClass) 'Высокое °C/Вт: высохла термопаста, пыль в радиаторе или слабый прижим кулера (проверьте крепление, у СЖО — работу помпы). Почистите, замените пасту.'
        }
    }
    $slowHalf = $(if ($G.IsLaptop) { 50 } else { 40 })
    if ($null -eq $half -and $peakT - $idleT -ge 15) {
        Add-Row $s 'Остывание' ('за {0} с процессор не остыл даже наполовину — радиатор плохо отдаёт тепло' -f $tCool) 'warn'
        Add-Issue 'warn' 'Охлаждение' 'после нагрузки процессор остывает очень медленно' 'Медленное остывание: пыль, высохшая термопаста или слабый прижим кулера. Почистите систему охлаждения и замените пасту.'
    } elseif ($null -ne $half -and $half -gt $slowHalf) {
        Add-Row $s 'Остывание' ('полупериод {0} с (норма до {1} с)' -f $half, $slowHalf) 'warn'
        Add-Issue 'warn' 'Охлаждение' ('медленное остывание процессора: полупериод {0} с' -f $half) 'Пыль / высохшая термопаста / слабый прижим кулера. Почистите, замените пасту.'
    }
    if ($ssT -ge 90) { Add-Issue 'warn' 'Охлаждение' ('под полной нагрузкой процессор держится {0:N0} °C' -f $ssT) 'Слабое охлаждение для этой нагрузки: пыль, паста, прижим кулера, корпусные вентиляторы.' }
    if ($null -ne $fanDelay -and $fanDelay -gt 45) { Add-Row $s 'Вентилятор' ('разгоняется с задержкой {0} с — мягкая кривая в BIOS, процессор успевает перегреться' -f $fanDelay) 'warn' }
    $G.Log.Add(('coolcurve: idle={0:N1} ss={1:N1} peak={2:N1} tau={3} half={4} rth={5} fanDelay={6}' -f $idleT, $ssT, $peakT, $tau, $half, $rth, $fanDelay))
    $best = 'ok'; if ($rth -and $rth -gt $(if ($G.IsLaptop) { 1.5 } else { 0.6 })) { $best = 'warn' }
    Add-Row $s 'Итог' $(if ($best -eq 'ok') { 'охлаждение в пределах нормы для класса' } else { 'охлаждение хуже нормы: паста / пыль / прижим' }) $best
}
