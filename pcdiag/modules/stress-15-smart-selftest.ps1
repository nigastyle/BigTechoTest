# Встроенный короткий самотест накопителей (SMART short self-test) через smartctl: диск сам проверяет электронику,
# механику/контроллер и выборочно читает поверхность. Данные пользователя не изменяются. Все диски — параллельно, до ~4 мин.
Step 'Накопители: самотест SMART (smartctl)' {
    $s = New-Section 'Накопители: самотест SMART (smartctl)'
    if (-not (Get-Smartctl)) { Add-Row $s 'smartctl' 'не удалось загрузить программу — тест пропущен' 'warn'; return }
    $devs = @(Get-SmartDevices)
    if (-not $devs.Count) { $devs = @(Get-SmartDevices -Refresh) }
    if (-not $devs.Count) { Add-Row $s 'Накопители' 'smartctl не нашёл ни одного диска' 'warn'; return }
    function N($v) { if ($null -eq $v -or "$v" -eq '') { return $null }; try { return [double]$v } catch { return $null } }
    function LogSig($t) {
        # «отпечаток» журнала самотестов — чтобы понять, появилась ли новая запись
        if (-not $t) { return '' }
        if ($t.Kind -eq 'ATA') { $l = $t.LogJ.ata_smart_self_test_log.standard; $e = @($l.table)[0]; return ('{0}|{1}|{2}|{3}' -f $l.count, $e.lifetime_hours, $e.status.value, $e.type.value) }
        $l = $t.LogJ.nvme_self_test_log; $e = @($l.table)[0]; return ('{0}|{1}|{2}|{3}' -f @($l.table).Count, $e.power_on_hours, $e.self_test_result.value, $e.self_test_code.value)
    }
    function Short($x) { if ($x.Length -gt 22) { return $x.Substring(0, 21) + '…' }; return $x }
    $tests = New-Object System.Collections.Generic.List[object]
    foreach ($d in $devs) {
        $lbl = $d.Label
        if ($d.OpenError -or -not $d.J) { Add-Row $s $lbl 'самотест не поддерживается (нет доступа к диску)' ''; continue }
        $j = $d.J
        $kind = ''; $sup = $false; $poll = $null
        if ($d.Proto -eq 'ATA') {
            $kind = 'ATA'; $sup = ($j.ata_smart_data.capabilities.self_tests_supported -eq $true)
            $poll = N $j.ata_smart_data.self_test.polling_minutes.short
        } elseif ($d.Proto -eq 'NVMe') {
            $kind = 'NVMe'
            $c = $j.nvme_controller_capabilities
            $sup = $true; if ($c -and $null -ne $c.self_test) { $sup = [bool]$c.self_test }
            $poll = 2   # NVMe: короткий тест по стандарту не дольше 2 мин
        }
        if (-not $kind -or -not $sup) { Add-Row $s $lbl 'самотест не поддерживается (USB-адаптер, RAID или диск без самотеста)' ''; continue }
        $limMin = 4; if ($null -ne $poll -and $poll -gt 0) { $limMin = [math]::Min(4, [math]::Max(3, $poll + 1)) }
        $t = [pscustomobject]@{ Dev = $d; Kind = $kind; Label = $lbl; Limit = $limMin * 60; T0 = $null; Done = $false; Seen = $false; Pct = 0; TimedOut = $false; Stopped = $false; Sig = ''; LogJ = $null; Note = '' }
        $t.LogJ = Invoke-Smartctl (@('-l', 'selftest', '-j') + (Get-SmartctlDevArgs $d))
        $t.Sig = LogSig $t
        $r = Invoke-Smartctl (@('-t', 'short', '-j') + (Get-SmartctlDevArgs $d))
        $ex = 0; if ($r) { $ex = [int](N $r.smartctl.exit_status) }
        if (-not $r -or ($ex -band 6)) {
            $msg = ''; if ($r) { $msg = (@($r.smartctl.messages | ForEach-Object { "$($_.string)" }) -join '; ') }
            $G.Log.Add(('selftest {0}: не запущен, exit {1}: {2}' -f $d.Name, $ex, $msg))
            $why = 'самотест не поддерживается или не запустился'
            if ($msg -match '(?i)in progress|already') { $why = 'не запущен: на диске уже идёт самотест' }
            Add-Row $s $lbl $why ''
            continue
        }
        $t.T0 = Get-Date
        $tests.Add($t)
    }
    if (-not $tests.Count) { Add-Row $s 'Итог' 'ни на одном диске самотест не запущен'; return }
    Info ('короткий самотест SMART запущен на {0} диск(ах), до {1:N0} мин. Данные не изменяются.' -f $tests.Count, ((@($tests | ForEach-Object { $_.Limit }) | Measure-Object -Maximum).Maximum / 60))
    $tStart = Get-Date; $guard = $false
    try {
        while (@($tests | Where-Object { -not $_.Done }).Count) {
            Start-Sleep -Seconds 5
            if (Get-Command Guard-Tripped -ErrorAction SilentlyContinue) { if (Guard-Tripped) { $guard = $true; break } }
            foreach ($t in @($tests | Where-Object { -not $_.Done })) {
                $el = ((Get-Date) - $t.T0).TotalSeconds
                $da = Get-SmartctlDevArgs $t.Dev
                $run = $false
                if ($t.Kind -eq 'ATA') {
                    $c = Invoke-Smartctl (@('-c', '-j') + $da)
                    $st = $null; if ($c) { $st = $c.ata_smart_data.self_test.status }
                    if ($st -and (([int](N $st.value)) -band 0xF0) -eq 0xF0) {
                        $run = $true; $rem = N $st.remaining_percent; if ($null -ne $rem) { $t.Pct = 100 - $rem }
                    }
                } else {
                    $c = Invoke-Smartctl (@('-l', 'selftest', '-j') + $da)
                    $op = $null; if ($c) { $op = $c.nvme_self_test_log.current_self_test_operation }
                    if ($op -and [int](N $op.value) -ne 0) {
                        $run = $true; $p = N $c.nvme_self_test_log.current_self_test_completion_percent; if ($null -ne $p) { $t.Pct = $p }
                    }
                }
                if ($run) { $t.Seen = $true }
                if ($run -and $el -gt $t.Limit) {
                    [void](Invoke-Smartctl (@('-X', '-j') + $da)); $t.TimedOut = $true; $t.Stopped = $true; $t.Done = $true
                } elseif (-not $run) {
                    # тест не виден как идущий: либо уже закончился, либо диск ещё не обновил статус — даём ему 20 с
                    if ($t.Seen -or $el -ge 20) { $t.Done = $true; $t.Pct = 100 }
                    elseif ($t.Kind -eq 'ATA') {
                        $lj = Invoke-Smartctl (@('-l', 'selftest', '-j') + $da)
                        $old = $t.LogJ; $t.LogJ = $lj
                        if ($lj -and (LogSig $t) -ne $t.Sig) { $t.Done = $true; $t.Pct = 100 } else { $t.LogJ = $old }
                    } elseif ($c -and (LogSig ([pscustomobject]@{ Kind = 'NVMe'; LogJ = $c })) -ne $t.Sig) { $t.Done = $true; $t.Pct = 100 }
                }
            }
            $parts = @($tests | ForEach-Object { '{0} {1}' -f (Short $_.Label), $(if ($_.Done) { 'готово' } else { '{0:N0} %' -f $_.Pct }) })
            Write-Host -NoNewline ("`r    {0,4:N0} с | {1}   " -f ((Get-Date) - $tStart).TotalSeconds, ($parts -join ' | '))
            if ($G.LiveOk) {
                $cur = @($tests | Where-Object { -not $_.Done } | Select-Object -First 1)
                if ($cur.Count) { Live-Activity ('Самотест SMART: {0} — {1:N0} %' -f $cur[0].Label, $cur[0].Pct) }
            }
        }
    } finally {
        Write-Host ''
        # прерывание (Ctrl+C, сторож безопасности): останавливаем всё, что ещё идёт
        foreach ($t in @($tests | Where-Object { -not $_.Done })) {
            [void](Invoke-Smartctl (@('-X', '-j') + (Get-SmartctlDevArgs $t.Dev))); $t.Stopped = $true; $t.Done = $true
        }
    }
    $rows = @(); $nFail = 0; $nOk = 0
    foreach ($t in $tests) {
        $res = ''; $st = ''; $lba = $null; $failed = $false
        if ($t.Stopped) {
            $res = $(if ($t.TimedOut) { 'не уложился в {0:N0} мин — остановлен' -f ($t.Limit / 60) } elseif ($guard) { 'остановлен сторожем безопасности' } else { 'прерван' })
            $st = 'warn'
        } else {
            $lj = Invoke-Smartctl (@('-l', 'selftest', '-j') + (Get-SmartctlDevArgs $t.Dev))
            $e = $null
            if ($t.Kind -eq 'ATA') { if ($lj) { $e = @($lj.ata_smart_self_test_log.standard.table)[0] } }
            else { if ($lj) { $e = @($lj.nvme_self_test_log.table)[0] } }
            $newSig = LogSig ([pscustomobject]@{ Kind = $t.Kind; LogJ = $lj })
            if (-not $e -or (-not $t.Seen -and $newSig -eq $t.Sig)) {
                $res = 'результат не появился в журнале диска'; $st = ''
            } elseif ($t.Kind -eq 'ATA') {
                $hv = ([int](N $e.status.value)) -shr 4
                if ($null -ne $e.status.passed) { $failed = -not [bool]$e.status.passed } else { $failed = ($hv -ge 3 -and $hv -le 8) }
                $res = "$($e.status.string)"; $lba = $e.lba
                if ($failed) { $st = 'crit' } elseif ($hv -eq 0) { $st = 'ok' } else { $st = 'warn' }
            } else {
                $v = [int](N $e.self_test_result.value)
                $failed = ($v -ge 5 -and $v -le 7)
                $res = "$($e.self_test_result.string)"; $lba = $e.lba
                if ($failed) { $st = 'crit' } elseif ($v -eq 0) { $st = 'ok' } else { $st = 'warn' }
            }
        }
        if ($failed) {
            $nFail++
            $txt = '{0} — диск не прошёл встроенный самотест — неисправен{1}' -f $t.Label, $(if ($null -ne $lba) { " (первая ошибка: LBA $lba)" } else { '' })
            Add-Issue 'crit' 'Накопитель' $txt 'Диск сам обнаружил дефект: СРОЧНО скопируйте важные данные и замените накопитель.'
        } elseif ($st -eq 'ok') { $nOk++ }
        Add-Row $s ('{0}: короткий самотест' -f $t.Label) ($(if ($st -eq 'ok') { 'пройден' } elseif ($failed) { 'ПРОВАЛЕН: ' + $res } else { $res })) $st
        $rows += [pscustomobject]@{
            'Накопитель' = $t.Label; 'Тип' = $t.Kind; 'Результат' = $res
            'LBA ошибки' = $(if ($null -ne $lba) { $lba } else { '' })
        }
        $G.Log.Add(('selftest {0} ({1}): {2}, seen {3}, timeout {4}' -f $t.Dev.Name, $t.Label, $res, $t.Seen, $t.TimedOut))
    }
    Add-Table $s 'Итог самотеста' $rows
    $G.Num.selftest_n = $tests.Count
    $G.Num.selftest_ok = $nOk
    $G.Num.selftest_fail = $nFail
}
