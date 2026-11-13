# Аккумулятор: разряд под типовой смешанной нагрузкой, реальная автономность, признаки износа/калибровки.
# Ключ/пресет и помощники (Get-BatSample, Set-KeepAwake) - в lib-83-battery.ps1.
Step 'Аккумулятор: тест разряда под нагрузкой' {
    $sec = New-Section 'Аккумулятор: тест разряда под нагрузкой'
    if (-not $G.IsLaptop) { Add-Row $sec 'Тест' 'не ноутбук - пропущен' ''; return }
    if ($G.Auto) { Add-Row $sec 'Тест' 'пропущен: требует участия пользователя (отключить и подключить зарядку), автоматический режим' ''; Info 'пропущено в автоматическом режиме'; return }
    if (@(CIM 'Win32_Battery').Count -eq 0) { Add-Row $sec 'Тест' 'аккумулятор не обнаружен' ''; return }
    if (-not $G.CoreOk) { Add-Row $sec 'Тест' 'модуль нагрузки не загрузился' 'warn'; return }
    $min = [int]$G.Sel.batmin; if ($min -lt 3) { $min = 10 }
    $s0 = Get-BatSample
    if (-not $s0 -or $s0.Rem -le 0) { Add-Row $sec 'Тест' 'контроллер батареи не отдаёт ёмкость/мощность (root/wmi BatteryStatus) - тест невозможен' ''; return }
    $full = 0.0; foreach ($f in (CIM 'BatteryFullChargedCapacity' 'root/wmi')) { if ($f.FullChargedCapacity -gt 0) { $full += [double]$f.FullChargedCapacity } }
    $design = 0.0; foreach ($f in (CIM 'BatteryStaticData' 'root/wmi')) { if ($f.DesignedCapacity -gt 0) { $design += [double]$f.DesignedCapacity } }
    if ($full -le 0) { Add-Row $sec 'Тест' 'полная ёмкость не определена (BatteryFullChargedCapacity) - тест невозможен' ''; return }
    $pct0 = [math]::Round($s0.Rem / $full * 100, 0)
    if ($pct0 -lt 30 -or ($null -ne $s0.Pct -and $s0.Pct -lt 30)) { Add-Row $sec 'Тест' ("заряд слишком низкий ({0} %) - сначала зарядите аккумулятор минимум до 30 %" -f $pct0) ''; return }

    if (-not (AskYN ("Тест разряда аккумулятора: нужно будет ОТКЛЮЧИТЬ зарядку на ~{0} мин, ноутбук получит нагрузку и разрядится на несколько процентов. Выполнить?" -f ($min + 1)) 'Y')) { Add-Row $sec 'Тест' 'пропущен по вашему выбору' ''; return }

    # --- ждём отключения зарядки
    Show-Instr 'Тест аккумулятора' 'ОТКЛЮЧИТЕ зарядное устройство от ноутбука и нажмите OK. Программа подождёт отключения до 2 минут.'
    $t0 = Get-Date; $unpl = $false
    while (((Get-Date) - $t0).TotalSeconds -lt 120) {
        $x = Get-BatSample
        if ($x -and -not $x.Online) { $unpl = $true; break }
        Start-Sleep -Seconds 2
    }
    if (-not $unpl) { Add-Row $sec 'Тест' 'зарядка не была отключена за 2 минуты - тест пропущен' 'warn'; return }
    Ok 'работаем от батареи'
    Start-Sleep -Seconds 5

    # --- нагрузка: половина потоков, приоритет ниже обычного, экран включён
    $idle = @(); foreach ($i in 1..3) { $x = Get-BatSample; if ($x) { $idle += $x }; Start-Sleep -Seconds 2 }
    $vIdle = 0.0; $vv = @($idle | Where-Object { $_.Volt -gt 0 } | ForEach-Object { $_.Volt }); if ($vv.Count) { $vIdle = ($vv | Measure-Object -Average).Average }
    $thr = [math]::Max(1, [int][math]::Floor([Environment]::ProcessorCount / 2))
    $secs = $min * 60
    Info ("разряд под нагрузкой: {0} мин, потоков {1} из {2}, экран включён. Тест остановится раньше, если заряд упадёт до 15 %." -f $min, $thr, [Environment]::ProcessorCount)
    $L = New-Object System.Collections.Generic.List[object]
    $L.Add((Get-BatSample))
    $stop = $null; $prio = $null; $replug = $false
    try {
        try { $prio = (Get-Process -Id $PID).PriorityClass; (Get-Process -Id $PID).PriorityClass = 'BelowNormal' } catch {}
        Set-KeepAwake $true
        [DiagCore]::Start($thr, $secs + 20)
        $t0 = Get-Date
        while (((Get-Date) - $t0).TotalSeconds -lt $secs) {
            Start-Sleep -Seconds 10
            $x = Get-BatSample
            if (-not $x) { continue }
            $L.Add($x)
            $pc = if ($full -gt 0) { $x.Rem / $full * 100 } else { 0 }
            Write-Host -NoNewline ("`r    {0,4:N0} с | {1,5:N0} мВт·ч ({2:N0} %) | {3,5:N1} Вт | {4:N2} В   " -f ((Get-Date) - $t0).TotalSeconds, $x.Rem, $pc, ($x.Rate / 1000), ($x.Volt / 1000))
            if ($x.Online) { $stop = 'зарядка была подключена во время теста'; $replug = $true; break }
            if ($pc -le 15 -or ($null -ne $x.Pct -and $x.Pct -le 15)) { $stop = 'заряд упал до 15 % - остановлено для безопасности'; break }
            if ($x.Critical) { $stop = 'контроллер сообщил критический заряд'; break }
            if (Stop-Requested) { $stop = 'остановлено пользователем / датчиками'; break }
            try { $k = Read-Key; if ($k -and $null -ne $k.CpuTemp -and $k.CpuTemp -ge 98) { $stop = 'температура процессора 98 °C'; break } } catch {}
        }
    } finally {
        try { [DiagCore]::Stop(); [DiagCore]::Wait() } catch {}
        Set-KeepAwake $false
        if ($prio) { try { (Get-Process -Id $PID).PriorityClass = $prio } catch {} }
    }
    Write-Host ''
    $sEnd = $L[$L.Count - 1]

    # --- просим вернуть зарядку (до анализа, чтобы не оставить ноутбук на батарее)
    $back = $sEnd.Online
    if (-not $back) {
        Show-Instr 'Тест аккумулятора' 'Замер закончен. ПОДКЛЮЧИТЕ зарядное устройство и нажмите OK (ждём до 3 минут).'
        $t1 = Get-Date
        while (((Get-Date) - $t1).TotalSeconds -lt 180) { $x = Get-BatSample; if ($x -and $x.Online) { $back = $true; break }; Start-Sleep -Seconds 2 }
    }
    $charging = $false; $pctNow = $null
    if ($back) {
        $t1 = Get-Date
        while (((Get-Date) - $t1).TotalSeconds -lt 45) {
            $x = Get-BatSample
            if ($x) { $pctNow = $x.Pct; if ($x.Charging -or $x.ChargeRate -gt 0 -or ($x.Online -and -not $x.Discharging -and $null -ne $x.Pct -and $x.Pct -ge 99)) { $charging = $true; break } }
            Start-Sleep -Seconds 3
        }
    }

    # --- анализ
    $dur = ($sEnd.T - $L[0].T).TotalSeconds
    if ($stop) { Add-Row $sec 'Остановлен досрочно' $stop 'warn' }
    if ($L.Count -lt 4 -or $dur -lt 60) { Add-Row $sec 'Тест' 'слишком мало данных для выводов' 'warn' }
    else {
        $dRem = $L[0].Rem - $sEnd.Rem                      # мВт·ч израсходовано (по ёмкости)
        $hrs = $dur / 3600.0
        $rates = @($L | Where-Object { $_.Rate -gt 0 } | ForEach-Object { $_.Rate })
        $avgRate = 0.0; if ($rates.Count) { $avgRate = ($rates | Measure-Object -Average).Average }   # мВт, по датчику
        $avgCap = 0.0; if ($dRem -gt 0 -and $hrs -gt 0) { $avgCap = $dRem / $hrs }                      # мВт, по ёмкости
        $dropPct = $dRem / $full * 100
        Add-Row $sec 'Длительность / расход' ('{0:N1} мин; израсходовано {1:N0} мВт·ч ({2:N1} % полной ёмкости)' -f ($dur / 60), $dRem, $dropPct)
        # основной показатель: по ёмкости, если расход заметен (>=1 %), иначе по датчику мощности
        $avgMw = $avgRate; $src = 'по датчику мощности'
        if ($dropPct -ge 1.0 -and $avgCap -gt 0) { $avgMw = $avgCap; $src = 'по расходу ёмкости' }
        if ($avgMw -le 0) { Add-Row $sec 'Потребление' 'не удалось определить' 'warn' }
        else {
            $avgW = $avgMw / 1000.0
            $hFull = $full / $avgMw; $hDes = if ($design -gt 0) { $design / $avgMw } else { 0 }
            Add-Row $sec 'Среднее потребление под нагрузкой' ('{0:N1} Вт ({1}); по датчику {2:N1} Вт, по ёмкости {3:N1} Вт' -f $avgW, $src, ($avgRate / 1000), ($avgCap / 1000))
            Add-Row $sec 'Расчётная автономность при такой нагрузке' ('{0:N1} ч (от полной ёмкости {1:N0} мВт·ч)' -f $hFull, $full) $(if ($hFull -ge 2) { 'ok' } elseif ($hFull -ge 1) { '' } else { 'warn' })
            if ($hDes -gt 0) { Add-Row $sec 'Для нового аккумулятора было бы' ('{0:N1} ч (заводская ёмкость {1:N0} мВт·ч; сейчас {2:N0} %)' -f $hDes, $design, ($full / $design * 100)) }
            $G.Num.bat_avg_w = [math]::Round($avgW, 1); $G.Num.bat_runtime_h = [math]::Round($hFull, 2)
            if ($hDes -gt 0) { $G.Num.bat_runtime_new_h = [math]::Round($hDes, 2) }
            Add-Row $sec 'Нагрузка теста' ('{0} из {1} потоков процессора, экран включён - это нагрузка выше офисной, реальная автономность в простое/браузере будет больше' -f $thr, [Environment]::ProcessorCount)
            if ($hFull -lt 1.0 -and $avgW -lt 40) { Add-Issue 'warn' 'Аккумулятор' ("при умеренной нагрузке ({0:N0} Вт) аккумулятора хватит лишь на {1:N1} ч" -f $avgW, $hFull) 'Аккумулятор сильно изношен или ёмкость занижена - рассмотрите замену.' }
        }

        # резкие падения: прирост расхода за минуту (окно 60 с по семплам каждые 10 с)
        $maxDrop = 0.0; $maxAt = 0
        for ($i = 6; $i -lt $L.Count; $i++) {
            $dm = ($L[$i - 6].Rem - $L[$i].Rem) / $full * 100 * (60.0 / [math]::Max(30, ($L[$i].T - $L[$i - 6].T).TotalSeconds))
            if ($dm -gt $maxDrop) { $maxDrop = $dm; $maxAt = $i }
        }
        if ($maxDrop -gt 5) {
            Add-Row $sec 'Скачки заряда' ('до {0:N1} % за минуту (норма - около 1 %)' -f $maxDrop) 'crit'
            Add-Issue 'crit' 'Аккумулятор' ("заряд резко падает (до {0:N1} % в минуту под нагрузкой)" -f $maxDrop) 'Признак изношенных ячеек или сбитой калибровки контроллера: ноутбук может внезапно выключиться. Выполните калибровку (полный разряд-заряд) или замените аккумулятор.'
        } else { Add-Row $sec 'Скачки заряда' ('нет (максимум {0:N1} % за минуту)' -f $maxDrop) 'ok' }

        # просадка напряжения
        $vs = @($L | Where-Object { $_.Volt -gt 0 } | ForEach-Object { $_.Volt })
        if ($vs.Count -ge 4 -and $vIdle -gt 0) {
            $vmin = ($vs | Measure-Object -Minimum).Minimum; $vEnd = $vs[$vs.Count - 1]
            $sag = ($vIdle - $vmin) / $vIdle * 100
            $G.Num.bat_vsag_pct = [math]::Round($sag, 1)
            Add-Row $sec 'Напряжение: до нагрузки / минимум / в конце' ('{0:N2} В / {1:N2} В / {2:N2} В (просадка {3:N1} %)' -f ($vIdle / 1000), ($vmin / 1000), ($vEnd / 1000), $sag) $(if ($sag -ge 15) { 'crit' } elseif ($sag -ge 8) { 'warn' } else { 'ok' })
            if ($sag -ge 15) { Add-Issue 'crit' 'Аккумулятор' ("сильная просадка напряжения под нагрузкой ({0:N0} %)" -f $sag) 'Высокое внутреннее сопротивление ячеек: ноутбук может выключаться при нагрузке и на остатке заряда. Замените аккумулятор.' }
            elseif ($sag -ge 8) { Add-Issue 'warn' 'Аккумулятор' ("заметная просадка напряжения под нагрузкой ({0:N0} %)" -f $sag) 'Аккумулятор изношен; при высокой нагрузке возможны внезапные отключения.' }
        }

        # непротиворечивость отчётов контроллера
        $incons = @()
        $pctCalc0 = $L[0].Rem / $full * 100
        if ($L[0].Rem -gt $full * 1.05) { $incons += ('остаток ({0:N0}) больше полной ёмкости ({1:N0})' -f $L[0].Rem, $full) }
        if ($null -ne $L[0].Pct -and $null -ne $sEnd.Pct -and [math]::Abs($L[0].Pct - $pctCalc0) -gt 12) { $incons += ('% заряда Windows ({0:N0}) и расчётный по мВт·ч ({1:N0}) расходятся' -f $L[0].Pct, $pctCalc0) }
        if ($null -ne $G.Num.bat_design -and $G.Num.bat_design -gt 0 -and $null -ne $G.Num.bat_health) {
            $expected = $G.Num.bat_design * $G.Num.bat_health / 100
            if ($expected -gt 0 -and [math]::Abs($full - $expected) / $expected -gt 0.15) { $incons += ('полная ёмкость в root/wmi ({0:N0}) не совпадает с отчётом powercfg ({1:N0})' -f $full, $expected) }
        }
        if ($avgRate -gt 0 -and $avgCap -gt 0 -and $dropPct -ge 2.0) {
            $ratio = $avgRate / $avgCap
            if ($ratio -gt 1.6 -or $ratio -lt 0.6) { $incons += ('мощность по датчику ({0:N1} Вт) и по расходу ёмкости ({1:N1} Вт) расходятся в {2:N1} раза' -f ($avgRate / 1000), ($avgCap / 1000), $(if ($ratio -gt 1) { $ratio } else { 1 / $ratio })) }
        }
        if ($incons.Count) {
            Add-Row $sec 'Согласованность показаний' ($incons -join '; ') 'warn'
            Add-Issue 'warn' 'Аккумулятор' 'контроллер батареи выдаёт противоречивые данные об ёмкости/заряде' ('Возможна сбитая калибровка или неисправный контроллер: ' + ($incons -join '; ') + '. Попробуйте полный цикл разряд-заряд; если не помогло - замена аккумулятора.')
        } else { Add-Row $sec 'Согласованность показаний' 'показания контроллера согласованы' 'ok' }

        # риск выключения при низком заряде
        if ($stop -and $stop -match '15 %|критическ') {
            Add-Row $sec 'Риск отключения при низком заряде' 'заряд дошёл до 15 % - дальше тест не продолжался' ''
        }
        if ($sEnd.Pct -ne $null -and $sEnd.Pct -le 20 -and $maxDrop -gt 3) { Add-Issue 'warn' 'Аккумулятор' 'на низком остатке заряд падает быстро - риск внезапного выключения' 'Не работайте от батареи с остатком менее 20 %.' }
    }

    # --- зарядка вернулась?
    if (-not $back) {
        Add-Row $sec 'Зарядка после теста' 'не подключена за 3 минуты - остальные проверки идут от батареи' 'warn'
        Add-Issue 'warn' 'Питание' 'зарядка не была подключена после теста разряда' 'Подключите зарядное устройство, иначе следующие тесты будут неточными.'
    } elseif ($charging) {
        Add-Row $sec 'Зарядка после подключения' 'идёт нормально' 'ok'
    } else {
        Add-Row $sec 'Зарядка после подключения' 'питание от сети есть, но зарядка не началась за 45 с' 'warn'
        Add-Issue 'warn' 'Аккумулятор' 'после подключения адаптера заряд аккумулятора не начался' 'Проверьте адаптер, разъём и ограничение заряда (режим сбережения батареи в BIOS/ПО производителя); при исправном блоке - контроллер или аккумулятор.'
    }
}
