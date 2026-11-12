# Проверка поверхности накопителей ЧТЕНИЕМ (аналог «Victoria/HDD Scan — чтение», выборочно по всей поверхности).
# Ничего не записывает: диск открыт только на чтение (см. lib-30-surface.ps1).
Step 'Накопители: проверка поверхности (чтение)' {
    $s = New-Section 'Накопители: проверка поверхности (чтение)'
    if (-not $G.SurfaceOk) { Add-Row $s 'Тест' 'модуль чтения диска не загрузился' 'warn'; return }
    $min = [int]$G.Sel.surfacemin; if ($min -lt 1) { $min = 3 }
    $sysNum = $null
    try { $sysNum = (Get-Partition -DriveLetter ($env:SystemDrive.TrimEnd(':')) -ErrorAction Stop | Get-Disk).Number } catch {}
    $pds = @(Get-PhysicalDisk -ErrorAction SilentlyContinue)
    $disks = @(Get-Disk -ErrorAction SilentlyContinue | Where-Object {
            $null -ne $_.Number -and [double]$_.Size -gt 1GB -and
            "$($_.BusType)" -notmatch 'Virtual|Spaces' -and "$($_.FriendlyName)" -notmatch 'Storage Space|Virtual Disk|VHD|Msft Virtual' -and
            "$($_.Model)" -notmatch 'Virtual Disk|Storage Space'
        } | Sort-Object Number)
    if (-not $disks.Count) { Add-Row $s 'Диски' 'физические диски не найдены' 'warn'; return }
    $perDisk = [math]::Max(60, [int]($min * 60 / $disks.Count))
    Info ('чтение поверхности {0} диск(ов), ~{1:N0} мин на диск. Только чтение — данные не изменяются.' -f $disks.Count, ($perDisk / 60))
    $rows = @(); $totErr = 0; $totSlow = 0; $worstUni = $null
    foreach ($d in $disks) {
        $num = [int]$d.Number
        $pd = $pds | Where-Object { "$($_.DeviceId)" -eq "$num" } | Select-Object -First 1
        $nm = Clean $(if ($pd) { $pd.FriendlyName } else { $d.FriendlyName })
        $bus = "$($d.BusType)"
        $media = if ($pd) { "$($pd.MediaType)" } else { '' }
        if ($bus -eq 'NVMe') { $media = 'SSD' }
        if ($media -notin 'HDD', 'SSD') {
            $sp = -1; try { $sp = [DiagSurface]::SeekPenalty($num) } catch {}
            $media = switch ($sp) { 1 { 'HDD' } 0 { 'SSD' } default { '' } }
        }
        $isHdd = ($media -eq 'HDD')
        $label = $nm + $(if ($num -eq $sysNum) { ' (системный)' } else { '' }) + $(if ($bus -eq 'USB') { ' [USB]' } else { '' })
        $size = Get-SurfaceDiskSize $num
        if (-not $size) { Add-Row $s $label 'не удалось узнать размер — пропуск' 'warn'; continue }
        $slowMs = if ($isHdd) { 500 } elseif ($media -eq 'SSD') { 100 } else { 300 }
        $zones = 200
        Info ('{0}: {1} {2}, {3}' -f $label, $(if ($media) { $media } else { 'тип неизвестен' }), $bus, (GB $size 0))
        [DiagSurface]::StartScan($num, [long]0, [long]$size, 1, $perDisk, $zones, $slowMs)
        $t0 = Get-Date
        while ([DiagSurface]::IsRunning) {
            [DiagSurface]::Wait(1000)
            Write-Host -NoNewline ("`r    {0,4:N0} с | зона {1,3}/{2} | {3,6:N0} МБ/с | ошибок {4} | медленных блоков {5}   " -f ((Get-Date) - $t0).TotalSeconds, [DiagSurface]::ProgZones, [DiagSurface]::ProgTotal, [DiagSurface]::ProgLastMBs, [DiagSurface]::ProgErrors, [DiagSurface]::ProgSlow)
            if (((Get-Date) - $t0).TotalSeconds -gt $perDisk + 120) { [DiagSurface]::Cancel = $true }   # страховка от «зависшего» диска
            if (Stop-Requested) { [DiagSurface]::Cancel = $true }   # ТемпературныйНюхач: перегрев диска и т. п.
        }
        Write-Host ''
        $r = [DiagSurface]::LastResult
        if (-not $r) { Add-Row $s $label ('ошибка теста: ' + [DiagSurface]::LastError) 'warn'; continue }
        if (-not $r.ZonesDone) { Add-Row $s $label $(if ($r.Note) { $r.Note } else { 'не прочитано ни одной зоны' }) 'warn'; continue }
        $sp = @($r.ZoneMBs | ForEach-Object { [double]$_ })
        $okv = @($sp | Where-Object { -not [double]::IsNaN($_) })
        $med = 0.0
        if ($okv.Count) { $so = @($okv | Sort-Object); $med = [double]$so[[int][math]::Floor(($so.Count - 1) / 2)] }
        $uni = if ($med -gt 0) { $r.MinSpeed / $med } else { 0 }
        # HDD: естественный спад скорости от начала к концу диска — сравниваем с линейным трендом, а не с медианой
        $dips = 0
        if ($okv.Count -ge 10) {
            $xs = @(); $ys = @()
            for ($i = 0; $i -lt $sp.Count; $i++) { if (-not [double]::IsNaN($sp[$i])) { $xs += [double]$i; $ys += $sp[$i] } }
            $n = $xs.Count; $mx = ($xs | Measure-Object -Average).Average; $my = ($ys | Measure-Object -Average).Average
            $sxy = 0.0; $sxx = 0.0
            for ($i = 0; $i -lt $n; $i++) { $sxy += ($xs[$i] - $mx) * ($ys[$i] - $my); $sxx += ($xs[$i] - $mx) * ($xs[$i] - $mx) }
            $kk = if ($sxx -gt 0) { $sxy / $sxx } else { 0 }; $bb = $my - $kk * $mx
            for ($i = 0; $i -lt $n; $i++) { $fit = $kk * $xs[$i] + $bb; if ($fit -le 0) { $fit = $my }; if ($ys[$i] -lt 0.3 * $fit) { $dips++ } }
        }
        $errIdx = @(); for ($i = 0; $i -lt $r.ZoneErrors.Length; $i++) { if ($r.ZoneErrors[$i] -gt 0) { $errIdx += $i } }
        $graph = Get-SpeedGraph $sp 60 $errIdx
        $totErr += $r.Errors; $totSlow += $r.SlowBlocks
        if ($okv.Count -and ($null -eq $worstUni -or $uni -lt $worstUni)) { $worstUni = $uni }
        # Вердикт
        $st = 'ok'; $why = @()
        if ($r.Errors -gt 0) {
            $st = 'crit'; $why += ('ошибок чтения: {0}' -f $r.Errors)
            Add-Issue 'crit' 'Накопитель' ('{0} — нечитаемые участки поверхности ({1} шт.)' -f $label, $r.Errors) 'Нечитаемые участки — диск умирает, срочно копируйте данные и замените накопитель.'
        }
        if ($r.Aborted -and $r.Note) { $st = 'crit'; $why += $r.Note }
        if ($isHdd) {
            $dipLim = [math]::Max(3, [int]($r.ZonesDone * 0.05))
            if ($dips -ge $dipLim -or $r.SlowBlocks -gt 10) {
                if ($st -ne 'crit') { $st = 'crit' }
                Add-Issue 'crit' 'Накопитель' ('{0} — много медленных участков поверхности (провалов скорости: {1}, задержек > {2} мс: {3})' -f $label, $dips, $slowMs, $r.SlowBlocks) 'Поверхность HDD деградирует (слабые сектора читаются с повторами). Сделайте резервную копию и планируйте замену диска.'
            } elseif ($dips -gt 0 -or $r.SlowBlocks -ge 3) {
                if ($st -eq 'ok') { $st = 'warn' }
                Add-Issue 'warn' 'Накопитель' ('{0} — есть медленные участки поверхности (провалов скорости: {1}, задержек > {2} мс: {3})' -f $label, $dips, $slowMs, $r.SlowBlocks) 'Возможны «слабые» сектора. Держите резервную копию; повторите проверку, когда компьютер ничем не занят (фоновая активность Windows тоже даёт провалы на системном HDD).'
            }
            if ($dips) { $why += "провалов скорости: $dips" }
        } else {
            if ($uni -gt 0 -and $uni -lt 0.3) {
                if ($st -eq 'ok') { $st = 'warn' }; $why += ('неравномерная скорость (мин./медиана {0:N2})' -f $uni)
                Add-Issue 'warn' 'Накопитель' ('{0} — неравномерная скорость чтения: местами {1:N0} МБ/с при обычных {2:N0} МБ/с' -f $label, $r.MinSpeed, $med) 'Участки читаются заметно медленнее: перегрев, деградация памяти SSD или старые данные, читаемые с коррекцией ошибок. Сделайте резервную копию, обновите прошивку SSD, проверьте температуру.'
            }
            if ($r.SlowBlocks -gt 5) {
                if ($st -eq 'ok') { $st = 'warn' }
                Add-Issue 'warn' 'Накопитель' ('{0} — зависания при чтении: {1} блоков дольше {2} мс (макс. {3:N0} мс)' -f $label, $r.SlowBlocks, $slowMs, $r.MaxLatencyMs) 'Для SSD это ненормально: возможна деградация памяти или контроллера, перегрев. Сделайте резервную копию, обновите прошивку.'
            }
        }
        if ($r.SlowBlocks) { $why += ('медленных блоков (> {0} мс): {1}' -f $slowMs, $r.SlowBlocks) }
        if ($r.TimedOut) { $why += ('прочитано {0} из {1} зон (не хватило времени)' -f $r.ZonesDone, $r.ZonesPlanned) }
        Add-Row $s ('{0}: скорость по поверхности' -f $label) ('начало → конец диска: {0}' -f $graph) $st
        Add-Row $s ('{0}: итог' -f $label) ($(if ($why.Count) { $why -join '; ' } else { 'ошибок и медленных участков нет' })) $st
        $rows += [pscustomobject]@{
            'Накопитель'       = $label
            'Тип'              = ('{0} {1}' -f $media, $bus).Trim()
            'Объём'            = GB $size 0
            'Средняя, МБ/с'    = '{0:N0}' -f $r.AvgSpeed
            'Мин., МБ/с'       = '{0:N0}' -f $r.MinSpeed
            'Равномерность'    = $(if ($med -gt 0) { '{0:N0} %' -f (100 * $uni) } else { '—' })
            'Медл. блоки'      = $r.SlowBlocks
            'Макс. задержка'   = '{0:N0} мс' -f $r.MaxLatencyMs
            'Ошибки чтения'    = $r.Errors
            'Прочитано'        = '{0:N1} ГБ за {1:N0} с, зон {2}/{3}' -f ($r.BytesRead / 1GB), $r.Seconds, $r.ZonesDone, $r.ZonesPlanned
        }
        if ($r.ErrorPositions.Length) {
            $er = @(); for ($i = 0; $i -lt $r.ErrorPositions.Length; $i++) {
                $er += [pscustomobject]@{ 'Позиция' = '{0:N2} ГБ' -f ($r.ErrorPositions[$i] / 1GB); 'LBA (512 Б)' = [long]($r.ErrorPositions[$i] / 512); 'Код Windows' = $r.ErrorCodes[$i] }
            }
            Add-Table $s ('Ошибки чтения: {0} (первые 20)' -f $label) $er -Collapsed
        }
        $G.Log.Add(('surface disk {0}: zones {1}/{2} avg {3:N0} min {4:N0} med {5:N0} slow {6} err {7} maxlat {8:N0} dips {9} note {10}' -f $num, $r.ZonesDone, $r.ZonesPlanned, $r.AvgSpeed, $r.MinSpeed, $med, $r.SlowBlocks, $r.Errors, $r.MaxLatencyMs, $dips, $r.Note))
    }
    Add-Table $s 'Итог по дискам' $rows
    Add-Row $s 'Как читать график' '▁…█ — скорость чтения зоны относительно максимума, × — зона с ошибкой чтения. У HDD скорость плавно падает к концу диска — это норма; резкие провалы — нет.'
    $G.Num.surface_err = [int]$totErr
    $G.Num.surface_slow = [int]$totSlow
    if ($null -ne $worstUni) { $G.Num.surface_uni = [int](100 * $worstUni) }
}
