# История этого ПК и прогноз: что ухудшается со временем и что скоро может сломаться.
# Сервер хранит прошлые отчёты; сравниваем текущие замеры с прошлыми визитами (по pc_id — хеш UUID платы).
Step 'Прогноз: что ухудшается и скоро может сломаться' {
    if ($null -ne $G.CpuTmax) { $G.Num.cpu_tmax = [math]::Round([double]$G.CpuTmax) }
    if ($G.GpuStressMax -and $null -ne $G.GpuStressMax.T) { $G.Num.gpu_tmax = [math]::Round([double]$G.GpuStressMax.T); if ($null -ne $G.GpuStressMax.H) { $G.Num.gpu_hot_delta = [math]::Round([double]$G.GpuStressMax.H - [double]$G.GpuStressMax.T) } }
    if ($null -ne $G.UnsafeShutdowns) { $G.Num.unsafe_sys = [int64]$G.UnsafeShutdowns }
    $s = New-Section 'Прогноз: что ухудшается и скоро может сломаться'
    $rows = New-Object System.Collections.Generic.List[object]
    function PRow($node, $now, $trend, $fc, $st) { $rows.Add([pscustomobject]@{ 'Узел' = $node; 'Сейчас' = $now; 'Изменение' = $trend; 'Прогноз' = $fc; '_st' = $st }) }
    # ---- прошлые визиты
    $hist = @()
    $pcid = ''
    try { $u = (CIM Win32_ComputerSystemProduct | Select-Object -First 1).UUID; if ($u) { $pcid = -join ([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes("pcdiag:$u")) | Select-Object -First 8 | ForEach-Object { $_.ToString('x2') }) } } catch {}
    if ($pcid -and (-not $env:DIAG_NOSEND -or $env:DIAG_HISTORY)) {
        try {
            $base = $UPLOAD.Url -replace '/upload$', ''
            $wc = New-Object Net.WebClient; $wc.Encoding = [Text.Encoding]::UTF8
            $wc.Headers.Add('X-Diag-Token', $UPLOAD.Token); $wc.Headers.Add('Content-Type', 'application/json')
            $r = $wc.UploadString("$base/history", (@{ pc_id = $pcid } | ConvertTo-Json -Compress)) | ConvertFrom-Json
            if ($r.ok) { $hist = @($r.reports) }
        } catch { $G.Log.Add('history: ' + $_.Exception.Message) }
    }
    $prev = $hist | Select-Object -First 1
    $days = $null
    if ($prev) {
        $pt = [datetime]::Parse($prev.t, $IC)
        $days = ((Get-Date) - $pt).TotalDays
        Add-Row $s 'Прошлые диагностики этого компьютера' ('{0}; последняя — {1:dd.MM.yyyy} ({2:N0} дн. назад), оценка была {3}' -f $hist.Count, $pt, $days, $prev.score)
    } else { Add-Row $s 'Прошлые диагностики этого компьютера' 'нет (это первая) — при следующей проверке программа покажет, что изменилось' }
    $pn = if ($prev) { $prev.num } else { $null }
    $val = { param($o, $k) if ($null -eq $o) { $null } else { $v = $o.$k; if ($null -eq $v -or "$v" -eq '') { $null } else { [double]$v } } }
    # ---- диски
    foreach ($d in @($G.Num.disks)) {
        if (-not $d) { continue }
        $pd = $null
        if ($pn -and $pn.disks) { $pd = @($pn.disks) | Where-Object { $_.m -eq $d.m -and [math]::Abs([double]$_.gb - [double]$d.gb) -le 2 } | Select-Object -First 1 }
        $bad = @()
        foreach ($k in @(@('realloc', 'переназначенных секторов'), @('pend', 'нестабильных секторов'), @('unc', 'нечитаемых секторов'), @('media', 'ошибок данных'), @('crc', 'ошибок кабеля'))) {
            $now = & $val $d $k[0]; $was = & $val $pd $k[0]
            if ($null -ne $now -and $null -ne $was -and $now -gt $was) { $bad += ('{0}: было {1}, стало {2}' -f $k[1], $was, $now) }
        }
        if ($bad.Count) {
            $crit = @($bad | Where-Object { $_ -notmatch 'кабеля' }).Count -gt 0
            PRow $d.m ($bad -join '; ') 'РАСТЁТ' $(if ($crit) { 'поверхность/память деградирует — диск может отказать в ближайшие недели-месяцы' } else { 'проблема с кабелем/разъёмом растёт' }) $(if ($crit) { 'crit' } else { 'warn' })
            Add-Issue $(if ($crit) { 'crit' } else { 'warn' }) 'Накопитель' ("$($d.m): с прошлой проверки " + ($bad -join '; ')) $(if ($crit) { 'Рост числа плохих секторов — главный признак скорого отказа: срочно резервная копия и замена диска.' } else { 'Замените SATA-кабель или порт.' })
        }
        $life = & $val $d 'life'; $wgb = & $val $d 'wgb'
        if ($d.ssd -and $null -ne $life -and $life -lt 100 -and $life -gt 0) {
            $fc = $null; $trend = '—'
            $plife = & $val $pd 'life'
            if ($null -ne $plife -and $days -ge 7 -and $plife -gt $life) {
                $perYear = ($plife - $life) / $days * 365
                $yrs = ($life - 10) / [math]::Max(0.01, $perYear)
                $trend = ('−{0:N1} % за {1:N0} дн.' -f ($plife - $life), $days)
                $fc = if ($yrs -lt 1) { 'ресурс закончится в течение года — готовьте замену' } elseif ($yrs -lt 3) { 'ресурса хватит примерно на {0:N1} г.' -f $yrs } else { 'ресурса хватит на годы (> 3 лет)' }
            } elseif ($wgb -and (100 - $life) -ge 1) {
                $fc = 'при таком же характере работы — ещё ~{0:N0} ТБ записи' -f ($wgb / (100 - $life) * ($life - 10) / 1024)
            }
            $st = if ($life -le 10) { 'crit' } elseif ($life -le 30) { 'warn' } else { 'ok' }
            PRow $d.m ('ресурс {0} %{1}' -f $life, $(if ($wgb) { ', записано {0:N1} ТБ' -f ($wgb / 1024) } else { '' })) $trend $(if ($fc) { $fc } else { '—' }) $st
            if ($life -le 10) { Add-Issue 'crit' 'Накопитель' "$($d.m): ресурс SSD почти исчерпан ($life %)" 'SSD может перейти в режим «только чтение» или отказать: резервная копия и замена.' }
        }
        $un = & $val $d 'unsafe'; $pun = & $val $pd 'unsafe'
        if ($null -ne $un -and $null -ne $pun -and $days -gt 0 -and $un -gt $pun) {
            $per = ($un - $pun) / [math]::Max(1, $days) * 30
            PRow $d.m ('аварийных отключений питания: {0}' -f $un) ('+{0} за {1:N0} дн.' -f ($un - $pun), $days) $(if ($per -ge 5) { 'компьютер часто теряет питание — риск повреждения данных и SSD' } else { 'единичные' }) $(if ($per -ge 5) { 'warn' } else { '' })
        }
    }
    # ---- охлаждение: максимум под нагрузкой против прошлого визита
    foreach ($c in @(@('cpu_tmax', 'Охлаждение процессора', 8), @('gpu_tmax', 'Охлаждение видеокарты', 7))) {
        $now = & $val $G.Num $c[0]; $was = & $val $pn $c[0]
        if ($null -eq $now -or $null -eq $was) { continue }
        $dt = $now - $was
        $st = if ($dt -ge $c[2] + 5) { 'crit' } elseif ($dt -ge $c[2]) { 'warn' } else { 'ok' }
        PRow $c[1] ('{0:N0} °C под нагрузкой' -f $now) ('{0:+0;-0;0} °C с прошлого раза' -f $dt) $(if ($st -ne 'ok') { 'охлаждение ухудшается: пыль / высыхает термопаста — нужна чистка' } else { 'стабильно' }) $st
        if ($st -ne 'ok') { Add-Issue 'warn' 'Охлаждение' ('{0}: под нагрузкой на {1:N0} °C горячее, чем при прошлой проверке' -f $c[1], $dt) 'Типичный признак пыли и высохшей термопасты: почистите систему охлаждения и замените пасту, пока не начался перегрев.' }
    }
    # тепловое сопротивление охлаждения (°C/Вт, тест «охлаждение по кривой»): рост = пыль / высыхает паста
    $rn = & $val $G.Num 'cool_rth'; $rw = & $val $pn 'cool_rth'
    if ($null -ne $rn -and $null -ne $rw -and $rw -gt 0) {
        $dr = $rn - $rw; $st = if ($dr -ge 0.15) { 'crit' } elseif ($dr -ge 0.08) { 'warn' } else { 'ok' }
        PRow 'Охлаждение процессора (°C/Вт)' ('{0:N2} °C/Вт' -f $rn) ('{0:+0.00;-0.00;0.00} с прошлого раза' -f $dr) $(if ($st -ne 'ok') { 'кулер стал хуже отводить тепло — чистка и замена пасты' } else { 'стабильно' }) $st
    }
    $hd = & $val $G.Num 'gpu_hot_delta'
    if ($null -ne $hd -and $hd -ge 20) { PRow 'Видеокарта: термопаста' ('разница ядро/hot spot {0:N0} °C' -f $hd) '—' $(if ($hd -ge 25) { 'термопаста высохла/плохой прижим — замените' } else { 'на границе нормы — паста начинает сохнуть' }) $(if ($hd -ge 25) { 'warn' } else { '' }) }
    # ---- аккумулятор
    $bh = & $val $G.Num 'bat_health'
    if ($null -ne $bh) {
        $pbh = & $val $pn 'bat_health'; $trend = '—'; $fc = '—'
        if ($null -ne $pbh -and $days -ge 14 -and $pbh -gt $bh) {
            $perM = ($pbh - $bh) / $days * 30; $trend = ('−{0:N0} % за {1:N0} дн.' -f ($pbh - $bh), $days)
            if ($bh -gt 60) { $fc = 'до 60 % (заметно меньше автономность) — примерно {0:N0} мес.' -f (($bh - 60) / [math]::Max(0.1, $perM)) } else { $fc = 'пора менять' }
        } elseif ($bh -lt 60) { $fc = 'пора менять' } elseif ($bh -lt 75) { $fc = 'заметный износ, замена в ближайший год-два' }
        PRow 'Аккумулятор' ('здоровье {0} %, циклов {1}' -f $bh, $G.Num.bat_cycles) $trend $fc $(if ($bh -lt 60) { 'crit' } elseif ($bh -lt 75) { 'warn' } else { 'ok' })
    }
    # ---- производительность: падение относительно прошлого раза
    foreach ($m in @(@('cpu_mips', 'Процессор (7-Zip)', 12), @('gpu_score', 'Видеокарта (FurMark)', 12), @('disk_seq_r', 'Диск: чтение', 30), @('ram_read', 'Память: скорость', 20))) {
        $now = & $val $G.Num $m[0]; $was = & $val $pn $m[0]
        if ($null -eq $now -or $null -eq $was -or $was -le 0) { continue }
        $dp = 100.0 * ($now - $was) / $was
        if ($dp -le -$m[2]) {
            PRow $m[1] ('{0:N0}' -f $now) ('{0:N0} % к прошлому разу' -f $dp) 'производительность упала: перегрев/троттлинг, фоновые программы, износ' 'warn'
            Add-Issue 'warn' 'Производительность' ('{0}: результат на {1:N0} % ниже, чем при прошлой проверке' -f $m[1], -$dp) 'Проверьте температуры под нагрузкой, режим питания Windows и фоновые программы; для дисков — заполненность и износ.'
        }
    }
    if ($prev -and $prev.shutdowns -and $G.Shutdowns) {
        $was = 0; foreach ($p in $prev.shutdowns.PSObject.Properties) { $was += [int]$p.Value }
        $now = 0; foreach ($k in @($G.Shutdowns.Keys)) { $now += [int]$G.Shutdowns[$k] }
        PRow 'Внезапные выключения (за 30 дней)' $now ('было {0}' -f $was) $(if ($now -gt $was) { 'учащаются' } elseif ($now -lt $was) { 'стало реже' } else { 'без изменений' }) $(if ($now -gt $was -and $now -ge 3) { 'warn' } else { '' })
    }
    if ($rows.Count) {
        Add-Table $s 'Узлы: состояние, изменение, прогноз' @($rows | Select-Object 'Узел', 'Сейчас', 'Изменение', 'Прогноз')
        $risk = @($rows | Where-Object { $_._st -in 'crit', 'warn' })
        $names = @($risk | ForEach-Object { $_.'Узел' } | Select-Object -Unique)
        Add-Row $s 'Итог прогноза' $(if ($risk.Count) { 'риск отказа: ' + ($names -join ', ') } else { 'признаков скорого отказа не найдено' }) $(if (@($risk | Where-Object { $_._st -eq 'crit' }).Count) { 'crit' } elseif ($risk.Count) { 'warn' } else { 'ok' })
    }
}
