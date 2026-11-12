# Синие экраны: разбор дампов (виновный драйвер, код, расшифровка) + журнал BugCheck, если дампы удалены
$TOOLS.BlueScreenView = @{ Url = 'https://www.nirsoft.net/utils/bluescreenview-x64.zip'; Sha = 'DF57D4C9418DD2771035F2F7B70952CAEB20D2269AF683A0AB0665125C821479'; Dir = 'BlueScreenView'; Exe = 'BlueScreenView\BlueScreenView.exe' }
$STEPKEYS['Синие экраны: разбор дампов'] = 'logs'
$G.BugNames = @{
    0x0AL = @('IRQL_NOT_LESS_OR_EQUAL', 'драйвер обратился к памяти недопустимым образом', 'драйвер или оперативная память')
    0x19L = @('BAD_POOL_HEADER', 'повреждена память ядра', 'драйвер, антивирус или ОЗУ')
    0x1AL = @('MEMORY_MANAGEMENT', 'ошибка управления памятью', 'оперативная память или её разгон (XMP)')
    0x1EL = @('KMODE_EXCEPTION_NOT_HANDLED', 'необработанное исключение в ядре', 'драйвер')
    0x24L = @('NTFS_FILE_SYSTEM', 'сбой файловой системы', 'диск, кабель, ошибки файловой системы')
    0x3BL = @('SYSTEM_SERVICE_EXCEPTION', 'исключение в системном вызове', 'драйвер (часто видео) или антивирус')
    0x3DL = @('INTERRUPT_EXCEPTION_NOT_HANDLED', 'исключение в обработчике прерываний', 'драйвер или железо')
    0x4EL = @('PFN_LIST_CORRUPT', 'повреждена таблица страниц памяти', 'оперативная память или драйвер')
    0x50L = @('PAGE_FAULT_IN_NONPAGED_AREA', 'обращение к несуществующей памяти', 'оперативная память, драйвер или антивирус')
    0x77L = @('KERNEL_STACK_INPAGE_ERROR', 'не удалось прочитать данные ядра с диска', 'диск или файл подкачки')
    0x7AL = @('KERNEL_DATA_INPAGE_ERROR', 'не удалось прочитать данные с диска', 'диск/SSD, кабель SATA, блок питания')
    0x7BL = @('INACCESSIBLE_BOOT_DEVICE', 'нет доступа к загрузочному диску', 'режим SATA/RAID в BIOS, драйвер контроллера, диск')
    0x7EL = @('SYSTEM_THREAD_EXCEPTION_NOT_HANDLED', 'исключение в системном потоке', 'драйвер')
    0x7FL = @('UNEXPECTED_KERNEL_MODE_TRAP', 'аппаратная ловушка процессора', 'оперативная память, перегрев, разгон')
    0x8EL = @('KERNEL_MODE_EXCEPTION_NOT_HANDLED', 'исключение в режиме ядра', 'драйвер или оперативная память')
    0x9CL = @('MACHINE_CHECK_EXCEPTION', 'аппаратная ошибка процессора', 'процессор, блок питания, перегрев')
    0x9FL = @('DRIVER_POWER_STATE_FAILURE', 'драйвер завис при уходе в сон / пробуждении', 'драйвер Wi-Fi/USB/видео, режим сна')
    0xA0L = @('INTERNAL_POWER_ERROR', 'ошибка управления питанием', 'драйвер, гибернация')
    0xC2L = @('BAD_POOL_CALLER', 'драйвер неправильно работает с памятью', 'драйвер')
    0xC4L = @('DRIVER_VERIFIER_DETECTED_VIOLATION', 'Driver Verifier поймал нарушение', 'драйвер (отключите verifier)')
    0xC5L = @('DRIVER_CORRUPTED_EXPOOL', 'драйвер испортил память ядра', 'драйвер')
    0xD1L = @('DRIVER_IRQL_NOT_LESS_OR_EQUAL', 'драйвер обратился к неверному адресу', 'сетевой/Wi-Fi/USB-драйвер')
    0xEAL = @('THREAD_STUCK_IN_DEVICE_DRIVER', 'поток завис в драйвере', 'видеокарта или её драйвер')
    0xEFL = @('CRITICAL_PROCESS_DIED', 'завершился критический процесс Windows', 'повреждение системных файлов, диск')
    0xF4L = @('CRITICAL_OBJECT_TERMINATION', 'завершился критический объект', 'диск/SSD, кабель')
    0xF7L = @('DRIVER_OVERRAN_STACK_BUFFER', 'переполнение буфера в драйвере', 'драйвер')
    0xFCL = @('ATTEMPTED_EXECUTE_OF_NOEXECUTE_MEMORY', 'выполнение кода из запрещённой памяти', 'драйвер или ОЗУ')
    0x101L = @('CLOCK_WATCHDOG_TIMEOUT', 'ядро процессора перестало отвечать', 'процессор, разгон/андервольт, BIOS')
    0x109L = @('CRITICAL_STRUCTURE_CORRUPTION', 'повреждены структуры ядра', 'оперативная память, драйвер, читы/античиты')
    0x10EL = @('VIDEO_MEMORY_MANAGEMENT_INTERNAL', 'сбой видеопамяти', 'видеокарта или драйвер')
    0x113L = @('VIDEO_DXGKRNL_FATAL_ERROR', 'сбой графического ядра DirectX', 'видеодрайвер')
    0x116L = @('VIDEO_TDR_FAILURE', 'видеокарта зависла и не восстановилась', 'видеокарта, драйвер, разгон, блок питания')
    0x119L = @('VIDEO_SCHEDULER_INTERNAL_ERROR', 'сбой планировщика видеокарты', 'видеодрайвер или видеокарта')
    0x124L = @('WHEA_UNCORRECTABLE_ERROR', 'неисправимая аппаратная ошибка', 'процессор, память, блок питания, разгон, перегрев')
    0x12BL = @('FAULTY_HARDWARE_CORRUPTED_PAGE', 'повреждённая страница памяти', 'оперативная память')
    0x133L = @('DPC_WATCHDOG_VIOLATION', 'драйвер слишком долго не отвечал', 'прошивка SSD, драйвер накопителя (iaStor/storahci)')
    0x139L = @('KERNEL_SECURITY_CHECK_FAILURE', 'нарушена целостность данных ядра', 'драйвер или оперативная память')
    0x13AL = @('KERNEL_MODE_HEAP_CORRUPTION', 'повреждена куча ядра', 'драйвер (часто видео/звук)')
    0x144L = @('BUGCODE_USB3_DRIVER', 'сбой USB 3', 'USB-устройство, хаб или драйвер')
    0x154L = @('UNEXPECTED_STORE_EXCEPTION', 'ошибка хранилища памяти', 'SSD/диск или ОЗУ')
    0x1C8L = @('MANUALLY_INITIATED_POWER_BUTTON_HOLD', 'удерживали кнопку питания', 'перед этим компьютер завис')
    0xC000021AL = @('STATUS_SYSTEM_PROCESS_TERMINATED', 'упал системный процесс', 'системные файлы, неудачное обновление')
}
function Get-DriverHint($f) {
    $n = "$f".ToLower()
    $map = @(
        @('^nvlddmkm', 'видеодрайвер NVIDIA', 'чистая переустановка драйвера (DDU), проверить температуру и питание видеокарты'),
        @('^(atikm|amdkm|atikmpag|amdwddmg)', 'видеодрайвер AMD', 'чистая переустановка драйвера (DDU) с сайта AMD'),
        @('^igdkm', 'видеодрайвер Intel', 'обновить драйвер Intel / производителя ноутбука'),
        @('^(dxgkrnl|dxgmms|watchdog)', 'графическое ядро Windows', 'почти всегда виноват видеодрайвер или видеокарта'),
        @('^(rt640|rt68|rtux|rtwlan)', 'сетевой адаптер Realtek', 'обновить сетевой/Wi-Fi драйвер'),
        @('^(netwtw|netwbw|e1d|e1i)', 'сетевой адаптер Intel', 'обновить драйвер, отключить энергосбережение адаптера'),
        @('^(athw|qcamain)', 'Wi-Fi Qualcomm Atheros', 'обновить драйвер Wi-Fi'),
        @('^(bthport|bthusb)', 'Bluetooth', 'обновить драйвер Bluetooth'),
        @('^(tcpip|ndis|netio|afd)', 'сетевой стек Windows', 'виноват сетевой драйвер, VPN или файрвол'),
        @('^(storport|stornvme|storahci|disk|classpnp)', 'драйвер накопителя', 'проверить SSD/HDD (SMART), прошивку, кабель'),
        @('^iastor', 'Intel RST', 'обновить или удалить Intel RST, проверить режим AHCI'),
        @('^(ntfs|volsnap)', 'файловая система', 'chkdsk, проверка диска'),
        @('^(ntoskrnl|ntkrnl|hal\.dll)', 'ядро Windows', 'обычно железо (память, процессор, питание) — проверьте ОЗУ и снимите разгон'),
        @('^wdf01000', 'фреймворк драйверов', 'виноват другой драйвер в цепочке'),
        @('^fltmgr', 'фильтры файловой системы', 'виноват антивирус или программа резервного копирования'),
        @('^(klif|kl1|kneps)', 'Kaspersky', 'обновить/переустановить антивирус'),
        @('^(asw|aswarpot)', 'Avast/AVG', 'удалить утилитой производителя'),
        @('^(eamonm|ehdrv|epfw)', 'ESET', 'обновить/переустановить антивирус'),
        @('^(usbxhci|usbhub3|ucx01000)', 'USB 3', 'отключить USB-устройства, обновить драйвер чипсета'),
        @('^(hdaudbus|rtkvhd|intcaudiobus)', 'звук', 'обновить аудиодрайвер'),
        @('^(acpi|intelppm|amdppm)', 'питание процессора', 'обновить BIOS, снять разгон/андервольт'),
        @('^(vgk|easyanticheat|bedaisy)', 'античит игры', 'переустановить игру/античит'),
        @('^(vboxdrv|vmx86)', 'виртуализация', 'обновить/удалить VirtualBox/VMware'),
        @('^win32k', 'графическая подсистема Windows', 'sfc /scannow, обновить видеодрайвер')
    )
    foreach ($m in $map) { if ($n -match $m[0]) { return @{ Who = $m[1]; Fix = $m[2] } } }
    return $null
}
function Read-DumpHeader($path) {
    # Заголовок дампа ядра (DUMP_HEADER64): код, параметры, время — без символов и сторонних программ
    try {
        $fs = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite'); $br = New-Object IO.BinaryReader($fs)
        $b = $br.ReadBytes(0x1000 + 0x40); $br.Close()
        if ($b.Length -lt 0xFB0 -or [Text.Encoding]::ASCII.GetString($b, 0, 8) -ne 'PAGEDU64') { return $null }
        $code = [BitConverter]::ToUInt32($b, 0x38) -band 0xEFFFFFFF
        $ft = [BitConverter]::ToInt64($b, 0xFA8)
        return [pscustomobject]@{ Code = [uint32]$code; P1 = [BitConverter]::ToUInt64($b, 0x40); P2 = [BitConverter]::ToUInt64($b, 0x48); P3 = [BitConverter]::ToUInt64($b, 0x50); P4 = [BitConverter]::ToUInt64($b, 0x58)
            Time = $(if ($ft -gt 0) { [DateTime]::FromFileTimeUtc($ft).ToLocalTime() } else { (Get-Item $path).LastWriteTime }); Build = [BitConverter]::ToUInt32($b, 0x0C); Type = [BitConverter]::ToUInt32($b, 0xF98) }
    } catch { return $null }
}
Step 'Синие экраны: разбор дампов' {
    $s = New-Section 'Синие экраны: разбор'
    $since = (Get-Date).AddDays(-90)
    $dumps = @(Get-ChildItem "$env:SystemRoot\Minidump" -Filter *.dmp -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt $since })
    $mem = Get-Item "$env:SystemRoot\MEMORY.DMP" -ErrorAction SilentlyContinue
    if ($mem -and $mem.LastWriteTime -gt $since) { $dumps += $mem }
    # Журнал: BugCheck 1001 (остаётся, даже если дампы удалены чистильщиками)
    $bc = @()
    try {
        $bc = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'; Id = 1001; StartTime = $since } -ErrorAction Stop | ForEach-Object {
                if ($_.Message -match '0x([0-9a-fA-F]{8})') { [pscustomobject]@{ T = $_.TimeCreated; Code = [Convert]::ToUInt32($matches[1], 16) } } })
    } catch {}
    try {
        $cc = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl' -ErrorAction Stop
        $dm = @{ 0 = 'выключено'; 1 = 'полный дамп'; 2 = 'дамп ядра'; 3 = 'малый дамп'; 7 = 'автоматический' }[[int]$cc.CrashDumpEnabled]
        Add-Row $s 'Сохранение дампов при сбое' $(if ($dm) { $dm } else { $cc.CrashDumpEnabled }) $(if ($cc.CrashDumpEnabled -eq 0) { 'warn' } else { '' })
        if ($cc.CrashDumpEnabled -eq 0) { Add-Issue 'info' 'Windows' 'сохранение дампов синих экранов выключено' 'Включите: Система → Дополнительные параметры → Загрузка и восстановление → «Малый дамп памяти» — иначе причину синих экранов не узнать.' }
    } catch {}
    Add-Row $s 'Синих экранов за 90 дней (по журналу)' $bc.Count $(if ($bc.Count -ge 3) { 'crit' } elseif ($bc.Count) { 'warn' } else { 'ok' })
    Add-Row $s 'Файлов дампов' $dumps.Count
    if (-not $dumps.Count -and -not $bc.Count) { return }
    # Виновный драйвер — по BlueScreenView (если доступен)
    $bsv = @{}
    if ($dumps.Count) {
        $exe = Get-Tool 'BlueScreenView'
        if ($exe) {
            $bd = Split-Path $exe
            "[General]`r`nAddExportHeaderLine=1`r`nShowGridLines=0" | Set-Content (Join-Path $bd 'BlueScreenView.cfg') -Encoding ascii
            Remove-Item (Join-Path $bd 'BlueScreenView_lng.ini') -Force -ErrorAction SilentlyContinue
            $csv = Join-Path $G.Temp 'bsod.csv'
            $cpy = Join-Path $G.Temp 'dumps'; New-Item -ItemType Directory -Force $cpy | Out-Null
            foreach ($d in $dumps) { if ($d.Length -lt 512MB) { Copy-Item $d.FullName $cpy -Force -ErrorAction SilentlyContinue } }
            try {
                $p = Start-Process $exe -ArgumentList "/LoadFrom 1 /MiniDumpFolder `"$cpy`" /scomma `"$csv`"" -PassThru -WindowStyle Hidden
                if (-not $p.WaitForExit(120000)) { try { $p.Kill() } catch {} }
            } catch {}
            if (Test-Path $csv) {
                foreach ($r in @(Import-Csv $csv -Encoding Default)) { $bsv[[IO.Path]::GetFileName($r.'Dump File')] = $r }
            }
        }
    }
    $rows = @(); $drivers = @{}; $codes = @{}; $seen = @{}
    foreach ($d in ($dumps | Sort-Object LastWriteTime -Descending | Select-Object -First 20)) {
        $h = Read-DumpHeader $d.FullName
        $r = $bsv[$d.Name]
        $code = if ($h) { $h.Code } elseif ($r) { try { [Convert]::ToUInt32(($r.'Bug Check Code' -replace '^0x', ''), 16) } catch { 0 } } else { 0 }
        $nm = $G.BugNames[[int64]$code]
        $drv = if ($r -and $r.'Caused By Driver') { $r.'Caused By Driver' } else { '' }
        $hint = if ($drv) { Get-DriverHint $drv } else { $null }
        $uk = ('{0}|{1}' -f $(if ($h) { $h.Time.ToString('yyyyMMddHHmm') } else { $d.LastWriteTime.ToString('yyyyMMddHHmm') }), $code)
        if (-not $seen.ContainsKey($uk)) { $seen[$uk] = 1; if ($drv) { $drivers[$drv]++ }; $codes[[int64]$code]++ }
        $rows += [pscustomobject]@{
            'Когда' = $(if ($h) { $h.Time.ToString('dd.MM.yyyy HH:mm') } else { $d.LastWriteTime.ToString('dd.MM.yyyy HH:mm') })
            'Код' = ('0x{0:X}' -f $code) + $(if ($nm) { ' ' + $nm[0] } else { '' })
            'Что случилось' = $(if ($nm) { $nm[1] } else { '—' })
            'Виновник' = $(if ($drv) { $drv + $(if ($hint) { ' (' + $hint.Who + ')' } elseif ($r.'Product Name') { ' (' + $r.'Product Name' + ')' } else { '' }) } else { '—' })
            'Параметры' = $(if ($h) { '{0:X} {1:X} {2:X} {3:X}' -f $h.P1, $h.P2, $h.P3, $h.P4 } else { '' })
        }
    }
    # один сбой может оставить и MEMORY.DMP, и минидамп — считаем уникальные (время+код)
    $rows = @($rows | Group-Object 'Когда', 'Код' | ForEach-Object { $_.Group[0] })
    if (-not $rows.Count) {
        foreach ($e in $bc) { $codes[[int64]$e.Code]++ }
        $rows = @($bc | Select-Object -First 20 | ForEach-Object { $nm = $G.BugNames[[int64]$_.Code]; [pscustomobject]@{ 'Когда' = $_.T.ToString('dd.MM.yyyy HH:mm'); 'Код' = ('0x{0:X}' -f $_.Code) + $(if ($nm) { ' ' + $nm[0] } else { '' }); 'Что случилось' = $(if ($nm) { $nm[1] } else { '—' }); 'Виновник' = 'дамп не сохранился' } })
    }
    Add-Table $s 'Синие экраны (новые сверху)' $rows
    # Итог: самый частый виновник / код
    $topD = $drivers.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1
    $topC = $codes.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1
    $total = if ($bc.Count) { $bc.Count } else { $rows.Count }
    $hwCodes = @(0x124, 0x9C, 0x101, 0x7F, 0x1A, 0x4E, 0x12B, 0x50, 0x7A, 0x77, 0xF4)
    $sev = if ($total -ge 3) { 'crit' } else { 'warn' }
    $what = @(); $fix = @()
    if ($topD -and $topD.Key -notmatch '(?i)^(ntoskrnl|ntkrnl|hal)') {
        $hn = Get-DriverHint $topD.Key
        $what += ('чаще всего виноват {0}{1}' -f $topD.Key, $(if ($hn) { " ($($hn.Who))" } else { '' }))
        if ($hn) { $fix += $hn.Fix } else { $fix += "обновите или переустановите программу/устройство, которому принадлежит $($topD.Key)" }
    }
    if ($topC) {
        $nm = $G.BugNames[[int64]$topC.Key]
        if ($nm) { $what += ('код 0x{0:X} {1} — {2}' -f $topC.Key, $nm[0], $nm[1]); if (-not $fix.Count -or $topC.Key -in $hwCodes) { $fix += ('вероятная причина: ' + $nm[2]) } }
        if ($topC.Key -in $hwCodes -and -not $G.Sel.ram) { $fix += 'обязательно проверьте оперативную память (полный тест памяти)' }
    }
    if (-not $what.Count) { $what += 'причина в дампах не определена' }
    Add-Row $s 'Вывод' ($what -join '; ') $sev
    Add-Issue $sev 'Стабильность' ('синих экранов: {0} за 90 дней — {1}' -f $total, ($what -join '; ')) $(if ($fix.Count) { ($fix | Select-Object -Unique) -join '; ' } else { 'Проверьте драйверы, оперативную память и температуры.' })
    $G.Num.bsod90 = $total
}
