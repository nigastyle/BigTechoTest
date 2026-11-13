# =====================================================================
#  BigTechoTest — автоустановка драйверов (отдельный процесс)
# =====================================================================
# Запускается основной программой (шаг «Драйверы: установка и обновление») отдельным процессом:
#   powershell -NoProfile -ExecutionPolicy Bypass -File BTT-Drivers.ps1 -Mode Install -Nvidia -OutJson r.json -LogFile d.log -Root <папка программы>
# Поставляется отдельным файлом выпуска; основная программа сверяет его SHA-256 с подписанным манифестом version.json.
#   1) устройства без драйвера / с ошибкой: ИД оборудования -> каталог Microsoft Update (catalog.update.microsoft.com)
#      -> .cab -> expand -> pnputil /add-driver /install -> перепроверка;
#   2) (-Nvidia) видеокарта NVIDIA: если вышел новый Game Ready — DCH-установщик с nvidia.com, проверка подписи
#      NVIDIA Corporation, распаковка 7zr, тихая установка (только драйвер + HD Audio).
#   AMD/Intel GPU — только Windows Update (автоустановка их пакетов ненадёжна).
# -Mode Search — только поиск: ничего не скачивается и не ставится.
# Никогда не перезагружает (только rebootNeeded в результате). Прошивки — только с -Firmware и не от батареи.
# Результат — JSON (-OutJson): { items: [ {device, was, installed, source, result, link, hwid} ], rebootNeeded, restorePoint, log: [...] }
param(
    [ValidateSet('Search', 'Install')][string]$Mode = 'Search',
    [switch]$Nvidia,
    [string]$OutJson = '',
    [string]$LogFile = '',
    [string]$Root = '',
    [switch]$RestorePoint,
    [switch]$Firmware
)
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
try { $Host.UI.RawUI.WindowTitle = 'BigTechoTest — драйверы' } catch {}
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}

