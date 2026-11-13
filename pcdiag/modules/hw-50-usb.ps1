# USB-порты: контроллеры, хабы, подключённые устройства и их скорость (USB 1.1/2.0/3.x), ошибки USB в журнале,
# тест скорости/целостности на подключённой флешке (временный файл 256 МБ, чужие данные не трогаются).
Step 'USB-порты: проверка' {
    $s = New-Section 'USB-порты'
    $lines = @()
    $okApi = Initialize-PcDiagUsb
    if ($okApi) {
        try { $lines = @([PcDiagUsb]::Enumerate()) } catch { $G.Log.Add("usb: Enumerate: $($_.Exception.Message)"); $lines = @() }
    }
    $clsMap = @{ 0 = 'составное'; 1 = 'аудио'; 2 = 'связь/COM'; 3 = 'HID (мышь/клавиатура)'; 6 = 'камера (PTP)'; 7 = 'принтер'; 8 = 'накопитель'; 9 = 'хаб'; 10 = 'CDC-данные'; 11 = 'смарт-карта'; 14 = 'видео'; 224 = 'беспроводное (Bluetooth)'; 255 = 'специфичное' }
    $spdName = @{ 0 = 'USB 1.0 Low (1,5 Мбит/с)'; 1 = 'USB 1.1 Full (12 Мбит/с)'; 2 = 'USB 2.0 High (480 Мбит/с)'; 3 = 'USB 3.x SuperSpeed (5 Гбит/с)' }
    $hcs = @(); $devs = @(); $usb2Mass = $false; $nHubs = 0
    if ($lines.Count -gt 0) {
        $hcDesc = @{}
        foreach ($ln in $lines) {
            $p = $ln.Split('|')
            if ($p[0] -eq 'HC') { $hcDesc[$p[1]] = $p[2] }
        }
        $hubPorts = @{}
        foreach ($ln in $lines) {
            $p = $ln.Split('|')
            if ($p[0] -eq 'HUB') { $hubPorts[$p[1]] = [int]$p[2]; if ([int]$p[3] -gt 0) { $nHubs++ } }
        }
        $cnt = @{}
        foreach ($ln in $lines) {
            $p = $ln.Split('|', 15)
            if ($p[0] -ne 'DEV') { continue }
            $root = $p[1].Split('.')[0]
            if (-not $cnt.ContainsKey($root)) { $cnt[$root] = 0 }
            if ($p[8] -ne '1') { $cnt[$root] = $cnt[$root] + 1 }
        }
        foreach ($k in ($hcDesc.Keys | Sort-Object)) {
            $hcs += [pscustomobject]@{ 'Контроллер' = $k; 'Описание' = $hcDesc[$k]; 'Портов у корневого хаба' = $(if ($hubPorts.ContainsKey($k)) { $hubPorts[$k] } else { '' }); 'Устройств' = $(if ($cnt.ContainsKey($k)) { $cnt[$k] } else { 0 }) }
        }
        foreach ($ln in $lines) {
            $p = $ln.Split('|', 15)
            if ($p[0] -eq 'ERR') {
                $codes = @{ '2' = 'не удалось опознать устройство'; '3' = 'общий сбой устройства'; '4' = 'перегрузка по току (замыкание/неисправный порт)'; '5' = 'недостаточно питания порта'; '6' = 'не хватает пропускной способности шины'; '7' = 'слишком много уровней хабов'; '8' = 'устройство в устаревшем хабе' }
                $why = $codes[$p[2]]; if (-not $why) { $why = "код $($p[2])" }
                $devs += [pscustomobject]@{ 'Порт' = $p[1]; 'Устройство' = 'ОШИБКА ПОРТА'; 'VID:PID' = ''; 'Тип' = ''; 'Скорость' = $why; 'Заявлено' = '' }
                Add-Issue 'warn' 'Устройства' ("USB порт {0}: {1}" -f $p[1], $why) 'Переткните устройство в другой порт, замените кабель; при повторении - проверьте порт/питание.'
                continue
            }
            if ($p[0] -ne 'DEV') { continue }
            $spd = [int]$p[5]; $bcd = $p[6]; $isHub = ($p[7] -eq '1'); $cls = [int]$p[8]
            $opSS = [int]$p[9]; $capSS = [int]$p[10]; $opSSP = [int]$p[11]; $capSSP = [int]$p[12]
            $sname = $spdName[$spd]; if (-not $sname) { $sname = "скорость $spd" }
            if ($spd -ge 3 -and $opSSP -eq 1) { $sname = 'USB 3.1+ SuperSpeed+ (10 Гбит/с и выше)' }
            $nm = $p[13]
            $ctype = $clsMap[$cls]; if ($isHub) { $ctype = 'хаб' } elseif (-not $ctype) { $ctype = "класс $cls" }
            if (-not $nm) { $nm = $(if ($isHub) { 'USB-хаб' } else { 'USB-устройство' }) }
            $decl = ''
            try { $b = [Convert]::ToInt32($bcd, 16); $decl = 'USB {0}.{1}' -f ($b -shr 8), (($b -band 0xFF) -shr 4) } catch { }
            $devs += [pscustomobject]@{ 'Порт' = $p[1]; 'Устройство' = $nm; 'VID:PID' = ('{0}:{1}' -f $p[3], $p[4]); 'Тип' = $ctype; 'Скорость' = $sname; 'Заявлено' = $decl }
            if ($cls -eq 8 -and $spd -le 2 -and -not $isHub) { $usb2Mass = $true }
            $capable = $false
            if ($capSS -eq 1 -and $opSS -eq 0) { $capable = $true }
            elseif ($capSS -lt 0) { try { if (([Convert]::ToInt32($bcd, 16) -ge 0x0300) -and $spd -lt 3) { $capable = $true } } catch { } }
            if ($capable -and -not $isHub) {
                $ss = $spdName[$spd]
                Add-Issue 'info' 'Устройства' ("«{0}» поддерживает USB 3, но работает как {1}" -f $nm, $ss) 'Подключено к порту USB 2.0 или плохой кабель/порт. Воткните в синий порт USB 3 (SS) напрямую в ПК, попробуйте другой кабель.'
            }
        }
        Add-Row $s 'Контроллеров USB' ([string]$hcs.Count) 'ok'
        Add-Row $s 'Подключено устройств' ([string]@($devs | Where-Object { $_.'Тип' -ne 'хаб' -and $_.'Устройство' -ne 'ОШИБКА ПОРТА' }).Count) ''
        if ($hcs.Count) { Add-Table $s 'Контроллеры USB и корневые хабы' $hcs }
        if ($devs.Count) { Add-Table $s ('Устройства USB и скорость подключения ({0})' -f $devs.Count) $devs }
        $slow = @($devs | Where-Object { $_.'Скорость' -match 'USB 1\.|USB 2\.0' -and $_.'Тип' -eq 'накопитель' })
        if ($slow.Count) { Add-Row $s 'Накопитель на USB 2.0' ('{0} шт. - скорость ограничена ~30-40 МБ/с' -f $slow.Count) 'warn' }
        $G.Num.usb_devices = (AsArr $devs).Count
    } else {
        # запасной вариант: список без скорости
        $G.Log.Add('usb: IOCTL-перечисление недоступно, список без скоростей')
        $fb = @()
        try {
            $fb = @(Get-PnpDevice -PresentOnly -ErrorAction Stop | Where-Object { $_.InstanceId -match '^USB\\VID_' -and $_.InstanceId -notmatch '&MI_' } | ForEach-Object {
                [pscustomobject]@{ 'Устройство' = "$($_.FriendlyName)"; 'ID' = ($_.InstanceId -replace '\\[^\\]+$', ''); 'Состояние' = "$($_.Status)" } })
        } catch { }
        Add-Row $s 'Скорость портов' 'не удалось определить (нет доступа к драйверу хаба) - показан только список устройств' 'warn'
        if ($fb.Count) { Add-Table $s ('Устройства USB ({0})' -f $fb.Count) $fb }
    }

    # ---------------------------------------------------------------- ошибки USB в журнале System за 30 дней
    $since = (Get-Date).AddDays(-30)
    $ev = @()
    try { $ev += @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; StartTime = $since; Level = 1, 2, 3; ProviderName = 'Microsoft-Windows-USB-USBHUB3', 'Microsoft-Windows-USB-USBXHCI', 'Microsoft-Windows-USB-USBHUB', 'Microsoft-Windows-USB-USBPORT', 'usbhub', 'usbhub3', 'USBXHCI', 'usbuhci', 'usbehci', 'usbohci' } -MaxEvents 1500 -ErrorAction SilentlyContinue) } catch { }
    try { $ev += @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; StartTime = $since; ProviderName = 'Microsoft-Windows-Kernel-PnP'; Id = 219, 411, 441 } -MaxEvents 800 -ErrorAction SilentlyContinue | Where-Object { $_.Message -match 'USB\\|USB Composite|Descriptor|дескриптор' }) } catch { }
    $ev = @($ev | Where-Object { $_ })
    if ($ev.Count) {
        $grp = @($ev | Group-Object { '{0}|{1}' -f $_.ProviderName, $_.Id } | Sort-Object Count -Descending | Select-Object -First 12)
        $rows = @($grp | ForEach-Object {
            $first = $_.Group | Sort-Object TimeCreated -Descending | Select-Object -First 1
            $t = ("$($first.Message)" -split "`r?`n")[0]; if ($t.Length -gt 110) { $t = $t.Substring(0, 110) + '...' }
            [pscustomobject]@{ 'Источник' = ($first.ProviderName -replace '^Microsoft-Windows-', ''); 'ID' = $first.Id; 'Раз' = $_.Count; 'Последнее' = $first.TimeCreated.ToString('dd.MM.yyyy HH:mm'); 'Описание' = $t } })
        Add-Table $s ('Ошибки USB в журнале за 30 дней: {0}' -f $ev.Count) $rows -Collapsed
        $st = $(if ($ev.Count -ge 30) { 'crit' } elseif ($ev.Count -ge 10) { 'warn' } else { '' })
        Add-Row $s 'Ошибки USB за 30 дней' ([string]$ev.Count) $st
        if ($ev.Count -ge 10) {
            Add-Issue 'warn' 'Устройства' ("много ошибок USB в журнале за 30 дней: {0}" -f $ev.Count) 'Сбои опознавания/сбросы USB: плохой кабель или порт, нехватка питания, неисправное устройство или драйвер контроллера. Проверьте, какие устройства отключаются, и попробуйте другие порты.'
        }
        $G.Num.usb_errors = $ev.Count
    } else {
        Add-Row $s 'Ошибки USB за 30 дней' 'не найдены' 'ok'
        $G.Num.usb_errors = 0
    }

    # ---------------------------------------------------------------- активный тест: флешка / внешний USB-диск
    $drives = @()
    $sysDrive = ("$env:SystemDrive").TrimEnd('\').ToUpper()
    $letters = New-Object System.Collections.Generic.List[string]
    try {
        foreach ($d in @(Get-Disk -ErrorAction Stop | Where-Object { $_.BusType -eq 'USB' })) {
            foreach ($pt in @(Get-Partition -DiskNumber $d.Number -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter })) { $letters.Add(([string]$pt.DriveLetter).ToUpper() + ':') }
        }
    } catch { }
    foreach ($ld in @(CIM 'Win32_LogicalDisk' 'root\cimv2' 'DriveType=2')) { $l = "$($ld.DeviceID)".ToUpper(); if ($l -and -not $letters.Contains($l)) { $letters.Add($l) } }
    foreach ($l in $letters) {
        if ($l -eq $sysDrive) { continue }
        try {
            $di = New-Object System.IO.DriveInfo($l)
            if ($di.IsReady -and $di.AvailableFreeSpace -ge 1GB) { $drives += [pscustomobject]@{ L = $l; Free = $di.AvailableFreeSpace; Total = $di.TotalSize; Fs = $di.DriveFormat; Lbl = $di.VolumeLabel } }
            elseif ($di.IsReady) { Add-Row $s ("Тест накопителя $l") 'пропущен: свободно меньше 1 ГБ' '' }
        } catch { }
    }
    if (-not $okApi) { $drives = @() }
    if (-not $drives.Count) {
        Add-Row $s 'Тест скорости флешки' 'нет подключённых USB-накопителей со свободным местом (для теста вставьте флешку/внешний диск и запустите снова)' ''
        return
    }
    $res = @()
    foreach ($dr in ($drives | Select-Object -First 2)) {
        $dir = Join-Path ($dr.L + '\') ('PCDiag-usb-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $file = Join-Path $dir 'test.bin'
        $r = $null
        Info ("USB-накопитель {0}: тест записи/чтения 256 МБ..." -f $dr.L)
        try {
            New-Item -ItemType Directory -Path $dir -ErrorAction Stop | Out-Null
            $r = [PcDiagUsb]::DiskTest($file, 256, 120)
        } catch { $r = 'ERR|' + $_.Exception.Message }
        finally { try { if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue } } catch { } }
        $G.Log.Add("usb-test $($dr.L): $r")
        $q = "$r".Split('|')
        $nm = '{0} ({1}, {2:N0} ГБ{3})' -f $dr.L, $dr.Fs, ($dr.Total / 1GB), $(if ($dr.Lbl) { ', ' + $dr.Lbl } else { '' })
        if ($q[0] -ne 'OK') {
            Add-Row $s ("Тест " + $dr.L) ("не удался: " + $q[1]) 'warn'
            if ($q[1] -match 'Win32 (19|5)\b') { Add-Row $s ("Тест " + $dr.L) 'носитель защищён от записи или нет прав - тест пропущен' '' }
            else { Add-Issue 'warn' 'Накопитель' ("USB-накопитель $($dr.L): тест записи/чтения не прошёл: $($q[1])") 'Ошибки записи: проверьте порт и кабель, попробуйте другой порт; если повторяется - накопитель неисправен, скопируйте с него данные.' }
            continue
        }
        $w = [double]::Parse($q[1], $IC); $rd = [double]::Parse($q[2], $IC)
        $bad = [int]$q[4]; $hashOk = ($q[6] -eq '1'); $mbw = [int]$q[3]
        $res += [pscustomobject]@{ 'Накопитель' = $nm; 'Запись, МБ/с' = ('{0:N1}' -f $w); 'Чтение, МБ/с' = ('{0:N1}' -f $rd); 'Проверено, МБ' = $mbw; 'Ошибок данных' = $bad; 'Хэш SHA-256' = $(if ($hashOk) { 'совпал' } else { 'НЕ совпал' }) }
        Add-Row $s ("Скорость $($dr.L)") ('запись {0:N1} МБ/с, чтение {1:N1} МБ/с' -f $w, $rd) $(if ($w -lt 3 -or $rd -lt 8) { 'warn' } else { 'ok' })
        $G.Num.usb_write_mbs = [math]::Round($w, 1); $G.Num.usb_read_mbs = [math]::Round($rd, 1)
        if ($bad -gt 0 -or -not $hashOk) {
            Add-Row $s ("Целостность $($dr.L)") ('данные прочитаны с ошибками (плохих блоков: {0}{1})' -f $bad, $(if ([int]$q[5] -ge 0) { ', первый на ' + $q[5] + ' МБ' } else { '' })) 'crit'
            Add-Issue 'crit' 'Накопитель' ("USB-накопитель $($dr.L): записанные данные прочитались с ошибками") 'Накопитель или порт/кабель ненадёжны (возможен износ или подделка объёма). Не храните на нём единственные копии файлов; проверьте в другом порту.'
        } else {
            Add-Row $s ("Целостность $($dr.L)") ('{0} МБ записаны и прочитаны без ошибок, хэш совпал' -f $mbw) 'ok'
        }
        if ($q[7]) { Add-Row $s ("Примечание $($dr.L)") $q[7] 'warn' }
        if ($w -lt 3) { Add-Issue 'warn' 'Накопитель' ("USB-накопитель $($dr.L): очень медленная запись ({0:N1} МБ/с)" -f $w) 'Медленная флешка (дешёвая/изношенная) либо порт USB 1.1/плохой кабель. Попробуйте другой порт.' }
        elseif ($rd -lt 8) { Add-Issue 'warn' 'Накопитель' ("USB-накопитель $($dr.L): очень медленное чтение ({0:N1} МБ/с)" -f $rd) 'Порт работает на USB 1.1/плохой кабель или накопитель изношен.' }
        elseif ($usb2Mass -and $rd -lt 45) { Add-Issue 'info' 'Устройства' ("USB-накопитель $($dr.L) работает на скорости порта USB 2.0 (чтение {0:N0} МБ/с)" -f $rd) 'Для скорости выше ~40 МБ/с нужен порт USB 3 (синий/SS) и кабель USB 3.' }
        Add-Row $s ("Подсказка $($dr.L)") 'Проверено только первые 256 МБ свободного места: подделку объёма (fake capacity) этот тест не выявляет, только намекает на проблемы.' ''
    }
    if ($res.Count) { Add-Table $s 'Результаты теста накопителей' $res }
}
