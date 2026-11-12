# Известные массовые дефекты железа и прошивок: Intel 13/14 Raptor Lake (деградация Vmin), AMD 7000X3D (выгорание SoC),
# AMD fTPM (микрофризы), прошивки SSD Samsung 980/990 PRO и WD SN770/SN580 (Windows 11 24H2), батарейка CMOS
Step 'Известные дефекты железа и прошивок' {
    $s = New-Section 'Известные дефекты железа и прошивок'
    $chk = New-Object System.Collections.Generic.List[object]
    $cpu = CIM Win32_Processor | Select-Object -First 1
    $bios = CIM Win32_BIOS | Select-Object -First 1
    $cpuName = Clean $cpu.Name
    $bdate = $null; if ($bios.ReleaseDate -is [datetime]) { $bdate = $bios.ReleaseDate }
    $bdTxt = $(if ($bdate) { DT $bdate } else { 'неизвестна' })
    $fam = 0; $mdl = 0
    if ("$($cpu.Caption)" -match 'Family\s+(\d+)\s+Model\s+(\d+)') { $fam = [int]$Matches[1]; $mdl = [int]$Matches[2] }
    $isIntel = ("$($cpu.Manufacturer)" -match 'Intel') -or ($cpuName -match 'Intel')
    $isAmd = ("$($cpu.Manufacturer)" -match 'AMD|AuthenticAMD') -or ($cpuName -match 'AMD|Ryzen')

    # ---------- Intel Raptor Lake: деградация из-за повышенного напряжения (Vmin shift), лечится микрокодом 0x12F+
    if ($isIntel) {
        $rev = $null
        try {
            $b = (Get-ItemProperty 'HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0' -Name 'Update Revision' -ErrorAction Stop).'Update Revision'
            # 8 байт: ревизия в старшем DWORD; на части систем (Win11) — 4 байта, ревизия целиком
            if ($b -and $b.Length -ge 8) { $rev = [BitConverter]::ToUInt32([byte[]]$b, 4); if ($rev -eq 0) { $rev = [BitConverter]::ToUInt32([byte[]]$b, 0) } }
            elseif ($b -and $b.Length -ge 4) { $rev = [BitConverter]::ToUInt32([byte[]]$b, 0) }
        } catch {}
        $revTxt = $(if ($null -ne $rev) { '0x{0:X}' -f $rev } else { 'не удалось прочитать' })
        $affected = $false; $why = ''
        if ($cpuName -match '(?i)\bi[3579]-(1[34]\d{2,3})([A-Z]*)\b') {
            $suf = $Matches[2].ToUpper()
            if ($suf -match '^(H|HX|HK|U|P|T|TE|HL|UL)$') { $why = 'мобильная/35-ваттная версия — дефект её не касается' }
            elseif ($fam -eq 6 -and $mdl -eq 183) { $affected = $true }
            elseif ($fam -eq 6 -and $mdl -gt 0) { $why = ('кристалл Alder Lake (модель 0x{0:X}) — дефект его не касается' -f $mdl) }
            else { $why = 'не удалось определить кристалл' }
        } elseif ($cpuName -match '(?i)\bi[3579]-1[0-2]\d{2,3}') { $why = '12-е поколение и старше — дефект не касается' }
        if ($affected) {
            $st = 'ok'
            if ($null -eq $rev) { $st = 'warn' } elseif ($rev -lt 0x129) { $st = 'crit' } elseif ($rev -lt 0x12F) { $st = 'warn' }
            Add-Row $s 'Микрокод процессора' ('{0} (нужен 0x12F или новее)' -f $revTxt) $st
            if ($st -eq 'crit') {
                Add-Issue 'crit' 'Процессор' ('Intel 13/14 поколения с опасным старым микрокодом {0}: процессор деградирует от завышенного напряжения' -f $revTxt) ('Срочно обновите BIOS до версии с микрокодом 0x12F или новее ({0}). Если уже есть вылеты игр, ошибки распаковки, синие экраны — процессор мог деградировать: проверьте стресс-тестом; деградировавший CPU меняется по гарантии Intel (расширена до 5 лет).' -f (Vendor-Tool))
            } elseif ($st -eq 'warn' -and $null -ne $rev) {
                Add-Issue 'warn' 'Процессор' ('Intel 13/14 поколения: микрокод {0} — промежуточный, не финальный' -f $revTxt) 'Обновите BIOS до версии с микрокодом 0x12F или новее — он окончательно исправляет проблему завышенного напряжения.'
            } elseif ($st -eq 'warn') {
                Add-Issue 'warn' 'Процессор' 'Intel 13/14 поколения: не удалось прочитать версию микрокода' 'Проверьте в BIOS, что установлена прошивка с микрокодом 0x12F или новее (дефект деградации Raptor Lake).'
            }
            $chk.Add([pscustomobject]@{ 'Проверка' = 'Intel 13/14 поколения: деградация (Vmin shift)'; 'Результат' = $(switch ($st) { 'ok' { "затронутая модель, микрокод $revTxt — исправлено" } 'warn' { "затронутая модель, микрокод $revTxt — обновите BIOS" } default { "ОПАСНО: микрокод $revTxt" } }) })
        } else {
            Add-Row $s 'Микрокод процессора' $revTxt
            $chk.Add([pscustomobject]@{ 'Проверка' = 'Intel 13/14 поколения: деградация (Vmin shift)'; 'Результат' = $(if ($why) { $why } else { 'не затронутая модель' }) })
        }
    } else {
        $chk.Add([pscustomobject]@{ 'Проверка' = 'Intel 13/14 поколения: деградация (Vmin shift)'; 'Результат' = 'не Intel' })
    }

    # ---------- AMD Ryzen 7000X3D: выгорание при высоком напряжении SoC на ранних BIOS (до AGESA 1.0.0.7b)
    if ($isAmd -and $cpuName -match '(?i)7800X3D|7900X3D|7950X3D') {
        if ($bdate -and $bdate -lt [datetime]'2023-05-01') {
            Add-Row $s 'Ryzen 7000X3D: прошивка BIOS' ('от {0} — ранняя, опасная' -f $bdTxt) 'crit'
            Add-Issue 'crit' 'BIOS' ('Ryzen 7000X3D с BIOS от {0}: на ранних прошивках завышено напряжение SoC — процессор и сокет могут выгореть' -f $bdTxt) ('Срочно обновите BIOS (AGESA 1.0.0.7b или новее): {0}. Не включайте EXPO до обновления.' -f (Vendor-Tool))
            $chk.Add([pscustomobject]@{ 'Проверка' = 'AMD 7000X3D: выгорание SoC'; 'Результат' = "ОПАСНО: BIOS от $bdTxt" })
        } elseif ($bdate) {
            $chk.Add([pscustomobject]@{ 'Проверка' = 'AMD 7000X3D: выгорание SoC'; 'Результат' = "BIOS от $bdTxt — исправленная версия" })
        } else {
            $chk.Add([pscustomobject]@{ 'Проверка' = 'AMD 7000X3D: выгорание SoC'; 'Результат' = 'дата BIOS неизвестна — убедитесь, что AGESA 1.0.0.7b+' })
        }
    } else {
        $chk.Add([pscustomobject]@{ 'Проверка' = 'AMD 7000X3D: выгорание SoC'; 'Результат' = 'не затронутая модель' })
    }

    # ---------- AMD fTPM: микрофризы/заикания звука на AM4 со старыми BIOS (исправлено AGESA 1.2.0.7, ~середина 2022)
    $am4 = $isAmd -and $cpuName -match '(?i)Ryzen\s+[3579]\s+(PRO\s+)?[1-5]\d{3}' -and $cpuName -notmatch '(?i)Ryzen\s+[3579]\s+(PRO\s+)?[1-5]\d{3}(U|H|HS|HX)\b' -and -not $G.IsLaptop
    if ($am4) {
        $ftpm = $false
        try { $t = Get-Tpm -ErrorAction Stop; if ($t.TpmPresent -and "$($t.ManufacturerIdTxt)" -match 'AMD') { $ftpm = $true } } catch {}
        if (-not $ftpm) { $w = CIM Win32_Tpm 'root/cimv2/Security/MicrosoftTpm' | Select-Object -First 1; if ($w -and "$($w.ManufacturerIdTxt)" -match 'AMD') { $ftpm = $true } }
        if ($ftpm -and $bdate -and $bdate -lt [datetime]'2022-06-01') {
            Add-Row $s 'AMD fTPM + BIOS' ('fTPM включён, BIOS от {0}' -f $bdTxt) 'warn'
            Add-Issue 'warn' 'BIOS' ('AMD fTPM на старом BIOS (от {0}): известная причина микрофризов и заиканий звука' -f $bdTxt) ('Обновите BIOS (AGESA 1.2.0.7 или новее): {0}.' -f (Vendor-Tool))
            $chk.Add([pscustomobject]@{ 'Проверка' = 'AMD fTPM: микрофризы'; 'Результат' = "fTPM + BIOS от $bdTxt — обновите BIOS" })
        } else {
            $chk.Add([pscustomobject]@{ 'Проверка' = 'AMD fTPM: микрофризы'; 'Результат' = $(if (-not $ftpm) { 'fTPM AMD не используется' } elseif ($bdate) { "BIOS от $bdTxt — исправлено" } else { 'дата BIOS неизвестна' }) })
        }
    } else {
        $chk.Add([pscustomobject]@{ 'Проверка' = 'AMD fTPM: микрофризы'; 'Результат' = 'не AM4 Ryzen' })
    }

    # ---------- Прошивки SSD с известными дефектами
    $build = 0
    try { $build = [int](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop).CurrentBuildNumber } catch {}
    $wdFixed = @('731130WD', '281050WD')   # SN770 / SN580 — версии с исправлением HMB для 24H2 (по данным WD; проверьте на сайте)
    $ssdHits = 0; $ssdSeen = 0
    foreach ($pd in @(Get-PhysicalDisk -ErrorAction SilentlyContinue)) {
        $nm = Clean ("{0} {1}" -f $pd.FriendlyName, $pd.Model)
        $fwv = (Clean $pd.FirmwareVersion).ToUpper()
        $label = Clean $pd.FriendlyName
        if ($nm -match '(?i)980\s*PRO') {
            $ssdSeen++
            if ($fwv -eq '3B2QGXA7') {
                $ssdHits++
                Add-Row $s ("Прошивка SSD: $label") "$fwv — ДЕФЕКТНАЯ" 'crit'
                Add-Issue 'crit' 'Накопитель' ("$label — прошивка $fwv с известным дефектом (быстрый износ, переход в режим «только чтение»)") 'Срочно сделайте резервную копию и обновите прошивку через Samsung Magician до 5B2QGXA7 или новее.'
            } else { Add-Row $s ("Прошивка SSD: $label") $fwv 'ok' }
        } elseif ($nm -match '(?i)990\s*PRO') {
            $ssdSeen++
            if ($fwv -eq '0B2QJXD7') {
                $ssdHits++
                Add-Row $s ("Прошивка SSD: $label") "$fwv — ДЕФЕКТНАЯ" 'crit'
                Add-Issue 'crit' 'Накопитель' ("$label — прошивка $fwv с известным дефектом (аномально быстрое падение ресурса)") 'Сделайте резервную копию и обновите прошивку через Samsung Magician до 1B2QJXD7 или новее.'
            } else { Add-Row $s ("Прошивка SSD: $label") $fwv 'ok' }
        } elseif ($nm -match '(?i)SN770|SN580|WDS\d{3}T3X0E|WDS\d{3}T3B0E') {
            $ssdSeen++
            if ($build -ge 26100 -and $wdFixed -notcontains $fwv) {
                $ssdHits++
                Add-Row $s ("Прошивка SSD: $label") ("$fwv — проверьте (Windows 11 24H2+, сборка $build)") 'warn'
                Add-Issue 'warn' 'Накопитель' ("$label (прошивка $fwv) на Windows 11 24H2: известны синие экраны и зависания из-за буфера HMB") 'Обновите прошивку SSD через WD Dashboard (Western Digital Dashboard) до последней версии. Номер исправленной прошивки сверьте на сайте WD.'
            } else { Add-Row $s ("Прошивка SSD: $label") $fwv $(if ($build -ge 26100) { 'ok' } else { '' }) }
        }
    }
    $chk.Add([pscustomobject]@{ 'Проверка' = 'Прошивки SSD (Samsung 980/990 PRO, WD SN770/SN580)'; 'Результат' = $(if (-not $ssdSeen) { 'таких SSD нет' } elseif ($ssdHits) { "найдено проблемных: $ssdHits" } else { 'прошивки без известных дефектов' }) })

    # ---------- Батарейка CMOS (CR2032): датчик напряжения и сбросы часов при включении
    $vb = @(Get-AllSensors | Where-Object { $_.HwType -match 'Motherboard|SuperIO' -and $_.Type -eq 'Voltage' -and $_.Name -match '(?i)CMOS|VBat|Battery' -and $null -ne $_.Value -and [double]$_.Value -ge 2.0 -and [double]$_.Value -le 3.6 } | Select-Object -First 1)
    $cmosBad = @()
    if ($vb.Count) {
        $v = [double]$vb[0].Value
        Add-Row $s 'Батарейка CMOS (напряжение)' ('{0:N2} В' -f $v) $(if ($v -lt 2.8) { 'warn' } else { 'ok' })
        if ($v -lt 2.8) { $cmosBad += ('напряжение {0:N2} В (норма 2,9–3,3 В)' -f $v) }
    }
    $jumps = @()
    try {
        $ch = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-General'; Id = 1; StartTime = (Get-Date).AddDays(-90) } -ErrorAction Stop)
        $boots = @()
        if ($ch.Count) { try { $boots = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-General'; Id = 12 } -MaxEvents 1000 -ErrorAction Stop) } catch {} }
        $inv = [Globalization.CultureInfo]::InvariantCulture
        $sty = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
        foreach ($e in $ch) {
            $d = @{}
            try { foreach ($n in ([xml]$e.ToXml()).Event.EventData.Data) { $d[$n.Name] = "$($n.'#text')" } } catch {}
            if (-not $d['NewTime'] -or -not $d['OldTime']) { continue }
            $nt = $null; $ot = $null
            try { $nt = [datetime]::Parse(($d['NewTime'] -replace '(\.\d{1,7})\d*', '$1'), $inv, $sty) } catch {}
            try { $ot = [datetime]::Parse(($d['OldTime'] -replace '(\.\d{1,7})\d*', '$1'), $inv, $sty) } catch {}
            if ($null -eq $nt -or $null -eq $ot) { continue }
            $diff = [math]::Abs(($nt - $ot).TotalDays)
            if ($diff -le 1 -and $ot.Year -ge 2015) { continue }
            # Последний старт ОС перед этим событием (по номеру записи); его время записано по «старым» часам — сравниваем со старым временем
            $b = $boots | Where-Object { $_.RecordId -lt $e.RecordId } | Sort-Object RecordId -Descending | Select-Object -First 1
            if (-not $b) { continue }
            $mins = ($ot - $b.TimeCreated.ToUniversalTime()).TotalMinutes
            if ($mins -lt -2 -or $mins -gt 10) { continue }
            $jumps += [pscustomobject]@{ 'Когда' = $e.TimeCreated.ToString('dd.MM.yyyy HH:mm'); 'Часы показывали' = $ot.ToLocalTime().ToString('dd.MM.yyyy HH:mm'); 'Исправлено на' = $nt.ToLocalTime().ToString('dd.MM.yyyy HH:mm') }
        }
    } catch {}
    if ($jumps.Count) {
        $cmosBad += ('после включения часы сбивались {0} раз за 90 дней' -f $jumps.Count)
        Add-Table $s 'Сбросы часов при включении (признак севшей батарейки CMOS)' $jumps -Collapsed
    }
    Add-Row $s 'Сбросы часов при включении (90 дней)' $jumps.Count $(if ($jumps.Count) { 'warn' } else { 'ok' })
    if ($cmosBad.Count) {
        Add-Issue 'warn' 'BIOS' ('батарейка CMOS садится: сбрасывается время/настройки BIOS (' + ($cmosBad -join '; ') + ')') 'Замените батарейку CR2032 на материнской плате (копеечная деталь). Севшая батарейка сбивает часы, настройки BIOS (XMP, порядок загрузки) и может мешать включению.'
    }
    $chk.Add([pscustomobject]@{ 'Проверка' = 'Батарейка CMOS'; 'Результат' = $(if ($cmosBad.Count) { $cmosBad -join '; ' } elseif ($vb.Count) { 'напряжение в норме, часы не сбрасывались' } else { 'датчика нет; часы не сбрасывались' }) })

    Add-Table $s 'Что проверено' $chk
}
