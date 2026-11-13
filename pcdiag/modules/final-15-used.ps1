# Проверка Б/У перед покупкой: сводка признаков износа и «следов» из уже собранных данных + несколько быстрых дополнительных проверок.
# Источники: smartctl ($G.SmartDevs), $G.Num (диски, GPU), отчёт батареи (powercfg), реестр/журналы Windows, nvidia-smi, датчики.
# Ограничения (честно): у видеокарт нет счётчика «часов работы» - майнинг определяется ПО КОСВЕННЫМ признакам (следы майнеров,
# температура памяти/hot spot, вентиляторы, ограничение мощности, ошибки PCIe, райзер x1). Это подсказки, а не доказательство.
# Выводы: «хорошее» / «есть износ» / «рискованно». Баллы: низкий риск 0, средний 1, высокий 3.
Step 'Проверка Б/У: износ и следы' {
    $s = New-Section 'Проверка Б/У перед покупкой'
    $uRows = New-Object System.Collections.Generic.List[object]
    $script:uPts = 0; $script:uCrit = 0; $script:uWarn = 0; $script:uMiner = $false
    # lvl: 0 низкий, 1 средний, 2 высокий, -1 не проверено
    function URow($what, $found, [int]$lvl, $area = '') {
        $risk = switch ($lvl) { 2 { 'ВЫСОКИЙ' } 1 { 'средний' } 0 { 'низкий' } default { 'не проверено' } }
        $uRows.Add([pscustomobject]@{ 'Что проверено' = $what; 'Находка' = $found; 'Оценка риска' = $risk })
        if ($lvl -eq 2) { $script:uCrit++; $script:uPts += 3; if ($area) { Add-Issue 'warn' $area ('Б/У: ' + $what + ' - ' + $found) 'Учтите при торге/покупке: это следы интенсивной эксплуатации или вмешательства.' } }
        elseif ($lvl -eq 1) { $script:uWarn++; $script:uPts += 1 }
    }
    function UNum($v) { if ($null -eq $v -or "$v" -eq '') { return $null }; try { return [double]$v } catch { return $null } }
    function UYears($hours) { return ($hours / 24 / 365.25) }

    # ================================================================ 1. НАКОПИТЕЛИ
    $disks = @()
    foreach ($sd in @($G.SmartDevs)) {
        if (-not $sd -or -not $sd.J) { continue }
        $j = $sd.J
        $nv = $j.nvme_smart_health_information_log
        $isNvme = ($sd.Proto -eq 'NVMe')
        $cap = UNum $j.user_capacity.bytes
        $poh = UNum $j.power_on_time.hours; $cyc = UNum $j.power_cycle_count
        $wTB = $null; $used = $null; $uns = $null
        $rot = UNum $j.rotation_rate
        $ssd = $isNvme -or ($null -ne $rot -and $rot -eq 0) -or ($sd.Model -match '(?i)SSD|NVMe|M\.2')
        if ($isNvme -and $nv) {
            if ($null -eq $poh) { $poh = UNum $nv.power_on_hours }
            if ($null -eq $cyc) { $cyc = UNum $nv.power_cycles }
            $du = UNum $nv.data_units_written; if ($null -ne $du) { $wTB = $du * 512000 / 1e12 }
            $used = UNum $nv.percentage_used; $uns = UNum $nv.unsafe_shutdowns
        } else {
            $bs = UNum $j.logical_block_size; if (-not $bs) { $bs = 512 }
            foreach ($a in @($j.ata_smart_attributes.table)) {
                if (-not $a) { continue }
                $rv = UNum $a.raw.value
                if ($a.id -in 241, 246 -and $null -eq $wTB -and $null -ne $rv -and $cap) { $t1 = $rv * $bs / 1e12; if ($t1 / ($cap / 1e12) -lt 3000) { $wTB = $t1 } }
                if ($a.id -in 174, 192 -and $null -eq $uns -and $null -ne $rv -and $a.name -match '(?i)unexpect|power.?off|unsafe') { $uns = $rv }
                if ($ssd -and $a.id -in 177, 233 -and $null -eq $used -and $null -ne (UNum $a.value) -and (UNum $a.value) -le 100) { $used = 100 - (UNum $a.value) }
            }
        }
        $disks += [pscustomobject]@{ Name = $(if ($sd.Label) { $sd.Label } else { $sd.Model }); Model = $sd.Model; Cap = $cap; Ssd = $ssd; Poh = $poh; Cyc = $cyc; WTB = $wTB; Used = $used; Uns = $uns; Removable = ($sd.Type -match 'usb') }
    }
    if (-not $disks.Count) {
        foreach ($d in @($G.Num.disks)) { if (-not $d) { continue }; $disks += [pscustomobject]@{ Name = $d.m; Model = $d.m; Cap = ([double]$d.gb * 1e9); Ssd = [bool]$d.ssd; Poh = (UNum $d.poh); Cyc = $null; WTB = $(if ($d.wgb) { [double]$d.wgb / 1000 } else { $null }); Used = $(if ($null -ne $d.life) { 100 - [double]$d.life } else { $null }); Uns = $null; Removable = $false } }
    }
    if (-not $disks.Count) { URow 'Накопители: наработка и износ' 'данных SMART нет (smartctl/LibreHardwareMonitor недоступны)' -1 }
    foreach ($dk in $disks) {
        $nm = "$($dk.Name)"
        if ($null -ne $dk.Poh) {
            $yrs = UYears $dk.Poh
            $lv = 0
            if ($dk.Ssd) { if ($dk.Poh -ge 50000) { $lv = 2 } elseif ($dk.Poh -ge 25000) { $lv = 1 } }
            else { if ($dk.Poh -ge 40000) { $lv = 2 } elseif ($dk.Poh -ge 20000) { $lv = 1 } }
            URow ('Наработка ' + $nm) ('{0:N0} ч ({1:N0} суток работы; ~{2:N1} г. при 8 ч/день){3}' -f $dk.Poh, ($dk.Poh / 24), ($yrs * 3), $(if ($dk.Cyc) { ', включений: {0:N0}' -f $dk.Cyc } else { '' })) $lv 'Накопитель'
        } else { URow ('Наработка ' + $nm) 'счётчик часов недоступен' -1 }
        if ($dk.Ssd -and $null -ne $dk.WTB -and $dk.Cap -gt 0) {
            $rw = $dk.WTB * 1e12 / $dk.Cap
            $lv = 0; if ($rw -ge 400) { $lv = 2 } elseif ($rw -ge 150) { $lv = 1 }
            URow ('Записано на SSD ' + $nm) ('{0:N1} ТБ - перезаписан целиком ~{1:N0} раз{2}' -f $dk.WTB, $rw, $(if ($null -ne $dk.Used) { ', израсходовано ресурса: {0:N0} %' -f $dk.Used } else { '' })) $lv 'Накопитель'
        } elseif ($dk.Ssd -and $null -ne $dk.Used) {
            $lv = 0; if ($dk.Used -ge 70) { $lv = 2 } elseif ($dk.Used -ge 30) { $lv = 1 }
            URow ('Износ SSD ' + $nm) ('израсходовано ресурса: {0:N0} %' -f $dk.Used) $lv 'Накопитель'
        }
        if ($dk.Ssd -and $null -ne $dk.WTB -and $null -ne $dk.Used) {
            $lv = 0; if ($dk.Used -ge 70) { $lv = 2 } elseif ($dk.Used -ge 30) { $lv = 1 }
            if ($lv -gt 0) { URow ('Ресурс SSD ' + $nm) ('использовано {0:N0} % заявленного ресурса' -f $dk.Used) $lv 'Накопитель' }
        }
        if ($null -ne $dk.Uns -and $dk.Uns -ge 100) {
            $ratio = 0; if ($dk.Cyc -gt 0) { $ratio = $dk.Uns / $dk.Cyc }
            $lv = 1; if ($dk.Uns -ge 1000 -and $ratio -ge 0.2) { $lv = 2 }
            if ($ratio -lt 0.1 -and $dk.Uns -lt 1000) { $lv = 0 }
            URow ('Аварийные отключения ' + $nm) ('{0:N0} раз (из {1} включений) - ПК часто выключали кнопкой/по питанию' -f $dk.Uns, $(if ($dk.Cyc) { '{0:N0}' -f $dk.Cyc } else { '?' })) $lv 'Накопитель'
        } elseif ($null -ne $dk.Uns) { URow ('Аварийные отключения ' + $nm) ('{0:N0}' -f $dk.Uns) 0 }
    }

    # ================================================================ 2. WINDOWS: ДАТЫ И ЗАЧИСТКА СЛЕДОВ
    $os = CIM Win32_OperatingSystem | Select-Object -First 1
    $bios = CIM Win32_BIOS | Select-Object -First 1
    $inst = $null; if ($os.InstallDate -is [datetime]) { $inst = $os.InstallDate }
    $first = $inst
    try {
        foreach ($k in @(Get-ChildItem 'HKLM:\SYSTEM\Setup' -ErrorAction Stop | Where-Object { $_.PSChildName -like 'Source OS*' })) {
            $u = (Get-ItemProperty $k.PSPath -ErrorAction Stop).InstallDate
            if ($u) { $dt = ([DateTimeOffset]::FromUnixTimeSeconds([int64]$u)).LocalDateTime; if ($dt.Year -ge 2005 -and (-not $first -or $dt -lt $first)) { $first = $dt } }
        }
    } catch {}
    if ($inst) {
        $ageD = ((Get-Date) - $inst).TotalDays
        $sysPoh = $null; $sysDisk = $disks | Where-Object { $_.Ssd -or $true } | Sort-Object { -1 * [double]$_.Poh } | Select-Object -First 1
        if ($sysDisk) { $sysPoh = $sysDisk.Poh }
        $txt = 'Windows установлена {0:dd.MM.yyyy} ({1:N0} дн. назад)' -f $inst, $ageD
        if ($first -and ($inst - $first).TotalDays -gt 30) { $txt += '; первая установка (по истории обновлений) {0:dd.MM.yyyy}' -f $first }
        $lv = 0
        if ($ageD -lt 30) { $lv = 1; $txt += ' - система переустановлена совсем недавно' }
        if ($ageD -lt 90 -and $sysPoh -and $sysPoh -gt 3000) { $lv = 1; $txt += ('; диск уже проработал {0:N0} ч - возможно, следы прошлого использования стёрты' -f $sysPoh) }
        URow 'Дата установки Windows' $txt $lv
        if ($sysPoh -and ($sysPoh / 24) -gt ($ageD + 60)) { URow 'Наработка диска vs возраст Windows' ('диск работал {0:N0} суток, а текущей Windows всего {1:N0} - система ставилась поверх старого диска' -f ($sysPoh / 24), $ageD) 0 }
    }
    if ($bios.ReleaseDate -is [datetime]) { URow 'Дата BIOS' ('BIOS от {0:dd.MM.yyyy} (возраст прошивки ~{1:N1} г.; железо не новее этой версии, если BIOS не обновляли)' -f $bios.ReleaseDate, (((Get-Date) - $bios.ReleaseDate).TotalDays / 365.25)) 0 }
    # профили пользователей
    try {
        $prof = @(Get-ChildItem "$env:SystemDrive\Users" -Directory -Force -ErrorAction Stop | Where-Object { $_.Name -notmatch '^(Public|Default|Default User|All Users|defaultuser0|WDAGUtilityAccount)$' } | Sort-Object CreationTime)
        if ($prof.Count) {
            $txt = 'профилей пользователей: {0}; самый старый создан {1:dd.MM.yyyy}' -f $prof.Count, $prof[0].CreationTime
            URow 'Учётные записи прошлых владельцев' $txt $(if ($prof.Count -ge 4) { 1 } else { 0 })
        }
    } catch {}
    # очистка журналов (Event 104 System / 1102 Security)
    try {
        $cl = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 104 } -MaxEvents 3 -ErrorAction Stop)
        if ($cl.Count) { URow 'Очистка журналов Windows' ('журнал System очищали, последний раз {0:dd.MM.yyyy}' -f $cl[0].TimeCreated) 1 }
    } catch {}
    try {
        $cl2 = @(Get-WinEvent -FilterHashtable @{ LogName = 'Security'; Id = 1102 } -MaxEvents 3 -ErrorAction Stop)
        if ($cl2.Count) { URow 'Очистка журнала безопасности' ('журнал Security очищали, последний раз {0:dd.MM.yyyy}' -f $cl2[0].TimeCreated) 1 }
    } catch {}
    try {
        $oldest = @(Get-WinEvent -LogName System -Oldest -MaxEvents 1 -ErrorAction Stop)
        if ($oldest.Count) { $sinceOld = ((Get-Date) - $oldest[0].TimeCreated).TotalDays; if ($sinceOld -gt 0) { URow 'Глубина журнала System' ('самая старая запись {0:dd.MM.yyyy} ({1:N0} дн.)' -f $oldest[0].TimeCreated, $sinceOld) 0 } }
    } catch {}

    # ================================================================ 3. БАТАРЕЯ
    $batTxt = Join-Path $G.Temp 'battery.xml'
    $hasBat = (@(CIM Win32_Battery).Count -gt 0)
    if ($hasBat) {
        if (-not (Test-Path $batTxt)) { $null = powercfg /batteryreport /xml /output "$batTxt" 2>&1 }
        try {
            [xml]$bx = Get-Content $batTxt -Raw -Encoding UTF8
            foreach ($bt in @($bx.BatteryReport.Batteries.Battery)) {
                $des = UNum $bt.DesignCapacity; $ful = UNum $bt.FullChargeCapacity; $cy = UNum $bt.CycleCount
                $mf = Clean $bt.Manufacturer; $bid = Clean $bt.Id; $bsn = Clean $bt.SerialNumber
                $hl = $null; if ($des -gt 0 -and $ful -gt 0) { $hl = [math]::Round($ful / $des * 100) }
                if ($null -ne $hl) { URow 'Износ батареи' ('здоровье {0:N0} % ({1:N0} из {2:N0} мВт·ч)' -f $hl, $ful, $des) $(if ($hl -lt 60) { 2 } elseif ($hl -lt 80) { 1 } else { 0 }) 'Аккумулятор' }
                if ($null -ne $cy -and $cy -gt 0) { URow 'Циклы заряда' ('{0:N0}' -f $cy) $(if ($cy -ge 800) { 2 } elseif ($cy -ge 400) { 1 } else { 0 }) 'Аккумулятор' }
                elseif ($null -ne $cy) { URow 'Циклы заряда' '0 (счётчик не ведётся или сброшен)' $(if ($null -ne $hl -and $hl -lt 92) { 1 } else { 0 }) }
                # неродная батарея
                $why = @()
                if (-not $mf -or $mf -match '(?i)^(unknown|generic|oem|default|none|0+|n/?a)$') { $why += 'производитель не указан' }
                if ($bid -match '(?i)generic|oem|replace|compatible|li-?ion\s*battery|noname|unknown' -or -not $bid) { $why += 'модель «' + $bid + '»' }
                if (-not $bsn -or $bsn -match '^(0+|1+|1234\d*|123456\d*|none|unknown|default.*|n/?a)$') { $why += 'серийный номер пустой/шаблонный' }
                if ($des -gt 0 -and ($des % 1000) -eq 0) { $why += ('ёмкость «круглая» ({0:N0} мВт·ч) - у оригиналов обычно нет' -f $des) }
                if ($null -ne $cy -and $cy -lt 150 -and $null -ne $hl -and $hl -lt 70) { $why += ('мало циклов ({0:N0}) при сильном износе - дешёвые ячейки' -f $cy) }
                if ($G.Vendor -match '(?i)lenovo|dell|hp|hewlett|asus|acer|apple|msi|samsung|huawei' -and $mf -and $G.Vendor -and ($mf -match ('(?i)' + ($G.Vendor -replace '[^A-Za-z]', '').Substring(0, [math]::Min(4, ($G.Vendor -replace '[^A-Za-z]', '').Length))))) { $why = @($why | Where-Object { $_ -notmatch 'производитель' }) }
                URow 'Батарея родная?' $(if ($why.Count) { 'возможно неоригинальная: ' + ($why -join '; ') + ' [производитель «{0}», модель «{1}»]' -f $mf, $bid } else { 'признаков замены нет [производитель «{0}», модель «{1}»]' -f $mf, $bid }) $(if ($why.Count -ge 2) { 2 } elseif ($why.Count -eq 1) { 1 } else { 0 }) 'Аккумулятор'
            }
        } catch { URow 'Батарея' ('отчёт батареи недоступен: ' + $_.Exception.Message) -1 }
    }

    # ================================================================ 4. ВИДЕОКАРТА: КОСВЕННЫЕ ПРИЗНАКИ МАЙНИНГА
    $smi = $null; if (Get-Command Get-SmiExe -ErrorAction SilentlyContinue) { $smi = Get-SmiExe }
    $hasGpu = $false
    foreach ($v in @(CIM Win32_VideoController)) { if ("$($v.PNPDeviceID)" -match 'VEN_(10DE|1002)' -and $v.Name -notmatch '(?i)basic|remote|virtual') { $hasGpu = $true } }
    if ($hasGpu) {
        URow 'Наработка видеокарты' 'драйверы NVIDIA/AMD не хранят счётчик часов работы - майнинг определяется только косвенно (строки ниже)' 0
        # следы майнеров
        $minerRe = '(?i)phoenix\s*miner|\bt-?rex\b|lol\s*miner|nbminer|gminer|teamred|xmrig|ethminer|nicehash|claymore|cgminer|bfgminer|awesome\s*miner|hiveos|kryptex|minergate|srbminer|wildrig|nanominer|minerstat|cudo\s*miner|honeyminer|bminer|ccminer|cpuminer|ethermine|2miners|flexpool|onezerominer|quickminer|\bminer\b'
        $hits = New-Object System.Collections.Generic.List[string]
        function AddHit($src, $name) { if ($hits.Count -lt 8) { $hits.Add(('{0}: {1}' -f $src, $name)) } }
        try { foreach ($rk in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*') { foreach ($it in @(Get-ItemProperty $rk -ErrorAction SilentlyContinue)) { if ("$($it.DisplayName)" -match $minerRe) { AddHit 'программа' $it.DisplayName } } } } catch {}
        try { foreach ($f in @(Get-ChildItem "$env:SystemRoot\Prefetch" -Filter '*.pf' -ErrorAction SilentlyContinue)) { if ($f.Name -match $minerRe) { AddHit 'запускалось' ($f.Name -replace '-[0-9A-F]{8}\.pf$', '') } } } catch {}
        try {
            $roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData, "$env:SystemDrive\")
            foreach ($pf in @(Get-ChildItem "$env:SystemDrive\Users" -Directory -ErrorAction SilentlyContinue)) { foreach ($sub in 'Desktop', 'Downloads', 'Documents', 'AppData\Roaming', 'AppData\Local') { $roots += (Join-Path $pf.FullName $sub) } }
            foreach ($rt in $roots) { if ($rt -and (Test-Path $rt)) { foreach ($it in @(Get-ChildItem $rt -Force -ErrorAction SilentlyContinue)) { if ($it.Name -match $minerRe) { AddHit 'на диске' $it.FullName } } } }
        } catch {}
        try { foreach ($tk in @(Get-ScheduledTask -ErrorAction SilentlyContinue)) { $ac = (@($tk.Actions) | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -join ' '; if ("$($tk.TaskName) $ac" -match $minerRe) { AddHit 'задача планировщика' $tk.TaskName } } } catch {}
        try { foreach ($rk in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run') { $pr = Get-ItemProperty $rk -ErrorAction SilentlyContinue; if ($pr) { foreach ($pp in $pr.PSObject.Properties) { if ($pp.Name -notmatch '^PS' -and "$($pp.Name) $($pp.Value)" -match $minerRe) { AddHit 'автозапуск' $pp.Name } } } } } catch {}
        try { foreach ($th in @(Get-MpThreat -ErrorAction Stop)) { if ("$($th.ThreatName)" -match '(?i)miner|coin') { AddHit 'антивирус' $th.ThreatName } } } catch {}
        if ($hits.Count) { $script:uMiner = $true; URow 'Следы майнинга' ('найдено: ' + (($hits | Select-Object -Unique) -join '; ')) 2 'Видеокарта' }
        else { URow 'Следы майнинга' 'программ-майнеров, их запусков и автозапуска не найдено (удалённые следы это не исключает)' 0 }
        # температура памяти и hot spot под нагрузкой
        $mx = $G.GpuStressMax
        if ($mx -and $null -ne $mx.M) {
            $mt = [double]$mx.M
            URow 'Температура видеопамяти под нагрузкой' ('{0:N0} °C (макс. за тест FurMark)' -f $mt) $(if ($mt -ge 105) { 2 } elseif ($mt -ge 95) { 1 } else { 0 }) 'Видеокарта'
        } else { URow 'Температура видеопамяти под нагрузкой' 'не измерена (нужен стресс-тест видеокарты или датчик недоступен)' -1 }
        $hd = UNum $G.Num.gpu_hot_delta
        if ($null -ne $hd) { URow 'Разница hot spot - GPU' ('{0:N0} °C' -f $hd) $(if ($hd -ge 28) { 2 } elseif ($hd -ge 20) { 1 } else { 0 }) 'Видеокарта' }
        # вентиляторы и лимиты
        $fmax = $null; $tmaxG = $null
        foreach ($r in @($G.SmiRows | Where-Object { $_ })) {
            $fv = UNum $r.'fan.speed'; if ($null -ne $fv -and ($null -eq $fmax -or $fv -gt $fmax)) { $fmax = $fv }
            $tv = UNum $r.'temperature.gpu'; if ($null -ne $tv -and ($null -eq $tmaxG -or $tv -gt $tmaxG)) { $tmaxG = $tv }
        }
        if ($null -ne $fmax -and $null -ne $tmaxG) {
            URow 'Вентиляторы видеокарты под нагрузкой' ('макс. {0:N0} % оборотов при {1:N0} °C' -f $fmax, $tmaxG) $(if ($fmax -ge 90 -and $tmaxG -ge 80) { 1 } else { 0 }) 'Видеокарта'
        }
        try {
            $fans = @(Get-AllSensors | Where-Object { $_.HwType -match 'Gpu' -and $_.Type -eq 'Fan' -and $null -ne $_.Value })
            $ctl = @(Get-AllSensors | Where-Object { $_.HwType -match 'Gpu' -and $_.Type -eq 'Control' -and $null -ne $_.Value })
            if ($fans.Count) {
                $rp = ($fans | Measure-Object Value -Maximum).Maximum; $pc = $null; if ($ctl.Count) { $pc = ($ctl | Measure-Object Value -Maximum).Maximum }
                $stuck = ($null -ne $pc -and $pc -ge 30 -and $rp -lt 200)
                URow 'Обороты вентиляторов видеокарты' ('{0:N0} об/мин{1}' -f $rp, $(if ($null -ne $pc) { ' при управлении {0:N0} %' -f $pc } else { '' })) $(if ($stuck) { 2 } else { 0 }) 'Видеокарта'
            }
        } catch {}
        if ($smi) {
            try {
                $help = (& $smi --help-query-gpu 2>$null) -join "`n"
                $want = 'vbios_version', 'power.limit', 'power.default_limit', 'power.max_limit', 'inforom.img', 'pcie.link.width.max', 'pcie.link.width.current'
                $fl = @($want | Where-Object { $help -match ('"' + [regex]::Escape($_) + '"') })
                if ($fl.Count) {
                    $r = Run-Exe $smi ('--query-gpu=name,' + ($fl -join ',') + ' --format=csv,noheader,nounits') 20
                    foreach ($ln in ($r.Out -split "`r?`n")) {
                        if ($ln -notmatch ',') { continue }
                        $p = $ln -split ',\s*'; $h = @{}
                        for ($i = 0; $i -lt $fl.Count -and ($i + 1) -lt $p.Count; $i++) { $h[$fl[$i]] = $p[$i + 1].Trim() }
                        if ($h['vbios_version']) { URow ('VBIOS ' + $p[0]) ('версия {0}{1} - сверьте с эталоном для этой модели (TechPowerUp VGA BIOS); нестандартная/модифицированная прошивка - признак майнинга' -f $h['vbios_version'], $(if ($h['inforom.img']) { ', InfoROM ' + $h['inforom.img'] } else { '' })) 0 }
                        $pl = UNum $h['power.limit']; $pd = UNum $h['power.default_limit']; $pm = UNum $h['power.max_limit']
                        if ($pl -and $pd) {
                            $txt = 'лимит {0:N0} Вт при заводском {1:N0} Вт' -f $pl, $pd
                            $lv = 0
                            if ($pl -lt $pd * 0.8) { $lv = 1; $txt += ' - занижен (типичная настройка майнеров)' } elseif ($pl -gt $pd * 1.03) { $lv = 1; $txt += ' - повышен (разгон)' }
                            URow 'Лимит мощности видеокарты' $txt $lv
                        }
                        $wc = UNum $h['pcie.link.width.current']; $wm = UNum $h['pcie.link.width.max']
                        if ($wm -and $wm -ge 8 -and $G.Num.gpu_pcie -match 'x1$') { URow 'Ширина PCIe под нагрузкой' ('{0} - карта работала на x1 (так подключают через райзер в майнинг-ферме)' -f $G.Num.gpu_pcie) 1 'Видеокарта' }
                    }
                }
                $q = Run-Exe $smi '-q -d PERFORMANCE,PCI,MEMORY' 30
                $rc = 0; foreach ($mm in [regex]::Matches($q.Out, '(?im)^\s*Replay Counter\s*:\s*(\d+)')) { $rc += [int64]$mm.Groups[1].Value }
                if ($rc -gt 0) { URow 'Ошибки шины PCIe (Replay Counter)' ('{0:N0} повторов передачи с загрузки драйвера' -f $rc) $(if ($rc -ge 100000) { 1 } else { 0 }) }
            } catch { $G.Log.Add('used smi: ' + $_.Exception.Message) }
        }
    }

    # ================================================================ 5. ПРИЗНАКИ РАЗГОНА
    $cpu = CIM Win32_Processor | Select-Object -First 1
    if ($cpu) {
        $ext = UNum $cpu.ExtClock
        if ($ext -and $ext -gt 0) { URow 'Частота шины BCLK' ('{0:N1} МГц' -f $ext) $(if ($ext -lt 98 -or $ext -gt 102) { 1 } else { 0 }) }
        if ($cpu.Name -match '(?i)\b(i[3579]-\d{4,5}K[FS]?|Ryzen\s*\d\s*\d{4}X3?D?|Ryzen\s*\d\s*\d{4}X)\b') { URow 'Разгоняемый процессор' ('{0}: модель с разблокированным множителем - проверьте в BIOS значения разгона' -f (Clean $cpu.Name)) 0 }
    }
    $pp = $G.Num.passport
    $xmp = $null; if ($pp -and $pp.ram_xmp) { $xmp = [double]$pp.ram_xmp }
    $conf = $null; foreach ($m in @(CIM Win32_PhysicalMemory)) { if ($m.ConfiguredClockSpeed -and ($null -eq $conf -or $m.ConfiguredClockSpeed -gt $conf)) { $conf = [double]$m.ConfiguredClockSpeed } }
    if ($xmp -and $conf) {
        if ($conf -ge $xmp * 0.95) { URow 'Профиль XMP/EXPO' ('память работает на {0:N0} МТ/с по профилю производителя - выше стандарта JEDEC' -f $conf) 0 }
        else { URow 'Профиль XMP/EXPO' ('не включён (работает {0:N0}, профиль до {1:N0} МТ/с)' -f $conf, $xmp) 0 }
    }
    try {
        $vm = @(CIM Win32_PhysicalMemory | Where-Object { $_.ConfiguredVoltage } | ForEach-Object { [double]$_.ConfiguredVoltage / 1000 })
        if ($vm.Count) { $vmax = ($vm | Measure-Object -Maximum).Maximum; URow 'Напряжение памяти' ('{0:N2} В' -f $vmax) $(if ($vmax -ge 1.45) { 1 } else { 0 }) }
    } catch {}

    # ================================================================ 6. ОХЛАЖДЕНИЕ (пыль, паста)
    $cool = @($G.Issues | Where-Object { $_ -and $_.Area -eq 'Охлаждение' -and $_.Sev -in 'crit', 'warn' })
    $ct = UNum $G.Num.cpu_tmax
    if ($cool.Count -or ($null -ne $ct -and $ct -ge 95)) { URow 'Охлаждение (пыль / термопаста)' ('замечаний: {0}{1} - возможно, система давно не обслуживалась' -f $cool.Count, $(if ($null -ne $ct) { ', CPU до {0:N0} °C' -f $ct } else { '' })) 1 'Охлаждение' }
    elseif ($null -ne $ct) { URow 'Охлаждение (пыль / термопаста)' ('CPU под нагрузкой до {0:N0} °C - в норме' -f $ct) 0 }
    # проблемы, найденные другими шагами
    $bad = @($G.Issues | Where-Object { $_ -and $_.Sev -eq 'crit' -and $_.Area -match 'Накопитель|Память|Видеокарта|Питание' })
    if ($bad.Count) { URow 'Критичные неисправности железа' ('найдено в других проверках: {0} (см. раздел «Что нашли»)' -f $bad.Count) 2 }

    # ================================================================ ИТОГ
    $checked = @($uRows | Where-Object { $_.'Оценка риска' -ne 'не проверено' }).Count
    $verdict = 'хорошее'; $st = 'ok'; $lvlNum = 0
    if ($script:uCrit -ge 2 -or $script:uPts -ge 6 -or $script:uMiner) { $verdict = 'рискованно'; $st = 'crit'; $lvlNum = 2 }
    elseif ($script:uPts -ge 2) { $verdict = 'есть износ'; $st = 'warn'; $lvlNum = 1 }
    Add-Table $s 'Что проверено / находка / оценка риска' @($uRows)
    Add-Row $s 'Состояние Б/У' ('{0} (баллов риска: {1}; высоких: {2}, средних: {3}; проверено пунктов: {4})' -f $verdict, $script:uPts, $script:uCrit, $script:uWarn, $checked) $st
    Add-Row $s 'Как читать' 'Баллы: средний риск = 1, высокий = 3. «Рискованно»: от 6 баллов, 2+ высоких рисков или найдены следы майнинга. Данные косвенные: сопоставьте с ценой и состоянием корпуса, продавцу задайте вопросы по найденному.'
    if ($lvlNum -eq 2) { Add-Issue 'warn' 'Windows' ('Состояние Б/У: РИСКОВАННО (баллов {0})' -f $script:uPts) 'Серьёзный износ или следы интенсивной эксплуатации/майнинга - торгуйтесь или откажитесь. Подробности - раздел «Проверка Б/У перед покупкой».' }
    elseif ($lvlNum -eq 1) { Add-Issue 'info' 'Windows' ('Состояние Б/У: есть износ (баллов {0})' -f $script:uPts) 'Умеренный износ: заложите в цену возможную замену батареи/накопителя/термопасты.' }
    $G.Summary['Состояние Б/У'] = '{0} ({1} б.)' -f $verdict, $script:uPts
    $G.Num.used_score = [int]$script:uPts
    $G.Num.used_level = $lvlNum
    $G.Num.used_crit = [int]$script:uCrit
    $G.Num.used_warn = [int]$script:uWarn
    if ($script:uMiner) { $G.Num.used_miner = 1 }
}
