# Скорость загрузки Windows и виновники замедления (Diagnostics-Performance), подробный разбор ошибок дисков/ФС в журнале System
$STEPKEYS['Загрузка Windows: скорость и виновники'] = 'logs'
Step 'Загрузка Windows: скорость и виновники' {
    $s = New-Section 'Загрузка Windows: скорость и виновники'
    $log = 'Microsoft-Windows-Diagnostics-Performance/Operational'
    function EvData($e) { $d = @{}; try { foreach ($n in ([xml]$e.ToXml()).Event.EventData.Data) { $d[$n.Name] = "$($n.'#text')" } } catch {}; return $d }
    function Num($v) { $x = 0.0; if ([double]::TryParse("$v", [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$x)) { return $x }; return $null }
    $boot = @(); $avgM = $null; $avgT = $null; $avgP = $null; $main = @(); $top = @(); $worst = @()
    $isSsd = "$($G.SysDiskType)" -match 'SSD|NVMe'
    $ok = $true
    try { $boot = @(Get-WinEvent -FilterHashtable @{ LogName = $log; Id = 100 } -MaxEvents 10 -ErrorAction Stop) }
    catch { if ("$($_.FullyQualifiedErrorId)" -notmatch 'NoMatchingEventsFound' -and "$($_.Exception.Message)" -notmatch 'No events were found|не найдено') { $ok = $false } }
    if (-not $ok) { Add-Row $s 'Журнал диагностики производительности' 'журнал недоступен (выключен или повреждён)'; return }
    if (-not $boot.Count) { Add-Row $s 'Время загрузки' 'нет записей о загрузках (журнал пуст)' }
    else {
        $main = @(); $tot = @(); $post = @()
        foreach ($e in $boot) {
            $d = EvData $e
            $m = Num $d['MainPathBootTime']; $t = Num $d['BootTime']; $p = Num $d['BootPostBootTime']
            if ($null -ne $m -and $m -gt 0) { $main += $m / 1000.0 }
            if ($null -ne $t -and $t -gt 0) { $tot += $t / 1000.0 }
            if ($null -ne $p -and $p -gt 0) { $post += $p / 1000.0 }
        }
        $d0 = EvData $boot[0]
        $lastM = Num $d0['MainPathBootTime']; $lastT = Num $d0['BootTime']
        $avgM = $null; if ($main.Count) { $avgM = ($main | Measure-Object -Average).Average }
        $avgT = $null; if ($tot.Count) { $avgT = ($tot | Measure-Object -Average).Average }
        $avgP = $null; if ($post.Count) { $avgP = ($post | Measure-Object -Average).Average }
        if ($null -ne $lastT -and $null -ne $lastM) { Add-Row $s ('Последняя загрузка ({0})' -f $boot[0].TimeCreated.ToString('dd.MM.yyyy HH:mm')) ('{0:N1} с до рабочего стола, {1:N1} с полностью' -f ($lastM / 1000.0), ($lastT / 1000.0)) }
        if ($null -ne $avgM) {
            $st = 'ok'; if ($isSsd -and $avgM -gt 60) { $st = 'warn' } elseif ($avgM -gt 120) { $st = 'warn' }
            Add-Row $s ('Среднее за {0} загрузок: до рабочего стола' -f $main.Count) ('{0:N1} с' -f $avgM) $st
        }
        if ($null -ne $avgP) { Add-Row $s 'Среднее: дозагрузка после входа (автозапуск)' ('{0:N1} с' -f $avgP) $(if ($avgP -gt 60) { 'warn' } else { '' }) }
        if ($null -ne $avgT) { Add-Row $s 'Среднее: полная загрузка' ('{0:N1} с' -f $avgT) }
        if ($null -ne $avgM) { $G.Num.boot_main_s = [math]::Round($avgM, 1) }
    }
    # Виновники замедления (события 101–110 за 30 дней)
    $types = @{ 101 = 'приложение'; 102 = 'драйвер'; 103 = 'служба'; 104 = 'кэширование ОС'; 105 = 'оптимизация (передний план)'; 106 = 'оптимизация (фон)'; 107 = 'групповая политика компьютера'; 108 = 'групповая политика пользователя'; 109 = 'устройство'; 110 = 'инициализация сеанса' }
    $deg = @()
    try { $deg = @(Get-WinEvent -FilterHashtable @{ LogName = $log; Id = 101, 102, 103, 104, 105, 106, 107, 108, 109, 110; StartTime = (Get-Date).AddDays(-30) } -ErrorAction Stop) } catch {}
    $agg = @{}
    foreach ($e in $deg) {
        $d = EvData $e
        $nm = Clean $d['FriendlyName']; if (-not $nm) { $nm = Clean $d['Name'] }; if (-not $nm) { $nm = '(без имени)' }
        $file = Clean $d['Name']
        $dt = Num $d['DegradationTime']; if ($null -eq $dt) { $dt = 0 }
        $key = '{0}|{1}' -f $e.Id, $nm
        if (-not $agg.ContainsKey($key)) { $agg[$key] = [pscustomobject]@{ Id = $e.Id; Name = $nm; File = $file; Sum = 0.0; Cnt = 0 } }
        $agg[$key].Sum += $dt; $agg[$key].Cnt++
    }
    $top = @($agg.Values | Sort-Object Sum -Descending | Select-Object -First 8)
    if ($top.Count) {
        Add-Table $s 'Что замедляет загрузку (30 дней)' @($top | ForEach-Object {
                [pscustomobject]@{ 'Виновник' = $_.Name; 'Тип' = $(if ($types[[int]$_.Id]) { $types[[int]$_.Id] } else { "событие $($_.Id)" }); 'Файл' = $(if ($_.File -and $_.File -ne $_.Name) { $_.File } else { '' }); 'Раз' = $_.Cnt; 'Задержка всего' = ('{0:N1} с' -f ($_.Sum / 1000.0)); 'В среднем' = ('{0:N1} с' -f ($_.Sum / 1000.0 / [math]::Max(1, $_.Cnt))) } })
        $worst = @($top | Where-Object { $_.Sum / [math]::Max(1, $_.Cnt) -ge 2000 } | Select-Object -First 3 | ForEach-Object { '{0} ({1}, ~{2:N1} с)' -f $_.Name, $types[[int]$_.Id], ($_.Sum / 1000.0 / [math]::Max(1, $_.Cnt)) })
        $slow = ($null -ne $avgM) -and (($isSsd -and $avgM -gt 60) -or $avgM -gt 120)
        if ($slow) {
            Add-Issue 'warn' 'Windows' (('медленная загрузка: в среднем {0:N0} с до рабочего стола' -f $avgM) + $(if ($worst.Count) { '; больше всего тормозят: ' + ($worst -join ', ') } else { '' })) 'Отключите лишний автозапуск (Диспетчер задач → Автозагрузка), обновите/удалите указанные драйверы и программы; проверьте диск.'
        } elseif ($worst.Count) {
            Add-Issue 'info' 'Windows' ('загрузку замедляют: ' + ($worst -join ', ')) 'Если загрузка кажется долгой — уберите эти программы из автозапуска или обновите их/драйверы.'
        }
    } else { Add-Row $s 'Виновники замедления (30 дней)' 'не зафиксированы' 'ok' }
    if (-not $top.Count -and $null -ne $avgM -and (($isSsd -and $avgM -gt 60) -or $avgM -gt 120)) {
        Add-Issue 'warn' 'Windows' ('медленная загрузка: в среднем {0:N0} с до рабочего стола' -f $avgM) 'Отключите лишний автозапуск, проверьте диск и драйверы.'
    }
}

$STEPKEYS['Журналы: ошибки дисков и файловой системы'] = 'logs'
Step 'Журналы: ошибки дисков и файловой системы' {
    $s = New-Section 'Журналы: ошибки дисков и файловой системы (30 дней)'
    $since = (Get-Date).AddDays(-30)
    # Описание: Ключ = 'провайдер(ы)|коды|уровни'
    $defs = @(
        @{ K = 'bad'; Prov = @('disk'); Id = @(7); Lvl = $null; T = 'диск: повреждённый блок (bad block)' }
        @{ K = 'ctl'; Prov = @('disk'); Id = @(11); Lvl = $null; T = 'диск: ошибка контроллера/кабеля' }
        @{ K = 'pag'; Prov = @('disk'); Id = @(51); Lvl = $null; T = 'диск: ошибка при подкачке страницы' }
        @{ K = 'smt'; Prov = @('disk'); Id = @(52); Lvl = $null; T = 'диск: SMART предсказывает отказ' }
        @{ K = 'rty'; Prov = @('disk'); Id = @(153); Lvl = $null; T = 'диск: операция ввода-вывода повторена' }
        @{ K = 'rst'; Prov = @('storahci', 'stornvme', 'iaStorAC', 'iaStorVD', 'iaStorA'); Id = @(129); Lvl = $null; T = 'контроллер: сброс устройства (диск не ответил)' }
        @{ K = 'n55'; Prov = @('Ntfs', 'Microsoft-Windows-Ntfs'); Id = @(55); Lvl = $null; T = 'NTFS: повреждена файловая система' }
        @{ K = 'n98'; Prov = @('Ntfs', 'Microsoft-Windows-Ntfs'); Id = @(98); Lvl = @(2, 3); T = 'NTFS: том требует проверки (chkdsk)' }
        @{ K = 'n50'; Prov = @('Ntfs', 'Microsoft-Windows-Ntfs'); Id = @(50); Lvl = $null; T = 'NTFS: отложенная запись не удалась (данные могли потеряться)' }
        @{ K = 'v161'; Prov = @('volmgr'); Id = @(161); Lvl = $null; T = 'volmgr: не удалось записать дамп памяти' }
        @{ K = 'v46'; Prov = @('volmgr'); Id = @(46); Lvl = $null; T = 'volmgr: не инициализирован дамп при сбое' }
    )
    $pdMap = @{}
    foreach ($pd in @(Get-PhysicalDisk -ErrorAction SilentlyContinue)) { $pdMap["$($pd.DeviceId)"] = Clean $pd.FriendlyName }
    $res = @{}; $all = New-Object System.Collections.Generic.List[object]
    foreach ($df in $defs) {
        $list = New-Object System.Collections.Generic.List[object]
        foreach ($p in $df.Prov) {
            $f = @{ LogName = 'System'; ProviderName = $p; Id = $df.Id; StartTime = $since }
            if ($df.Lvl) { $f.Level = $df.Lvl }
            try { Get-WinEvent -FilterHashtable $f -ErrorAction Stop | ForEach-Object { $list.Add($_) } } catch {}
        }
        $disks = @{}
        foreach ($e in $list) {
            $txt = "$($e.Message) " + (($e.Properties | ForEach-Object { "$($_.Value)" }) -join ' ')
            $num = $null
            if ($txt -match 'Harddisk(\d+)') { $num = $Matches[1] }
            elseif ($txt -match '(?i)\b(?:Disk|диска?)\s+(\d+)\b') { $num = $Matches[1] }
            if ($null -ne $num) {
                $nm = $(if ($pdMap.ContainsKey($num)) { '{0} (диск {1})' -f $pdMap[$num], $num } else { "диск $num" })
                $disks[$nm] = 1
            } elseif ($txt -match '(RaidPort\d+)') { $disks[$Matches[1]] = 1 }
            $all.Add([pscustomobject]@{ E = $e; T = $df.T })
        }
        $last = $null; if ($list.Count) { $last = ($list | Sort-Object TimeCreated -Descending | Select-Object -First 1).TimeCreated }
        $res[$df.K] = [pscustomobject]@{ T = $df.T; Codes = ($df.Id -join ','); N = $list.Count; Disks = (@($disks.Keys) -join ', '); Last = $last }
    }
    $rows = @($defs | ForEach-Object { $r = $res[$_.K]; if ($r.N) { [pscustomobject]@{ 'Событие' = $r.T; 'Код' = $r.Codes; 'Сколько' = $r.N; 'Диск' = $(if ($r.Disks) { $r.Disks } else { '—' }); 'Последний раз' = $r.Last.ToString('dd.MM.yyyy HH:mm') } } })
    $hard = $res['bad'].N + $res['pag'].N + $res['smt'].N
    Add-Row $s 'Повреждённые блоки / отказ по SMART (коды 7, 51, 52)' $hard $(if ($hard) { 'crit' } else { 'ok' })
    Add-Row $s 'Повторы ввода-вывода (153)' $res['rty'].N $(if ($res['rty'].N -ge 5) { 'crit' } elseif ($res['rty'].N) { 'warn' } else { 'ok' })
    Add-Row $s 'Сбросы диска контроллером (129)' $res['rst'].N $(if ($res['rst'].N -ge 3) { 'warn' } else { 'ok' })
    $fs = $res['n55'].N + $res['n98'].N + $res['n50'].N
    Add-Row $s 'Ошибки файловой системы NTFS (55, 98, 50)' $fs $(if ($fs) { 'warn' } else { 'ok' })
    if ($res['v161'].N + $res['v46'].N) { Add-Row $s 'Сбои записи дампа памяти (volmgr)' ($res['v161'].N + $res['v46'].N) 'warn' }
    if ($rows.Count) { Add-Table $s 'Ошибки по типам' $rows }
    else { Add-Row $s 'Итог' 'ошибок дисков и файловой системы в журнале нет' 'ok' }
    $recent = @($all | Sort-Object { $_.E.TimeCreated } -Descending | Select-Object -First 20 | ForEach-Object {
            $msg = Clean $_.E.Message; if ($msg.Length -gt 200) { $msg = $msg.Substring(0, 200) + '…' }
            [pscustomobject]@{ 'Время' = $_.E.TimeCreated.ToString('dd.MM.yyyy HH:mm'); 'Источник' = $_.E.ProviderName; 'Код' = $_.E.Id; 'Сообщение' = $msg } })
    Add-Table $s 'Последние события' $recent -Collapsed
    # Проблемы. Общие «ошибки дисковой подсистемы» (7/11/51/153) и NTFS 55 уже выдаёт шаг 'Журналы ошибок за 30 дней' —
    # здесь только то, что он не различает: серьёзность по типу, конкретный диск, сбросы 129 от драйверов контроллера, NTFS 98/50.
    $dsk = @(@('bad', 'pag', 'smt', 'rty') | ForEach-Object { $res[$_].Disks } | Where-Object { $_ }) -join ', '
    $where = $(if ($dsk) { " ($dsk)" } else { '' })
    if ($hard) {
        Add-Issue 'crit' 'Накопитель' ('в журнале повреждённые блоки / предсказание отказа диска{0}: {1} событий' -f $where, $hard) 'Диск начал сыпаться: СРОЧНО сделайте резервную копию важных данных и замените накопитель. Если SMART чистый — проверьте кабель SATA/питание.'
    } elseif ($res['rty'].N -ge 5) {
        Add-Issue 'crit' 'Накопитель' ('диск многократно повторял операции чтения/записи{0}: {1} раз' -f $where, $res['rty'].N) 'Признак отказывающего диска или плохого кабеля/разъёма: сделайте резервную копию, замените SATA-кабель (или переустановите NVMe), обновите прошивку SSD; при повторении — замена диска.'
    }
    if ($res['rst'].N -ge 3) {
        $rd = $(if ($res['rst'].Disks) { " ($($res['rst'].Disks))" } else { '' })
        Add-Issue 'warn' 'Накопитель' ('контроллер сбрасывал зависший диск{0}: {1} раз (код 129) — отсюда подвисания системы' -f $rd, $res['rst'].N) 'Проверьте кабель и питание диска (SATA), переустановите NVMe, обновите прошивку SSD и драйвер контроллера (Intel RST/AMD SATA), отключите агрессивное энергосбережение PCIe/диска.'
    }
    if ($res['n98'].N -or $res['n50'].N) {
        Add-Issue 'warn' 'Диск' ('NTFS сообщает о проблемах тома (проверка нужна: {0}, сбои отложенной записи: {1})' -f $res['n98'].N, $res['n50'].N) 'Выполните chkdsk <диск>: /f (для системного — с перезагрузкой). Сбои отложенной записи часто вызваны отвалом диска — проверьте кабель/питание.'
    }
    $G.Num.disk_ev_hard30 = $hard
    $G.Num.disk_ev_reset30 = $res['rst'].N
}
