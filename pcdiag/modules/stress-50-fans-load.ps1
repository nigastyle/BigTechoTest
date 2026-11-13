# Реакция вентиляторов на нагрузку: 60 с нагрузки на все потоки процессора, сравниваем рост оборотов с ростом температуры.
# Ловит «застывшую» кривую вентиляторов в BIOS, вентилятор без управления (3-pin на PWM-разъёме) и неисправный вентилятор.
$STEPKEYS['Вентиляторы: реакция на нагрузку'] = 'cpu'
Step 'Вентиляторы: реакция на нагрузку' {
    $s = New-Section 'Вентиляторы: реакция на нагрузку'
    if (-not $G.CoreOk) { Add-Row $s 'Тест' 'модуль нагрузки не загрузился' 'warn'; return }
    $isFan = { param($x) $x.Type -eq 'Fan' -and $null -ne $x.Value -and -not [double]::IsNaN([double]$x.Value) -and [double]$x.Value -ge 0 -and [double]$x.Value -lt 20000 }
    $isCtl = { param($x) $x.Type -eq 'Control' -and $null -ne $x.Value -and -not [double]::IsNaN([double]$x.Value) }
    if (-not @(Get-AllSensors | Where-Object { & $isFan $_ }).Count) { Add-Row $s 'Датчики оборотов' 'нет данных — тест пропущен'; return }
    # Даём остыть после предыдущих тестов и снимаем исходные значения (среднее из 3 замеров)
    Info 'пауза 20 с (остывание после предыдущих тестов)...'
    Start-Sleep -Seconds 20
    $base = @{}; $baseC = @{}; $bt = @()
    1..3 | ForEach-Object {
        $k = Read-Key; if ($null -ne $k.CpuTemp) { $bt += [double]$k.CpuTemp }
        foreach ($x in @(Get-AllSensors)) {
            $key = "$($x.Hw)|$($x.Name)"
            if (& $isFan $x) { if (-not $base.ContainsKey($key)) { $base[$key] = @() }; $base[$key] += [double]$x.Value }
            elseif (& $isCtl $x) { if (-not $baseC.ContainsKey($key)) { $baseC[$key] = @() }; $baseC[$key] += [double]$x.Value }
        }
        Start-Sleep -Milliseconds 800
    }
    $t0C = if ($bt.Count) { ($bt | Measure-Object -Average).Average } else { $null }
    $avgOf = { param($a) (@($a) | Measure-Object -Average).Average }
    $fb = @{}; foreach ($kk in $base.Keys) { $fb[$kk] = & $avgOf $base[$kk] }
    $cb = @{}; foreach ($kk in $baseC.Keys) { $cb[$kk] = & $avgOf $baseC[$kk] }
    $fmax = @{}; foreach ($kk in $fb.Keys) { $fmax[$kk] = $fb[$kk] }
    $cmax = @{}; foreach ($kk in $cb.Keys) { $cmax[$kk] = $cb[$kk] }
    $sec = 60; $thr = [Environment]::ProcessorCount
    Info ('нагрузка на все {0} потоков процессора, {1} с — следим за оборотами вентиляторов...' -f $thr, $sec)
    [DiagCore]::Start($thr, $sec)
    $t0 = Get-Date; $tmax = $t0C
    while ([DiagCore]::IsRunning) {
        Start-Sleep -Seconds 3
        $k = Read-Key
        if (Stop-Requested) { Write-Host ''; Warn (Stop-Text); break }
        if ($null -ne $k.CpuTemp -and ($null -eq $tmax -or $k.CpuTemp -gt $tmax)) { $tmax = [double]$k.CpuTemp }
        foreach ($x in @(Get-AllSensors)) {
            $key = "$($x.Hw)|$($x.Name)"
            if (& $isFan $x) { $v = [double]$x.Value; if (-not $fmax.ContainsKey($key) -or $v -gt $fmax[$key]) { $fmax[$key] = $v } }
            elseif (& $isCtl $x) { $v = [double]$x.Value; if (-not $cmax.ContainsKey($key) -or $v -gt $cmax[$key]) { $cmax[$key] = $v } }
        }
        $top = ($fmax.Values | Measure-Object -Maximum).Maximum
        Write-Host -NoNewline ("`r    {0,4:N0} с | CPU {1} °C | макс. обороты {2:N0} об/мин   " -f ((Get-Date) - $t0).TotalSeconds, $(if ($null -ne $k.CpuTemp) { '{0:N0}' -f $k.CpuTemp } else { '—' }), $top)
    }
    Write-Host ''
    [DiagCore]::Wait()
    $rise = if ($null -ne $t0C -and $null -ne $tmax) { $tmax - $t0C } else { $null }
    $rows = @(); $reacted = @(); $deaf = @()
    foreach ($kk in ($fmax.Keys | Sort-Object)) {
        $b = if ($fb.ContainsKey($kk)) { $fb[$kk] } else { 0 }; $m = $fmax[$kk]
        if ($b -le 0 -and $m -le 0) { continue }   # пустой разъём
        $up = ($m -gt $b * 1.10 -and $m - $b -ge 50) -or ($b -le 0 -and $m -ge 300)
        if ($up) { $reacted += $kk }
        $nm = ($kk -split '\|', 2)[1]
        $first = if ($G.FanIdle -and $G.FanIdle.ContainsKey($kk)) { '{0:N0}' -f $G.FanIdle[$kk] } else { '—' }
        # Управление выросло, а обороты нет — вентилятор не слушается (3-pin на PWM-разъёме / неисправен)
        $ck = ("$kk" -replace '(?i)\s*Control', '')
        $cKey = $cmax.Keys | Where-Object { ("$_" -replace '(?i)\s*Control', '') -eq $ck } | Select-Object -First 1
        $cTxt = '—'
        if ($cKey) {
            $c0 = if ($cb.ContainsKey($cKey)) { $cb[$cKey] } else { $null }; $c1 = $cmax[$cKey]
            $cTxt = $(if ($null -ne $c0) { '{0:N0} → {1:N0} %' -f $c0, $c1 } else { '{0:N0} %' -f $c1 })
            if ($null -ne $c0 -and $c1 - $c0 -ge 20 -and -not $up -and $b -gt 0) { $deaf += $nm }
        }
        $rows += [pscustomobject]@{
            'Вентилятор'                = $nm
            'В начале диагностики'      = $first
            'Перед нагрузкой → макс.'   = '{0:N0} → {1:N0} об/мин' -f $b, $m
            'Рост'                      = $(if ($b -gt 0) { '{0:+0;-0;0} %' -f (100 * ($m - $b) / $b) } elseif ($m -gt 0) { 'запустился' } else { '—' })
            'Управление'                = $cTxt
        }
    }
    Add-Table $s 'Обороты: до нагрузки → под нагрузкой' $rows
    Add-Row $s 'Температура процессора' $(if ($null -ne $rise) { '{0:N0} → {1:N0} °C (+{2:N0})' -f $t0C, $tmax, $rise } else { 'датчик недоступен' })
    if (-not $rows.Count) { Add-Row $s 'Итог' 'нет вращающихся вентиляторов с датчиком оборотов'; return }
    if ($null -eq $rise) { Add-Row $s 'Итог' ('реагируют вентиляторов: {0} (без температуры процессора оценить нельзя)' -f $reacted.Count); return }
    $G.Num.fan_react = $reacted.Count
    if ($rise -gt 15 -and -not $reacted.Count) {
        Add-Row $s 'Итог' ('процессор нагрелся на {0:N0} °C, а обороты не выросли' -f $rise) 'warn'
        Add-Issue 'warn' 'Охлаждение' ('вентиляторы не реагируют на нагрузку: процессор +{0:N0} °C, обороты прежние' -f $rise) 'Вентиляторы не реагируют на нагрузку: кривая в BIOS/неисправный вентилятор. Проверьте настройки Smart Fan / Q-Fan в BIOS (режим PWM/DC под тип вентилятора), исправность вентилятора; у ноутбука — фирменную утилиту управления охлаждением.'
    } elseif ($reacted.Count) {
        Add-Row $s 'Итог' ('вентиляторы реагируют на нагрузку ({0})' -f $reacted.Count) 'ok'
    } else {
        Add-Row $s 'Итог' ('температура выросла всего на {0:N0} °C — обороты могли и не меняться' -f $rise)
    }
    foreach ($n in $deaf) { Add-Issue 'info' 'Охлаждение' ('{0}: плата повышает управление, а обороты не растут' -f $n) 'Вентилятор не слушается управления: 3-контактный вентилятор на разъёме в режиме PWM (переключите разъём в DC в BIOS) или вентилятор неисправен.' }
}
