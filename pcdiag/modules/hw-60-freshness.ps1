# Свежесть драйверов и BIOS: сравнение установленных версий с последними у производителей (нужен интернет, каждый запрос до 15 с, сбой сети не ломает прогон).
# NVIDIA — публичный lookup nvidia.com; AMD — страница загрузок (ориентировочно); BIOS — lib-97-biosupd (Colorful, ASUS, MSI, Gigabyte, Lenovo, HP, Dell): поиск версии, загрузка файла и инструкция; ASRock — только ссылка.
Step 'Драйверы и BIOS: актуальность' {
    $s = New-Section 'Драйверы и BIOS: актуальность'
    $rows = New-Object System.Collections.Generic.List[object]
    $addRow = {
        param($comp, $inst, $last, $stat, $link)
        $rows.Add([pscustomobject]@{ 'Компонент' = $comp; 'Установлено' = $inst; 'Последняя версия' = $last; 'Статус' = $stat; 'Где скачать' = $link })
    }
    $now = Get-Date
    $dash = '—'
    $build = 0
    try { $build = [int](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop).CurrentBuild } catch {}
    $isW11 = ($build -ge 22000)

    # ---------- видеокарты
    $vcs = @(CIM Win32_VideoController | Where-Object { $_.Name -and $_.Name -notmatch '(?i)Microsoft|Basic|Remote|Virtual|Parsec|Citrix' })
    $nvDone = $false
    foreach ($vc in $vcs) {
        $vname = Clean $vc.Name
        $vdate = $null; if ($vc.DriverDate -is [datetime]) { $vdate = $vc.DriverDate }
        $ageY = $null; if ($vdate) { $ageY = ($now - $vdate).TotalDays / 365.25 }
        $dTxt = ''; if ($vdate) { $dTxt = ' от ' + (DT $vdate) }

        if ($vname -match '(?i)NVIDIA') {
            if ($nvDone) { continue }
            $iv = $null
            try {
                $smi = $null
                foreach ($pth in "$env:SystemRoot\System32\nvidia-smi.exe", "$env:ProgramFiles\NVIDIA Corporation\NVSMI\nvidia-smi.exe") { if (Test-Path $pth) { $smi = $pth; break } }
                if ($smi) {
                    $q = (& $smi --query-gpu=driver_version --format=csv,noheader 2>$null | Select-Object -First 1)
                    if ("$q".Trim() -match '^\d+\.\d+$') { $iv = "$q".Trim() }
                }
            } catch {}
            if (-not $iv -and "$($vc.DriverVersion)" -match '^\d+\.\d+\.(\d+)\.(\d+)$') {
                $dg = ($Matches[1] + $Matches[2]); if ($dg.Length -ge 5) { $iv = $dg.Substring($dg.Length - 5, 3) + '.' + $dg.Substring($dg.Length - 2) }
            }
            if (-not $iv) { $iv = Clean $vc.DriverVersion }
            $nvDone = $true
            $lat = $null
            try { $lat = Fresh-Nvidia $vname $isW11 } catch { $G.Log.Add("freshness nvidia: $($_.Exception.Message)") }
            $st = ''; $lastTxt = 'не удалось получить (нет сети или видеокарта не опознана)'; $link = 'nvidia.com/Download'
            if ($lat) {
                $lastTxt = $lat.Version
                if ($lat.Date) { $lastTxt = '{0} ({1})' -f $lat.Version, (DT $lat.Date) }
                $link = $lat.Url
                $a = Fresh-ParseVer $iv; $b = Fresh-ParseVer $lat.Version
                if ($a -and $b) {
                    if ($a -ge $b) { $st = 'актуальный' }
                    else {
                        $gap = $null; if ($vdate -and $lat.Date) { $gap = ($lat.Date - $vdate).TotalDays }
                        if ($gap -ne $null -and $gap -gt 183) { $st = 'устарел (разрыв {0:N0} мес.)' -f ($gap / 30.4) } else { $st = 'есть новее' }
                    }
                }
            }
            if ($ageY -ne $null -and $ageY -gt 1) {
                $st = ('старше года (' + (Fresh-AgeText $vdate) + ')') + $(if ($st -and $st -ne 'актуальный') { '; ' + $st } else { '' })
                Add-Issue 'warn' 'Видеокарта' ('драйвер {0} {1} установлен давно (от {2}, {3})' -f $vname, $iv, (DT $vdate), (Fresh-AgeText $vdate)) ('Обновите драйвер видеокарты (чистая установка, лучше через DDU при проблемах): ' + $link + ' — новые версии исправляют ошибки и добавляют оптимизацию под игры.')
            } elseif ($lat -and $st -match 'устарел') {
                Add-Issue 'info' 'Видеокарта' ('вышел новый драйвер NVIDIA {0}, установлен {1}{2}' -f $lastTxt, $iv, $dTxt) ('Скачайте с ' + $link)
            }
            & $addRow $vname ($iv + $dTxt) $lastTxt $st $link
        }
        elseif ($vname -match '(?i)AMD|Radeon|ATI ') {
            $iv = Clean $vc.DriverVersion
            # версию Adrenalin пробуем взять из реестра AMD
            $adr = $null
            try {
                $ak = Get-ItemProperty 'HKLM:\SOFTWARE\AMD\CN' -ErrorAction Stop
                foreach ($pr in $ak.PSObject.Properties) { if ($pr.Name -match 'Version' -and "$($pr.Value)" -match '^(\d{2}\.\d{1,2}\.\d{1,2})') { $adr = $Matches[1]; break } }
            } catch {}
            $lat = $null
            try { $lat = Fresh-Amd } catch { $G.Log.Add("freshness amd: $($_.Exception.Message)") }
            $instTxt = $iv + $dTxt; if ($adr) { $instTxt = 'Adrenalin ' + $adr + ' (драйвер ' + $iv + ')' + $dTxt }
            $lastTxt = 'не удалось получить'; $st = ''; $link = 'amd.com/en/support'
            if ($lat) {
                $lastTxt = 'Adrenalin ' + $lat.Version; $link = $lat.Url
                if ($adr) {
                    $a = Fresh-ParseVer $adr; $b = Fresh-ParseVer $lat.Version
                    if ($a -and $b) { if ($a -ge $b) { $st = 'актуальный' } else { $st = 'есть новее' } }
                }
            }
            if ($ageY -ne $null -and $ageY -gt 1) {
                $st = ('старше года (' + (Fresh-AgeText $vdate) + ')') + $(if ($st -and $st -ne 'актуальный') { '; ' + $st } else { '' })
                Add-Issue 'warn' 'Видеокарта' ('драйвер {0} установлен давно (от {1}, {2})' -f $vname, (DT $vdate), (Fresh-AgeText $vdate)) ('Обновите драйвер Radeon (Adrenalin): ' + $link)
            } elseif (-not $st -and $vdate) { $st = 'возраст ' + (Fresh-AgeText $vdate) }
            & $addRow $vname $instTxt $lastTxt $st $link
        }
        elseif ($vname -match '(?i)Intel') {
            $st = $dash
            if ($ageY -ne $null) {
                $st = 'возраст ' + (Fresh-AgeText $vdate)
                if ($ageY -gt 2) { $st = 'старше 2 лет (' + (Fresh-AgeText $vdate) + ')' }
            }
            & $addRow $vname ((Clean $vc.DriverVersion) + $dTxt) $dash $st 'intel.com/support (Driver & Support Assistant)'
        }
    }

    # ---------- Intel: Wi-Fi, Bluetooth, LAN
    $oldIntel = New-Object System.Collections.Generic.List[string]
    try {
        $pn = @(CIM Win32_PnPSignedDriver | Where-Object { $_.DeviceClass -in 'NET', 'BLUETOOTH' -and "$($_.DriverProviderName)$($_.Manufacturer)" -match 'Intel' -and $_.DeviceName -notmatch '(?i)virtual|miniport|tunnel|loopback|wan |hyper-v|vpn|TAP' })
        $seen = @{}
        foreach ($d in $pn) {
            $nmx = Clean $d.DeviceName
            if (-not $nmx -or $seen.ContainsKey($nmx)) { continue }
            $seen[$nmx] = 1
            $dd = $null; if ($d.DriverDate -is [datetime]) { $dd = $d.DriverDate }
            $st = $dash; $dTxt2 = ''
            if ($dd) {
                $dTxt2 = ' от ' + (DT $dd)
                $st = 'возраст ' + (Fresh-AgeText $dd)
                if (($now - $dd).TotalDays / 365.25 -gt 2) { $st = 'старше 2 лет (' + (Fresh-AgeText $dd) + ')'; $oldIntel.Add($nmx) }
            }
            $kind = 'Intel LAN'; if ($d.DeviceClass -eq 'BLUETOOTH') { $kind = 'Intel Bluetooth' } elseif ($nmx -match '(?i)wi-?fi|wireless|AX\d|AC\s?\d|BE\d') { $kind = 'Intel Wi-Fi' }
            & $addRow ($kind + ': ' + $nmx) ((Clean $d.DriverVersion) + $dTxt2) $dash $st 'intel.com/support (Driver & Support Assistant)'
        }
    } catch { $G.Log.Add("freshness intel pnp: $($_.Exception.Message)") }
    if ($oldIntel.Count) {
        Add-Issue 'info' 'Драйверы' ('драйверы Intel старше 2 лет: ' + (($oldIntel | Select-Object -First 4) -join '; ')) 'Обновите через Intel Driver & Support Assistant (intel.com/support) — обновления Wi-Fi/Bluetooth исправляют обрывы связи и уязвимости.'
    }

    # ---------- BIOS: поиск обновления у производителя и загрузка файла (lib-97-biosupd)
    $bb = CIM Win32_BaseBoard | Select-Object -First 1
    $bios = CIM Win32_BIOS | Select-Object -First 1
    $csx = CIM Win32_ComputerSystem | Select-Object -First 1
    $cspx = CIM Win32_ComputerSystemProduct | Select-Object -First 1
    $bbMan = Clean $bb.Manufacturer; $bbMod = Clean $bb.Product
    $bver = Clean $bios.SMBIOSBIOSVersion
    $bdate = $null; if ($bios.ReleaseDate -is [datetime] -and $bios.ReleaseDate.Year -ge 1990) { $bdate = $bios.ReleaseDate }
    $bInst = $bver; if ($bdate) { $bInst = '{0} от {1}' -f $bver, (DT $bdate) }
    $bName = ('BIOS: {0} {1}' -f $bbMan, $bbMod).Trim()
    $bLink = Vendor-Tool
    $lastB = $dash; $bst = ''
    if ($bdate) { $bst = 'возраст ' + (Fresh-AgeText $bdate) }
    $blk = $false
    try { $blv = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop; if ("$($blv.ProtectionStatus)" -eq 'On') { $blk = $true } } catch {}
    $hwb = @{ BbMan = $bbMan; BbProd = $bbMod; BbVer = (Clean $bb.Version); CsMan = (Clean $csx.Manufacturer); CsModel = (Clean $csx.Model); CsFamily = (Clean $cspx.Version)
        Sku = (Clean $csx.SystemSKUNumber); BiosVer = $bver; BiosDate = $bdate; IsLaptop = [bool]$G.IsLaptop; BitLocker = $blk }
    $bres = $null; $bdec = $null
    if ($FRESH.Fails -lt 3) {
        Info 'ищу обновление BIOS на сайте производителя...'
        try { $bres = Bios-Lookup $hwb; $bdec = Bios-Decide $bres $bver $bdate } catch { $G.Log.Add("biosupd: $($_.Exception.Message)") }
    }
    $ageIssue = [Predicate[object]] { param($i) $i.Area -eq 'BIOS' -and "$($i.Text)" -match '^прошивке BIOS' }
    if ($bres -and $bres.Page) { $bLink = $bres.Page }
    if ($bdec -and $bdec.State -eq 'update') {
        $lat = $bdec.Latest
        $lastB = '{0} от {1}' -f $lat.Version, (DT $lat.Date)
        $bst = 'доступна новая версия'
        $instTxt = $bInst; if ($bdec.Current -and (Bios-Norm $bdec.Current.Version) -ne (Bios-Norm $bver)) { $instTxt = '{0} (версия производителя {1})' -f $bInst, $bdec.Current.Version }
        $lag = ''; if ($bdate) { $lag = ', отставание ' + (Fresh-AgeText ($now.AddDays(-(($lat.Date - $bdate).TotalDays)))) }
        $notesRu = ''; if ($lat.Notes) { $notesRu = ((Bios-NoteRu $lat.Notes) -replace "`n", '; '); if ($notesRu.Length -gt 300) { $notesRu = $notesRu.Substring(0, 300) + '...' } }
        $manual = (@($bdec.Newer | Where-Object { "$($_.Notes)" -match '(?i)UEFI\s*DOS' }).Count -gt 0)
        $bf = $null
        if ($env:DIAG_BIOSDL -ne '0') { try { $bf = Bios-Fetch $bres $lat $hwb $bdec } catch { $G.Log.Add("biosupd fetch: $($_.Exception.Message)") } }
        [void]$G.Issues.RemoveAll($ageIssue)
        $itxt = 'доступно обновление BIOS: версия {0} (установлена {1}{2}; пропущено версий: {3})' -f $lastB, $instTxt, $lag, @($bdec.Newer).Count
        if ($bf -and $bf.Folder) {
            $ifix = 'Файл обновления уже скачан: папка «{0}» на рабочем столе (внутри — файл прошивки и «КАК ОБНОВИТЬ BIOS.txt»). {1}Обновляйте при стабильном питании; на исправно работающем ПК обновление не обязательно.' -f (Split-Path $bf.Folder -Leaf), $(if ($manual) { 'ВНИМАНИЕ: по описанию производителя эта версия ставится вручную из UEFI Shell («UEFI DOS»). ' } else { '' })
            Ok ('BIOS: скачано обновление {0} -> {1}' -f $lat.Version, $bf.Folder)
        } else {
            $ifix = 'Скачайте со страницы модели: ' + $bLink + $(if ($bf -and $bf.Err) { ' (автозагрузка не удалась: ' + $bf.Err + ')' } else { '' })
        }
        Add-Issue 'info' 'BIOS' $itxt $ifix
        Add-Row $s 'Обновление BIOS' ('найдено: {0} {1}, версия {2}; установлена {3}' -f $bres.Vendor, $bres.Model, $lastB, $instTxt) 'warn'
        if ($notesRu) { Add-Row $s 'Что нового в BIOS' $notesRu }
        if ($bf -and $bf.Folder) {
            Add-Row $s 'Файл обновления BIOS' ('{0} ({1} МБ) — {2}' -f $bf.File, $bf.SizeMb, $bf.Verified) 'ok'
            Add-Row $s 'Как обновить BIOS' ('инструкция лежит рядом с файлом: «КАК ОБНОВИТЬ BIOS.txt». Программа сама BIOS не прошивает.' + $(if ($bf.Kit) { ' В архиве готовый загрузочный комплект: его содержимое копируется на флешку FAT32, прошивка стартует сама при загрузке с неё.' } elseif ($manual) { ' Версия ставится вручную из UEFI Shell.' } else { '' }))
        } elseif ($bf -and $bf.Err) { Add-Row $s 'Файл обновления BIOS' ('не скачан: ' + $bf.Err + '. Страница модели: ' + $bLink) 'warn' }
        $hist = @()
        foreach ($hv in ($bdec.Newer | Sort-Object Date -Descending | Select-Object -First 20)) { $hist += [pscustomobject]@{ 'Версия' = $hv.Version; 'Дата' = (DT $hv.Date); 'Что изменилось' = ((Bios-NoteRu $hv.Notes) -replace "`n", '; ') } }
        if ($hist.Count) { Add-Table $s 'Версии BIOS новее установленной' $hist -Collapsed }
        $G.BiosUpd = @{ State = 'update'; Vendor = $bres.Vendor; Model = $bres.Model; Inst = $instTxt; NewVer = $lat.Version; NewDate = $lat.Date; Notes = $notesRu; Page = $bLink; Manual = $manual
            Kit = $(if ($bf) { [bool]$bf.Kit } else { $false }); Folder = $(if ($bf) { $bf.Folder } else { '' }); File = $(if ($bf) { $bf.File } else { '' }); Err = $(if ($bf) { $bf.Err } else { '' }); Skipped = @($bdec.Newer).Count }
    }
    elseif ($bdec -and $bdec.State -eq 'current') {
        $lat = $bdec.Latest
        $lastB = '{0} от {1}' -f $lat.Version, (DT $lat.Date)
        $bst = 'актуальный'
        # BIOS последний из выпущенных — его возраст проблемой не является
        [void]$G.Issues.RemoveAll($ageIssue)
        $G.BiosUpd = @{ State = 'current'; Vendor = $bres.Vendor; Model = $bres.Model; NewVer = $lat.Version; NewDate = $lat.Date }
        Ok ('BIOS актуален: установлена последняя версия производителя ({0})' -f $lastB)
    }
    elseif ($bres -and $bres.Why) {
        $lastB = 'не определено: ' + $bres.Why
        $G.Log.Add("biosupd: $($bres.Why)")
    }
    & $addRow $bName $bInst $lastB $bst $bLink

    # ---------- Windows (только показать)
    try {
        $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
        $ubr = ''; if ($null -ne $cv.UBR) { $ubr = '.' + $cv.UBR }
        $dv = ''; if ($cv.DisplayVersion) { $dv = ' ' + $cv.DisplayVersion } elseif ($cv.ReleaseId) { $dv = ' ' + $cv.ReleaseId }
        $wn = 'Windows 10'; if ($isW11) { $wn = 'Windows 11' }
        $last = $null
        try { $last = (Get-HotFix -ErrorAction Stop | Where-Object { $_.InstalledOn } | Sort-Object InstalledOn -Descending | Select-Object -First 1).InstalledOn } catch {}
        $wst = $dash; if ($last -is [datetime]) { $wst = 'последнее обновление: ' + (DT $last) }
        & $addRow ('Windows: ' + $wn + $dv) ('сборка {0}{1}' -f $cv.CurrentBuild, $ubr) $dash $wst 'Параметры → Центр обновления Windows'
    } catch {}

    if ($rows.Count) { Add-Table $s 'Актуальность драйверов и BIOS' $rows.ToArray() }
    if ($FRESH.Fails -ge 3) { Add-Row $s 'Интернет' 'недоступен или блокирует запросы — последние версии не проверены' 'warn' }
    else { Add-Row $s 'Источники' 'NVIDIA (nvidia.com), AMD (amd.com, ориентировочно), BIOS — сайт производителя платы/ноутбука. Наружу передаются только названия моделей, без серийных номеров.' }
    Add-Row $s 'Intel 13/14 поколения' 'проверка микрокода BIOS — в разделе «Известные дефекты железа и прошивок»'
}
