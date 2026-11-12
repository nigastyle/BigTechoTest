# Долгий тест стабильности GPU (Vulkan). Ключ и пресет — в lib-80-gpustab.ps1.
Step 'Видеокарта: стабильность (Vulkan, долгий)' {
    $s = New-Section 'Видеокарта: долгий тест стабильности (Vulkan)'
    $min = [int]$G.Sel.gpustabmin; if ($min -lt 1) { $min = 20 }
    $sec = $min * 60
    $fm = Get-Tool 'FurMark'
    if (-not $fm) { Add-Row $s 'Тест' 'FurMark недоступен' 'warn'; return }
    $fd = Split-Path $fm
    # родное разрешение основного экрана (окно видно на экране, не fullscreen)
    $w = 1920; $h = 1080
    try {
        $vc = @(CIM Win32_VideoController | Where-Object { $_.CurrentHorizontalResolution -gt 0 } | Select-Object -First 1)
        if ($vc.Count -and $vc[0].CurrentHorizontalResolution -ge 800) { $w = [int]$vc[0].CurrentHorizontalResolution; $h = [int]$vc[0].CurrentVerticalResolution }
    } catch {}
    Info ('Стабильность GPU: FurMark 2 Vulkan {0}×{1}, {2} мин. Окно с «бубликом» на экране — это нормально, не трогайте его.' -f $w, $h, $min)
    $demo = 'furmark-vk'
    $t0 = Get-Date
    $smiH = if (Get-Command Start-SmiLog -ErrorAction SilentlyContinue) { Start-SmiLog } else { $null }
    $mkArgs = { param($d) $a = '--demo {0} --width {1} --height {2} --max-time {3} --no-score-box --disable-demo-options' -f $d, $w, $h, ($sec + 30); if ($G.IsLaptop) { $a += ' --hpgfx 1' }; $a }
    $p = Start-Process $fm -ArgumentList (& $mkArgs $demo) -WorkingDirectory $fd -PassThru -WindowStyle Normal
    if (Get-Command Guard-Register -ErrorAction SilentlyContinue) { Guard-Register $p }
    # Vulkan не поднялся (старый драйвер/GPU) — один раз пробуем OpenGL, чтобы тест всё же состоялся
    Start-Sleep -Seconds 6
    if ($p.HasExited -and $p.ExitCode -ne 0 -and -not (Stop-Requested)) {
        Warn 'Vulkan-версия FurMark не запустилась, пробую OpenGL'
        $demo = 'furmark-gl'
        $p = Start-Process $fm -ArgumentList (& $mkArgs $demo) -WorkingDirectory $fd -PassThru -WindowStyle Normal
        if (Get-Command Guard-Register -ErrorAction SilentlyContinue) { Guard-Register $p }
        Add-Issue 'info' 'Видеокарта' 'Vulkan недоступен, долгий тест выполнен через OpenGL' 'Обновите драйвер видеокарты, если видеокарта должна поддерживать Vulkan.'
    }
    $L = New-Object System.Collections.Generic.List[object]
    $stop = $null; $early = $false
    try {
        while (((Get-Date) - $t0).TotalSeconds -lt $sec) {
            if ($p.HasExited) { if (((Get-Date) - $t0).TotalSeconds -lt ($sec - 15) -and -not (Stop-Requested)) { $early = $true }; break }
            Start-Sleep -Seconds 3
            $k = Read-Key
            $L.Add([pscustomobject]@{ T = ((Get-Date) - $t0).TotalSeconds; Temp = $k.GpuTemp; Hot = $k.GpuHot; Clock = $k.GpuClock; Power = $k.GpuPower; Load = $k.GpuLoad; Fan = $k.GpuFan })
            if (Stop-Requested) { Write-Host ''; Warn 'тест остановлен: ТемпературныйНюхач или кнопка «Остановить»'; $stop = 'остановлен защитой/пользователем'; break }
            Write-Host -NoNewline ("`r    {0,4:N0} / {1} с | GPU {2} °C | hot spot {3} °C | {4} МГц | {5} Вт | загрузка {6} %   " -f ((Get-Date) - $t0).TotalSeconds, $sec, $(if ($null -ne $k.GpuTemp) { '{0:N0}' -f $k.GpuTemp } else { '—' }), $(if ($null -ne $k.GpuHot) { '{0:N0}' -f $k.GpuHot } else { '—' }), $(if ($k.GpuClock) { '{0:N0}' -f $k.GpuClock } else { '—' }), $(if ($k.GpuPower) { '{0:N0}' -f $k.GpuPower } else { '—' }), $(if ($null -ne $k.GpuLoad) { '{0:N0}' -f $k.GpuLoad } else { '—' }))
            if ($null -ne $k.GpuTemp -and $k.GpuTemp -ge 95) { Write-Host ''; Warn 'GPU 95 °C — тест остановлен для защиты'; $stop = 'температура GPU 95 °C'; break }
        }
    } finally {
        try { if (-not $p.HasExited) { $p.Kill() } } catch {}
    }
    Write-Host ''
    $exitCode = $null; try { $exitCode = $p.ExitCode } catch {}
    $smi = if ($smiH) { Stop-SmiLog $smiH } else { @() }
    $dur = ((Get-Date) - $t0).TotalSeconds
    Add-Row $s 'Тест' ('FurMark 2, {0}, {1}×{2}' -f $demo, $w, $h)
    Add-Row $s 'Длительность' ('{0:N1} мин из {1}' -f ($dur / 60), $min) $(if ($stop -or $early) { 'warn' } else { 'ok' })
    if ($stop) { Add-Row $s 'Остановлен досрочно' $stop 'warn' }

    # --- 1. падение FurMark / события драйвера
    $tdr = @(); $drv = @(); $xid = 0
    try { $tdr = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Display'; Id = 4101; StartTime = $t0 } -ErrorAction Stop) } catch {}
    foreach ($prov in 'nvlddmkm', 'amdkmdag', 'amdwddmg', 'igfx', 'igfxn') {
        try {
            foreach ($e in @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = $prov; StartTime = $t0; Level = 1, 2, 3 } -ErrorAction Stop)) {
                $drv += $e
                $txt = "$($e.Message) " + (($e.Properties | ForEach-Object { "$($_.Value)" }) -join ' ')
                if ($txt -match 'Xid \(PCI:') { $xid++ }
            }
        } catch {}
    }
    $crash = $early -and -not $stop
    if ($crash) {
        Add-Row $s 'FurMark завершился сам' ('через {0:N0} с (код {1}) — вероятен сбой драйвера или GPU' -f $dur, $exitCode) 'crit'
        Add-Issue 'crit' 'Видеокарта' ('FurMark аварийно завершился через {0:N0} с под долгой нагрузкой' -f $dur) 'Признак нестабильности видеокарты/драйвера: уберите разгон (в т.ч. заводской «OC»), проверьте питание PCIe-кабелями, температуру; переустановите драйвер.'
    }
    Add-Row $s 'Сбросы драйвера (TDR, событие 4101) за тест' $tdr.Count $(if ($tdr.Count) { 'crit' } else { 'ok' })
    Add-Row $s 'Ошибки драйвера GPU в журнале за тест (в т.ч. Xid)' ('{0} (Xid: {1})' -f $drv.Count, $xid) $(if ($xid) { 'crit' } elseif ($drv.Count) { 'warn' } else { 'ok' })
    if ($tdr.Count) { Add-Issue 'crit' 'Видеокарта' ('драйвер видеокарты упал во время долгого теста (TDR ×{0})' -f $tdr.Count) 'Нестабильность видеокарты: уберите разгон, проверьте питание и температуру; возможна неисправность GPU или видеопамяти.' }
    elseif ($xid) { Add-Issue 'crit' 'Видеокарта' ('NVIDIA Xid-ошибки во время долгого теста ({0})' -f $xid) 'Драйвер зафиксировал аппаратные ошибки GPU/памяти/шины: проверьте питание, разгон, посадку в слоте PCIe.' }
    elseif ($drv.Count -and -not $crash) { Add-Issue 'warn' 'Видеокарта' ('ошибки драйвера видеокарты во время долгого теста: {0}' -f $drv.Count) 'Посмотрите журнал Windows (Система) за время теста; при повторении обновите драйвер или проверьте разгон.' }

    # --- 2. разбор кривых (если данных мало — не делаем выводов)
    if ($L.Count -lt 20) { Add-Row $s 'Анализ кривых' 'слишком короткий тест для анализа' 'warn'; return }
    $a = @($L)
    $n = $a.Count
    $warmEnd = [int][math]::Max(5, [math]::Floor($n * 0.15))     # первые ~15 % — прогрев
    $steady = @($a | Select-Object -Skip $warmEnd)
    $loaded = @($steady | Where-Object { $null -ne $_.Load -and $_.Load -ge 80 })
    if ($loaded.Count -lt 10 -and ($steady | Where-Object { $null -ne $_.Load }).Count -gt 0) {
        Add-Row $s 'Загрузка GPU' 'FurMark не догрузил видеокарту (<80 %), анализ может быть неточным' 'warn'
    }
    if ($loaded.Count -lt 10) { $loaded = $steady }

    # температура: время выхода на плато, дрейф
    $temps = @($a | Where-Object { $null -ne $_.Temp })
    if ($temps.Count -ge 20) {
        $tail = @($temps | Select-Object -Last ([int][math]::Max(5, [math]::Floor($temps.Count * 0.2))))
        $final = Get-GsPct ($tail | ForEach-Object { $_.Temp }) 50
        $plat = $null
        foreach ($x in $temps) { if ($x.Temp -ge $final - 1.5) { $plat = $x.T; break } }
        $maxT = ($temps | Measure-Object -Property Temp -Maximum).Maximum
        $startT = [double]$temps[0].Temp
        Add-Row $s 'Температура GPU: старт → плато → макс.' ('{0:N0} → {1:N0} → {2:N0} °C' -f $startT, $final, $maxT) $(if ($maxT -ge 90) { 'crit' } elseif ($maxT -ge 84) { 'warn' } else { 'ok' })
        if ($null -ne $plat) { Add-Row $s 'Время выхода на плато температуры' ('{0:N0} с ({1:N1} мин)' -f $plat, ($plat / 60)) $(if ($plat -ge $sec * 0.6) { 'warn' } else { 'ok' }) }
        # дрейф: средняя температура последней пятой против предыдущей пятой
        $fifth = [int][math]::Max(5, [math]::Floor($temps.Count * 0.2))
        if ($temps.Count -ge 5 * 5) {
            $prev = @($temps | Select-Object -Skip ($temps.Count - 2 * $fifth) -First $fifth)
            $dTemp = $final - ($prev | Measure-Object -Property Temp -Average).Average
            if ($dTemp -ge 3) {
                Add-Row $s 'Температура не стабилизировалась' ('в конце теста всё ещё растёт: +{0:N1} °C за последнюю пятую часть' -f $dTemp) 'warn'
                Add-Issue 'warn' 'Охлаждение' ('температура видеокарты не вышла на плато за {0} мин (+{1:N1} °C к концу)' -f $min, $dTemp) 'Слабое охлаждение или забитый радиатор/корпус: почистите, проверьте вентиляторы и обдув корпуса.'
            }
        }
        if ($maxT -ge 90) { Add-Issue 'crit' 'Видеокарта' ('перегрев видеокарты в долгом тесте: {0:N0} °C' -f $maxT) 'Почистите видеокарту от пыли, проверьте вентиляторы; часто нужна замена термопасты/термопрокладок.' }
        elseif ($maxT -ge 84) { Add-Issue 'warn' 'Видеокарта' ('видеокарта горячая в долгом тесте: {0:N0} °C' -f $maxT) 'Улучшите обдув корпуса, почистите от пыли.' }
    }

    # hot spot − температура ядра: тренд (рост = выдавливание термопасты)
    $hd = @($a | Where-Object { $null -ne $_.Hot -and $null -ne $_.Temp } | ForEach-Object { [pscustomobject]@{ T = $_.T; D = [double]($_.Hot - $_.Temp) } })
    if ($hd.Count -ge 20) {
        $third = [int][math]::Floor($hd.Count / 3)
        $dFirst = ($hd | Select-Object -Skip ([int]($hd.Count * 0.15)) -First $third | Measure-Object -Property D -Average).Average
        $dLast = ($hd | Select-Object -Last $third | Measure-Object -Property D -Average).Average
        $dMax = ($hd | Measure-Object -Property D -Maximum).Maximum
        Add-Row $s 'Hot spot − ядро: начало → конец (макс.)' ('{0:N0} → {1:N0} °C ({2:N0})' -f $dFirst, $dLast, $dMax) $(if ($dLast -ge 25) { 'warn' } else { 'ok' })
        if (($dLast - $dFirst) -ge 6 -and $dLast -ge 15) { Add-Issue 'warn' 'Видеокарта' ('разница hot spot/ядро растёт во время теста: {0:N0} → {1:N0} °C' -f $dFirst, $dLast) 'Признак плохого контакта кулера с кристаллом (высохшая термопаста): замените термопасту/прокладки.' }
        elseif ($dLast -ge 25) { Add-Issue 'warn' 'Видеокарта' ('большая разница ядро / hot spot: {0:N0} °C' -f $dLast) 'Признак высохшей термопасты на GPU — нужна замена.' }
    } else { Add-Row $s 'Hot spot' 'датчик недоступен' '' }

    # частота: просадки при той же температуре
    $clk = @($loaded | Where-Object { $_.Clock -gt 0 })
    $thrReasons = ''
    if ($clk.Count -ge 15) {
        $cMed = Get-GsPct ($clk | ForEach-Object { $_.Clock }) 50
        $cTop = Get-GsPct ($clk | ForEach-Object { $_.Clock }) 90
        $tMed = Get-GsPct ($clk | Where-Object { $null -ne $_.Temp } | ForEach-Object { $_.Temp }) 50
        $tHi = $(if ($null -ne $tMed) { $tMed + 3 } else { 999 })
        $drops = @($clk | Where-Object { $_.Clock -lt 0.85 * $cTop -and ($null -eq $_.Temp -or $_.Temp -le $tHi) })
        # подряд идущие просадки (≥3 замера ≈ 9 с) считаем реальной просадкой, а не выбросом датчика
        $runs = 0; $cur = 0
        foreach ($x in $clk) {
            if ($x.Clock -lt 0.85 * $cTop -and ($null -eq $x.Temp -or $x.Temp -le $tHi)) { $cur++; if ($cur -eq 3) { $runs++ } } else { $cur = 0 }
        }
        $cmin = (Get-GsPct ($clk | ForEach-Object { $_.Clock }) 2)
        Add-Row $s 'Частота ядра под нагрузкой (медиана / 90% / 2%)' ('{0:N0} / {1:N0} / {2:N0} МГц' -f $cMed, $cTop, $cmin)
        if ($runs -ge 1) {
            Add-Row $s 'Просадки частоты >15 % без роста температуры' ('{0} эпизод(ов), {1} замеров' -f $runs, $drops.Count) 'warn'
            Add-Issue 'warn' 'Стабильность' ('частота видеокарты проседала >15 % без перегрева ({0} раз за тест)' -f $runs) 'Возможна нехватка питания (БП/кабели), нестабильный разгон или сбои в драйвере. Проверьте план электропитания, питание PCIe, уберите разгон.'
        } else { Add-Row $s 'Просадки частоты >15 % без роста температуры' 'нет' 'ok' }
        # плавный спад частоты за тест (троттлинг от нагрева)
        $q = [int][math]::Floor($clk.Count / 4)
        $cA = ($clk | Select-Object -First $q | Measure-Object -Property Clock -Average).Average
        $cB = ($clk | Select-Object -Last $q | Measure-Object -Property Clock -Average).Average
        if ($cA -gt 0) {
            $loss = 100.0 * ($cA - $cB) / $cA
            Add-Row $s 'Частота: начало → конец теста' ('{0:N0} → {1:N0} МГц ({2:N1} %)' -f $cA, $cB, (-$loss)) $(if ($loss -ge 15) { 'warn' } else { 'ok' })
            if ($loss -ge 15) { Add-Issue 'warn' 'Охлаждение' ('видеокарта сбросила частоту на {0:N0} % к концу долгого теста (тепловой троттлинг)' -f $loss) 'Почистите охлаждение, улучшите обдув; проверьте термопасту.' }
        }
        # дребезг: коэффициент вариации частоты в устойчивой части + переключения лимита мощности по nvidia-smi
        $cv = $null
        $cvals = @($clk | ForEach-Object { [double]$_.Clock }); $cm = ($cvals | Measure-Object -Average).Average
        if ($cm -gt 0) { $var = ($cvals | ForEach-Object { ($_ - $cm) * ($_ - $cm) } | Measure-Object -Average).Average; $cv = 100.0 * [math]::Sqrt($var) / $cm }
        $toggles = 0; $capOn = 0; $prevCap = $null; $reasonSeen = @{}
        $smiSteady = @($smi | Select-Object -Skip ([int]($smi.Count * 0.15)))
        foreach ($r in $smiSteady) {
            $mask = ConvertFrom-SmiMask $r.'clocks_throttle_reasons.active'
            if ($null -eq $mask) { continue }
            $cap = [bool]($mask -band 0x4)
            if ($cap) { $capOn++ }
            if ($null -ne $prevCap -and $cap -ne $prevCap) { $toggles++ }
            $prevCap = $cap
            foreach ($bit in @(@(0x4, 'лимит мощности'), @(0x8, 'аппаратное замедление'), @(0x20, 'программный перегрев'), @(0x40, 'аппаратный перегрев'), @(0x80, 'аварийное снижение питания'))) { if ($mask -band $bit[0]) { $reasonSeen[$bit[1]] = 1 + [int]$reasonSeen[$bit[1]] } }
        }
        $perMin = $(if ($smiSteady.Count -gt 0) { $toggles / ($smiSteady.Count / 60.0) } else { 0 })
        if ($cv -ne $null) { Add-Row $s 'Разброс частоты (σ/среднее)' ('{0:N1} %' -f $cv) $(if ($cv -ge 8) { 'warn' } else { 'ok' }) }
        if ($smiSteady.Count) { Add-Row $s 'Переключений лимита мощности в минуту' ('{0:N1} (лимит активен {1:N0} % времени)' -f $perMin, (100.0 * $capOn / $smiSteady.Count)) $(if ($perMin -ge 12 -and $cv -ge 5) { 'warn' } else { '' }) }
        if ($reasonSeen.Count) { $thrReasons = ($reasonSeen.Keys | ForEach-Object { '{0} ({1} с)' -f $_, $reasonSeen[$_] }) -join '; '; Add-Row $s 'Причины ограничения частоты (nvidia-smi)' $thrReasons }
        if ($perMin -ge 12 -and $cv -ge 5) { Add-Issue 'info' 'Видеокарта' ('частота «скачет» из-за упора в лимит мощности ({0:N0} переключений/мин, разброс {1:N1} %)' -f $perMin, $cv) 'Обычно норма для FurMark; в играх это проявится редко. Если в играх рывки — проверьте питание и план электропитания.' }
        if ($reasonSeen.ContainsKey('аппаратное замедление') -or $reasonSeen.ContainsKey('аварийное снижение питания')) {
            Add-Issue 'warn' 'Питание' 'видеокарта аппаратно замедлялась/снижала питание под нагрузкой' 'Проверьте БП и кабели питания видеокарты (без переходников «в цепочку»), температуру VRM.'
        }
    } else { Add-Row $s 'Анализ частоты' 'нет данных о частоте/загрузке GPU' '' }

    # --- итог
    if (-not $crash -and -not $tdr.Count -and -not $xid -and -not $stop) {
        Add-Row $s 'Итог' ('Видеокарта отработала {0} мин Vulkan-нагрузки без падений драйвера' -f $min) 'ok'
    } elseif ($crash -or $tdr.Count -or $xid) { Add-Row $s 'Итог' 'НЕСТАБИЛЬНО: сбой во время длительной нагрузки' 'crit' }
    else { Add-Row $s 'Итог' 'тест прерван, вывод о стабильности сделать нельзя' 'warn' }
}
