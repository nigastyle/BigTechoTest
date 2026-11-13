# Полный SMART через smartctl (smartmontools, JSON): то, чего не видно через LibreHardwareMonitor/DiskInfoToolkit —
# собственный вердикт диска, биты критических предупреждений NVMe, резерв, журнал ошибок ATA, история самотестов, атрибуты «сбоил сейчас/в прошлом».
# Переназначенные/нестабильные сектора, износ, ошибки носителя NVMe, CRC уже выдаёт шаг 'Накопители (SSD / HDD)' — здесь не дублируются.
Step 'Накопители: полный SMART (smartctl)' {
    $s = New-Section 'Накопители: полный SMART (smartctl)'
    if (-not (Get-Smartctl)) { Add-Row $s 'smartctl' 'не удалось загрузить программу — раздел пропущен' 'warn'; return }
    $devs = @(Get-SmartDevices -Refresh)
    if (-not $devs.Count) { Add-Row $s 'Накопители' 'smartctl не нашёл ни одного диска' 'warn'; return }
    function HasIssue($lbl, $re) {
        foreach ($x in (AsArr $G.Issues)) {
            $t = "$($x.Text)"
            if ($lbl -and $t.IndexOf($lbl, [StringComparison]::OrdinalIgnoreCase) -ge 0 -and $t -match $re) { return $true }
        }
        return $false
    }
    function N($v) { if ($null -eq $v -or "$v" -eq '') { return $null }; try { return [double]$v } catch { return $null } }
    $cwText = @(@(1, 'резервные блоки ниже порога'), @(2, 'температура вне допустимого диапазона'), @(4, 'надёжность снижена из-за ошибок носителя'), @(8, 'диск переведён в режим только чтения'), @(16, 'отказ резервного питания (volatile memory backup)'))
    $over = @()
    $nOk = 0; $nFail = 0; $nCw = 0; $errLogSum = 0; $stBad = 0; $wfNow = 0; $minSpare = $null; $maxUsed = $null
    foreach ($d in $devs) {
        $lbl = $d.Label
        if ($d.OpenError) { Add-Row $s $lbl ('нет доступа: ' + $d.OpenError) ''; continue }
        $j = $d.J
        if (-not $j) { Add-Row $s $lbl 'smartctl не вернул данные' 'warn'; continue }
        $ex = [int](N $j.smartctl.exit_status)
        if (($ex -band 2) -or ($j.smart_support -and $j.smart_support.available -eq $false)) {
            Add-Row $s $lbl 'SMART недоступен (USB-адаптер или RAID-контроллер не пропускает команды)' ''
            $over += [pscustomobject]@{ 'Накопитель' = $lbl; 'Серийный №' = $d.Serial; 'Прошивка' = Clean $j.firmware_version; 'Интерфейс' = $d.Proto; 'SMART' = 'недоступен'; 'Температура' = '—'; 'Наработка' = '—'; 'Включений' = '—' }
            continue
        }
        $nOk++
        $isNvme = ($d.Proto -eq 'NVMe')
        $isAta = ($d.Proto -eq 'ATA')
        $nv = $j.nvme_smart_health_information_log
        # ---- общий вердикт диска
        $passed = $null; if ($j.smart_status -and $null -ne $j.smart_status.passed) { $passed = [bool]$j.smart_status.passed }
        $temp = N $j.temperature.current
        $poh = N $j.power_on_time.hours
        $cyc = N $j.power_cycle_count
        if ($isNvme -and $nv) {
            if ($null -eq $temp) { $temp = N $nv.temperature }
            if ($null -eq $poh) { $poh = N $nv.power_on_hours }
            if ($null -eq $cyc) { $cyc = N $nv.power_cycles }
        }
        $verd = $(if ($null -eq $passed) { '—' } elseif ($passed) { 'норма (PASSED)' } else { 'ОТКАЗ (FAILED)' })
        $over += [pscustomobject]@{
            'Накопитель'  = $lbl
            'Серийный №'  = $d.Serial
            'Прошивка'    = Clean $j.firmware_version
            'Интерфейс'   = ('{0} {1}' -f $d.Proto, $d.Name).Trim()
            'SMART'       = $verd
            'Температура' = $(if ($null -ne $temp) { '{0:N0} °C' -f $temp } else { '—' })
            'Наработка'   = $(if ($null -ne $poh) { '{0:N0} ч' -f $poh } else { '—' })
            'Включений'   = $(if ($null -ne $cyc) { '{0:N0}' -f $cyc } else { '—' })
        }
        Add-Row $s ('{0}: самооценка SMART' -f $lbl) $verd $(if ($null -eq $passed) { '' } elseif ($passed) { 'ok' } else { 'crit' })
        if ($passed -eq $false) {
            $nFail++
            if (-not (HasIssue $lbl 'SMART: ПЛОХОЕ|состояние:')) { Add-Issue 'crit' 'Накопитель' "$lbl — диск сам сообщает об отказе (SMART FAILED)" 'Диск может отказать в любой момент: СРОЧНО скопируйте важные данные и замените накопитель.' }
        }
        # ---- ATA / SATA
        if ($isAta) {
            $arows = @(); $nowA = @(); $pastA = @()
            foreach ($a in @($j.ata_smart_attributes.table)) {
                if (-not $a) { continue }
                $wf = "$($a.when_failed)"
                if ($wf -eq 'now') { $nowA += ('{0} ({1})' -f $a.name, $a.id) } elseif ($wf -eq 'past') { $pastA += ('{0} ({1})' -f $a.name, $a.id) }
                $arows += [pscustomobject]@{
                    'ID' = $a.id; 'Атрибут' = "$($a.name)"; 'Значение' = $a.value; 'Худшее' = $a.worst; 'Порог' = $a.thresh
                    'Сырое' = $(if ($a.raw.string) { "$($a.raw.string)" } else { "$($a.raw.value)" })
                    'Тип' = $(if ($a.flags.prefailure) { 'критичный' } else { '' })
                    'Сбой' = $(switch ($wf) { 'now' { 'СЕЙЧАС' } 'past' { 'в прошлом' } default { '' } })
                }
            }
            if ($arows.Count) { Add-Table $s ('Атрибуты SMART (smartctl): {0}' -f $lbl) $arows -Collapsed }
            if ($nowA.Count) {
                $wfNow += $nowA.Count
                Add-Row $s ('{0}: атрибуты ниже порога' -f $lbl) ($nowA -join ', ') 'crit'
                Add-Issue 'crit' 'Накопитель' ('{0} — атрибуты SMART сейчас ниже порога отказа: {1}' -f $lbl, ($nowA -join ', ')) 'Производитель считает диск неисправным: СРОЧНО сделайте резервную копию и замените накопитель.'
            }
            if ($pastA.Count) {
                Add-Row $s ('{0}: атрибуты, бывшие ниже порога' -f $lbl) ($pastA -join ', ') 'warn'
                Add-Issue 'warn' 'Накопитель' ('{0} — атрибуты SMART в прошлом опускались ниже порога отказа: {1}' -f $lbl, ($pastA -join ', ')) 'Был эпизод отказа (перегрев, сбой питания или деградация). Держите резервную копию, повторите проверку.'
            }
            # журнал ошибок
            $ec = N $j.ata_smart_error_log.summary.count
            if ($null -eq $ec) { $ec = N $j.ata_smart_error_log.extended.count }
            if ($null -ne $ec) {
                $errLogSum += [int]$ec
                Add-Row $s ('{0}: журнал ошибок диска' -f $lbl) $(if ($ec -gt 0) { 'записей: {0:N0}' -f $ec } else { 'пуст' }) $(if ($ec -gt 0) { 'warn' } else { 'ok' })
                if ($ec -gt 0) { Add-Issue 'warn' 'Накопитель' ('{0} — в журнале ошибок диска {1:N0} записей' -f $lbl, $ec) 'Диск фиксировал сбои команд (чтение/запись/интерфейс). Если число растёт — проверьте кабель/питание SATA и сделайте резервную копию.' }
            }
            # история самотестов
            $tl = @($j.ata_smart_self_test_log.standard.table | Where-Object { $_ })
            if ($tl.Count) {
                $trows = @($tl | Select-Object -First 5 | ForEach-Object {
                        [pscustomobject]@{ 'Тест' = "$($_.type.string)"; 'Результат' = "$($_.status.string)"; 'Наработка, ч' = $_.lifetime_hours; 'LBA ошибки' = $(if ($null -ne $_.lba) { $_.lba } else { '' }) } })
                Add-Table $s ('Последние самотесты: {0}' -f $lbl) $trows -Collapsed
                $t0 = $tl[0]
                $f0 = $false
                if ($null -ne $t0.status.passed) { $f0 = (-not [bool]$t0.status.passed) }
                else { $hv = ([int](N $t0.status.value)) -shr 4; $f0 = ($hv -ge 3 -and $hv -le 8) }
                Add-Row $s ('{0}: последний самотест' -f $lbl) ('{0}: {1}' -f $t0.type.string, $t0.status.string) $(if ($f0) { 'crit' } else { '' })
                if ($f0) {
                    $stBad++
                    Add-Issue 'crit' 'Накопитель' ('{0} — последний встроенный самотест диска провален ({1}{2})' -f $lbl, $t0.status.string, $(if ($null -ne $t0.lba) { ', LBA ' + $t0.lba } else { '' })) 'Диск сам обнаружил дефект: СРОЧНО скопируйте важные данные и замените накопитель.'
                }
            } else { Add-Row $s ('{0}: самотесты' -f $lbl) 'журнал самотестов пуст' }
        }
        # ---- NVMe
        if ($isNvme -and $nv) {
            $cw = [int](N $nv.critical_warning)
            $bits = @(); foreach ($k in $cwText) { if ($cw -band $k[0]) { $bits += $k[1] } }
            Add-Row $s ('{0}: критические предупреждения' -f $lbl) $(if ($cw) { ('0x{0:X2}: {1}' -f $cw, ($bits -join '; ')) } else { 'нет' }) $(if ($cw) { 'crit' } else { 'ok' })
            if ($cw) {
                $nCw++
                Add-Issue 'crit' 'Накопитель' ('{0} — SSD выставил критическое предупреждение: {1}' -f $lbl, ($bits -join '; ')) 'Контроллер SSD сообщает об аварийном состоянии: СРОЧНО скопируйте данные. При «только чтение»/«надёжность снижена» — замена диска; при температуре — улучшите охлаждение (радиатор на NVMe).'
            }
            $sp = N $nv.available_spare; $spt = N $nv.available_spare_threshold
            if ($null -ne $sp) {
                $low = ($null -ne $spt -and $sp -lt $spt)
                Add-Row $s ('{0}: резерв блоков' -f $lbl) ('{0:N0} % (порог {1})' -f $sp, $(if ($null -ne $spt) { '{0:N0} %' -f $spt } else { '—' })) $(if ($low) { 'crit' } elseif ($sp -lt 50) { 'warn' } else { 'ok' })
                if ($null -eq $minSpare -or $sp -lt $minSpare) { $minSpare = $sp }
                if ($low -and -not ($cw -band 1)) { Add-Issue 'crit' 'Накопитель' ('{0} — резерв блоков {1:N0} % ниже порога {2:N0} %' -f $lbl, $sp, $spt) 'Запасные блоки SSD исчерпаны: резервная копия и замена диска.' }
            }
            $pu = N $nv.percentage_used
            if ($null -ne $pu) {
                Add-Row $s ('{0}: израсходовано ресурса' -f $lbl) ('{0:N0} %' -f $pu) $(if ($pu -ge 100) { 'crit' } elseif ($pu -ge 90) { 'warn' } else { 'ok' })
                if ($null -eq $maxUsed -or $pu -gt $maxUsed) { $maxUsed = $pu }
                if ($pu -ge 90 -and -not (HasIssue $lbl 'изношен')) {
                    if ($pu -ge 100) { Add-Issue 'crit' 'Накопитель' ('{0} — ресурс записи исчерпан ({1:N0} %)' -f $lbl, $pu) 'Заявленный ресурс SSD выработан: резервная копия и замена диска.' }
                    else { Add-Issue 'warn' 'Накопитель' ('{0} — ресурс записи почти исчерпан ({1:N0} %)' -f $lbl, $pu) 'Планируйте замену SSD, держите резервные копии.' }
                }
            }
            $me = N $nv.media_errors
            if ($null -ne $me) { Add-Row $s ('{0}: ошибки носителя' -f $lbl) ('{0:N0}' -f $me) $(if ($me -gt 0) { 'crit' } else { 'ok' }) }
            $ne = N $nv.num_err_log_entries
            if ($null -ne $ne) { Add-Row $s ('{0}: записей в журнале ошибок' -f $lbl) ('{0:N0} (обычно безвредны — неподдерживаемые команды от программ)' -f $ne) }
            $dw = N $nv.data_units_written; $dr = N $nv.data_units_read
            if ($null -ne $dw) { Add-Row $s ('{0}: записано / прочитано' -f $lbl) ('{0:N2} ТБ / {1} ТБ' -f ($dw * 512000 / 1e12), $(if ($null -ne $dr) { '{0:N2}' -f ($dr * 512000 / 1e12) } else { '—' })) }
            $us = N $nv.unsafe_shutdowns
            if ($null -ne $us) { Add-Row $s ('{0}: аварийных отключений питания' -f $lbl) ('{0:N0}' -f $us) }
            $ts = @($nv.temperature_sensors | Where-Object { $null -ne $_ })
            if ($ts.Count) { Add-Row $s ('{0}: датчики температуры' -f $lbl) ((@($ts | ForEach-Object { '{0:N0} °C' -f [double]$_ })) -join ', ') }
            $wt = N $nv.warning_temp_time; $ct = N $nv.critical_comp_time
            if ($null -ne $wt -or $null -ne $ct) {
                Add-Row $s ('{0}: время в перегреве (предупр. / крит.)' -f $lbl) ('{0:N0} / {1:N0} мин' -f [double]$wt, [double]$ct) $(if ($ct -gt 0) { 'warn' } elseif ($wt -gt 0) { 'warn' } else { 'ok' })
            }
            # история самотестов NVMe (smartctl 7.3+ выводит её в -a, если диск поддерживает)
            $nt = @($j.nvme_self_test_log.table | Where-Object { $_ })
            if ($nt.Count) {
                $trows = @($nt | Select-Object -First 5 | ForEach-Object {
                        [pscustomobject]@{ 'Тест' = "$($_.self_test_code.string)"; 'Результат' = "$($_.self_test_result.string)"; 'Наработка, ч' = $_.power_on_hours; 'LBA ошибки' = $(if ($null -ne $_.lba) { $_.lba } else { '' }) } })
                Add-Table $s ('Последние самотесты: {0}' -f $lbl) $trows -Collapsed
                $r0 = [int](N $nt[0].self_test_result.value)
                if ($r0 -ge 5 -and $r0 -le 7) {
                    $stBad++
                    Add-Issue 'crit' 'Накопитель' ('{0} — последний встроенный самотест SSD провален ({1}{2})' -f $lbl, $nt[0].self_test_result.string, $(if ($null -ne $nt[0].lba) { ', LBA ' + $nt[0].lba } else { '' })) 'Диск сам обнаружил дефект: СРОЧНО скопируйте важные данные и замените накопитель.'
                }
            }
        }
        if ($d.File) { $G.Log.Add(('smartctl {0} ({1}): exit {2}, json {3}' -f $d.Name, $lbl, $ex, $d.File)) }
    }
    Add-Table $s 'Накопители по данным smartctl' $over
    $G.Num.smart_n = $nOk
    $G.Num.smart_fail = $nFail
    $G.Num.smart_nvme_cw = $nCw
    $G.Num.smart_ata_errlog = $errLogSum
    $G.Num.smart_selftest_bad = $stBad
    $G.Num.smart_attr_now = $wfNow
    if ($null -ne $minSpare) { $G.Num.smart_min_spare = $minSpare }
    if ($null -ne $maxUsed) { $G.Num.smart_max_used = $maxUsed }
}
