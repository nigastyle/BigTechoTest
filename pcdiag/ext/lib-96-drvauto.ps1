# Автоустановка драйверов (вызывается из шага 'Драйверы: установка и обновление' после Windows Update):
#   DrvA-Run $Section $Install  — 1) устройства без драйвера / с ошибкой: ИД оборудования -> каталог Microsoft Update
#                                    (catalog.update.microsoft.com) -> .cab -> expand -> pnputil /add-driver /install -> перепроверка;
#                                 2) видеокарта NVIDIA: если вышел новый Game Ready — скачать DCH-установщик nvidia.com,
#                                    проверить подпись NVIDIA Corporation, распаковать 7zr, тихая установка (только драйвер + HD Audio).
#                                 AMD/Intel GPU — только Windows Update (автоустановка их пакетов ненадёжна).
# $Install = $false (авто-режим без DIAG_DRV=Y) — только поиск: ничего не скачивается и не ставится.
# Никогда не перезагружает (только $G.RebootNeeded), прошивки/BIOS — только при явном согласии ($G.UpdFirmware) и не от батареи.
# Каждое действие пишется в $G.Log.
$DRVA = @{ UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36'; NetFail = 0 }
$DRVA.Cat = 'https://www.catalog.update.microsoft.com/'
# Метки «version X and later» в колонке «Продукты» каталога -> минимальная сборка Windows
$DRVA.B10 = @{ '1507' = 10240; '1511' = 10586; '1607' = 14393; '1703' = 15063; '1709' = 16299; '1803' = 17134; '1809' = 17763; '1903' = 18362; '1909' = 18363
    '2004' = 19041; 'VIBRANIUM' = 19041; '20H2' = 19042; '21H1' = 19043; '21H2' = 19044; '22H2' = 19045 }
$DRVA.B11 = @{ '21H2' = 22000; 'COBALT' = 22000; '22H2' = 22621; 'NICKEL' = 22621; '23H2' = 22631; '24H2' = 26100; 'GERMANIUM' = 26100; '25H2' = 26200; '26H1' = 28000 }

function DrvA-Log($t) { try { $G.Log.Add(('{0:HH:mm:ss} drvauto: {1}' -f (Get-Date), $t)) } catch {} }

# GET/POST-форма с тайм-аутом; Invoke-WebRequest, при сбое — curl.exe. Текст или $null (не бросает).
function DrvA-Http($Url, $Form = $null, $TimeoutSec = 30) {
    $txt = $null
    try {
        if ($Form) { $r = Invoke-WebRequest -Uri $Url -Method Post -Body $Form -UseBasicParsing -UserAgent $DRVA.UA -TimeoutSec $TimeoutSec -ErrorAction Stop }
        else { $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -UserAgent $DRVA.UA -TimeoutSec $TimeoutSec -ErrorAction Stop }
        if ($r -and $r.Content) { if ($r.Content -is [byte[]]) { $txt = [Text.Encoding]::UTF8.GetString($r.Content) } else { $txt = [string]$r.Content } }
    } catch { DrvA-Log ("http {0}: {1}" -f $Url, $_.Exception.Message) }
    if (-not $txt) {
        try {
            $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
            if (Test-Path $curl) {
                $tf = Join-Path $G.Temp ('drva_resp_' + [guid]::NewGuid().ToString('N') + '.txt')
                $ca = @('-fsSL', '--max-time', "$TimeoutSec", '-A', $DRVA.UA, '-o', $tf)
                if ($Form) {
                    # значения формы — через файлы (PS 5.1 портит кавычки JSON в аргументах внешних программ)
                    foreach ($k in $Form.Keys) {
                        $ff = Join-Path $G.Temp ('drva_form_' + [guid]::NewGuid().ToString('N') + '.txt')
                        [IO.File]::WriteAllText($ff, [string]$Form[$k], (New-Object Text.UTF8Encoding($false)))
                        $ca += @('--data-urlencode', ($k + '@' + $ff))
                    }
                }
                $ca += $Url
                & $curl @ca 2>$null | Out-Null
                if (Test-Path $tf) { $txt = [IO.File]::ReadAllText($tf, [Text.Encoding]::UTF8); Remove-Item $tf -Force -ErrorAction SilentlyContinue }
            }
        } catch { DrvA-Log ("curl {0}: {1}" -f $Url, $_.Exception.Message) }
    }
    if ($txt) { $DRVA.NetFail = 0 } else { $DRVA.NetFail = $DRVA.NetFail + 1 }
    return $txt
}

# Скачивание файла с тайм-аутом и прогрессом (curl.exe в фоне, иначе Invoke-WebRequest). $true/$false.
function DrvA-Download($Url, $Path, $TimeoutSec = 300, $Label = 'загрузка', $Total = 0) {
    Remove-Item $Path -Force -ErrorAction SilentlyContinue
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    $t0 = Get-Date
    if (Test-Path $curl) {
        try {
            $argl = ('-fsSL --retry 2 --max-time {0} -A "{1}" -o "{2}" "{3}"' -f [int]$TimeoutSec, $DRVA.UA, $Path, $Url)
            $p = Start-Process $curl -ArgumentList $argl -PassThru -WindowStyle Hidden
            $null = $p.Handle   # иначе ExitCode бывает пустым
            $shown = $false
            while (-not $p.HasExited) {
                if (((Get-Date) - $t0).TotalSeconds -gt $TimeoutSec + 15) { try { $p.Kill() } catch {}; break }
                Start-Sleep -Seconds 2
                $sz = 0; try { $sz = (Get-Item $Path -ErrorAction Stop).Length } catch {}
                $pc = ''; if ($Total -gt 0) { $pc = (' ({0:N0} %)' -f (100.0 * $sz / $Total)) }
                Write-Host -NoNewline ("`r    {0}: {1:N1} МБ{2}, {3:N0} с   " -f $Label, ($sz / 1MB), $pc, ((Get-Date) - $t0).TotalSeconds); $shown = $true
            }
            if ($shown) { Write-Host '' }
            $p.WaitForExit()
            if ($p.ExitCode -eq 0 -and (Test-Path $Path) -and (Get-Item $Path).Length -gt 0) { DrvA-Log ("скачано {0} ({1:N0} байт, {2:N0} с)" -f $Url, (Get-Item $Path).Length, ((Get-Date) - $t0).TotalSeconds); return $true }
            DrvA-Log ("curl download {0}: код {1}" -f $Url, $p.ExitCode)
        } catch { DrvA-Log ("curl download {0}: {1}" -f $Url, $_.Exception.Message) }
    }
    $left = [int]($TimeoutSec - ((Get-Date) - $t0).TotalSeconds)
    if ($left -lt 30) { return $false }
    try {
        $pp = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $Url -OutFile $Path -UseBasicParsing -UserAgent $DRVA.UA -TimeoutSec $left -ErrorAction Stop
        $ProgressPreference = $pp
        if ((Test-Path $Path) -and (Get-Item $Path).Length -gt 0) { DrvA-Log ("скачано (IWR) {0}" -f $Url); return $true }
    } catch { DrvA-Log ("IWR download {0}: {1}" -f $Url, $_.Exception.Message) }
    return $false
}

function DrvA-Os {
    $b = 0; try { $b = [int](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop).CurrentBuild } catch {}
    return @{ Build = $b; W11 = ($b -ge 22000); Arm = ("$env:PROCESSOR_ARCHITECTURE" -match 'ARM') }
}

# Колонка «Продукты»: подходит ли обновление к этой Windows. Возвращает минимальную сборку (>=0) или -1 (не подходит).
function DrvA-ProdFit($Products, $Os) {
    $best = -1
    foreach ($m in [regex]::Matches("$Products", '(?i)Windows\s*(10|11|-)[^,]*?(?:,\s*(?:version\s+)?(\w+)\s+and\s+later)?(?=,|$)')) {
        $fam = $m.Groups[1].Value; $ver = $m.Groups[2].Value.ToUpper()
        if ($fam -eq '-') { $fam = '11' }
        if ($fam -eq '11' -and -not $Os.W11) { continue }
        $mb = 0
        if ($ver) {
            $tab = $DRVA.B10; if ($fam -eq '11') { $tab = $DRVA.B11 }
            if ($tab.ContainsKey($ver)) { $mb = [int]$tab[$ver] }
        }
        if ($mb -le $Os.Build -and $mb -gt $best) { $best = $mb }
    }
    return $best
}

# Поиск в каталоге: массив @{Id; Title; Products; Class; Date; Version; Size}
function DrvA-CatSearch($Q) {
    $res = New-Object System.Collections.Generic.List[object]
    $html = DrvA-Http ($DRVA.Cat + 'Search.aspx?q=' + [uri]::EscapeDataString($Q)) $null 30
    if (-not $html) { return $res.ToArray() }
    foreach ($m in [regex]::Matches($html, '(?s)<tr id="([0-9a-fA-F-]{36})_R\d+".*?</tr>')) {
        $id = $m.Groups[1].Value; $r = $m.Value
        $cells = @{}
        foreach ($c in [regex]::Matches($r, '(?s)id="' + [regex]::Escape($id) + '_C(\d)_R\d+">(.*?)</td>')) {
            $cells[[int]$c.Groups[1].Value] = Clean ([Net.WebUtility]::HtmlDecode(($c.Groups[2].Value -replace '<[^>]+>', ' ')))
        }
        $dt = $null; $d0 = [datetime]::MinValue
        if ([datetime]::TryParseExact("$($cells[4])", 'M/d/yyyy', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$d0)) { $dt = $d0 }
        $szm = [regex]::Match($r, '_originalSize">(\d+)<')
        $sz = 0; if ($szm.Success) { $sz = [int64]$szm.Groups[1].Value }
        $res.Add([pscustomobject]@{ Id = $id; Title = "$($cells[1])"; Products = "$($cells[2])"; Class = "$($cells[3])"; Date = $dt; Version = "$($cells[5])"; Size = $sz })
    }
    return $res.ToArray()
}

# Отбор: подходит к этой Windows, не прошивка (если нет согласия), новее — первыми; по одному на версию
function DrvA-CatPick($Rows, $Os, $AllowFw) {
    $ok = New-Object System.Collections.Generic.List[object]
    foreach ($r in $Rows) {
        if (-not $AllowFw -and ($r.Class -match '(?i)firmware' -or $r.Title -match '(?i)firmware|\bbios\b|uefi')) { continue }
        if (-not $Os.Arm -and $r.Title -match '(?i)\bARM64\b') { continue }
        $fit = DrvA-ProdFit $r.Products $Os
        if ($fit -lt 0) { continue }
        $r | Add-Member -NotePropertyName Fit -NotePropertyValue $fit -Force
        $r | Add-Member -NotePropertyName Ver -NotePropertyValue (Fresh-ParseVer $r.Version) -Force
        $ok.Add($r)
    }
    $sorted = @($ok.ToArray() | Sort-Object -Property @{ e = { if ($_.Date) { $_.Date } else { [datetime]::MinValue } }; Descending = $true }, @{ e = { $_.Ver }; Descending = $true }, @{ e = { $_.Fit }; Descending = $true })
    $seen = @{}; $res = New-Object System.Collections.Generic.List[object]
    foreach ($r in $sorted) { if (-not $seen.ContainsKey($r.Version)) { $seen[$r.Version] = 1; $res.Add($r) } }
    return $res.ToArray()
}

# Прямые ссылки на файлы обновления (DownloadDialog.aspx, формат как в модуле MSCatalog)
function DrvA-CatFiles($Id) {
    $form = @{ updateIDs = ('[{"size":0,"languages":"","uidInfo":"' + $Id + '","updateID":"' + $Id + '"}]') }
    $t = DrvA-Http ($DRVA.Cat + 'DownloadDialog.aspx') $form 30
    $urls = New-Object System.Collections.Generic.List[string]
    if ($t) { foreach ($m in [regex]::Matches($t, "downloadInformation\[\d+\]\.files\[\d+\]\.url\s*=\s*'([^']+)'")) { $urls.Add($m.Groups[1].Value) } }
    return $urls.ToArray()
}

# ИД оборудования для поиска: самые точные первыми, в конце — короткий VEN&DEV / VID&PID
function DrvA-Queries($HwIds) {
    $q = New-Object System.Collections.Generic.List[string]
    foreach ($h in (AsArr $HwIds)) {
        $h = "$h".Trim()
        if (-not $h -or $h -match '^(?i)(ROOT|SWD|SW|STORAGE\\Volume|\{)') { continue }
        if (-not $q.Contains($h)) { $q.Add($h) }
    }
    foreach ($h in (AsArr $HwIds)) {
        $mm = [regex]::Match("$h", '(?i)^(\w+)\\(VEN_[0-9A-F]{4}&DEV_[0-9A-F]{4}|VID_[0-9A-F]{4}&PID_[0-9A-F]{4})')
        if ($mm.Success) { $sh = $mm.Groups[1].Value + '\' + $mm.Groups[2].Value; if (-not $q.Contains($sh)) { $q.Add($sh) } }
    }
    $o = New-Object System.Collections.Generic.List[string]
    foreach ($x in $q) { if ($o.Count -lt 5) { $o.Add($x) } }
    return $o.ToArray()
}

function DrvA-DevVer($InstId) {
    try { return "$((Get-PnpDeviceProperty -InstanceId $InstId -KeyName 'DEVPKEY_Device_DriverVersion' -ErrorAction Stop).Data)".Trim() } catch { return '' }
}
function DrvA-DevCode($InstId) {
    try { return [int](Get-PnpDevice -InstanceId $InstId -ErrorAction Stop).ConfigManagerErrorCode } catch { return -1 }
}

# Точка восстановления — один раз за прогон (WU-блок шага ставит $G.DrvRP сам)
function DrvA-RestorePoint($Sec) {
    if ($G.DrvRP) { return }
    $G.DrvRP = $true
    try {
        Checkpoint-Computer -Description 'Перед обновлением драйверов (BigTechoTest)' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        Add-Row $Sec 'Точка восстановления' 'создана' 'ok'; DrvA-Log 'точка восстановления создана'
    } catch { Add-Row $Sec 'Точка восстановления' 'не создана (защита системы выключена или точка уже создавалась сегодня)' 'warn'; DrvA-Log ('точка восстановления: ' + $_.Exception.Message) }
}

# Установка .cab из каталога: expand -> pnputil. @{ Ok; Text; Reboot }
function DrvA-InstallCab($Cab, $Dir, $TimeoutSec) {
    New-Item -ItemType Directory -Force $Dir | Out-Null
    $exp = Join-Path $env:SystemRoot 'System32\expand.exe'
    $r1 = Run-Exe $exp ('-F:* "{0}" "{1}"' -f $Cab, $Dir) 180
    DrvA-Log ("expand код {0}: {1}" -f $r1.Code, (Clean $r1.Out))
    if (-not @(Get-ChildItem $Dir -Recurse -Filter *.inf -ErrorAction SilentlyContinue).Count) {
        foreach ($ic2 in @(Get-ChildItem $Dir -Recurse -Filter *.cab -ErrorAction SilentlyContinue)) {
            $sub = Join-Path $Dir ([IO.Path]::GetFileNameWithoutExtension($ic2.Name))
            New-Item -ItemType Directory -Force $sub | Out-Null
            $null = Run-Exe $exp ('-F:* "{0}" "{1}"' -f $ic2.FullName, $sub) 180
        }
    }
    $infs = @(Get-ChildItem $Dir -Recurse -Filter *.inf -ErrorAction SilentlyContinue)
    if (-not $infs.Count) { return @{ Ok = $false; Text = 'в архиве нет .inf'; Reboot = $false } }
    $pn = Join-Path $env:SystemRoot 'System32\pnputil.exe'
    $r2 = Run-Exe $pn ('/add-driver "{0}\*.inf" /subdirs /install' -f $Dir) $TimeoutSec
    DrvA-Log ("pnputil код {0}{1}: {2}" -f $r2.Code, $(if ($r2.TimedOut) { ' (тайм-аут)' } else { '' }), (Clean $r2.Out))
    $rb = ($r2.Code -eq 3010 -or $r2.Out -match '(?i)reboot|перезагруз')
    if ($r2.TimedOut) { return @{ Ok = $false; Text = "pnputil не уложился в $TimeoutSec с"; Reboot = $rb } }
    $ok = ($r2.Code -in 0, 3010)
    $txt = 'pnputil: код ' + $r2.Code; if ($r2.Code -eq 259) { $txt = 'драйвер добавлен, но к устройству не подошёл' }
    return @{ Ok = $ok; Text = $txt; Reboot = $rb }
}

# ---- 1. Устройства без драйвера / с ошибкой
function DrvA-Devices($Sec, $Install, $Rows, $Fails) {
    $os = DrvA-Os
    $onBat = [bool](CIM Win32_Battery | Where-Object { $_.BatteryStatus -eq 1 })
    $allowFw = [bool]($G.UpdFirmware -and -not $onBat)
    $devs = @()
    try { $devs = @(Get-PnpDevice -PresentOnly -ErrorAction Stop | Where-Object { ($_.Status -ne 'OK' -or [int]$_.ConfigManagerErrorCode -eq 28) -and [int]$_.ConfigManagerErrorCode -notin 0, 22, 24, 45 }) }
    catch { DrvA-Log ('Get-PnpDevice: ' + $_.Exception.Message) }
    DrvA-Log ('проблемных устройств: ' + $devs.Count)
    if (-not $devs.Count) { return }
    Info ('Каталог Microsoft Update: ищу драйверы для устройств с проблемами ({0})...' -f $devs.Count)
    $deadline = (Get-Date).AddMinutes(20)
    $n = 0
    foreach ($d in $devs) {
        $n++
        $nm = Clean $d.FriendlyName; if (-not $nm) { $nm = Clean $d.Name }; if (-not $nm) { $nm = $d.InstanceId }
        $code = [int]$d.ConfigManagerErrorCode
        $was = DrvA-DevVer $d.InstanceId
        $wasTxt = 'нет драйвера'; if ($code -ne 28 -and $was) { $wasTxt = $was + ' (ошибка ' + $code + ')' } elseif ($code -ne 28) { $wasTxt = 'ошибка ' + $code }
        $hw = (AsArr $d.HardwareID)
        $row = [pscustomobject]@{ 'Устройство' = $nm; 'Было' = $wasTxt; 'Поставлено' = '—'; 'Источник' = 'Каталог Microsoft Update'; 'Результат' = '' }
        $failLink = { param($why) $row.'Результат' = $why; $Fails.Add([pscustomobject]@{ 'Устройство' = $nm; 'ИД оборудования' = "$($hw | Select-Object -First 1)"; 'Где искать' = ($DRVA.Cat + 'Search.aspx?q=' + [uri]::EscapeDataString("$(@(DrvA-Queries $hw) | Select-Object -Last 1)")) }) }
        if ($n -gt 15 -or (Get-Date) -gt $deadline) { & $failLink 'не обработано (лимит времени/количества)'; $Rows.Add($row); continue }
        if (-not $allowFw -and ("$($d.Class)" -eq 'Firmware' -or $nm -match '(?i)firmware|прошив')) { & $failLink 'прошивка — без согласия не ставится'; $Rows.Add($row); continue }
        if ($DRVA.NetFail -ge 3) { & $failLink 'нет связи с каталогом Microsoft'; $Rows.Add($row); continue }
        $cands = @(); $usedQ = ''
        foreach ($q in @(DrvA-Queries $hw)) {
            $found = @(DrvA-CatSearch $q)
            DrvA-Log ("[{0}] поиск '{1}': строк {2}" -f $nm, $q, $found.Count)
            if ($found.Count) { $cands = @(DrvA-CatPick $found $os $allowFw); $usedQ = $q; if ($cands.Count) { break } }
        }
        if (-not $cands.Count) { & $failLink 'в каталоге Microsoft подходящего драйвера нет'; $Rows.Add($row); continue }
        # устройство с драйвером: ставим, только если в каталоге версия новее
        $wv = Fresh-ParseVer $was
        if ($code -ne 28 -and $wv) { $cands = @($cands | Where-Object { $_.Ver -and $_.Ver -gt $wv }) }
        if (-not $cands.Count) { & $failLink ('в каталоге нет версии новее ' + $was); $Rows.Add($row); continue }
        $top = $cands[0]
        DrvA-Log ("[{0}] кандидат {1} | {2} | {3} | {4:d} | {5} (запрос '{6}')" -f $nm, $top.Id, $top.Title, $top.Products, $top.Date, $top.Version, $usedQ)
        if (-not $Install) { $row.'Поставлено' = $top.Version; $row.'Результат' = 'найден, не ставили (режим «только поиск»)'; $Rows.Add($row); continue }
        $row.'Результат' = 'ОШИБКА'
        $tries = 0
        foreach ($c in $cands) {
            $tries++
            if ($tries -gt 2 -or (Get-Date) -gt $deadline) { break }
            Info ('[{0}/{1}] {2}: {3} ({4:N1} МБ)' -f $n, $devs.Count, $nm, $c.Title, ($c.Size / 1MB))
            $urls = @(DrvA-CatFiles $c.Id | Where-Object { $_ -match '(?i)^https?://([a-z0-9.-]+\.)?(windowsupdate\.com|microsoft\.com)/' })
            $cabU = @($urls | Where-Object { $_ -match '(?i)\.cab$' } | Select-Object -First 1)
            if (-not $cabU.Count) { $row.'Результат' = 'каталог не дал ссылку на файл'; DrvA-Log ("[{0}] нет .cab: {1}" -f $nm, ($urls -join ' ')); continue }
            $wdir = Join-Path $G.Temp ('drva\' + $c.Id)
            New-Item -ItemType Directory -Force $wdir | Out-Null
            $cab = Join-Path $wdir 'drv.cab'
            if (-not (DrvA-Download $cabU[0] $cab 300 'скачивание' $c.Size)) { $row.'Результат' = 'не скачался'; continue }
            DrvA-RestorePoint $Sec
            $ir = DrvA-InstallCab $cab (Join-Path $wdir 'x') 300
            if ($ir.Reboot) { $G.RebootNeeded = $true }
            Start-Sleep -Seconds 3
            $nc = DrvA-DevCode $d.InstanceId
            $nv = DrvA-DevVer $d.InstanceId
            DrvA-Log ("[{0}] после установки: код {1}, версия '{2}', {3}" -f $nm, $nc, $nv, $ir.Text)
            if ($nc -eq 0) { $row.'Поставлено' = $(if ($nv) { $nv } else { $c.Version }); $row.'Результат' = 'установлен, устройство работает'; break }
            if ($ir.Ok -and $nv -and $nv -ne $was) { $row.'Поставлено' = $nv; $row.'Результат' = $(if ($G.RebootNeeded) { 'установлен, нужна перезагрузка' } else { 'установлен, устройство всё ещё с ошибкой ' + $nc }); if ($G.RebootNeeded) { break } else { continue } }
            $row.'Результат' = $ir.Text
        }
        if ($row.'Результат' -notmatch '^установлен') { & $failLink ('не установлен: ' + $row.'Результат') }
        $Rows.Add($row)
    }
}

# ---- 2. Видеокарта NVIDIA: свежий Game Ready
function DrvA-NvVer($Vc) {
    foreach ($pth in "$env:SystemRoot\System32\nvidia-smi.exe", "$env:ProgramFiles\NVIDIA Corporation\NVSMI\nvidia-smi.exe") {
        if (Test-Path $pth) { try { $q = "$(& $pth --query-gpu=driver_version --format=csv,noheader 2>$null | Select-Object -First 1)".Trim(); if ($q -match '^\d+\.\d+$') { return $q } } catch {} }
    }
    if ("$($Vc.DriverVersion)" -match '^\d+\.\d+\.(\d+)\.(\d+)$') { $dg = ($Matches[1] + $Matches[2]); if ($dg.Length -ge 5) { return ($dg.Substring($dg.Length - 5, 3) + '.' + $dg.Substring($dg.Length - 2)) } }
    return "$($Vc.DriverVersion)"
}

function DrvA-Nvidia($Sec, $Install, $Rows, $Fails) {
    $vc = @(CIM Win32_VideoController | Where-Object { $_.Name -match '(?i)NVIDIA' }) | Select-Object -First 1
    if (-not $vc) { return }
    $os = DrvA-Os
    $nm = Clean $vc.Name
    $iv = DrvA-NvVer $vc
    $row = [pscustomobject]@{ 'Устройство' = $nm; 'Было' = $iv; 'Поставлено' = '—'; 'Источник' = 'nvidia.com (Game Ready DCH)'; 'Результат' = '' }
    $fail = { param($why) $row.'Результат' = $why; $Fails.Add([pscustomobject]@{ 'Устройство' = $nm; 'ИД оборудования' = ''; 'Где искать' = 'https://www.nvidia.com/Download/index.aspx' }) }
    $lat = $null
    if ($os.Arm) { & $fail 'ARM-Windows — только Windows Update'; $Rows.Add($row); return }
    try { $lat = Fresh-Nvidia $nm $os.W11 } catch { DrvA-Log ('Fresh-Nvidia: ' + $_.Exception.Message) }
    if (-not $lat -or -not $lat.DownloadUrl) { & $fail 'не удалось узнать последнюю версию (видеокарта не опознана или нет сети)'; $Rows.Add($row); return }
    DrvA-Log ("NVIDIA {0}: установлен {1}, последний {2}, {3}" -f $nm, $iv, $lat.Version, $lat.DownloadUrl)
    $a = Fresh-ParseVer $iv; $b = Fresh-ParseVer $lat.Version
    if ($a -and $b -and $a -ge $b) { $row.'Результат' = 'уже последняя версия'; $Rows.Add($row); return }
    if (-not $Install) { $row.'Поставлено' = $lat.Version; $row.'Результат' = 'есть новее, не ставили (режим «только поиск»)'; $Rows.Add($row); return }
    if ($lat.DownloadUrl -notmatch '(?i)^https://([a-z0-9-]+\.)*download\.nvidia\.com/') { & $fail ('подозрительная ссылка: ' + $lat.DownloadUrl); $Rows.Add($row); return }
    $wdir = Join-Path $G.Temp 'drva\nvidia'
    New-Item -ItemType Directory -Force $wdir | Out-Null
    try { $free = (Get-PSDrive ((Split-Path $wdir -Qualifier).TrimEnd(':')) -ErrorAction Stop).Free } catch { $free = 10GB }
    if ($free -lt 4GB) { & $fail ('мало места на диске для установщика ({0:N1} ГБ свободно, нужно 4)' -f ($free / 1GB)); $Rows.Add($row); return }
    $deadline = (Get-Date).AddMinutes(25)
    $exe = Join-Path $wdir ('nvidia_' + $lat.Version + '.exe')
    $total = 0
    try { $h = Invoke-WebRequest -Uri $lat.DownloadUrl -Method Head -UseBasicParsing -UserAgent $DRVA.UA -TimeoutSec 20 -ErrorAction Stop; $total = [int64]$h.Headers['Content-Length'] } catch { DrvA-Log ('NVIDIA HEAD: ' + $_.Exception.Message) }
    Info ('NVIDIA: скачиваю драйвер {0} ({1:N0} МБ)...' -f $lat.Version, ($total / 1MB))
    if (-not (DrvA-Download $lat.DownloadUrl $exe ([int]($deadline - (Get-Date)).TotalSeconds - 300) 'NVIDIA' $total)) { & $fail 'не скачался (сеть или лимит 25 мин)'; $Rows.Add($row); return }
    if ($total -gt 0 -and (Get-Item $exe).Length -ne $total) { & $fail 'файл скачался не полностью'; $Rows.Add($row); return }
    $sig = Get-AuthenticodeSignature $exe
    $subj = ''; if ($sig.SignerCertificate) { $subj = $sig.SignerCertificate.Subject }
    DrvA-Log ("NVIDIA подпись: {0} | {1}" -f $sig.Status, $subj)
    if ("$($sig.Status)" -ne 'Valid' -or $subj -notmatch 'O="?NVIDIA Corporation') { & $fail ('подпись файла не NVIDIA Corporation (' + $sig.Status + ') — не запускали'); Remove-Item $exe -Force -ErrorAction SilentlyContinue; $Rows.Add($row); return }
    $z = Get-Tool 'SevenZ'
    if (-not $z) { & $fail 'нет 7zr для распаковки'; $Rows.Add($row); return }
    $xd = Join-Path $wdir 'x'
    Info 'NVIDIA: распаковка...'
    $rx = Run-Exe $z ('x -y -o"{0}" "{1}"' -f $xd, $exe) 600
    DrvA-Log ("7zr код {0}" -f $rx.Code)
    $setup = Join-Path $xd 'setup.exe'
    if (-not (Test-Path $setup)) { & $fail 'не удалось распаковать установщик'; $Rows.Add($row); return }
    # лишнее (NVIDIA App, телеметрия, FrameView) не ставим — как в пакете Chocolatey nvidia-display-driver
    foreach ($junk in 'NvApp', 'GFExperience', 'GFExperience.NvStreamSrv', 'NvTelemetry', 'FrameViewSDK', 'ShadowPlay') { Remove-Item (Join-Path $xd $junk) -Recurse -Force -ErrorAction SilentlyContinue }
    DrvA-RestorePoint $Sec
    $argl = '-s Display.Driver HDAudio.Driver -noreboot -noeula -clean'
    DrvA-Log ("NVIDIA: setup.exe {0}" -f $argl)
    Info 'NVIDIA: тихая установка драйвера (экран может мигнуть)...'
    $t0 = Get-Date
    $p = Start-Process $setup -ArgumentList $argl -WorkingDirectory $xd -PassThru -WindowStyle Hidden
    $null = $p.Handle
    while (-not $p.HasExited -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 5
        Write-Host -NoNewline ("`r    установка NVIDIA: {0:N0} с   " -f ((Get-Date) - $t0).TotalSeconds)
    }
    Write-Host ''
    if (-not $p.HasExited) {
        # прерывать установщик драйвера опасно — оставляем его работать
        DrvA-Log 'NVIDIA setup: не завершился за лимит 25 мин, оставлен работать'
        $G.RebootNeeded = $true
        & $fail 'установщик не завершился за 25 мин (продолжает работу в фоне — дождитесь и перезагрузите)'; $Rows.Add($row); return
    }
    $ec = $p.ExitCode
    $nv = DrvA-NvVer (@(CIM Win32_VideoController | Where-Object { $_.Name -match '(?i)NVIDIA' }) | Select-Object -First 1)
    DrvA-Log ("NVIDIA setup код {0}, версия теперь {1}" -f $ec, $nv)
    $G.RebootNeeded = $true
    $c2 = Fresh-ParseVer $nv
    if ($c2 -and $b -and $c2 -ge $b) { $row.'Поставлено' = $nv; $row.'Результат' = 'установлен (код ' + $ec + '), нужна перезагрузка' }
    elseif ($ec -in 0, 1) { $row.'Поставлено' = $lat.Version; $row.'Результат' = 'установлен (код ' + $ec + '), версия применится после перезагрузки' }
    else { & $fail ('установщик NVIDIA вернул код ' + $ec) }
    $Rows.Add($row)
}

# ---- точка входа из шага драйверов
function DrvA-Run($Sec, [bool]$Install) {
    $rows = New-Object System.Collections.Generic.List[object]
    $fails = New-Object System.Collections.Generic.List[object]
    try { DrvA-Devices $Sec $Install $rows $fails } catch { DrvA-Log ('devices: ' + $_.Exception.Message); Warn ('автоустановка драйверов устройств: ' + $_.Exception.Message) }
    try { DrvA-Nvidia $Sec $Install $rows $fails } catch { DrvA-Log ('nvidia: ' + $_.Exception.Message); Warn ('обновление драйвера NVIDIA: ' + $_.Exception.Message) }
    $gpuNames = (@(CIM Win32_VideoController) | ForEach-Object { $_.Name }) -join '; '
    if ($gpuNames -match '(?i)AMD|Radeon') { $rows.Add([pscustomobject]@{ 'Устройство' = 'Видеокарта AMD'; 'Было' = '—'; 'Поставлено' = '—'; 'Источник' = 'Windows Update'; 'Результат' = 'автоустановка Adrenalin ненадёжна — только Windows Update (выше)' }) }
    if ($gpuNames -match '(?i)Intel') { $rows.Add([pscustomobject]@{ 'Устройство' = 'Графика Intel'; 'Было' = '—'; 'Поставлено' = '—'; 'Источник' = 'Windows Update'; 'Результат' = 'автоустановка пакета Intel ненадёжна — только Windows Update (выше)' }) }
    $ra = $rows.ToArray()
    if ($ra.Count) { Add-Table $Sec 'Автоустановка драйверов: результат' $ra }
    $fa = $fails.ToArray()
    if ($fa.Count) {
        Add-Table $Sec 'Не удалось установить автоматически — где искать вручную' $fa
        Add-Issue 'info' 'Устройства' ('не удалось автоматически установить драйверов: {0}' -f $fa.Count) 'См. таблицу «Не удалось установить автоматически» в разделе драйверов — там ссылки на поиск.'
    }
    $okN = @($ra | Where-Object { $_.'Результат' -match '^установлен' }).Count
    if ($okN) { Ok ('автоматически установлено драйверов: {0}' -f $okN) }
}
