# Загрузочная флешка BTT на WinPE (НЕ шаг диагностики) — для ПК, где Windows не загружается.
#   Invoke-DiagTool 'rescueusb' -> New-BttRescueUsb   (см. lib-86-usbtools.ps1; хук DIAG_TOOL в body.ps1)
# Схема: Windows ADK (Deployment Tools) + WinPE add-on -> copype amd64 -> boot.wim + компоненты
# (WMI, NetFX, Scripting, PowerShell, StorageWMI, DismCmdlets, SecureStartup + ru-ru) -> startnet.cmd
# автозапускает программу с DIAG_PE=1 -> флешка: MBR + FAT32 (<= 32 ГБ) + файлы media + bootsect /nt60
# (то же, что делает MakeWinPEMedia /UFD, но по НОМЕРУ диска после всех проверок lib-86, а не по букве,
#  и без ошибки diskpart на флешках > 32 ГБ). Дополнительно кладёт ISO (MakeWinPEMedia /ISO) — для Ventoy.
# В WinPE ($env:DIAG_PE='1') программа должна пропускать неподдерживаемые шаги — пресет ниже уже снимает их галочки.

# Windows ADK 10.1.26100.9457 (сентябрь 2026) — поддерживает Windows 10/11 до 26H2. Веб-установщики Microsoft:
# хеш не фиксируем (ссылки fwlink обновляются), проверяем цифровую подпись Microsoft.
$G.BttAdkUrl = 'https://go.microsoft.com/fwlink/?linkid=2289980'
$G.BttPeUrl = 'https://go.microsoft.com/fwlink/?linkid=2289981'
$G.BttPeOCs = @('WinPE-WMI', 'WinPE-NetFX', 'WinPE-Scripting', 'WinPE-PowerShell', 'WinPE-StorageWMI', 'WinPE-DismCmdlets', 'WinPE-SecureStartup', 'WinPE-EnhancedStorage')
$G.BttPeTools = @('LHM', 'PawnIO', 'DiskSpd', 'Smartctl', 'SevenZ', 'YCruncher')   # Linpack (~400 МБ) и FurMark (нужен GPU-драйвер) не берём

# В WinPE снимаем то, что там не работает или бессмысленно (живые журналы/программы/драйверы/антивирус/GPU/звук/камера)
$G.PresetHooks.Add({
    param($full)
    if ($env:DIAG_PE) { foreach ($k in 'programs', 'logs', 'drivers', 'av', 'gpu', 'sound', 'mic', 'cam', 'firmware', 'memdiag', 'sys') { $G.Sel[$k] = $false } }
})

function Get-BttOfflineWindows {
    # Для WinPE-режима: буквы дисков с установленной (незагружающейся) Windows.
    # Журналы читать так: Get-WinEvent -Path "$d\Windows\System32\winevt\Logs\System.evtx"; дампы: "$d\Windows\Minidump".
    $res = @()
    foreach ($v in @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
        $root = "$($v.Name):"
        if ($root -eq 'X:') { continue }
        if (Test-Path "$root\Windows\System32\config\SYSTEM") { $res += $root }
    }
    return , $res
}