$S = @{ UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36'; NetFail = 0 }
$S.Install = ($Mode -eq 'Install')
$S.Log = New-Object System.Collections.Generic.List[string]
$S.Items = New-Object System.Collections.Generic.List[object]
$S.Reboot = $false
$S.RPWanted = [bool]$RestorePoint; $S.RPDone = $false; $S.RPText = ''
$S.Temp = Join-Path $env:TEMP ('btt_drivers_' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
New-Item -ItemType Directory -Force $S.Temp | Out-Null
if (-not $Root) { $Root = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutJson) { $OutJson = Join-Path $env:TEMP 'btt_drivers_result.json' }
$S.Cat = 'https://www.catalog.update.microsoft.com/'
# Метки «version X and later» в колонке «Продукты» каталога -> минимальная сборка Windows
$S.B10 = @{ '1507' = 10240; '1511' = 10586; '1607' = 14393; '1703' = 15063; '1709' = 16299; '1803' = 17134; '1809' = 17763; '1903' = 18362; '1909' = 18363
    '2004' = 19041; 'VIBRANIUM' = 19041; '20H2' = 19042; '21H1' = 19043; '21H2' = 19044; '22H2' = 19045 }
$S.B11 = @{ '21H2' = 22000; 'COBALT' = 22000; '22H2' = 22621; 'NICKEL' = 22621; '23H2' = 22631; '24H2' = 26100; 'GERMANIUM' = 26100; '25H2' = 26200; '26H1' = 28000 }

# ---------------------------------------------------------------- помощники
function Log($t) {
    $line = '{0:HH:mm:ss} {1}' -f (Get-Date), $t
    $S.Log.Add($line)
    if ($LogFile) { try { [IO.File]::AppendAllText($LogFile, $line + "`r`n", (New-Object Text.UTF8Encoding($false))) } catch {} }
}
# строка прогресса: в консоль и в журнал с пометкой '> ' (основная программа показывает такие строки у себя)
function Say($t) { Write-Host $t; Log ('> ' + $t) }
function Clean($x) { if ($null -eq $x) { return '' }; return (("$x" -replace '\s+', ' ').Trim()) }
function AsArr($x) { $o = New-Object System.Collections.ArrayList; if ($null -ne $x) { foreach ($i in $x) { [void]$o.Add($i) } }; return ,$o.ToArray() }
function Get-Wmi($Class) { try { return @(Get-CimInstance -ClassName $Class -ErrorAction Stop) } catch { return @() } }
function Parse-Ver($v) {
    try {
        $m = [regex]::Match("$v", '\d+(\.\d+){0,3}')
        if (-not $m.Success) { return $null }
        $t = $m.Value; if ($t -notmatch '\.') { $t = $t + '.0' }
        return [version]$t
    } catch { return $null }
}

function Run-Exe($File, $ArgLine, $TimeoutSec = 600, $WorkDir = $null) {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $File; $psi.Arguments = $ArgLine
    $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
    if ($WorkDir) { $psi.WorkingDirectory = $WorkDir }
    try { $psi.StandardOutputEncoding = [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage) } catch {}
    $p = [Diagnostics.Process]::Start($psi)
    $outTask = $p.StandardOutput.ReadToEndAsync(); $errTask = $p.StandardError.ReadToEndAsync()
    $to = $false
    if (-not $p.WaitForExit($TimeoutSec * 1000)) { try { $p.Kill() } catch {}; $to = $true }
    $p.WaitForExit()
    $o = $outTask.Result + "`n" + $errTask.Result
    return [pscustomobject]@{ Out = ($o -replace "`0", ''); Code = $p.ExitCode; TimedOut = $to }
}

# GET/POST-форма с тайм-аутом; Invoke-WebRequest, при сбое — curl.exe. Текст или $null (не бросает).
function Http-Text($Url, $Form = $null, $TimeoutSec = 30) {
    $txt = $null
    try {
        if ($Form) { $r = Invoke-WebRequest -Uri $Url -Method Post -Body $Form -UseBasicParsing -UserAgent $S.UA -TimeoutSec $TimeoutSec -ErrorAction Stop }
        else { $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -UserAgent $S.UA -TimeoutSec $TimeoutSec -ErrorAction Stop }
        if ($r -and $r.Content) { if ($r.Content -is [byte[]]) { $txt = [Text.Encoding]::UTF8.GetString($r.Content) } else { $txt = [string]$r.Content } }
    } catch { Log ("http {0}: {1}" -f $Url, $_.Exception.Message) }
    if (-not $txt) {
        try {
            $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
            if (Test-Path $curl) {
                $tf = Join-Path $S.Temp ('resp_' + [guid]::NewGuid().ToString('N') + '.txt')
                $ca = @('-fsSL', '--max-time', "$TimeoutSec", '-A', $S.UA, '-o', $tf)
                if ($Form) {
                    # значения формы — через файлы (PS 5.1 портит кавычки JSON в аргументах внешних программ)
                    foreach ($k in $Form.Keys) {
                        $ff = Join-Path $S.Temp ('form_' + [guid]::NewGuid().ToString('N') + '.txt')
                        [IO.File]::WriteAllText($ff, [string]$Form[$k], (New-Object Text.UTF8Encoding($false)))
                        $ca += @('--data-urlencode', ($k + '@' + $ff))
                    }
                }
                $ca += $Url
                & $curl @ca 2>$null | Out-Null
                if (Test-Path $tf) { $txt = [IO.File]::ReadAllText($tf, [Text.Encoding]::UTF8); Remove-Item $tf -Force -ErrorAction SilentlyContinue }
            }
        } catch { Log ("curl {0}: {1}" -f $Url, $_.Exception.Message) }
    }
    if ($txt) { $S.NetFail = 0 } else { $S.NetFail = $S.NetFail + 1 }
    return $txt
}

# Скачивание файла с тайм-аутом и прогрессом (curl.exe, иначе Invoke-WebRequest). $true/$false.
function Get-File($Url, $Path, $TimeoutSec = 300, $Label = 'загрузка', $Total = 0) {
    Remove-Item $Path -Force -ErrorAction SilentlyContinue
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    $t0 = Get-Date
    if (Test-Path $curl) {
        try {
            $argl = ('-fsSL --retry 2 --max-time {0} -A "{1}" -o "{2}" "{3}"' -f [int]$TimeoutSec, $S.UA, $Path, $Url)
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
            if ($p.ExitCode -eq 0 -and (Test-Path $Path) -and (Get-Item $Path).Length -gt 0) { Log ("скачано {0} ({1:N0} байт, {2:N0} с)" -f $Url, (Get-Item $Path).Length, ((Get-Date) - $t0).TotalSeconds); return $true }
            Log ("curl download {0}: код {1}" -f $Url, $p.ExitCode)
        } catch { Log ("curl download {0}: {1}" -f $Url, $_.Exception.Message) }
    }
    $left = [int]($TimeoutSec - ((Get-Date) - $t0).TotalSeconds)
    if ($left -lt 30) { return $false }
    try {
        Invoke-WebRequest -Uri $Url -OutFile $Path -UseBasicParsing -UserAgent $S.UA -TimeoutSec $left -ErrorAction Stop
        if ((Test-Path $Path) -and (Get-Item $Path).Length -gt 0) { Log ("скачано (IWR) {0}" -f $Url); return $true }
    } catch { Log ("IWR download {0}: {1}" -f $Url, $_.Exception.Message) }
    return $false
}

# 7zr.exe: из папки программы (tools\7zr.exe), иначе скачать и сверить SHA-256
function Get-7zr {
    $p = Join-Path $Root 'tools\7zr.exe'
    if (Test-Path $p) { return $p }
    $dl = Join-Path $S.Temp '7zr.exe'
    if (-not (Get-File 'https://github.com/ip7z/7zip/releases/download/26.06/7zr.exe' $dl 300 '7zr')) { return $null }
    if ((Get-FileHash $dl -Algorithm SHA256).Hash -ne 'E80DB2DAD715A6C5ADABE292D31ED54E11F4E9B99CA349827B50573B175891BC') { Log '7zr: контрольная сумма не совпала'; return $null }
    try { New-Item -ItemType Directory -Force (Split-Path $p) | Out-Null; Copy-Item $dl $p -Force; return $p } catch { return $dl }
}

function Get-Os {
    $b = 0; try { $b = [int](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop).CurrentBuild } catch {}
    return @{ Build = $b; W11 = ($b -ge 22000); Arm = ("$env:PROCESSOR_ARCHITECTURE" -match 'ARM') }
}

# Точка восстановления — один раз за запуск, только с -RestorePoint
function New-RP {
    if (-not $S.RPWanted -or $S.RPDone) { return }
    $S.RPDone = $true
    try {
        Checkpoint-Computer -Description 'Перед обновлением драйверов (BigTechoTest)' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        $S.RPText = 'создана'; Log 'точка восстановления создана'
    } catch { $S.RPText = 'не создана (защита системы выключена или точка уже создавалась сегодня)'; Log ('точка восстановления: ' + $_.Exception.Message) }
}

function New-Item2($Device, $Was, $Source) { return [pscustomobject]@{ device = "$Device"; was = "$Was"; installed = '—'; source = $Source; result = ''; link = ''; hwid = '' } }

# ---------------------------------------------------------------- каталог Microsoft Update
# Колонка «Продукты»: подходит ли обновление к этой Windows. Минимальная сборка (>=0) или -1 (не подходит).
function Cat-ProdFit($Products, $Os) {
    $best = -1
    foreach ($m in [regex]::Matches("$Products", '(?i)Windows\s*(10|11|-)[^,]*?(?:,\s*(?:version\s+)?(\w+)\s+and\s+later)?(?=,|$)')) {
        $fam = $m.Groups[1].Value; $ver = $m.Groups[2].Value.ToUpper()
        if ($fam -eq '-') { $fam = '11' }
        if ($fam -eq '11' -and -not $Os.W11) { continue }
        $mb = 0
        if ($ver) {
            $tab = $S.B10; if ($fam -eq '11') { $tab = $S.B11 }
            if ($tab.ContainsKey($ver)) { $mb = [int]$tab[$ver] }
        }
        if ($mb -le $Os.Build -and $mb -gt $best) { $best = $mb }
    }
    return $best
}

# Поиск в каталоге: массив @{Id; Title; Products; Class; Date; Version; Size}
function Cat-Search($Q) {
    $res = New-Object System.Collections.Generic.List[object]
    $html = Http-Text ($S.Cat + 'Search.aspx?q=' + [uri]::EscapeDataString($Q)) $null 30
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

# Отбор: подходит к этой Windows, не прошивка (без согласия), новее — первыми; по одному на версию
function Cat-Pick($Rows, $Os, $AllowFw) {
    $ok = New-Object System.Collections.Generic.List[object]
    foreach ($r in $Rows) {
        if (-not $AllowFw -and ($r.Class -match '(?i)firmware' -or $r.Title -match '(?i)firmware|\bbios\b|uefi')) { continue }
        if (-not $Os.Arm -and $r.Title -match '(?i)\bARM64\b') { continue }
        $fit = Cat-ProdFit $r.Products $Os
        if ($fit -lt 0) { continue }
        $r | Add-Member -NotePropertyName Fit -NotePropertyValue $fit -Force
        $r | Add-Member -NotePropertyName Ver -NotePropertyValue (Parse-Ver $r.Version) -Force
        $ok.Add($r)
    }
    $sorted = @($ok.ToArray() | Sort-Object -Property @{ e = { if ($_.Date) { $_.Date } else { [datetime]::MinValue } }; Descending = $true }, @{ e = { $_.Ver }; Descending = $true }, @{ e = { $_.Fit }; Descending = $true })
    $seen = @{}; $res = New-Object System.Collections.Generic.List[object]
    foreach ($r in $sorted) { if (-not $seen.ContainsKey($r.Version)) { $seen[$r.Version] = 1; $res.Add($r) } }
    return $res.ToArray()
}

# Прямые ссылки на файлы обновления (DownloadDialog.aspx, формат как в модуле MSCatalog)
function Cat-Files($Id) {
    $form = @{ updateIDs = ('[{"size":0,"languages":"","uidInfo":"' + $Id + '","updateID":"' + $Id + '"}]') }
    $t = Http-Text ($S.Cat + 'DownloadDialog.aspx') $form 30
    $urls = New-Object System.Collections.Generic.List[string]
    if ($t) { foreach ($m in [regex]::Matches($t, "downloadInformation\[\d+\]\.files\[\d+\]\.url\s*=\s*'([^']+)'")) { $urls.Add($m.Groups[1].Value) } }
    return $urls.ToArray()
}

# ИД оборудования для поиска: самые точные первыми, в конце — короткий VEN&DEV / VID&PID
function Cat-Queries($HwIds) {
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

function Dev-Ver($InstId) {
    try { return "$((Get-PnpDeviceProperty -InstanceId $InstId -KeyName 'DEVPKEY_Device_DriverVersion' -ErrorAction Stop).Data)".Trim() } catch { return '' }
}
function Dev-Code($InstId) {
    try { return [int](Get-PnpDevice -InstanceId $InstId -ErrorAction Stop).ConfigManagerErrorCode } catch { return -1 }
}

# Установка .cab из каталога: expand -> pnputil. @{ Ok; Text; Reboot }
function Install-Cab($Cab, $Dir, $TimeoutSec) {
    New-Item -ItemType Directory -Force $Dir | Out-Null
    $exp = Join-Path $env:SystemRoot 'System32\expand.exe'
    $r1 = Run-Exe $exp ('-F:* "{0}" "{1}"' -f $Cab, $Dir) 180
    Log ("expand код {0}: {1}" -f $r1.Code, (Clean $r1.Out))
    if (-not @(Get-ChildItem $Dir -Recurse -Filter *.inf -ErrorAction SilentlyContinue).Count) {
        foreach ($inner in @(Get-ChildItem $Dir -Recurse -Filter *.cab -ErrorAction SilentlyContinue)) {
            $sub = Join-Path $Dir ([IO.Path]::GetFileNameWithoutExtension($inner.Name))
            New-Item -ItemType Directory -Force $sub | Out-Null
            $null = Run-Exe $exp ('-F:* "{0}" "{1}"' -f $inner.FullName, $sub) 180
        }
    }
    $infs = @(Get-ChildItem $Dir -Recurse -Filter *.inf -ErrorAction SilentlyContinue)
    if (-not $infs.Count) { return @{ Ok = $false; Text = 'в архиве нет .inf'; Reboot = $false } }
    $pn = Join-Path $env:SystemRoot 'System32\pnputil.exe'
    $r2 = Run-Exe $pn ('/add-driver "{0}\*.inf" /subdirs /install' -f $Dir) $TimeoutSec
    Log ("pnputil код {0}{1}: {2}" -f $r2.Code, $(if ($r2.TimedOut) { ' (тайм-аут)' } else { '' }), (Clean $r2.Out))
    $rb = ($r2.Code -eq 3010 -or $r2.Out -match '(?i)reboot|перезагруз')
    if ($r2.TimedOut) { return @{ Ok = $false; Text = "pnputil не уложился в $TimeoutSec с"; Reboot = $rb } }
    $ok = ($r2.Code -in 0, 3010)
    $txt = 'pnputil: код ' + $r2.Code; if ($r2.Code -eq 259) { $txt = 'драйвер добавлен, но к устройству не подошёл' }
    return @{ Ok = $ok; Text = $txt; Reboot = $rb }
}

# ---------------------------------------------------------------- 1. устройства без драйвера / с ошибкой
function Do-Devices {
    $os = Get-Os
    $onBat = [bool](Get-Wmi Win32_Battery | Where-Object { $_.BatteryStatus -eq 1 })
    $allowFw = [bool]($Firmware -and -not $onBat)
    $devs = @()
    try { $devs = @(Get-PnpDevice -PresentOnly -ErrorAction Stop | Where-Object { ($_.Status -ne 'OK' -or [int]$_.ConfigManagerErrorCode -eq 28) -and [int]$_.ConfigManagerErrorCode -notin 0, 22, 24, 45 }) }
    catch { Log ('Get-PnpDevice: ' + $_.Exception.Message) }
    Log ('проблемных устройств: ' + $devs.Count)
    if (-not $devs.Count) { Say 'Устройств без драйвера или с ошибкой нет.'; return }
    Say ('Каталог Microsoft Update: ищу драйверы для устройств с проблемами ({0})...' -f $devs.Count)
    $deadline = (Get-Date).AddMinutes(20)
    $n = 0
    foreach ($d in $devs) {
        $n++
        $nm = Clean $d.FriendlyName; if (-not $nm) { $nm = Clean $d.Name }; if (-not $nm) { $nm = $d.InstanceId }
        $code = [int]$d.ConfigManagerErrorCode
        $was = Dev-Ver $d.InstanceId
        $wasTxt = 'нет драйвера'; if ($code -ne 28 -and $was) { $wasTxt = $was + ' (ошибка ' + $code + ')' } elseif ($code -ne 28) { $wasTxt = 'ошибка ' + $code }
        $hw = (AsArr $d.HardwareID)
        $it = New-Item2 $nm $wasTxt 'Каталог Microsoft Update'
        $fail = { param($why) $it.result = $why; $it.hwid = "$($hw | Select-Object -First 1)"; $it.link = ($S.Cat + 'Search.aspx?q=' + [uri]::EscapeDataString("$(@(Cat-Queries $hw) | Select-Object -Last 1)")) }
        if ($n -gt 15 -or (Get-Date) -gt $deadline) { & $fail 'не обработано (лимит времени/количества)'; $S.Items.Add($it); continue }
        if (-not $allowFw -and ("$($d.Class)" -eq 'Firmware' -or $nm -match '(?i)firmware|прошив')) { & $fail 'прошивка — без согласия не ставится'; $S.Items.Add($it); continue }
        if ($S.NetFail -ge 3) { & $fail 'нет связи с каталогом Microsoft'; $S.Items.Add($it); continue }
        Say ('[{0}/{1}] {2}: поиск в каталоге...' -f $n, $devs.Count, $nm)
        $cands = @(); $usedQ = ''
        foreach ($q in @(Cat-Queries $hw)) {
            $found = @(Cat-Search $q)
            Log ("[{0}] поиск '{1}': строк {2}" -f $nm, $q, $found.Count)
            if ($found.Count) { $cands = @(Cat-Pick $found $os $allowFw); $usedQ = $q; if ($cands.Count) { break } }
        }
        if (-not $cands.Count) { & $fail 'в каталоге Microsoft подходящего драйвера нет'; $S.Items.Add($it); continue }
        # устройство с драйвером: ставим, только если в каталоге версия новее
        $wv = Parse-Ver $was
        if ($code -ne 28 -and $wv) { $cands = @($cands | Where-Object { $_.Ver -and $_.Ver -gt $wv }) }
        if (-not $cands.Count) { & $fail ('в каталоге нет версии новее ' + $was); $S.Items.Add($it); continue }
        $top = $cands[0]
        Log ("[{0}] кандидат {1} | {2} | {3} | {4:d} | {5} (запрос '{6}')" -f $nm, $top.Id, $top.Title, $top.Products, $top.Date, $top.Version, $usedQ)
        if (-not $S.Install) { $it.installed = $top.Version; $it.result = 'найден, не ставили (режим «только поиск»)'; $S.Items.Add($it); continue }
        $it.result = 'ОШИБКА'
        $tries = 0
        foreach ($c in $cands) {
            $tries++
            if ($tries -gt 2 -or (Get-Date) -gt $deadline) { break }
            Say ('[{0}/{1}] {2}: {3} ({4:N1} МБ)' -f $n, $devs.Count, $nm, $c.Title, ($c.Size / 1MB))
            $urls = @(Cat-Files $c.Id | Where-Object { $_ -match '(?i)^https?://([a-z0-9.-]+\.)?(windowsupdate\.com|microsoft\.com)/' })
            $cabU = @($urls | Where-Object { $_ -match '(?i)\.cab$' } | Select-Object -First 1)
            if (-not $cabU.Count) { $it.result = 'каталог не дал ссылку на файл'; Log ("[{0}] нет .cab: {1}" -f $nm, ($urls -join ' ')); continue }
            $wdir = Join-Path $S.Temp ('cat\' + $c.Id)
            New-Item -ItemType Directory -Force $wdir | Out-Null
            $cab = Join-Path $wdir 'drv.cab'
            if (-not (Get-File $cabU[0] $cab 300 'скачивание' $c.Size)) { $it.result = 'не скачался'; continue }
            New-RP
            $ir = Install-Cab $cab (Join-Path $wdir 'x') 300
            if ($ir.Reboot) { $S.Reboot = $true }
            Start-Sleep -Seconds 3
            $nc = Dev-Code $d.InstanceId
            $nv = Dev-Ver $d.InstanceId
            Log ("[{0}] после установки: код {1}, версия '{2}', {3}" -f $nm, $nc, $nv, $ir.Text)
            if ($nc -eq 0) { $it.installed = $(if ($nv) { $nv } else { $c.Version }); $it.result = 'установлен, устройство работает'; break }
            if ($ir.Ok -and $nv -and $nv -ne $was) { $it.installed = $nv; $it.result = $(if ($S.Reboot) { 'установлен, нужна перезагрузка' } else { 'установлен, устройство всё ещё с ошибкой ' + $nc }); if ($S.Reboot) { break } else { continue } }
            $it.result = $ir.Text
        }
        if ($it.result -notmatch '^установлен') { & $fail ('не установлен: ' + $it.result) }
        Say ('    -> ' + $it.result)
        $S.Items.Add($it)
    }
}

# ---------------------------------------------------------------- 2. видеокарта NVIDIA: свежий Game Ready
# Имя видеокарты -> psid/pfid (публичный lookup на nvidia.com) -> последняя версия Game Ready DCH. @{Version; DownloadUrl} или $null
function Nv-Latest($GpuName, $IsWin11) {
    $nm = ("$GpuName" -replace '(?i)NVIDIA\s+', '').Trim()
    if ($nm -notmatch '(?i)GeForce|RTX|GTX|\bGT\b') { return $null }
    if ($nm -match '(?i)Quadro|RTX\s*A\d|Tesla|\bL\d{2}\b') { return $null }
    $norm = { param($x) (("$x" -replace '(?i)NVIDIA|GeForce', '' -replace '\s+', ' ').Trim().ToLower()) }
    $want = & $norm $nm
    $gen = $null
    if ($nm -match '(?i)(?:RTX|GTX|GT)\s*(\d{3,4})') {
        $dg = $Matches[1]
        if ($dg.Length -eq 4) { $gen = $dg.Substring(0, 2) } else { $gen = $dg.Substring(0, 1) + '00' }
    }
    if (-not $gen) { return $null }
    $mobile = ($nm -match '(?i)Laptop|Mobile|Max-Q|Notebook')
    $base = 'https://www.nvidia.com/Download/API/lookupValueSearch.aspx'
    $x = Http-Text "${base}?TypeID=2&ParentID=1" $null 15
    if (-not $x) { return $null }
    $series = @()
    foreach ($m in [regex]::Matches($x, '<Name>([^<]+)</Name>\s*<Value>(\d+)</Value>')) {
        $sn = $m.Groups[1].Value
        if ($sn -notmatch ('(?<!\d)' + $gen + '\s+Series')) { continue }
        $isNb = ($sn -match 'Notebook')
        if ($isNb -eq $mobile) { $series += ,@($sn, $m.Groups[2].Value) }
    }
    $psid = $null; $pfid = $null
    foreach ($sr in $series) {
        $p = Http-Text "${base}?TypeID=3&ParentID=$($sr[1])" $null 15
        if (-not $p) { continue }
        foreach ($m in [regex]::Matches($p, '<Name>([^<]+)</Name>\s*<Value>(\d+)</Value>')) {
            if ((& $norm $m.Groups[1].Value) -eq $want) { $psid = $sr[1]; $pfid = $m.Groups[2].Value; break }
        }
        if ($pfid) { break }
    }
    if (-not $pfid) { return $null }
    $osId = 57; if ($IsWin11) { $osId = 135 }
    $u = "https://gfwsl.geforce.com/services_toolkit/services/com/nvidia/services/AjaxDriverService.php?func=DriverManualLookup&psid=$psid&pfid=$pfid&osID=$osId&languageCode=1033&isWHQL=1&dch=1&sort1=0&numberOfResults=1"
    $j = Http-Text $u $null 15
    if (-not $j) { return $null }
    $vm = [regex]::Match($j, '"Version"\s*:\s*"([\d\.]+)"')
    if (-not $vm.Success) { return $null }
    $res = @{ Version = $vm.Groups[1].Value; DownloadUrl = $null }
    $dm2 = [regex]::Match($j, '"DownloadURL"\s*:\s*"([^"]+)"')
    if ($dm2.Success) { $res.DownloadUrl = ($dm2.Groups[1].Value -replace '\\/', '/') }
    return $res
}

function Nv-Ver($Vc) {
    foreach ($pth in "$env:SystemRoot\System32\nvidia-smi.exe", "$env:ProgramFiles\NVIDIA Corporation\NVSMI\nvidia-smi.exe") {
        if (Test-Path $pth) { try { $q = "$(& $pth --query-gpu=driver_version --format=csv,noheader 2>$null | Select-Object -First 1)".Trim(); if ($q -match '^\d+\.\d+$') { return $q } } catch {} }
    }
    if ("$($Vc.DriverVersion)" -match '^\d+\.\d+\.(\d+)\.(\d+)$') { $dg = ($Matches[1] + $Matches[2]); if ($dg.Length -ge 5) { return ($dg.Substring($dg.Length - 5, 3) + '.' + $dg.Substring($dg.Length - 2)) } }
    return "$($Vc.DriverVersion)"
}

function Do-Nvidia {
    $vc = @(Get-Wmi Win32_VideoController | Where-Object { $_.Name -match '(?i)NVIDIA' }) | Select-Object -First 1
    if (-not $vc) { return }
    $os = Get-Os
    $nm = Clean $vc.Name
    $iv = Nv-Ver $vc
    $it = New-Item2 $nm $iv 'nvidia.com (Game Ready DCH)'
    $fail = { param($why) $it.result = $why; $it.link = 'https://www.nvidia.com/Download/index.aspx' }
    if ($os.Arm) { & $fail 'ARM-Windows — только Windows Update'; $S.Items.Add($it); return }
    Say ('NVIDIA: проверяю последнюю версию драйвера для {0} (установлен {1})...' -f $nm, $iv)
    $lat = $null
    try { $lat = Nv-Latest $nm $os.W11 } catch { Log ('Nv-Latest: ' + $_.Exception.Message) }
    if (-not $lat -or -not $lat.DownloadUrl) { & $fail 'не удалось узнать последнюю версию (видеокарта не опознана или нет сети)'; $S.Items.Add($it); return }
    Log ("NVIDIA {0}: установлен {1}, последний {2}, {3}" -f $nm, $iv, $lat.Version, $lat.DownloadUrl)
    $a = Parse-Ver $iv; $b = Parse-Ver $lat.Version
    if ($a -and $b -and $a -ge $b) { $it.result = 'уже последняя версия'; Say ('NVIDIA: уже последняя версия ' + $iv); $S.Items.Add($it); return }
    if (-not $S.Install) { $it.installed = $lat.Version; $it.result = 'есть новее, не ставили (режим «только поиск»)'; $S.Items.Add($it); return }
    if ($lat.DownloadUrl -notmatch '(?i)^https://([a-z0-9-]+\.)*download\.nvidia\.com/') { & $fail ('подозрительная ссылка: ' + $lat.DownloadUrl); $S.Items.Add($it); return }
    $wdir = Join-Path $S.Temp 'nvidia'
    New-Item -ItemType Directory -Force $wdir | Out-Null
    try { $free = (Get-PSDrive ((Split-Path $wdir -Qualifier).TrimEnd(':')) -ErrorAction Stop).Free } catch { $free = 10GB }
    if ($free -lt 4GB) { & $fail ('мало места на диске для установщика ({0:N1} ГБ свободно, нужно 4)' -f ($free / 1GB)); $S.Items.Add($it); return }
    $deadline = (Get-Date).AddMinutes(25)
    $exe = Join-Path $wdir ('nvidia_' + $lat.Version + '.exe')
    $total = 0
    try { $h = Invoke-WebRequest -Uri $lat.DownloadUrl -Method Head -UseBasicParsing -UserAgent $S.UA -TimeoutSec 20 -ErrorAction Stop; $total = [int64]$h.Headers['Content-Length'] } catch { Log ('NVIDIA HEAD: ' + $_.Exception.Message) }
    Say ('NVIDIA: скачиваю драйвер {0} ({1:N0} МБ)...' -f $lat.Version, ($total / 1MB))
    if (-not (Get-File $lat.DownloadUrl $exe ([int]($deadline - (Get-Date)).TotalSeconds - 300) 'NVIDIA' $total)) { & $fail 'не скачался (сеть или лимит 25 мин)'; $S.Items.Add($it); return }
    if ($total -gt 0 -and (Get-Item $exe).Length -ne $total) { & $fail 'файл скачался не полностью'; $S.Items.Add($it); return }
    $sig = Get-AuthenticodeSignature $exe
    $subj = ''; if ($sig.SignerCertificate) { $subj = $sig.SignerCertificate.Subject }
    Log ("NVIDIA подпись: {0} | {1}" -f $sig.Status, $subj)
    if ("$($sig.Status)" -ne 'Valid' -or $subj -notmatch 'O="?NVIDIA Corporation') { & $fail ('подпись файла не NVIDIA Corporation (' + $sig.Status + ') — не запускали'); Remove-Item $exe -Force -ErrorAction SilentlyContinue; $S.Items.Add($it); return }
    $z = Get-7zr
    if (-not $z) { & $fail 'нет 7zr для распаковки'; $S.Items.Add($it); return }
    $xd = Join-Path $wdir 'x'
    Say 'NVIDIA: распаковка...'
    $rx = Run-Exe $z ('x -y -o"{0}" "{1}"' -f $xd, $exe) 600
    Log ("7zr код {0}" -f $rx.Code)
    $setup = Join-Path $xd 'setup.exe'
    if (-not (Test-Path $setup)) { & $fail 'не удалось распаковать установщик'; $S.Items.Add($it); return }
    # лишнее (NVIDIA App, телеметрия, FrameView) не ставим — как в пакете Chocolatey nvidia-display-driver
    # Оставляем только драйвер и его обязательные части (белый список) и убираем из setup.cfg ссылки на файлы соглашений —
    # иначе setup.exe падает с 0x80070003 «путь не найден». Имена компонентов в командной строке установщик не принимает.
    $keep = 'Display.Driver', 'Display.Nview', 'Display.Optimus', 'HDAudio', 'MSVCRT', 'NVI2', 'NVPCF', 'PhysX', 'PPC', 'EULA.txt', 'ListDevices.txt', 'setup.cfg', 'setup.exe', 'license.txt'
    foreach ($e in @(Get-ChildItem -LiteralPath $xd -Force -ErrorAction SilentlyContinue)) { if ($keep -notcontains $e.Name) { Remove-Item -LiteralPath $e.FullName -Recurse -Force -ErrorAction SilentlyContinue } }
    try {
        $cfg = Join-Path $xd 'setup.cfg'
        $cl = @(Get-Content -LiteralPath $cfg -Encoding UTF8 | Where-Object { $_ -notmatch 'name="\$\{\{(EulaHtmlFile|FunctionalConsentFile|PrivacyPolicyFile)\}\}' })
        [IO.File]::WriteAllLines($cfg, $cl, (New-Object Text.UTF8Encoding $true))
    } catch { Log ('NVIDIA setup.cfg: ' + $_.Exception.Message) }
    Log ('NVIDIA пакет: ' + ((Get-ChildItem -LiteralPath $xd -Force | ForEach-Object { $_.Name }) -join ', '))
    New-RP
    $argl = '-s -noreboot -noeula'
    Log ("NVIDIA: setup.exe {0}" -f $argl)
    Say 'NVIDIA: тихая установка драйвера (экран может мигнуть)...'
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
        Log 'NVIDIA setup: не завершился за лимит 25 мин, оставлен работать'
        $S.Reboot = $true
        & $fail 'установщик не завершился за 25 мин (продолжает работу в фоне — дождитесь и перезагрузите)'; $S.Items.Add($it); return
    }
    $ec = $p.ExitCode
    $nv = Nv-Ver (@(Get-Wmi Win32_VideoController | Where-Object { $_.Name -match '(?i)NVIDIA' }) | Select-Object -First 1)
    Log ("NVIDIA setup код {0}, версия теперь {1}" -f $ec, $nv)
    $S.Reboot = $true
    $c2 = Parse-Ver $nv
    if ($c2 -and $b -and $c2 -ge $b) { $it.installed = $nv; $it.result = 'установлен (код ' + $ec + '), нужна перезагрузка' }
    elseif ($ec -in 0, 1) { $it.installed = $lat.Version; $it.result = 'установлен (код ' + $ec + '), версия применится после перезагрузки' }
    else { & $fail ('установщик NVIDIA вернул код ' + $ec) }
    Say ('    -> ' + $it.result)
    $S.Items.Add($it)
}

# ---------------------------------------------------------------- запуск
Say ('BigTechoTest — драйверы: режим {0}' -f $(if ($S.Install) { 'установка' } else { 'только поиск' }))
try {
    try { Do-Devices } catch { Log ('devices: ' + $_.Exception.Message); Say ('[!] автоустановка драйверов устройств: ' + $_.Exception.Message) }
    if ($Nvidia) { try { Do-Nvidia } catch { Log ('nvidia: ' + $_.Exception.Message); Say ('[!] обновление драйвера NVIDIA: ' + $_.Exception.Message) } }
    $gpuNames = (@(Get-Wmi Win32_VideoController) | ForEach-Object { $_.Name }) -join '; '
    if ($gpuNames -match '(?i)AMD|Radeon') { $x = New-Item2 'Видеокарта AMD' '—' 'Windows Update'; $x.result = 'автоустановка Adrenalin ненадёжна — только Windows Update (выше)'; $S.Items.Add($x) }
    if ($gpuNames -match '(?i)Intel') { $x = New-Item2 'Графика Intel' '—' 'Windows Update'; $x.result = 'автоустановка пакета Intel ненадёжна — только Windows Update (выше)'; $S.Items.Add($x) }
} finally {
    $okN = @($S.Items.ToArray() | Where-Object { $_.result -match '^установлен' }).Count
    Say ('Готово: установлено драйверов: {0}{1}' -f $okN, $(if ($S.Reboot) { ', нужна перезагрузка' } else { '' }))
    $logArr = $S.Log.ToArray(); if ($logArr.Count -gt 800) { $logArr = $logArr[($logArr.Count - 800)..($logArr.Count - 1)] }
    $res = [ordered]@{ items = $S.Items.ToArray(); rebootNeeded = [bool]$S.Reboot; restorePoint = $S.RPText; log = $logArr }
    try {
        $tmp = $OutJson + '.tmp'
        [IO.File]::WriteAllText($tmp, (ConvertTo-Json -InputObject $res -Depth 5), (New-Object Text.UTF8Encoding($false)))
        Move-Item $tmp $OutJson -Force
    } catch { Write-Host ('не удалось записать результат: ' + $_.Exception.Message) }
    # скачанные .cab / установщики — удалить (журнал — в -LogFile)
    try { Remove-Item $S.Temp -Recurse -Force -ErrorAction SilentlyContinue } catch {}
}
exit 0
