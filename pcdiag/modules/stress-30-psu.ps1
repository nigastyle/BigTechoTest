# Совместный тест блока питания: процессор (Prime95) + видеокарта (FurMark) одновременно — максимум потребления.
# Ловит слабый/изношенный БП, который в отдельных тестах не проявляется (выключения и перезагрузки в играх).
# ключ и пресет — в lib-31-psu-keys.ps1 (пресеты применяются до блока stress)
Step 'Блок питания: совместная нагрузка CPU + GPU' {
    $s = New-Section 'Блок питания: совместная нагрузка CPU + GPU'
    $min = [int]$G.Sel.psumin; if ($min -lt 1) { $min = 2 }
    $p95 = Get-Tool 'Prime95'; $fm = Get-Tool 'FurMark'
    if (-not $p95 -or -not $fm) { Add-Row $s 'Тест' 'нет Prime95 или FurMark' 'warn'; return }
    # Напряжения в простое (для сравнения с нагрузкой)
    $idle = @(); 1..3 | ForEach-Object { $idle += Read-Key; Start-Sleep -Milliseconds 700 }
    $avg = { param($a, $f) $v = @($a | ForEach-Object { $_.$f } | Where-Object { $null -ne $_ }); if ($v.Count) { ($v | Measure-Object -Average).Average } else { $null } }
    $i12 = & $avg $idle 'V12'; $i5 = & $avg $idle 'V5'; $i33 = & $avg $idle 'V33'
    Info ("совместная нагрузка процессор + видеокарта: {0} мин. Если компьютер выключится — это ответ: блок питания не тянет (при следующем запуске программа покажет подробности)." -f $min)
    $pd = Split-Path $p95
    $thr = [math]::Max(1, [Environment]::ProcessorCount - 1)   # один поток оставляем FurMark, чтобы он догружал видеокарту
    Remove-Item (Join-Path $pd 'results.txt') -ErrorAction SilentlyContinue
    @('V30OptionsConverted=1', 'StressTester=1', 'UsePrimenet=0', 'MinTortureFFT=4', 'MaxTortureFFT=32', 'TortureMem=0', 'TortureTime=3', "TortureThreads=$thr", 'TortureHyperthreading=1') | Set-Content (Join-Path $pd 'prime.txt') -Encoding ascii
    $t0 = Get-Date
    $pp = Start-Process $p95 -ArgumentList '-t' -WorkingDirectory $pd -PassThru -WindowStyle Normal
    $fd = Split-Path $fm
    $fa = '--demo furmark-gl --width 1920 --height 1080 --max-time {0} --no-score-box --disable-demo-options' -f ($min * 60 + 30)
    $pf = Start-Process $fm -ArgumentList $fa -WorkingDirectory $fd -PassThru
    $smiH = if (Get-Command Start-SmiLog -ErrorAction SilentlyContinue) { Start-SmiLog } else { $null }
    $L = New-Object System.Collections.Generic.List[object]; $stop = $null
    try {
    while (((Get-Date) - $t0).TotalMinutes -lt $min) {
        Start-Sleep -Seconds 3
        $k = Read-Key; $L.Add($k)
        if (Stop-Requested) { Write-Host ''; Warn 'тест остановлен: ТемпературныйНюхач обнаружил аномалию'; break }
        $tot = 0; if ($k.CpuPower) { $tot += $k.CpuPower }; if ($k.GpuPower) { $tot += $k.GpuPower }
        Write-Host -NoNewline ("`r    {0,4:N0} с | CPU {1} °C | GPU {2} °C | CPU+GPU {3} Вт{4}   " -f ((Get-Date) - $t0).TotalSeconds, $(if ($null -ne $k.CpuTemp) { '{0:N0}' -f $k.CpuTemp } else { '—' }), $(if ($null -ne $k.GpuTemp) { '{0:N0}' -f $k.GpuTemp } else { '—' }), $(if ($tot) { '{0:N0}' -f $tot } else { '—' }), $(if ($k.V12) { ' | 12V {0:N2}' -f $k.V12 } else { '' }))
        if ($null -ne $k.CpuTemp -and $k.CpuTemp -ge 100) { $stop = 'температура процессора 100 °C'; break }
        if ($null -ne $k.GpuTemp -and $k.GpuTemp -ge 95) { $stop = 'температура видеокарты 95 °C'; break }
        if ($pf.HasExited -and ((Get-Date) - $t0).TotalSeconds -lt ($min * 60 - 5)) { $stop = 'FurMark завершился раньше времени'; break }
        if ($pp.HasExited) { $stop = 'Prime95 завершился раньше времени'; break }
    }
    } finally { foreach ($x in $pp, $pf, $(if ($smiH) { $smiH.P })) { try { if ($x -and -not $x.HasExited) { $x.Kill() } } catch {} } }
    Write-Host ''
    $smi = if ($smiH) { Stop-SmiLog $smiH } else { @() }
    Start-Sleep -Seconds 1
    $dur = ((Get-Date) - $t0).TotalSeconds
    Add-Row $s 'Длительность' ('{0:N0} с из {1} мин' -f $dur, $min) $(if ($stop) { 'warn' } else { 'ok' })
    if ($stop) { Add-Row $s 'Остановлен досрочно' $stop 'warn' }
    $mx = { param($f) $v = @($L | ForEach-Object { $_.$f } | Where-Object { $null -ne $_ }); if ($v.Count) { ($v | Measure-Object -Maximum).Maximum } else { $null } }
    # устойчивый минимум (второй снизу): одиночный выброс датчика не считается просадкой
    $mn = { param($f) $v = @($L | ForEach-Object { $_.$f } | Where-Object { $null -ne $_ } | Sort-Object); if ($v.Count -ge 3) { $v[1] } elseif ($v.Count) { $v[0] } else { $null } }
    $cpuP = & $mx 'CpuPower'; $gpuP = & $mx 'GpuPower'
    $tot = @($L | ForEach-Object { $a = 0; if ($_.CpuPower) { $a += $_.CpuPower }; if ($_.GpuPower) { $a += $_.GpuPower }; $a }) | Measure-Object -Maximum
    if ($tot.Maximum) {
        Add-Row $s 'Мощность процессор + видеокарта (макс.)' ('{0:N0} Вт (CPU {1:N0} + GPU {2:N0})' -f $tot.Maximum, $cpuP, $gpuP)
        Add-Row $s 'Рекомендуемый блок питания' ('не менее {0:N0} Вт качественного БП (с запасом на плату, диски, вентиляторы и пики)' -f ([math]::Ceiling(($tot.Maximum * 1.25 + 75) / 50) * 50))
        $G.Num.psu_load_w = [int]$tot.Maximum
    }
    $ct = & $mx 'CpuTemp'; $gt = & $mx 'GpuTemp'
    if ($null -ne $ct) { Add-Row $s 'Процессор: макс. температура' ('{0:N0} °C' -f $ct) $(if ($ct -ge 95) { 'crit' } elseif ($ct -ge 90) { 'warn' } else { 'ok' }) }
    if ($null -ne $gt) { Add-Row $s 'Видеокарта: макс. температура' ('{0:N0} °C' -f $gt) $(if ($gt -ge 88) { 'crit' } elseif ($gt -ge 84) { 'warn' } else { 'ok' }) }
    if ($null -ne $ct -and $null -ne $G.CpuTmax -and $ct -ge $G.CpuTmax + 8) { Add-Issue 'warn' 'Охлаждение' ('когда греется видеокарта, процессор нагревается до {0:N0} °C (в одиночном тесте {1:N0} °C)' -f $ct, $G.CpuTmax) 'Плохая вентиляция корпуса: горячий воздух от видеокарты не выводится. Добавьте/разверните корпусные вентиляторы (вдув спереди, выдув сзади и сверху).' }
    # Напряжения: просадка под нагрузкой
    $rails = @(@('V12', '+12V', 12.0, $i12), @('V5', '+5V', 5.0, $i5), @('V33', '+3.3V', 3.3, $i33))
    $anyV = $false
    foreach ($r in $rails) {
        $lo = & $mn $r[0]; if ($null -eq $lo) { continue }; $anyV = $true
        $dev = 100.0 * ($lo - $r[2]) / $r[2]; $sag = if ($null -ne $r[3]) { 100.0 * ($r[3] - $lo) / $r[3] } else { $null }
        $st = if ($dev -le -8 -or ($null -ne $sag -and $sag -ge 6)) { 'crit' } elseif ($dev -le -5 -or ($null -ne $sag -and $sag -ge 4.5)) { 'warn' } else { 'ok' }
        Add-Row $s ('{0}: в простое → минимум под нагрузкой' -f $r[1]) ('{0} → {1:N2} В ({2:+0.0;−0.0} % от нормы{3})' -f $(if ($null -ne $r[3]) { '{0:N2}' -f $r[3] } else { '—' }), $lo, $dev, $(if ($null -ne $sag) { ', просадка {0:N1} %' -f $sag } else { '' })) $st
        if ($st -ne 'ok') { Add-Issue $st 'Питание' ('линия {0} проседает под нагрузкой до {1:N2} В' -f $r[1], $lo) 'Блок питания не держит напряжение: изношен или слабый. Замените БП на качественный нужной мощности (датчики платы имеют погрешность 2–3 %, поэтому решение — после проверки мультиметром/заменой БП).' }
    }
    if (-not $anyV) { Add-Row $s 'Напряжения линий БП' 'плата не отдаёт названные датчики +12V/+5V (у многих плат их нет) — оценка по стабильности под нагрузкой' }
    $vc = & $mx 'Vcore'; if ($null -ne $vc) { Add-Row $s 'Vcore (макс. под нагрузкой)' ('{0:N3} В' -f $vc) $(if ($vc -ge 1.55) { 'warn' } else { 'ok' }) }
    if ($vc -ge 1.55) { Add-Issue 'warn' 'Процессор' ('высокое напряжение (VID) на процессоре под нагрузкой: {0:N3} В' -f $vc) 'Проверьте настройки BIOS (ручное напряжение, разгон, «MultiCore Enhancement»); для Intel 13/14 поколения — обязательно BIOS с микрокодом 0x12F.' }
    # Сбои во время теста
    $tdr = @(); try { $tdr = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Display'; Id = 4101; StartTime = $t0 } -ErrorAction Stop) } catch {}
    $whea = @(); try { $whea = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WHEA-Logger'; Level = 1, 2; StartTime = $t0 } -ErrorAction Stop) } catch {}
    $res = Get-Content (Join-Path $pd 'results.txt') -Raw -ErrorAction SilentlyContinue
    $pfail = @([regex]::Matches("$res", '(?im)^.*(FATAL ERROR|Hardware failure|ILLEGAL SUMOUT|SUM\(INPUTS\) != SUM\(OUTPUTS\)|Rounding was .* expected less than|possible hardware failure).*$')).Count
    $brake = 0
    foreach ($r in $smi) { $m = "$($r.'clocks_throttle_reasons.active')"; if ($m) { try { if (([Convert]::ToUInt64(($m -replace '^0x', ''), 16) -band 0x88) -ne 0) { $brake++ } } catch {} } }
    $prob = @()
    if ($tdr.Count) { $prob += "сбой видеодрайвера ($($tdr.Count))" }
    if ($whea.Count) { $prob += "аппаратные ошибки WHEA ($($whea.Count))" }
    if ($pfail) { $prob += "ошибки вычислений Prime95 ($pfail)" }
    if ($brake) { $prob += 'видеокарта получала сигнал торможения по питанию' }
    if ($brake -lt 3) { $prob = @($prob | Where-Object { $_ -notmatch 'торможения' }) }
    if ($stop -match 'раньше') { Add-Issue 'info' 'Питание' ('совместный тест: ' + $stop) 'Тест не отработал полностью — вывод о блоке питания недостоверен; повторите.' }
    Add-Row $s 'Стабильность под полной нагрузкой' $(if ($prob.Count) { $prob -join '; ' } else { 'сбоев нет' }) $(if ($prob.Count) { 'crit' } else { 'ok' })
    if ($prob.Count) { Add-Issue 'crit' 'Питание' ('под одновременной нагрузкой CPU + GPU: ' + ($prob -join '; ')) 'По отдельности компоненты могут работать, а вместе — нет: это типичная картина слабого или изношенного блока питания (реже — перегрев в корпусе). Проверьте БП заменой на заведомо исправный с запасом мощности.' }
}