function Get-BttAdkPaths {
    $kits = $null
    foreach ($k in 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots', 'HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots') {
        try { $kits = (Get-ItemProperty $k -ErrorAction Stop).KitsRoot10; if ($kits) { break } } catch {}
    }
    if (-not $kits) { $kits = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\' }
    $adk = Join-Path $kits 'Assessment and Deployment Kit'
    $r = [pscustomobject]@{
        Adk      = $adk
        DandI    = Join-Path $adk 'Deployment Tools\DandISetEnv.bat'
        Dism     = Join-Path $adk 'Deployment Tools\amd64\DISM\dism.exe'
        Bootsect = Join-Path $adk 'Deployment Tools\amd64\BCDBoot\bootsect.exe'
        PeRoot   = Join-Path $adk 'Windows Preinstallation Environment\amd64'
        OCs      = Join-Path $adk 'Windows Preinstallation Environment\amd64\WinPE_OCs'
        HasDT    = $false
        HasPE    = $false
    }
    $r.HasDT = (Test-Path $r.DandI) -and (Test-Path $r.Dism)
    $r.HasPE = Test-Path (Join-Path $r.PeRoot 'en-us\winpe.wim')
    return $r
}

function Invoke-BttProc([string]$File, [string]$Arguments, [string]$What) {
    # Запуск внешней программы с ожиданием; код возврата 0 (и 3010 — нужна перезагрузка) = успех
    $G.Log.Add(('{0}: "{1}" {2}' -f $What, $File, $Arguments))
    try {
        $p = Start-Process -FilePath $File -ArgumentList $Arguments -Wait -PassThru -NoNewWindow -ErrorAction Stop
        $code = $p.ExitCode
    } catch { Bad ('{0}: {1}' -f $What, $_.Exception.Message); return $false }
    if ($code -ne 0 -and $code -ne 3010) { Bad ('{0}: код ошибки {1}' -f $What, $code); return $false }
    return $true
}

function Get-BttSignedMsDownload([string]$Url, [string]$Name) {
    $dl = Join-Path $G.Temp $Name
    Info "скачиваю $Name..."
    try { Invoke-WebRequest -Uri $Url -OutFile $dl -UseBasicParsing -UserAgent 'Mozilla/5.0' -TimeoutSec 600 -ErrorAction Stop }
    catch { Bad ('не удалось скачать {0}: {1}' -f $Name, $_.Exception.Message); return $null }
    $sig = Get-AuthenticodeSignature $dl
    if ($sig.Status -ne 'Valid' -or "$($sig.SignerCertificate.Subject)" -notmatch 'O=Microsoft Corporation') {
        Bad ('{0}: нет действительной подписи Microsoft — файл не используется' -f $Name)
        Remove-Item $dl -Force -ErrorAction SilentlyContinue
        return $null
    }
    return $dl
}

function Install-BttAdk {
    # Тихая установка ADK (только Deployment Tools) и WinPE add-on. Возвращает пути или $null.
    $paths = Get-BttAdkPaths
    if ($paths.HasDT -and $paths.HasPE) { Ok 'Windows ADK и WinPE add-on уже установлены'; return $paths }
    $free = 0
    try { $free = (Get-PSDrive ($env:SystemDrive.TrimEnd(':')) -ErrorAction Stop).Free } catch {}
    Write-Host ''
    Warn 'Для сборки флешки нужен Windows ADK от Microsoft (бесплатно): Deployment Tools + WinPE add-on.'
    Warn ('Скачивание ~3–4 ГБ, на диске {0} займёт ~6 ГБ, установка 15–40 мин. Свободно: {1:N1} ГБ.' -f $env:SystemDrive, ($free / 1e9))
    if ($free -gt 0 -and $free -lt 10e9) { Bad 'Нужно хотя бы 10 ГБ свободного места на системном диске.'; return $null }
    if (-not (AskYN 'Скачать и установить Windows ADK на ЭТОТ компьютер?' 'N')) { return $null }
    if (-not $paths.HasDT) {
        $f = Get-BttSignedMsDownload $G.BttAdkUrl 'adksetup.exe'
        if (-not $f) { return $null }
        Info 'устанавливаю ADK Deployment Tools (тихо)...'
        if (-not (Invoke-BttProc $f '/quiet /norestart /ceip off /features OptionId.DeploymentTools' 'adksetup')) { return $null }
    }
    if (-not $paths.HasPE) {
        $f = Get-BttSignedMsDownload $G.BttPeUrl 'adkwinpesetup.exe'
        if (-not $f) { return $null }
        Info 'устанавливаю WinPE add-on (тихо, это самая долгая часть)...'
        if (-not (Invoke-BttProc $f '/quiet /norestart /ceip off /features OptionId.WindowsPreinstallationEnvironment' 'adkwinpesetup')) { return $null }
    }
    $paths = Get-BttAdkPaths
    if (-not ($paths.HasDT -and $paths.HasPE)) { Bad 'ADK установлен не полностью — сборка невозможна.'; return $null }
    Ok 'Windows ADK установлен'
    return $paths
}

function Get-BttStartnet {
    # startnet.cmd внутри boot.wim: инициализация, поиск флешки по метке-файлу, запуск программы в режиме DIAG_PE.
    # Запускаем powershell напрямую (как раздел :run в заголовке .cmd): проверка 'net session' в WinPE не работает.
    # Только ASCII — кодовая страница консоли WinPE заранее неизвестна.
    return @(
        '@echo off'
        'wpeinit'
        'powercfg /s 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c >nul 2>&1'
        'set BTTDRV='
        'for %%d in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do if exist %%d:\BTT\btt-pe.marker set "BTTDRV=%%d:"'
        'if not defined BTTDRV ( echo BTT: USB drive with \BTT not found. Type "exit" to reboot. & goto :eof )'
        'set "DIAG_PE=1"'
        'set "DIAG_NOUPDATE=1"'
        'set "DIAG_ROOT=%BTTDRV%\BTT"'
        'set "DIAG_SELF=%BTTDRV%\BTT\BigTechoTest.cmd"'
        'if not exist "%BTTDRV%\BTT\Reports" mkdir "%BTTDRV%\BTT\Reports"'
        'set "DIAG_OUT=%BTTDRV%\BTT\Reports"'
        'chcp 65001 >nul'
        'powershell -NoProfile -ExecutionPolicy Bypass -Command "iex ([IO.File]::ReadAllText($env:DIAG_SELF,[Text.Encoding]::UTF8))"'
        'echo.'
        'echo BTT finished. Reports: %DIAG_OUT%   Type "exit" to reboot.'
    ) -join "`r`n"
}

function Build-BttPeMedia($Paths, [string]$Work) {
    # Сборка папки media (copype + компоненты в boot.wim + программа). Возвращает путь к media или $null.
    $mount = Join-Path $Work 'mount'
    $media = Join-Path $Work 'media'
    if (Test-Path $Work) {
        # остатки прошлой сборки: размонтировать без сохранения и удалить
        if (Test-Path (Join-Path $mount 'Windows')) { [void](Invoke-BttProc $Paths.Dism ('/Unmount-Image /MountDir:"{0}" /Discard' -f $mount) 'dism unmount (старое)') }
        [void](Invoke-BttProc $Paths.Dism '/Cleanup-Mountpoints' 'dism cleanup')
        Remove-Item $Work -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path $Work) { Bad "Не удалось очистить $Work (закройте окна Проводника в этой папке)."; return $null }
    }
    $bat = Join-Path $G.Temp 'btt-copype.cmd'
    [IO.File]::WriteAllText($bat, ('@call "{0}" >nul' -f $Paths.DandI) + "`r`n" + ('@copype amd64 "{0}"' -f $Work) + "`r`n", (New-Object Text.UTF8Encoding $false))
    Info 'copype amd64...'
    if (-not (Invoke-BttProc "$env:SystemRoot\System32\cmd.exe" ('/c "{0}"' -f $bat) 'copype')) { return $null }
    $wim = Join-Path $media 'sources\boot.wim'
    if (-not (Test-Path $wim)) { Bad 'copype не создал boot.wim'; return $null }

    Info 'монтирую boot.wim...'
    if (-not (Invoke-BttProc $Paths.Dism ('/Mount-Image /ImageFile:"{0}" /Index:1 /MountDir:"{1}"' -f $wim, $mount) 'dism mount')) { return $null }
    $committed = $false
    try {
        $ru = Join-Path $Paths.OCs 'ru-ru'
        $pk = New-Object System.Collections.Generic.List[string]
        if (Test-Path (Join-Path $ru 'lp.cab')) { $pk.Add((Join-Path $ru 'lp.cab')) }
        foreach ($oc in $G.BttPeOCs) {
            $cab = Join-Path $Paths.OCs ($oc + '.cab')
            if (-not (Test-Path $cab)) { Warn "нет компонента $oc"; continue }
            $pk.Add($cab)
            $rc = Join-Path $ru ($oc + '_ru-ru.cab')
            if (Test-Path $rc) { $pk.Add($rc) }
        }
        foreach ($c in $pk) {
            Info ('добавляю ' + [IO.Path]::GetFileName($c))
            if (-not (Invoke-BttProc $Paths.Dism ('/Image:"{0}" /Add-Package /PackagePath:"{1}"' -f $mount, $c) 'dism add-package')) {
                if ($c -match 'WinPE-(WMI|NetFX|PowerShell)\.cab$') { throw ('не добавлен обязательный компонент ' + [IO.Path]::GetFileName($c)) }
            }
        }
        $tz = 'Russian Standard Time'
        try { $tz = (Get-TimeZone).Id } catch {}
        [void](Invoke-BttProc $Paths.Dism ('/Image:"{0}" /Set-AllIntl:ru-RU' -f $mount) 'dism intl')
        [void](Invoke-BttProc $Paths.Dism ('/Image:"{0}" /Set-InputLocale:0409:00000409;0419:00000419' -f $mount) 'dism input')
        [void](Invoke-BttProc $Paths.Dism ('/Image:"{0}" /Set-TimeZone:"{1}"' -f $mount, $tz) 'dism tz')
        [void](Invoke-BttProc $Paths.Dism ('/Image:"{0}" /Set-ScratchSpace:512' -f $mount) 'dism scratch')
        # Add-Type (C#-модули программы) требует csc.exe из .NET — проверяем, что WinPE-NetFX его принёс
        if (-not (Test-Path (Join-Path $mount 'Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'))) {
            Warn 'В образе нет csc.exe — C#-модули программы (окна, тесты) в WinPE не скомпилируются; нужна предкомпилированная DLL.'
            $G.Log.Add('WinPE: csc.exe отсутствует в Framework64\v4.0.30319')
        }
        [IO.File]::WriteAllText((Join-Path $mount 'Windows\System32\startnet.cmd'), (Get-BttStartnet), [Text.Encoding]::ASCII)
        Info 'сохраняю boot.wim...'
        if (-not (Invoke-BttProc $Paths.Dism ('/Unmount-Image /MountDir:"{0}" /Commit' -f $mount) 'dism commit')) { throw 'не удалось сохранить boot.wim' }
        $committed = $true
    } catch { Bad ('Сборка WinPE: ' + $_.Exception.Message) }
    finally {
        if (-not $committed) { [void](Invoke-BttProc $Paths.Dism ('/Unmount-Image /MountDir:"{0}" /Discard' -f $mount) 'dism discard') }
    }
    if (-not $committed) { return $null }

    # Программа и инструменты — на флешку рядом с WinPE (\BTT)
    $btt = Join-Path $media 'BTT'
    $bt = Join-Path $btt 'tools'
    New-Item -ItemType Directory -Path $bt -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $btt 'Reports') -Force | Out-Null
    $self = $G.Self
    if (-not $self -or -not (Test-Path $self)) { $self = Join-Path $G.Root 'PC-Diagnostika.cmd' }
    if (-not (Test-Path $self)) { Bad 'Не найден файл программы (.cmd) для копирования на флешку.'; return $null }
    Copy-Item $self (Join-Path $btt 'BigTechoTest.cmd') -Force
    [IO.File]::WriteAllText((Join-Path $btt 'btt-pe.marker'), ('BigTechoTest WinPE ' + (Get-Date -Format 'yyyy-MM-dd')), [Text.Encoding]::ASCII)
    foreach ($tn in $G.BttPeTools) {
        if (-not $TOOLS.ContainsKey($tn)) { continue }
        $exe = Get-Tool $tn
        if (-not $exe) { Warn "$tn не скачан — в WinPE его не будет"; continue }
        $top = ("$($TOOLS[$tn].Exe)" -split '\\')[0]   # верхний уровень в tools\ (папка или одиночный exe)
        $src = Join-Path $G.Tools $top
        if (Test-Path $src) { Copy-Item $src -Destination $bt -Recurse -Force -ErrorAction SilentlyContinue }
    }
    $mb = (Get-ChildItem $media -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1MB
    Ok ('Образ собран: {0:N0} МБ' -f $mb)
    return $media
}

