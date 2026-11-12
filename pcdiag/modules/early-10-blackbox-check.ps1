# Разбор «чёрного ящика» прошлых запусков: компьютер выключился посреди стресс-теста?
& {
    $files = @()
    foreach ($d in (Join-Path $G.Root 'reports\blackbox'), (Join-Path $env:LOCALAPPDATA 'PCDiag\blackbox')) {
        if (Test-Path $d) { $files += @(Get-ChildItem $d -Filter 'bb_*.csv' -File -ErrorAction SilentlyContinue) }
    }
    if (-not $files.Count) { return }
    $boot = $null; try { $boot = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime } catch {}
    $names = @{ '_cpu' = 'стресс-тест процессора'; 'ycr' = 'y-cruncher'; 'ram' = 'тест памяти'; 'gpu' = 'стресс-тест видеокарты (FurMark)'; 'psu' = 'совместный тест блока питания'; 'vram' = 'тест видеопамяти' }
    foreach ($f in $files) {
        $r = Read-BBFile $f.FullName
        if (-not $r) { Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue; continue }
        # Окно программы просто закрыли (загрузки после теста не было) — не авария
        if (-not $boot -or $r.End -gt $boot) { Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue; continue }
        # события аварийного завершения — только в первые сутки после теста
        $kp = @(); try { $kp = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 41, 6008; StartTime = $r.End; EndTime = $r.End.AddHours(24) } -MaxEvents 5 -ErrorAction Stop) } catch {}
        $bsodCode = 0
        foreach ($e in $kp) { if ($e.Id -eq 41 -and $e.ProviderName -match 'Kernel-Power') { try { $c = [int64]$e.Properties[0].Value; if ($c -ne 0) { $bsodCode = $c } } catch {} } }
        $abrupt = $kp.Count -gt 0
        if (-not $abrupt) { Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue; continue }   # окно закрыли, перезагрузились позже — не авария
        $key = ''; foreach ($k in $STEPKEYS.Keys) { if ($k -eq $r.Test) { $key = $STEPKEYS[$k] } }
        $tn = if ($names[$key]) { $names[$key] } else { $r.Test }
        $s = New-Section 'Чёрный ящик: компьютер отключился во время прошлой диагностики'
        Add-Row $s 'Когда' ('{0:dd.MM.yyyy HH:mm:ss}' -f $r.End)
        Add-Row $s 'Во время теста' ('{0}, через {1:N0} с после начала' -f $tn, $r.LastSec)
        Add-Row $s 'Что произошло' $(if ($bsodCode) { 'СИНИЙ ЭКРАН (код 0x{0:X}) во время теста' -f $bsodCode } else { 'внезапное выключение / перезагрузка (Windows не завершила работу штатно)' }) 'crit'
        $L = $r.Last
        $lastTxt = @()
        foreach ($c in @(@('cpuT', 'CPU {0} °C'), @('cpuP', 'CPU {0} Вт'), @('gpuT', 'GPU {0} °C'), @('gpuHot', 'hot spot {0} °C'), @('gpuP', 'GPU {0} Вт'), @('v12', '+12V {0} В'), @('v5', '+5V {0} В'), @('vcore', 'Vcore {0} В'), @('fanMin', 'вентилятор CPU {0} об/мин'))) {
            if ($L[$c[0]]) { $lastTxt += ($c[1] -f $L[$c[0]]) }
        }
        if ($lastTxt.Count) { Add-Row $s 'Последние показания' ($lastTxt -join ', ') }
        if ($null -ne $r.CpuTmax) { Add-Row $s 'CPU: макс. температура' ('{0:N0} °C' -f $r.CpuTmax) $(if ($r.CpuTmax -ge 95) { 'crit' } else { '' }) }
        if ($null -ne $r.GpuTmax) { Add-Row $s 'GPU: макс. температура' ('{0:N0} °C' -f $r.GpuTmax) $(if ($r.GpuTmax -ge 88) { 'crit' } else { '' }) }
        $pw = 0; if ($r.CpuPmax) { $pw += $r.CpuPmax }; if ($r.GpuPmax) { $pw += $r.GpuPmax }
        if ($pw -gt 0) { Add-Row $s 'Мощность CPU + GPU (макс.)' ('{0:N0} Вт' -f $pw) }
        if ($null -ne $r.V12min) { Add-Row $s '+12V минимум' ('{0:N2} В' -f $r.V12min) $(if ($r.V12min -lt 11.4) { 'crit' } else { 'ok' }) }
        # Вероятная причина — по показаниям перед отключением
        $why = @()
        if ($bsodCode) { $why += ('синий экран 0x{0:X} под нагрузкой — {1}' -f $bsodCode, $(if ($key -in 'ram', 'ycr') { 'нестабильна оперативная память/контроллер памяти (XMP, разгон)' } elseif ($key -in 'gpu', 'vram') { 'видеокарта или её драйвер' } else { 'процессор/память/питание процессора (разгон, андервольт, VRM)' })) }
        if ($null -ne $r.CpuTmax -and $r.CpuTmax -ge 95) { $why += 'перегрев процессора (сработала защита)' }
        if (($null -ne $r.GpuTmax -and $r.GpuTmax -ge 90) -or ($null -ne $r.GpuHotMax -and $r.GpuHotMax -ge 105)) { $why += 'перегрев видеокарты' }
        if (($null -ne $r.V12min -and $r.V12min -lt 11.4) -or ($null -ne $r.V5min -and $r.V5min -lt 4.75) -or ($null -ne $r.V33min -and $r.V33min -lt 3.135)) { $why += 'просадка напряжения — блок питания не держит нагрузку' }
        if (-not $why.Count -and -not $bsodCode) {
            if ($key -in 'gpu', 'psu' -or $pw -ge 250) { $why += 'блок питания (не выдерживает пиковую нагрузку или изношен) — самая частая причина выключений под нагрузкой' }
            elseif ($key -in 'ram', 'ycr') { $why += 'нестабильность памяти/контроллера памяти или питания процессора (VRM)' }
            else { $why += 'питание процессора: блок питания или VRM материнской платы' }
        }
        Add-Row $s 'Вероятная причина' ($why -join '; ') 'crit'
        $tail = @($r.Rows | Select-Object -Last 8 | ForEach-Object { $x = $_; [pscustomobject]@{ 'Время' = $x['t']; 'CPU °C' = $x['cpuT']; 'CPU Вт' = $x['cpuP']; 'GPU °C' = $x['gpuT']; 'GPU Вт' = $x['gpuP']; '+12V' = $x['v12']; 'Vcore' = $x['vcore'] } })
        if ($tail.Count) { Add-Table $s 'Последние секунды перед отключением' $tail }
        Add-Issue 'crit' $(if ($bsodCode) { 'Стабильность' } else { 'Питание' }) ('во время прошлой диагностики компьютер {0} ({1}, {2:dd.MM HH:mm})' -f $(if ($bsodCode) { 'упал в синий экран' } else { 'внезапно выключился' }), $tn, $r.End) ('Вероятная причина: ' + ($why -join '; ') + '. Повторите тот же тест, наблюдая за компьютером; проверьте блок питания (заменой на заведомо исправный), охлаждение и разгон.')
        $G.Num.blackbox_crash = 1
        # Сохраняем запись для мастера и больше её не показываем
        try { Move-Item $f.FullName (Join-Path $f.DirectoryName ('crash_' + $f.Name.Substring(3))) -Force } catch { Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue }
    }
}
