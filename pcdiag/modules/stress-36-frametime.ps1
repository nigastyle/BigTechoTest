# Фризы и статтеры: PresentMon во время 60-секундной нагрузки FurMark (1080p, в окне) или в игре (DIAG_GAME_EXE, 120 с).
# Ключ и пресет — в lib-81-frametime.ps1.
Step 'Видеокарта: фризы и статтеры (frametime)' {
    $s = New-Section 'Фризы и статтеры (frametime)'
    $pm = Get-Tool 'PresentMon'
    if (-not $pm) { Add-Row $s 'Тест' 'PresentMon недоступен (нет интернета?)' 'warn'; return }
    $gameExe = "$env:DIAG_GAME_EXE".Trim()
    $isGame = [bool]$gameExe
    $csv = Join-Path $G.Temp ('frametime_' + (Get-Date -Format 'HHmmss') + '.csv')
    $p = $null; $pf = $null
    $capSec = $(if ($isGame) { 120 } else { 60 })
    if ($isGame) {
        $procName = $gameExe; if ($procName -notmatch '\.exe$') { $procName += '.exe' }
        $bare = $procName -replace '\.exe$', ''
        Info ('Захват кадров игры {0}: {1} с. Запустите игру и держите её на экране в игровой сцене (ждём до 90 с).' -f $procName, $capSec)
        $w0 = Get-Date
        while (-not (Get-Process -Name $bare -ErrorAction SilentlyContinue) -and ((Get-Date) - $w0).TotalSeconds -lt 90) {
            if (Stop-Requested) { return }
            Start-Sleep -Seconds 2
        }
        if (-not (Get-Process -Name $bare -ErrorAction SilentlyContinue)) { Add-Row $s 'Игра' ('процесс {0} не найден за 90 с — тест пропущен' -f $procName) 'warn'; return }
        Info 'игра найдена, через 10 с начнётся запись (перейдите в игровую сцену)'
        Start-Sleep -Seconds 10
    } else {
        $procName = 'furmark.exe'
        $fm = Get-Tool 'FurMark'
        if (-not $fm) { Add-Row $s 'Тест' 'FurMark недоступен' 'warn'; return }
        $fd = Split-Path $fm
        Info 'FurMark 1920×1080 в окне, 60 с + запись кадров PresentMon. Окно с «бубликом» на экране — это нормально.'
        $fa = '--demo furmark-gl --width 1920 --height 1080 --max-time {0} --no-score-box --disable-demo-options' -f ($capSec + 25)
        if ($G.IsLaptop) { $fa += ' --hpgfx 1' }
        $pf = Start-Process $fm -ArgumentList $fa -WorkingDirectory $fd -PassThru -WindowStyle Normal
        if (Get-Command Guard-Register -ErrorAction SilentlyContinue) { Guard-Register $pf }
        Start-Sleep -Seconds 8   # прогрев/создание окна — захват начинаем, когда кадры уже идут
    }
    $t0 = Get-Date
    $L = New-Object System.Collections.Generic.List[object]
    $dpc = New-Object System.Collections.Generic.List[double]
    try {
        $pa = '--process_name {0} --output_file "{1}" --timed {2} --terminate_after_timed --stop_existing_session --no_console_stats' -f $procName, $csv, $capSec
        $p = Start-Process $pm -ArgumentList $pa -WorkingDirectory $G.Temp -PassThru -WindowStyle Hidden
        if (Get-Command Guard-Register -ErrorAction SilentlyContinue) { Guard-Register $p }
        while (-not $p.HasExited -and ((Get-Date) - $t0).TotalSeconds -lt ($capSec + 40)) {
            Start-Sleep -Seconds 3
            $k = Read-Key; $L.Add($k)
            try { $c = Get-Counter '\Processor(_Total)\% DPC Time' -ErrorAction Stop; $dpc.Add([double]$c.CounterSamples[0].CookedValue) } catch {}
            if (Stop-Requested) { Write-Host ''; Warn 'тест остановлен: ТемпературныйНюхач или кнопка «Остановить»'; break }
            Write-Host -NoNewline ("`r    {0,4:N0} / {1} с | GPU {2} °C | {3} МГц | DPC {4} %   " -f ((Get-Date) - $t0).TotalSeconds, $capSec, $(if ($null -ne $k.GpuTemp) { '{0:N0}' -f $k.GpuTemp } else { '—' }), $(if ($k.GpuClock) { '{0:N0}' -f $k.GpuClock } else { '—' }), $(if ($dpc.Count) { '{0:N1}' -f $dpc[$dpc.Count - 1] } else { '—' }))
            if ($null -ne $k.GpuTemp -and $k.GpuTemp -ge 95) { Write-Host ''; Warn 'GPU 95 °C — тест остановлен для защиты'; break }
            if (-not $isGame -and $pf.HasExited) { break }
        }
    } finally {
        foreach ($x in $p, $pf) { try { if ($x -and -not $x.HasExited) { $x.Kill() } } catch {} }
    }
    Write-Host ''
    Start-Sleep -Milliseconds 500
    $ft = Read-FrameTimes $csv
    Remove-Item $csv -ErrorAction SilentlyContinue
    if ($ft.Count -lt 120) {
        Add-Row $s 'Захват кадров' ('получено кадров: {0} — данных недостаточно (PresentMon не увидел {1}; нужны права администратора и работающее окно)' -f $ft.Count, $procName) 'warn'
        return
    }
    $arr = $ft.ToArray(); $sorted = [double[]]$arr.Clone(); [array]::Sort($sorted)
    $total = ($arr | Measure-Object -Sum).Sum
    $avgFps = 1000.0 * $arr.Count / $total
    $median = Get-FtPct $sorted 50
    $p99 = Get-FtPct $sorted 99; $p999 = Get-FtPct $sorted 99.9
    $low1 = 1000.0 / $p99; $low01 = 1000.0 / $p999
    $mean = $total / $arr.Count
    $var = ($arr | ForEach-Object { ($_ - $mean) * ($_ - $mean) } | Measure-Object -Average).Average
    $std = [math]::Sqrt($var)
    $thr = 2.5 * $median
    $stut = @($arr | Where-Object { $_ -gt $thr }).Count
    $worst = $sorted[$sorted.Length - 1]
    $capMin = $total / 60000.0
    $perMin = $stut / [math]::Max(0.1, $capMin)
    $stutPct = 100.0 * $stut / $arr.Count
    $ratio = $low1 / $avgFps
    Add-Row $s 'Что снимали' $(if ($isGame) { 'игра ' + $procName + ' (' + $capSec + ' с)' } else { 'FurMark 1080p в окне (синтетическая нагрузка), 60 с' })
    Add-Row $s 'Кадров записано' ('{0:N0} за {1:N0} с' -f $arr.Count, ($total / 1000))
    Add-Row $s 'Средний FPS' ('{0:N1}' -f $avgFps)
    Add-Row $s '1% low FPS (99-й перцентиль кадра)' ('{0:N1} ({1:N0} % от среднего)' -f $low1, (100 * $ratio)) $(if ($ratio -lt 0.5) { 'warn' } else { 'ok' })
    Add-Row $s '0.1% low FPS' ('{0:N1}' -f $low01) $(if ($low01 / $avgFps -lt 0.3) { 'warn' } else { 'ok' })
    Add-Row $s 'Время кадра: медиана / σ / худший' ('{0:N2} / {1:N2} / {2:N1} мс' -f $median, $std, $worst)
    Add-Row $s ('Статтеры (кадр > 2.5× медианы = {0:N1} мс)' -f $thr) ('{0} шт. ({1:N2} % кадров, {2:N1} в минуту)' -f $stut, $stutPct, $perMin) $(if ($perMin -ge 20 -or $stutPct -ge 1) { 'crit' } elseif ($perMin -ge 6 -or $stutPct -ge 0.3) { 'warn' } else { 'ok' })
    # контекст: что происходило с системой во время захвата
    $gc = @($L | Where-Object { $_.GpuClock } | ForEach-Object { [double]$_.GpuClock })
    $gt = @($L | Where-Object { $null -ne $_.GpuTemp } | ForEach-Object { [double]$_.GpuTemp })
    $clkLoss = 0.0
    if ($gc.Count -ge 8) {
        $q = [int][math]::Floor($gc.Count / 4)
        $cA = ($gc | Select-Object -First $q | Measure-Object -Average).Average; $cB = ($gc | Select-Object -Last $q | Measure-Object -Average).Average
        if ($cA -gt 0) { $clkLoss = 100.0 * ($cA - $cB) / $cA }
        Add-Row $s 'Частота GPU за захват: начало → конец' ('{0:N0} → {1:N0} МГц' -f $cA, $cB) $(if ($clkLoss -ge 10) { 'warn' } else { '' })
    }
    $maxT = $(if ($gt.Count) { ($gt | Measure-Object -Maximum).Maximum } else { $null })
    $dpcMax = $(if ($dpc.Count) { ($dpc | Measure-Object -Maximum).Maximum } else { $null })
    $dpcAvg = $(if ($dpc.Count) { ($dpc | Measure-Object -Average).Average } else { $null })
    if ($null -ne $dpcMax) { Add-Row $s 'Время в DPC (прерывания драйверов): средн. / макс.' ('{0:N1} / {1:N1} %' -f $dpcAvg, $dpcMax) $(if ($dpcAvg -ge 5) { 'crit' } elseif ($dpcMax -ge 15) { 'warn' } else { 'ok' }) }
    $plan = ''; $saver = $false
    try { $plan = (& powercfg /getactivescheme 2>$null) -join ' '; if ($plan -match 'a1841308-3541-4fab-bc81-f71556f20b4a') { $saver = $true } } catch {}
    if ($plan) { Add-Row $s 'План электропитания' (($plan -replace '^.*?:\s*[0-9a-fA-F-]+\s*', '').Trim()) $(if ($saver) { 'warn' } else { '' }) }
    # вердикт
    $bad = ($perMin -ge 6 -or $stutPct -ge 0.3 -or $ratio -lt 0.5)
    $causes = @()
    if ($null -ne $dpcAvg -and ($dpcAvg -ge 5 -or $dpcMax -ge 15)) { $causes += 'высокая загрузка DPC (драйвер сети/звука/хранилища или USB мешает системе)' }
    if ($saver) { $causes += 'включён план электропитания «Экономия энергии»' }
    if ($clkLoss -ge 10 -or ($null -ne $maxT -and $maxT -ge 85)) { $causes += 'тепловой троттлинг видеокарты' }
    if ($bad) {
        if (-not $isGame) {
            $txt = 'на ровной синтетической нагрузке кадры идут неравномерно'
            if ($causes.Count) { $txt += ': ' + ($causes -join '; ') }
            Add-Issue $(if ($perMin -ge 20 -or $stutPct -ge 1) { 'warn' } else { 'info' }) 'Стабильность' ('фризы/статтеры на синтетической нагрузке: {0} рывков ({1:N1}/мин), 1% low = {2:N0} % от среднего FPS' -f $stut, $perMin, (100 * $ratio)) ('Тест FurMark ровный, поэтому причина в системе, а не в игре. ' + $(if ($causes.Count) { 'Вероятно: ' + ($causes -join '; ') + '. ' } else { '' }) + 'Проверьте: план питания «Высокая производительность», драйверы сети/звука (LatencyMon), охлаждение GPU, фоновые программы, антивирус.')
        } else {
            Add-Issue 'info' 'Стабильность' ('рывки в игре {0}: {1} шт. ({2:N1}/мин), 1% low = {3:N0} % от среднего FPS' -f $procName, $stut, $perMin, (100 * $ratio)) ('Сравните с результатом на FurMark (ровная нагрузка): если там рывков нет, причина в игре/настройках/диске (подгрузка ресурсов). ' + $(if ($causes.Count) { 'В системе замечено: ' + ($causes -join '; ') + '. ' } else { '' }))
        }
        Add-Row $s 'Итог' $(if ($causes.Count) { 'неровная подача кадров; вероятные причины: ' + ($causes -join '; ') } else { 'неровная подача кадров, явная причина не найдена' }) 'warn'
    } else {
        Add-Row $s 'Итог' 'кадры идут ровно, заметных фризов нет' 'ok'
    }
}