function Write-BttPeToUsb($Target, $Paths, [string]$Media) {
    # Разметка по номеру диска (после повторной проверки): MBR + один активный FAT32 (<= 32 ГБ), копирование, bootsect /nt60.
    # MBR+FAT32 грузится и в UEFI (\EFI\Boot\bootx64.efi), и в Legacy BIOS.
    if (-not (Assert-BttUsbTarget $Target)) { return $false }
    $num = [int]$Target.Number
    try {
        Set-Disk -Number $num -IsReadOnly $false -ErrorAction SilentlyContinue
        Info 'очищаю флешку...'
        Clear-Disk -Number $num -RemoveData -RemoveOEM -Confirm:$false -ErrorAction Stop
        try { Initialize-Disk -Number $num -PartitionStyle MBR -ErrorAction Stop } catch { Set-Disk -Number $num -PartitionStyle MBR -ErrorAction SilentlyContinue }
        if (-not (Assert-BttUsbTarget $Target)) { return $false }
        $max = [long]32000MB   # FAT32 в Windows форматируется до 32 ГБ
        $part = $null
        if ($Target.Size -gt ($max + 16MB)) { $part = New-Partition -DiskNumber $num -Size $max -IsActive -AssignDriveLetter -ErrorAction Stop }
        else { $part = New-Partition -DiskNumber $num -UseMaximumSize -IsActive -AssignDriveLetter -ErrorAction Stop }
        Start-Sleep -Seconds 2
        $part = Get-Partition -DiskNumber $num -PartitionNumber $part.PartitionNumber -ErrorAction Stop
        if (-not $part.DriveLetter -or "$($part.DriveLetter)" -notmatch '[A-Z]') { throw 'разделу не назначена буква' }
        Format-Volume -Partition $part -FileSystem FAT32 -NewFileSystemLabel 'BTT-PE' -Confirm:$false -Force -ErrorAction Stop | Out-Null
    } catch { Bad ('Разметка флешки: ' + $_.Exception.Message); return $false }
    $dl = "$($part.DriveLetter):"
    # последняя страховка: буква точно на выбранном USB-диске
    if ((Get-Partition -DriveLetter $part.DriveLetter -ErrorAction SilentlyContinue | Select-Object -First 1).DiskNumber -ne $num) { Bad 'Буква тома не на выбранном диске — стоп.'; return $false }
    Info "копирую файлы на $dl ..."
    & robocopy.exe $Media "$dl\" /E /R:1 /W:1 /NFL /NDL /NJH /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { Bad ('robocopy: код ' + $LASTEXITCODE); return $false }
    if (Test-Path $Paths.Bootsect) {
        if (-not (Invoke-BttProc $Paths.Bootsect ('/nt60 {0} /force /mbr' -f $dl) 'bootsect')) { Warn 'Загрузка в режиме Legacy BIOS может не работать (UEFI будет).' }
    }
    if (-not (Test-Path "$dl\EFI\Boot\bootx64.efi") -or -not (Test-Path "$dl\sources\boot.wim") -or -not (Test-Path "$dl\BTT\btt-pe.marker")) { Bad 'Файлы на флешке неполные.'; return $false }
    $wa = (Get-FileHash (Join-Path $Media 'sources\boot.wim') -Algorithm SHA256).Hash
    $wb = (Get-FileHash "$dl\sources\boot.wim" -Algorithm SHA256).Hash
    if ($wa -ne $wb) { Bad 'boot.wim на флешке не совпал с собранным — флешка неисправна.'; return $false }
    Ok "Флешка готова ($dl, проверено)"
    return $true
}

function New-BttRescueUsb {
    Title 'Загрузочная флешка BTT (WinPE)'
    Say 'Флешка, с которой программа запускается БЕЗ Windows — для ПК, где система не загружается.'
    Say 'В режиме WinPE работают: сведения о железе, SMART и тест дисков, тест ОЗУ/процессора (y-cruncher),'
    Say 'чтение журналов и дампов синих экранов с диска незагружающейся Windows. Не работают: тест видеокарты'
    Say '(нет драйверов GPU), звук/камера, драйверы, антивирус, обновления. Датчики — частично.'
    if (-not (Test-BttToolAllowed)) { return }
    if ([Environment]::Is64BitOperatingSystem -eq $false) { Bad 'Нужна 64-битная Windows.'; return }
    $target = Read-BttUsbTarget ([long]1.8e9) 'загрузочная флешка BTT'
    if (-not $target) { Info 'Отменено.'; return }
    $paths = Install-BttAdk
    if (-not $paths) { Info 'Без Windows ADK флешку собрать нельзя.'; return }
    $work = Join-Path $env:TEMP 'BTT-PE'
    $media = Build-BttPeMedia $paths $work
    if (-not $media) { return }
    # ISO рядом с программой — для Ventoy/виртуалок (не обязательно)
    $iso = Join-Path $G.Root 'BTT-PE.iso'
    $mk = Join-Path $paths.Adk 'Windows Preinstallation Environment\MakeWinPEMedia.cmd'
    if (Test-Path $mk) {
        $bat = Join-Path $G.Temp 'btt-iso.cmd'
        [IO.File]::WriteAllText($bat, ('@call "{0}" >nul' -f $paths.DandI) + "`r`n" + ('@call MakeWinPEMedia /ISO /F "{0}" "{1}"' -f $work, $iso) + "`r`n", (New-Object Text.UTF8Encoding $false))
        if (Invoke-BttProc "$env:SystemRoot\System32\cmd.exe" ('/c "{0}"' -f $bat) 'MakeWinPEMedia /ISO') { Ok "ISO: $iso" }
    }
    Write-Host ''
    Write-Host ('  Сейчас будет записана флешка: диск {0} «{1}», {2:N1} ГБ' -f $target.Number, $target.Model, $target.SizeGB) -ForegroundColor Yellow
    if (-not (AskYN 'Записать?' 'N')) { Info "Отменено. Собранные файлы: $media"; return }
    if (-not (Write-BttPeToUsb $target $paths $media)) { return }
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host ''
    Write-Host '  ФЛЕШКА BTT (WinPE) ГОТОВА.' -ForegroundColor Green
    Write-Host '   1. Вставьте её в нерабочий ПК, включите и жмите клавишу меню загрузки (F8 / F11 / F12 / Esc).'
    Write-Host '   2. Выберите флешку (UEFI). Secure Boot отключать не нужно — WinPE подписан Microsoft.'
    Write-Host '   3. Программа запустится сама; отчёты сохраняются на флешку в папку \BTT\Reports.'
    Write-Host '   Флешку можно продолжать использовать: свои файлы кладите рядом, папки EFI, boot, sources, BTT не трогайте.' -ForegroundColor DarkGray
}
