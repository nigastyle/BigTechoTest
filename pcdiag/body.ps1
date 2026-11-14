# =====================================================================
#  ДИАГНОСТИКА ПК — полная автоматическая проверка компьютера/ноутбука
# =====================================================================
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$VER = '1.6'
# Канал сборки: 'stable' — выпущена на GitHub, обновляется сама; 'test' — предрелизная, не обновляется (см. test.sh / release.sh)
$CHANNEL = 'stable'
$APPNAME = 'BigTechoTest'
try { $Host.UI.RawUI.WindowTitle = "$APPNAME v$VER$(if ($CHANNEL -ne 'stable') { ' ТЕСТ' }) — диагностика ПК" } catch {}
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
$IC = [Globalization.CultureInfo]::InvariantCulture

$G = @{}
$G.Start = Get-Date
$G.Self = $env:DIAG_SELF
$G.Root = if ($env:DIAG_ROOT) { $env:DIAG_ROOT } elseif ($G.Self) { Split-Path -Parent $G.Self } else { (Get-Location).Path }
$G.Tools = Join-Path $G.Root 'tools'
$G.Temp = Join-Path $env:TEMP ('pcdiag_' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
New-Item -ItemType Directory -Path $G.Temp -Force | Out-Null
New-Item -ItemType Directory -Path $G.Tools -Force | Out-Null
$G.Sections = New-Object System.Collections.Generic.List[object]
$G.Issues = New-Object System.Collections.Generic.List[object]
$G.Summary = [ordered]@{}
$G.Bench = [ordered]@{}
$G.Num = @{}
$G.Skipped = New-Object System.Collections.Generic.List[string]
# Куда отправлять отчёты для статистики (DIAG_NOSEND=1 — не отправлять)
# Открытый ключ проверки подписи обновлений (закрытый — только на сервере выпуска, /root/secrets/btt-update-key.pem)
$UPDATE_PUBKEY = '<RSAKeyValue><Modulus>78KaUldkgo8WB4S7cscvmsvsU1zsPjNmfvkt7crFFFuqnRDTyLSiGFdoXHGHvwP9borjeP9incIU8mqb6XZ9EMwGrQh1ElqW3VQgGqddQHylsAYYa6XQ9uL0opf+uuYIXpwIjOG+sWJG8T4dU5eoDh6XFI5UB4s0huHMb9/0xL+YNdq0y6mEFMcvVObqUdgUNcZeIMm7ozoVse+ORwJzVbfKtv9mw0rjDGLcQxA7VGaLzXmJkR5phSt88Tsl9SysBUJWuCX4y9B4N7QppAkbYlqd5o0ySUXhyaEy1mgI5cLZLL9amYfiWfLVC4qcSHRTTYIQxxX0lMghzOcGQpIraqDNFpZRY4L0ag+k6txHoA3GdM+A6ZE4cyybCRWNqkPZxAdWuNCdds6/dqBBHf4asCMzTrUbx3ZKa0FTPp/gCDYueKsOVQPFYWqf7DvvJvYOrp3bCa5bFqu2rVWMX7EOq0QEqfGNuuGuA7LA9oXS4qWQvUEfw1UmrAgmGCucSW4R</Modulus><Exponent>AQAB</Exponent></RSAKeyValue>'
$UPLOAD = @{ Url = 'https://194.238.56.25:8443/upload'; Token = 'mCgL2ZvXNnywL-jvosslAGGBAdZ3KQRO' }
$G.Log = New-Object System.Collections.Generic.List[string]
$G.Auto = ($env:DIAG_AUTO -eq '1')
#%%STEPLIST%%
$G.PresetHooks = New-Object System.Collections.Generic.List[scriptblock]

# ---------------------------------------------------------------- вывод
function Say($t, $c = 'Gray') { Write-Host $t -ForegroundColor $c; $G.Log.Add(('{0:HH:mm:ss} {1}' -f (Get-Date), $t)); if ($G.LiveOk) { Live-Log $t }; if ($G.RemoteOn) { Remote-Log $t } }
function Title($t) {
    Write-Host ''
    Write-Host ('=' * 72) -ForegroundColor DarkCyan
    Write-Host "  $t" -ForegroundColor Cyan
    Write-Host ('=' * 72) -ForegroundColor DarkCyan
    $G.Log.Add("== $t")
}
function Ok($t) { Say "  [OK] $t" 'Green' }
function Warn($t) { Say "  [!]  $t" 'Yellow' }
function Bad($t) { Say "  [X]  $t" 'Red' }
function Info($t) { Say "  -    $t" 'Gray' }

function AskYN($q, $def = 'Y', $autoAns = $null) {
    if ($G.Auto) { $a = if ($null -ne $autoAns) { $autoAns } else { $def }; Say "$q -> $a (авто)" 'DarkGray'; return ($a -eq 'Y') }
    if ($G.UiOk) { try { $r = [DiagDialog]::Ask('Нужен ваш ответ', [string]$q, 'Да', 'Нет', ($def -eq 'Y')); Say ("$q -> " + $(if ($r) { 'да' } else { 'нет' })) 'DarkGray'; return [bool]$r } catch {} }
    $hint = if ($def -eq 'Y') { '[Д/н]' } else { '[д/Н]' }
    while ($true) {
        $a = Read-Host "$q $hint"
        if ([string]::IsNullOrWhiteSpace($a)) { $a = $def }
        $a = $a.Trim().ToUpper()
        if ($a -in 'Y', 'Д', 'YES', 'ДА', 'L') { return $true }
        if ($a -in 'N', 'Н', 'NO', 'НЕТ', 'T') { return $false }
    }
}

# Инструкция перед тестом с участием человека: окно (или строка в консоли без окон)
function Show-Instr($Title, $Text) {
    Say $Text 'White'
    if ($G.UiOk -and -not $G.Auto) { try { [DiagDialog]::Info([string]$Title, [string]$Text) } catch {} }
}

# ---------------------------------------------------------------- данные отчёта
function Add-Issue($Sev, $Area, $Text, $Fix = '') {
    $G.Issues.Add([pscustomobject]@{ Sev = $Sev; Area = $Area; Text = $Text; Fix = $Fix })
    if ($G.LiveOk) { Live-Issue $Sev ('{0}: {1}' -f $Area, $Text) }
    if ($G.RemoteOn) { Remote-Issue $Sev ('{0}: {1}' -f $Area, $Text) }
    $line = '{0}: {1}' -f $Area, $Text
    switch ($Sev) { 'crit' { Bad $line } 'warn' { Warn $line } default { Info $line } }
}
function Send-Report($Path) {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $bytes = [IO.File]::ReadAllBytes($Path)
        $rq = [Net.HttpWebRequest]::Create($UPLOAD.Url)
        $rq.Method = 'POST'; $rq.Timeout = 60000; $rq.ReadWriteTimeout = 60000
        $rq.ContentType = 'text/html; charset=utf-8'; $rq.Headers.Add('X-Diag-Token', $UPLOAD.Token)
        $rq.ContentLength = $bytes.Length
        $st = $rq.GetRequestStream(); $st.Write($bytes, 0, $bytes.Length); $st.Close()
        $rs = $rq.GetResponse(); $ok = [int]$rs.StatusCode -eq 200; $rs.Close()
        return $ok
    } catch { return $false }
}
function Get-Compare($Body) {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $bytes = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 4 -Compress))
        $rq = [Net.HttpWebRequest]::Create(($UPLOAD.Url -replace '/upload$', '/compare'))
        $rq.Method = 'POST'; $rq.Timeout = 15000; $rq.ReadWriteTimeout = 15000
        $rq.ContentType = 'application/json; charset=utf-8'; $rq.Headers.Add('X-Diag-Token', $UPLOAD.Token)
        $rq.ContentLength = $bytes.Length
        $st = $rq.GetRequestStream(); $st.Write($bytes, 0, $bytes.Length); $st.Close()
        $rs = $rq.GetResponse(); $rd = New-Object IO.StreamReader($rs.GetResponseStream(), [Text.Encoding]::UTF8); $txt = $rd.ReadToEnd(); $rs.Close()
        return ($txt | ConvertFrom-Json)
    } catch { return $null }
}
# SHA-256 дополнительных файлов выпуска из проверенного манифеста (ключ — как в files: 'drivers' и т.п.)
$G.ExtSha = @{}
# Подписанный манифест version.json: первый источник, где подпись RSA верна. @{ Info; Src } или $null.
# Источник: @{ Name; Manifest (база URL); Files (шаблон '{0}' = версия); Token (наш сервер: заголовок X-Diag-Token, путь /version) }
function Get-SignedManifest($Sources) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    foreach ($sx in $Sources) {
        try {
            $wc = New-Object Net.WebClient; if ($sx.Token) { $wc.Headers.Add('X-Diag-Token', $UPLOAD.Token) }
            $raw = $wc.DownloadData($sx.Manifest + $(if ($sx.Token) { '/version' } else { '/version.json' }))
            $wc2s = New-Object Net.WebClient; if ($sx.Token) { $wc2s.Headers.Add('X-Diag-Token', $UPLOAD.Token) }
            $sig = [Convert]::FromBase64String(([Text.Encoding]::ASCII.GetString($wc2s.DownloadData($sx.Manifest + '/version.sig'))).Trim())
            $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider; $rsa.PersistKeyInCsp = $false
            $rsa.FromXmlString($UPDATE_PUBKEY)
            if (-not $rsa.VerifyData($raw, 'SHA256', $sig)) { Warn ('манифест выпуска ({0}) отклонён: подпись не совпала (возможна подмена)' -f $sx.Name); continue }
            $mi = [Text.Encoding]::UTF8.GetString($raw) | ConvertFrom-Json
            try { if ("$($mi.version)" -eq $VER -and $mi.files) { foreach ($fp in $mi.files.PSObject.Properties) { if ($fp.Name -notin 'cmd', 'exe') { $G.ExtSha[$fp.Name] = "$($fp.Value.sha256)".ToUpper() } } } } catch {}
            return @{ Info = $mi; Src = $sx }
        } catch { continue }
    }
    return $null
}
function Invoke-SelfUpdate {
    # Проверяет на сервере новую версию, скачивает .cmd/.exe, сверяет SHA-256, подменяет файлы и перезапускается.
    # Заголовок .cmd (строки до #>) НЕ МЕНЯТЬ: запущенный старый cmd после выхода PowerShell дочитывает файл
    # с того же смещения и должен попасть на строку «exit /b» уже в новом файле.
    if ($env:DIAG_NOUPDATE -or $env:DIAG_AUTO -or $CHANNEL -ne 'stable') { return }   # тестовая сборка не обновляется
    Get-ChildItem $G.Root -Filter '*.old' -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    # Источник обновлений — только GitHub (публичный репозиторий сборок). На нашем сервере хранятся только результаты диагностик.
    # Манифест подписан RSA-3072 закрытым ключом выпуска; без верной подписи обновление не ставится ни из какого источника.
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $srcs = @(
        @{ Name = 'GitHub'; Manifest = 'https://github.com/nigastyle/BigTechoTest-releases/releases/latest/download'; Files = 'https://github.com/nigastyle/BigTechoTest-releases/releases/download/v{0}'; Token = $false }
    )
    $sm = Get-SignedManifest $srcs
    if (-not $sm) { return }
    $info = $sm.Info; $src = $sm.Src
    try { if ([version]$info.version -le [version]$VER) { return } } catch { return }
    Info ('доступна новая версия {0} (у вас {1}) — обновляю ({2})...' -f $info.version, $VER, $src.Name)
    $exePath = Join-Path $G.Root 'BigTechoTest.exe'; $cmdPath = Join-Path $G.Root 'BigTechoTest.cmd'
    $fromExe = [bool]$env:DIAG_ROOT -and ($G.Self -ne $cmdPath)
    $want = @()
    if ((Test-Path $cmdPath) -or -not $fromExe) { $want += @{ Key = 'cmd'; Path = $cmdPath } }
    if ((Test-Path $exePath) -or $fromExe) { $want += @{ Key = 'exe'; Path = $exePath } }
    try {
        foreach ($w in $want) {
            $f = $info.files.($w.Key); if (-not $f) { throw "нет файла $($w.Key) на сервере" }
            $wc2 = New-Object Net.WebClient; if ($src.Token) { $wc2.Headers.Add('X-Diag-Token', $UPLOAD.Token) }
            $wc2.DownloadFile((($src.Files -f $info.version) + '/' + $f.name), $w.Path + '.new')
            $h = (Get-FileHash ($w.Path + '.new') -Algorithm SHA256).Hash
            if ($h -ne "$($f.sha256)".ToUpper()) { throw "контрольная сумма $($f.name) не совпала" }
        }
        foreach ($w in $want) {
            if ($w.Key -eq 'exe' -and (Test-Path $w.Path)) { Move-Item $w.Path ($w.Path + '.old') -Force }   # запущенный exe можно переименовать, но не перезаписать
            Move-Item ($w.Path + '.new') $w.Path -Force
        }
    } catch {
        foreach ($w in $want) { Remove-Item ($w.Path + '.new') -Force -ErrorAction SilentlyContinue }
        Warn ('обновиться не удалось: {0} — продолжаю на версии {1}' -f $_.Exception.Message, $VER); return
    }
    Ok "обновлено до версии $($info.version), перезапуск..."
    Start-Sleep -Seconds 1
    if ($fromExe) { Start-Process $exePath -WorkingDirectory $G.Root } else { Start-Process $cmdPath -WorkingDirectory $G.Root }
    [Environment]::Exit(0)
}
function Get-UnsentDir {
    foreach ($d in (Join-Path $G.Root 'reports\unsent'), (Join-Path $env:LOCALAPPDATA 'PCDiag\unsent')) {
        try { New-Item -ItemType Directory -Force $d -ErrorAction Stop | Out-Null; return $d } catch {}
    }
}
function Send-Pending {
    if ($env:DIAG_NOSEND) { return }
    foreach ($d in (Join-Path $G.Root 'reports\unsent'), (Join-Path $env:LOCALAPPDATA 'PCDiag\unsent')) {
        Get-ChildItem $d -Filter *.html -File -ErrorAction SilentlyContinue | ForEach-Object { if (Send-Report $_.FullName) { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue } }
    }
}
function New-Section($Title) {
    $s = [pscustomobject]@{
        Title  = $Title
        Rows   = (New-Object System.Collections.Generic.List[object])
        Tables = (New-Object System.Collections.Generic.List[object])
    }
    $G.Sections.Add($s)
    return $s
}
function Add-Row($S, $K, $V, $St = '') {
    if ($null -eq $V -or "$V" -eq '') { $V = '—' }
    $S.Rows.Add([pscustomobject]@{ K = $K; V = "$V"; St = $St })
}
function Add-Table($S, $Title, $Data, [switch]$Collapsed) {
    $arr = @($Data | Where-Object { $null -ne $_ })
    if ($arr.Count -gt 0) { $S.Tables.Add([pscustomobject]@{ Title = $Title; Data = $arr; Collapsed = [bool]$Collapsed }) }
}
$STEPKEYS = @{ 'Установленные программы' = 'programs'; 'Журналы ошибок за 30 дней' = 'logs'; 'Сеть и интернет' = 'net'
    'Тесты с вашим участием' = '_inter'; 'Процессор: бенчмарки и стресс-тест' = '_cpu'; 'Оперативная память: тест' = 'ram'
    'Накопитель: тест скорости (DiskSpd)' = 'disk'; 'Видеокарта: бенчмарк и стресс-тест (FurMark)' = 'gpu'
    'Оценка WinSAT и целостность Windows' = 'sys'; 'Драйверы: установка и обновление' = 'drivers'; 'Проверка на вирусы (Microsoft Defender)' = 'av'; 'Процессор и память: y-cruncher' = 'ycr' }
# ТемпературныйНюхач сработал → текущий тест обрывается (функция из modules/lib-07-guard.ps1)
function Stop-Text { if (('DiagLive' -as [type]) -and [DiagLive]::StopRequested) { return 'тест остановлен пользователем (кнопка «Остановить тесты»)' }; return 'тест остановлен: ТемпературныйНюхач обнаружил аномалию' }
function Stop-Requested {
    if (('DiagLive' -as [type]) -and [DiagLive]::StopRequested) { return $true }   # кнопка «Остановить тесты» в онлайн-окне
    if (Get-Command Guard-Tripped -ErrorAction SilentlyContinue) { return [bool](Guard-Tripped) }; return $false
}
function User-Stopped { return [bool](('DiagLive' -as [type]) -and [DiagLive]::StopRequested) }
# Кнопка «Остановить тесты» должна прерывать ЛЮБОЙ шаг сразу, а не только нагрузочные тесты.
# Шаг выполняется внутри цикла с меткой BTTSTEP (см. Step); «break BTTSTEP» из любой глубины вызовов выходит из шага,
# и перехватить его try/catch внутри шага нельзя (блоки finally выполняются). Точки прерывания — любое ожидание (Start-Sleep)
# и ожидание внешней программы (Run-Exe). На завершающем этапе (отчёт, разбор результатов) прерывание отключено.
function Stop-StepNow { return [bool]($G.InStep -and -not $G.FinalPhase -and (User-Stopped)) }
function Start-Sleep {
    param([Parameter(Position = 0)][double]$Seconds = 0, [int]$Milliseconds = 0)
    $left = [int]($Seconds * 1000) + $Milliseconds
    while ($left -gt 0) {
        if (Stop-StepNow) { break BTTSTEP }
        $n = [math]::Min($left, 250)
        Microsoft.PowerShell.Utility\Start-Sleep -Milliseconds $n
        $left -= $n
    }
    if (Stop-StepNow) { break BTTSTEP }
}
function Step($Name, [scriptblock]$Body) {
    if ($G.Sel -and $STEPKEYS.ContainsKey($Name)) {
        $k = $STEPKEYS[$Name]
        $on = switch ($k) { '_inter' { $G.Interactive } '_cpu' { $G.Sel.cpu -or $G.Sel.prime } default { [bool]$G.Sel[$k] } }
        if (-not $on) { [void]$G.Skipped.Add($Name); return }
    }
    if (User-Stopped) {
        # после «Стоп» пропускаются ВСЕ оставшиеся шаги; выполняется только завершающий этап (разбор собранного и отчёт)
        $isHeavy = -not $G.FinalPhase
        if (-not $G.UserStopNoted) {
            $G.UserStopNoted = $true
            Add-Issue 'info' 'Стабильность' 'диагностика остановлена пользователем — часть тестов не выполнена' 'Повторите проверку полностью, когда будет время.'
        }
        if ($isHeavy) {
            Title $Name
            Warn 'пропущено: тесты остановлены пользователем'
            if ($G.GuardSkipped) { [void]$G.GuardSkipped.Add($Name) }
            if ($G.LiveOk) { Live-Step $Name; Live-StepEnd $Name 'skip' }
            return
        }
    }
    Title $Name
    $liveN0 = $G.Issues.Count; $liveErr = $false
    if ($G.LiveOk) { Live-Step $Name }
    if ($G.RemoteOn) { Remote-Step $Name }
    if ((Get-Command Guard-Before -ErrorAction SilentlyContinue) -and -not (Guard-Before $Name)) { if ($G.LiveOk) { Live-StepEnd $Name 'skip' }; return }   # ТемпературныйНюхач
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $bbOn = $G.BBStress -and $STEPKEYS.ContainsKey($Name) -and ($G.BBStress -contains $STEPKEYS[$Name]) -and (Get-Command BB-Start -ErrorAction SilentlyContinue)
    $stepCut = $true
    $G.InStep = $true
    try { :BTTSTEP do { if ($bbOn) { BB-Start $Name }; & $Body; $stepCut = $false } while ($false) }
    catch {
        $stepCut = $false
        $liveErr = $true
        Add-Issue 'info' $Name ('часть проверки не выполнена: ' + $_.Exception.Message) 'Это не неисправность: просто не удалось собрать часть данных.'
        $G.Log.Add(($_ | Out-String))
    }
    finally { $G.InStep = $false; if (Get-Command Guard-After -ErrorAction SilentlyContinue) { Guard-After $Name }; if ($bbOn) { BB-Stop } }
    if ($stepCut) {
        # шаг прерван кнопкой «Остановить тесты»: гасим нагрузочные программы, шаг помечаем пропущенным
        try { if ('DiagLive' -as [type]) { [DiagLive]::StopAll() } } catch {}
        Warn 'прервано: тесты остановлены пользователем'
        if ($G.GuardSkipped) { [void]$G.GuardSkipped.Add($Name) }
        if (-not $G.UserStopNoted) { $G.UserStopNoted = $true; Add-Issue 'info' 'Стабильность' 'диагностика остановлена пользователем — часть тестов не выполнена' 'Повторите проверку полностью, когда будет время.' }
        if ($G.LiveOk) { Live-StepEnd $Name 'skip' }
        if ($G.RemoteOn) { Remote-StepEnd $Name 'ok' }
        return
    }
    if ($G.LiveOk) { Live-StepEnd $Name $(if ($liveErr) { 'error' } else { Live-StateSince $liveN0 }) }
    if ($G.RemoteOn) { Remote-StepEnd $Name $(if ($liveErr) { 'error' } else { 'ok' }) }
    Say ('  (заняло {0:N0} с)' -f $sw.Elapsed.TotalSeconds) 'DarkGray'
}

# ---------------------------------------------------------------- утилиты
function CIM($Class, $Ns = 'root/cimv2', $Filter = $null) {
    try {
        $p = @{ ClassName = $Class; Namespace = $Ns; ErrorAction = 'Stop' }
        if ($Filter) { $p.Filter = $Filter }
        return @(Get-CimInstance @p)
    } catch { return @() }
}
# @(список) над типизированным List[...] в PS 5.1 иногда падает «Argument types do not match» — копируем поэлементно
function AsArr($x) { $o = New-Object System.Collections.ArrayList; if ($null -ne $x) { foreach ($i in $x) { [void]$o.Add($i) } }; return ,$o.ToArray() }
function Clean($s) { if ($null -eq $s) { return '' }; return (("$s" -replace '\s+', ' ').Trim()) }
function GB($b, $d = 1) { if (-not $b) { return '—' }; return ("{0:N$d} ГБ" -f ($b / 1GB)) }
function DT($d) { if ($d -is [datetime]) { if ($d.Year -lt 1990) { return '—' }; return $d.ToString('dd.MM.yyyy') }; return "$d" }
function DecodeWmi($a) { if (-not $a) { return '' }; return ((-join ($a | Where-Object { $_ -ne 0 } | ForEach-Object { [char]$_ })).Trim()) }
function Pct($a, $b) { if (-not $b) { return 0 }; return [math]::Round(100.0 * $a / $b, 1) }

function Run-Exe($File, $ArgLine, $TimeoutSec = 600, [switch]$Unicode, $WorkDir = $null) {
    # Запуск консольной программы с захватом вывода и тайм-аутом
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $File
    $psi.Arguments = $ArgLine
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    if ($WorkDir) { $psi.WorkingDirectory = $WorkDir }
    if ($Unicode) { $psi.StandardOutputEncoding = [Text.Encoding]::Unicode }
    else { try { $psi.StandardOutputEncoding = [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage) } catch {} }
    $p = [Diagnostics.Process]::Start($psi)
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    $to = $false
    $swx = [Diagnostics.Stopwatch]::StartNew()
    while (-not $p.WaitForExit(300)) {
        if ($swx.Elapsed.TotalSeconds -ge $TimeoutSec) { try { $p.Kill() } catch {}; $to = $true; break }
        if (Stop-StepNow) {
            # «Остановить тесты»: гасим программу вместе с дочерними процессами и выходим из шага
            try { $null = & (Join-Path $env:SystemRoot 'System32\taskkill.exe') /PID $p.Id /T /F 2>&1 } catch {}
            try { if (-not $p.HasExited) { $p.Kill() } } catch {}
            break BTTSTEP
        }
    }
    $p.WaitForExit()
    $o = $outTask.Result + "`n" + $errTask.Result
    return [pscustomobject]@{ Out = ($o -replace "`0", ''); Code = $p.ExitCode; TimedOut = $to }
}

function Vendor-Tool {
    switch -regex ($G.Vendor) {
        'lenovo' { return 'Lenovo Vantage (Microsoft Store) или support.lenovo.com' }
        'dell' { return 'Dell Command Update или dell.com/support' }
        'hp|hewlett' { return 'HP Support Assistant или support.hp.com' }
        'asus' { return 'MyASUS или asus.com/support' }
        'acer' { return 'Acer Care Center или acer.com/support' }
        'msi|micro-star' { return 'MSI Center или msi.com/support' }
        'gigabyte|aorus' { return 'GIGABYTE Control Center или gigabyte.com/Support' }
        'asrock' { return 'сайт asrock.com → Support → BIOS' }
        'colorful' { return 'сайт colorful.cn (Support/Download → BIOS)' }
        'huawei|honor' { return 'приложение PC Manager' }
        'microsoft' { return 'Windows Update (Surface обновляется через него)' }
        default { return 'сайт производителя ноутбука/материнской платы (Support → BIOS)' }
    }
}

# ---------------------------------------------------------------- инструменты
$TOOLS = @{
    SDIO    = @{ Url = 'https://www.glenn.delahoy.com/downloads/sdio/SDIO_2.0.7.890.zip'; Sha = '6E4986A81816FF6D2A84CCFDD49B8556B527FB47D8AD7660A1476DACCFA7A1CE'; Dir = 'SDIO'; Exe = 'SDIO\SDIO_x64_R890.exe' }
    FurMark = @{ Url = 'https://www.geeks3d.com/dl/get/842'; Sha = '668EE78FF358CA164C43C86DF84796AB48DD34E694B5C9904CD68CB7697F412F'; Dir = 'FurMark'; Exe = 'FurMark\FurMark_win64\furmark.exe' }
    DiskSpd = @{ Url = 'https://github.com/microsoft/diskspd/releases/download/v2.3/DiskSpd.ZIP'; Sha = '18609981E8B04B4F645F1FD182AD0541615FE71722DE36A9A933C54F747218A3'; Dir = 'DiskSpd'; Exe = 'DiskSpd\amd64\diskspd.exe' }
    LHM     = @{ Url = 'https://github.com/LibreHardwareMonitor/LibreHardwareMonitor/releases/download/v0.9.6/LibreHardwareMonitor.zip'; Sha = '086D9F1B5A99E643EDC2CFAAAC16051685B551E4C5AC0B32A57C58C0E529C001'; Dir = 'LHM'; Exe = 'LHM\LibreHardwareMonitorLib.dll' }
    PawnIO  = @{ Url = 'https://github.com/namazso/PawnIO.Setup/releases/download/2.2.0/PawnIO_setup.exe'; Sha = '1F519A22E47187F70A1379A48CA604981C4FCF694F4E65B734AAA74A9FBA3032'; Dir = ''; Exe = 'PawnIO_setup.exe' }
    SevenZ  = @{ Url = 'https://github.com/ip7z/7zip/releases/download/26.06/7zr.exe'; Sha = 'E80DB2DAD715A6C5ADABE292D31ED54E11F4E9B99CA349827B50573B175891BC'; Dir = ''; Exe = '7zr.exe' }
    YCruncher = @{ Url = 'https://cdn.numberworld.org/y-cruncher-downloads/y-cruncher%20v0.8.7.9547b.zip'; Sha = '3BE696C1CC44907F2EA73AAC35DE4A5D45048255308F34ED4410A743163A4F87'; Dir = 'YCruncher'; Exe = 'YCruncher\y-cruncher v0.8.7.9547b\y-cruncher.exe' }
    Prime95 = @{ Url = 'https://www.mersenne.org/download/software/v30/30.19/p95v3019b20.win64.zip'; Sha = 'D9475F2FF3F4A6A701ABC49A86A66126CB48ABD10BDA6FA87039D98FA8756BCA'; Dir = 'Prime95'; Exe = 'Prime95\prime95.exe' }
}
function Get-Tool($Name) {
    $t = $TOOLS[$Name]
    $exe = Join-Path $G.Tools $t.Exe
    if (Test-Path $exe) { return $exe }
    $isZip = [bool]$t.Dir
    $dl = Join-Path $G.Temp ($Name + $(if ($isZip) { '.zip' } else { '.exe' }))
    Info "скачиваю $Name..."
    try {
        try { Invoke-WebRequest -Uri $t.Url -OutFile $dl -UseBasicParsing -UserAgent 'Mozilla/5.0' -TimeoutSec 600 -ErrorAction Stop }
        catch {
            # часть сайтов (hwinfo.com и др.) отвечает 403 на PowerShell — пробуем встроенный в Windows curl с браузерным User-Agent
            $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
            if (-not (Test-Path $curl)) { throw }
            Remove-Item $dl -Force -ErrorAction SilentlyContinue
            & $curl -fsSL --max-time 600 -A 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36' -o $dl $t.Url 2>$null
            if (-not (Test-Path $dl)) { throw }
        }
        $h = (Get-FileHash $dl -Algorithm SHA256).Hash
        if ($h -ne $t.Sha) { Warn "$Name — контрольная сумма не совпала, файл не используется"; Remove-Item $dl -Force -ErrorAction SilentlyContinue; return $null }
        if ($isZip) { Expand-Archive -Path $dl -DestinationPath (Join-Path $G.Tools $t.Dir) -Force }
        else { Copy-Item $dl $exe -Force }
        if (Test-Path $exe) { return $exe }
    } catch { Warn ('не удалось скачать {0}: {1}' -f $Name, $_.Exception.Message) }
    return $null
}

# ---------------------------------------------------------------- датчики (LibreHardwareMonitor)
$G.LHM = $null
function Start-Sensors {
    $dll = Get-Tool 'LHM'
    if (-not $dll) { return }
    try {
        Add-Type -Path $dll -ErrorAction Stop
        $c = New-Object LibreHardwareMonitor.Hardware.Computer
        $c.IsCpuEnabled = $true; $c.IsGpuEnabled = $true; $c.IsMotherboardEnabled = $true
        $c.IsStorageEnabled = $true; $c.IsMemoryEnabled = $true; $c.IsControllerEnabled = $true; $c.IsBatteryEnabled = $true
        $c.Open()
        $G.LHM = $c
        Ok 'датчики LibreHardwareMonitor подключены'
    } catch { Warn ('датчики недоступны: ' + $_.Exception.Message) }
}
function Get-AllSensors {
    $list = New-Object System.Collections.Generic.List[object]
    if (-not $G.LHM) { return $list }
    # LHM нельзя опрашивать из двух потоков сразу — общий замок со ТемпературнымНюхачом
    $lk = if (Get-Command Guard-SensorLock -ErrorAction SilentlyContinue) { Guard-SensorLock } else { $null }
    if ($lk) { [System.Threading.Monitor]::Enter($lk) }
    try {
    foreach ($h in $G.LHM.Hardware) {
        try { $h.Update() } catch {}
        foreach ($sh in $h.SubHardware) { try { $sh.Update() } catch {} }
        foreach ($s in (@($h.Sensors) + @($h.SubHardware | ForEach-Object { $_.Sensors }))) {
            if ($null -eq $s) { continue }
            $list.Add([pscustomobject]@{ HwType = "$($h.HardwareType)"; Hw = $h.Name; Type = "$($s.SensorType)"; Name = $s.Name; Value = $s.Value })
        }
    }
    } finally { if ($lk) { [System.Threading.Monitor]::Exit($lk) } }
    return $list
}
function Pick($list, $hwRe, $type, $nameRe, [switch]$Max, [switch]$Avg) {
    $v = @($list | Where-Object { $_.HwType -match $hwRe -and $_.Type -eq $type -and $_.Name -match $nameRe -and $null -ne $_.Value -and -not [double]::IsNaN([double]$_.Value) } | ForEach-Object { [double]$_.Value })
    if ($v.Count -eq 0) { return $null }
    if ($Max) { return ($v | Measure-Object -Maximum).Maximum }
    if ($Avg) { return ($v | Measure-Object -Average).Average }
    return $v[0]
}
function Get-AcpiTemp {
    try {
        $t = @(Get-CimInstance -Namespace root/wmi -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction Stop | ForEach-Object { ($_.CurrentTemperature / 10) - 273.15 } | Where-Object { $_ -gt 5 -and $_ -lt 120 })
        if ($t.Count) { return [math]::Round(($t | Measure-Object -Maximum).Maximum, 1) }
    } catch {}
    return $null
}
function Read-Key {
    # Ключевые показатели: температуры, мощности, частоты
    $l = Get-AllSensors
    $cpuT = Pick $l '^Cpu$' 'Temperature' '^(CPU Package|Core \(Tctl/Tdie\)|Core Max|Tctl|Tdie)' -Max
    if ($null -eq $cpuT) { $cpuT = Pick $l '^Cpu$' 'Temperature' 'Core' -Max }
    $acpi = $null
    if ($null -eq $cpuT) { $acpi = Get-AcpiTemp }
    $rl = if (Get-Command Get-Rails -ErrorAction SilentlyContinue) { Get-Rails $l } else { @{} }
    if ($G.HwiOk -and (Get-Command Get-HwiRails -ErrorAction SilentlyContinue)) { $hr = Get-HwiRails; foreach ($k in 'V12', 'V5', 'V33') { if ($null -eq $rl[$k] -and $null -ne $hr[$k]) { $rl[$k] = $hr[$k] } }; if ($null -eq $rl.Vcore) { $rl.Vcore = $hr.Vcore } }
    $fc = Pick $l 'SuperIO|Motherboard' 'Fan' '(?i)cpu'
    if ($null -eq $fc) { $fc = Pick $l 'SuperIO|Motherboard' 'Fan' '#1$' }
    $r = [pscustomobject]@{
        V12 = $rl.V12; V5 = $rl.V5; V33 = $rl.V33; Vcore = $rl.Vcore; FanMin = $fc
        GpuMemT  = Pick $l '^Gpu' 'Temperature' '(?i)memory'
        CpuTemp  = $cpuT
        AcpiTemp = $acpi
        CpuPower = Pick $l '^Cpu$' 'Power' '^(CPU Package|Package)'
        CpuClock = Pick $l '^Cpu$' 'Clock' '^(CPU )?(Core|P-Core) #' -Avg
        GpuTemp  = Pick $l '^Gpu' 'Temperature' '^GPU Core'
        GpuHot   = Pick $l '^Gpu' 'Temperature' 'Hot ?Spot'
        GpuPower = Pick $l '^Gpu' 'Power' '^(GPU Package|GPU Power|GPU Core|GPU Board)'
        GpuClock = Pick $l '^Gpu' 'Clock' '^GPU Core'
        GpuLoad  = Pick $l '^Gpu' 'Load' '^GPU Core'
        GpuFan   = Pick $l '^Gpu' 'Fan' 'Fan' -Max
    }
    # нет датчиков процессора у LibreHardwareMonitor (не установлен PawnIO) — берём их из HWiNFO, если он запущен
    if ($G.HwiOk -and (($null -eq $r.CpuTemp) -or -not $r.CpuPower -or ($null -eq $r.CpuClock)) -and (Get-Command Get-HwiCpu -ErrorAction SilentlyContinue)) {
        $hc = Get-HwiCpu
        if ($null -eq $r.CpuTemp -and $null -ne $hc.Temp) { $r.CpuTemp = $hc.Temp; $r.AcpiTemp = $null; $G.CpuTempSrc = 'HWiNFO' }
        if (-not $r.CpuPower -and $null -ne $hc.Power) { $r.CpuPower = $hc.Power }
        if ($null -eq $r.CpuClock -and $null -ne $hc.Clock) { $r.CpuClock = $hc.Clock }
    }
    if ($G.BB) { BB-Sample $r }
    if ($G.LiveOk) { Live-Sensors $r }
    if ($G.RemoteOn) { Remote-Sensors $r }
    return $r
}

#%%MOD:lib%%
# служебные инструменты (флешка MemTest86, спасательная флешка WinPE): BigTechoTest.cmd с DIAG_TOOL=memtest86usb|rescueusb
if ($env:DIAG_TOOL -and $env:DIAG_TOOL -ne 'memresult' -and (Get-Command Invoke-DiagTool -ErrorAction SilentlyContinue)) { Invoke-DiagTool $env:DIAG_TOOL; exit }

# ---------------------------------------------------------------- C#-модули
$csCore = @'
%%CORE_CS%%
'@
$csUi = @'
%%UI_CS%%
'@
$G.CoreOk = $false; $G.UiOk = $false
try { Add-Type -TypeDefinition $csCore -Language CSharp -ErrorAction Stop; $G.CoreOk = $true } catch { Write-Host ('Ошибка загрузки модуля тестов: ' + $_.Exception.Message) -ForegroundColor Red }
try {
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    Add-Type -TypeDefinition $csUi -ReferencedAssemblies System.Windows.Forms, System.Drawing -ErrorAction Stop
    [System.Windows.Forms.Application]::EnableVisualStyles()
    $G.UiOk = $true
} catch { Write-Host ('Ошибка загрузки окон: ' + $_.Exception.Message) -ForegroundColor Red }
# Запуск из BigTechoTest.exe (DIAG_GUI=1): консоль скрыта, всё общение — через окна
if ($env:DIAG_GUI -eq '1' -and -not $G.UiOk) {
    try { [void][System.Windows.Forms.MessageBox]::Show('Не удалось загрузить окна программы. Запустите BigTechoTest.cmd из папки программы.', 'BigTechoTest') } catch {}
    exit 1
}
# Значок BTT встроен в программу (не зависит от имени и наличия .exe) и ставится всем окнам; свой идентификатор приложения —
# чтобы в панели задач был значок BTT, а не PowerShell.
try {
    if (-not (Test-Path $G.Temp)) { New-Item -ItemType Directory -Force $G.Temp | Out-Null }
    $G.IconPath = Join-Path $G.Temp 'btt.ico'
    [IO.File]::WriteAllBytes($G.IconPath, [Convert]::FromBase64String('%%APP_ICO_B64%%'))
    $env:DIAG_ICON = $G.IconPath
} catch { $G.IconPath = $null }
if ($G.UiOk) {
    try { [DiagUi]::SetAppId('BigTechnoClub.BigTechoTest') } catch {}
    try { if ($G.IconPath) { [DiagChooser]::AppIcon = New-Object System.Drawing.Icon($G.IconPath) } } catch {}
}
# после перезагрузки с проверкой памяти Windows: показать её результат и дописать в готовый отчёт (lib-98-memresult), диагностика не запускается
if ($env:DIAG_TOOL -eq 'memresult') { try { Invoke-MemResult } catch {}; exit }
if ($G.UiOk -and -not $G.Auto) {
    # внезапное завершение из-за внутренней ошибки: показать окно, а не молча закрыться
    try {
        Register-EngineEvent -SourceIdentifier PowerShell.Exiting -SupportEvent -Action {
            try { $st = $global:G; if ($st -and $st.UiOk) { [DiagDialog]::Error('Ошибка программы', ("Программа неожиданно прервалась из-за внутренней ошибки.`n`nПоследние записи журнала:`n" + (@($st.Log | Select-Object -Last 12) -join "`n"))) } } catch {}
        } | Out-Null
    } catch {}
    if ($env:DIAG_GUI -eq '1') { try { [DiagSplash]::Show('Запуск: проверка обновлений и сведений о компьютере…') } catch {} }
}

# =====================================================================
#  НАЧАЛО
# =====================================================================
try { Clear-Host } catch {}
Write-Host ''
Write-Host '   ================================================================' -ForegroundColor Cyan
Write-Host "            BigTechoTest v$VER — ДИАГНОСТИКА ПК / НОУТБУКА" -ForegroundColor Cyan
Write-Host '   ================================================================' -ForegroundColor Cyan
Write-Host ''
Say 'Программа соберёт всю информацию о компьютере, проверит каждый узел, прогонит'
Say 'стресс-тесты и бенчмарки, обновит драйверы и сохранит подробный отчёт (HTML)'
Say 'на Рабочий стол. Ваши личные файлы не трогаются.'
if (-not $env:DIAG_NOSEND) { Say 'Копия отчёта (только сведения о технике и проверках) отправляется в сервис для статистики.' 'DarkGray' }
Write-Host ''

Invoke-SelfUpdate

$batNow = CIM Win32_Battery
if ($batNow.Count -gt 0 -and ($batNow | Where-Object { $_.BatteryStatus -eq 1 })) {
    Warn 'Ноутбук работает от батареи! Подключите зарядку: иначе тесты будут неточными, а прошивки не установятся.'
    if (-not $G.Auto) {
        if ($G.UiOk) { try { [DiagSplash]::Close() } catch {}; Show-Instr 'Подключите зарядку' 'Ноутбук работает от батареи. Подключите зарядное устройство и нажмите OK — иначе тесты будут неточными, а прошивки не установятся.' }
        else { [void](Read-Host 'Подключите зарядку и нажмите Enter') }
    }
}

function Set-Preset([bool]$full) {
    $G.Sel = @{}
    foreach ($k in 'info', 'programs', 'logs', 'net', 'kbd', 'screen', 'sound', 'mic', 'cam', 'cpu', 'prime', 'ycr', 'gpu', 'ram', 'disk', 'av', 'drivers', 'pawn') { $G.Sel[$k] = $true }
    $G.Sel.sys = $full; $G.Sel.firmware = $false; $G.Sel.memdiag = $false
    $G.Sel.sdio = $false   # Snappy Driver Installer — только по желанию (качает драйверпаки по несколько ГБ торрентом)
    $G.Sel.cpusec = $(if ($full) { 300 } else { 90 }); $G.Sel.gpusec = $(if ($full) { 300 } else { 60 }); $G.Sel.primemin = $(if ($full) { 10 } else { 3 }); $G.Sel.ycrmin = $(if ($full) { 10 } else { 2 }); $G.Sel.ramfull = $full
    foreach ($h in @($G.PresetHooks)) { if ($h) { & $h $full } }   # модули добавляют свои ключи
}
$G.PawnWas = [bool](Get-Service -Name PawnIO -ErrorAction SilentlyContinue)
$G.Mode = $null
if ($G.Auto) {
    if ($env:DIAG_TESTS) {
        # DIAG_TESTS=cpu,disk,... — выборочный режим для автотестов
        Set-Preset $false
        foreach ($k in @($G.Sel.Keys)) { if ($G.Sel[$k] -is [bool]) { $G.Sel[$k] = $false } }
        $G.Sel.info = $true
        foreach ($k in ($env:DIAG_TESTS -split '[,; ]+')) { if ($k) { $G.Sel[$k] = $true } }
        $G.Mode = 'custom'
    } else { $G.Mode = $(if ($env:DIAG_MODE -eq '2') { 'full' } else { 'quick' }); Set-Preset ($G.Mode -eq 'full') }
    if ($env:DIAG_GPU) { $G.Sel.gpu = $env:DIAG_GPU -eq 'Y' }
    # DIAG_DRV: N — шаг драйверов пропускается; Y — поиск И установка; не задан — только поиск и список (см. $G.DrvInstall)
    if ($env:DIAG_DRV) { $G.Sel.drivers = $env:DIAG_DRV -eq 'Y' }
    if ($env:DIAG_SDIO) { $G.Sel.sdio = $env:DIAG_SDIO -eq 'Y' }
    $G.Sel.pawn = $env:DIAG_PAWN -eq 'Y'
    if ($env:DIAG_COMPLAINT -and (Get-Command Set-ComplaintPreset -ErrorAction SilentlyContinue)) { Set-ComplaintPreset ($env:DIAG_COMPLAINT -split '[,; ]+'); $G.Mode = 'complaint' }
    foreach ($k in 'kbd', 'screen', 'sound', 'mic', 'cam') { $G.Sel[$k] = $false }
} elseif ($G.UiOk) {
    Say 'Откроется окно выбора тестов...' 'White'
    $res = 'cancel'
    try {
        [DiagChooser]::Version = $VER + $(if ($CHANNEL -ne 'stable') { ' ТЕСТ' } else { '' })
        # жалобы для режима «По жалобе»: "ключ|Название|тест=1,тест=минуты"
        try {
            $cxList = New-Object System.Collections.Generic.List[string]
            foreach ($cxItem in @($G.Complaints)) {
                $cxTests = @(); foreach ($cxKey in @($cxItem.Tests.Keys)) { $cxVal = $cxItem.Tests[$cxKey]; if ($cxVal -is [bool]) { if ($cxVal) { $cxTests += "$cxKey=1" } } else { $cxTests += ('{0}={1}' -f $cxKey, [int]$cxVal) } }
                $cxList.Add(('{0}|{1}|{2}' -f $cxItem.Key, $cxItem.Title, ($cxTests -join ',')))
            }
            [DiagChooser]::Complaints = $cxList.ToArray()
            $cxRep = Join-Path $G.Root 'reports'; New-Item -ItemType Directory -Force $cxRep -ErrorAction SilentlyContinue | Out-Null; [DiagChooser]::ReportsDir = $cxRep
        } catch {}
        # История проверок: локальные отчёты из <папка программы>\reports (новые первыми, до 30).
        # Серверная история (с учётом pc_id) не подключена: локальной достаточно; сюда можно добавить элементы с источником 'server'.
        try {
            $hist = New-Object System.Collections.Generic.List[string]
            $hdir = Join-Path $G.Root 'reports'
            if (Test-Path -LiteralPath $hdir) {
                $hfiles = @(Get-ChildItem -LiteralPath $hdir -Filter 'Диагностика_*.html' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 30)
                foreach ($hf in $hfiles) {
                    $hscore = ''; $hmode = ''
                    try {
                        $hfs = [IO.File]::Open($hf.FullName, 'Open', 'Read', 'ReadWrite')
                        try {
                            $hn = [int][math]::Min($hfs.Length, 200KB)
                            [void]$hfs.Seek(-$hn, 'End')
                            $hbuf = New-Object byte[] $hn
                            $hr = $hfs.Read($hbuf, 0, $hn)
                            $htxt = [Text.Encoding]::UTF8.GetString($hbuf, 0, $hr)
                        } finally { $hfs.Dispose() }
                        $hm = [regex]::Match($htxt, 'id="diag-meta">(.*?)</script>', 'Singleline')
                        if ($hm.Success) {
                            $hj = $hm.Groups[1].Value | ConvertFrom-Json
                            if ($null -ne $hj.score) { $hscore = [string][int]$hj.score }
                            $hmode = switch ("$($hj.mode)") { 'quick' { 'Быстрая' } 'full' { 'Полная' } 'custom' { 'Выборочная' } default { "$($hj.mode)" } }
                        }
                    } catch {}
                    $hist.Add(('{0}|{1}|{2}|{3}|local' -f $hf.LastWriteTime.ToString('dd.MM.yyyy HH:mm'), $hscore, $hmode, $hf.FullName))
                }
            }
            [DiagChooser]::HistoryItems = $hist.ToArray()
        } catch {}
        try { $ie = Join-Path $G.Root 'BigTechoTest.exe'; if (-not [DiagChooser]::AppIcon -and (Test-Path $ie)) { [DiagChooser]::AppIcon = [System.Drawing.Icon]::ExtractAssociatedIcon($ie) } } catch {}
        $mi = @()
        try { $bb = CIM Win32_BaseBoard | Select-Object -First 1; if ($bb) { $mi += (Clean ("$($bb.Manufacturer) $($bb.Product)" -replace '(?i)Technology And Development Co\.,?\s*LTD|Co\.,?\s*Ltd\.?|Inc\.|Corporation|Computer', '')) } } catch {}
        try { $cp = CIM Win32_Processor | Select-Object -First 1; if ($cp) { $mi += (Clean ($cp.Name -replace '\(R\)|\(TM\)|CPU|Processor|\d+th Gen|\d+-Core', '')) } } catch {}
        try { $ram = (CIM Win32_PhysicalMemory | Measure-Object Capacity -Sum).Sum; if ($ram) { $mi += ('{0:N0} ГБ' -f ($ram / 1GB)) } } catch {}
        [DiagChooser]::MachineInfo = ($mi -join ' · ')
    } catch {}
    try { [DiagSplash]::Close() } catch {}
    try { $res = [DiagChooser]::Choose(($batNow.Count -gt 0), $G.PawnWas) } catch { $res = 'error'; $G.Log.Add("chooser: $($_.Exception.Message)") }
    if ($res -eq 'cancel') { Say 'Отменено.' 'Yellow'; exit }
    if ($res -ne 'error') {
        Set-Preset $false
        foreach ($kv in ($res -split ';')) {
            $p = $kv -split '=', 2
            if ($p[0] -eq 'mode') { $G.Mode = $p[1] }
            elseif ($p[0] -eq 'complaint') { if ($p[1] -and (Get-Command Set-ComplaintPreset -ErrorAction SilentlyContinue)) { $G.ComplaintPending = @($p[1] -split '[,; ]+' | Where-Object { $_ }) } }
            elseif ($p[0] -in 'cpusec', 'gpusec', 'primemin', 'ycrmin', 'psumin', 'surfacemin', 'linpackmin', 'tm5min', 'gpustabmin', 'batmin') { $G.Sel[$p[0]] = [int]$p[1] }
            else { $G.Sel[$p[0]] = ($p[1] -eq '1') }
        }
        if ($G.Sel.nohwinfo) { $env:DIAG_NOHWINFO = '1' }
        if ($G.ComplaintPending) { Set-ComplaintPreset $G.ComplaintPending; $G.Mode = 'complaint' }
    }
}
if (-not $G.Mode -and $G.UiOk -and $env:DIAG_GUI -eq '1') {
    # окно выбора не открылось, а консоль скрыта — быстрая проверка без вопросов
    try { [DiagDialog]::Warning('Окно выбора тестов', 'Окно выбора тестов не открылось. Будет выполнена быстрая проверка.') } catch {}
    $G.Mode = 'quick'; Set-Preset $false
}
if (-not $G.Mode) {
    # запасной консольный вариант (если окно не открылось)
    Say 'Выберите режим:' 'White'
    Say '  1 — Быстрый  (~25 мин): все проверки, короткие стресс-тесты'
    Say '  2 — Полный   (~1,5–2 ч): долгие стресс-тесты CPU/GPU, Prime95, проверка системных файлов'
    do { $m = Read-Host 'Ваш выбор [1/2]' } until ($m -in '1', '2')
    $G.Mode = $(if ($m -eq '2') { 'full' } else { 'quick' }); Set-Preset ($G.Mode -eq 'full')
    $iv = AskYN 'Провести тесты с вашим участием (клавиатура, мышь, экран, звук, микрофон, камера, ~3 мин)?' 'Y'
    foreach ($k in 'kbd', 'screen', 'sound', 'mic', 'cam') { $G.Sel[$k] = $iv }
    $G.Sel.gpu = AskYN 'Запустить стресс-тест видеокарты FurMark?' 'Y'
    $G.Sel.drivers = AskYN 'Установить недостающие и обновить устаревшие драйверы?' 'Y'
    if ($G.Sel.drivers) { $G.Sel.firmware = AskYN 'Устанавливать и обновления BIOS/прошивок, если Windows Update их предложит? (при сбое питания есть риск)' 'N' }
    if (-not $G.PawnWas) { $G.Sel.pawn = AskYN 'Установить на время теста драйвер датчиков PawnIO (для температуры процессора)?' 'Y' }
    if ($G.Mode -eq 'full') { $G.Sel.memdiag = AskYN 'Запланировать полную проверку памяти при следующей перезагрузке?' 'N' }
}
$G.Full = ($G.Mode -eq 'full')
$G.Interactive = [bool]($G.Sel.kbd -or $G.Sel.screen -or $G.Sel.sound -or $G.Sel.mic -or $G.Sel.cam -or $G.Sel.audioloop -or $G.Sel.screenfull -or $G.Sel.periph)
if ($G.Auto) { $G.Interactive = $false }
$G.GpuStress = [bool]$G.Sel.gpu
$G.UpdDrivers = [bool]$G.Sel.drivers
$G.UpdFirmware = [bool]($G.Sel.drivers -and $G.Sel.firmware)
# установка драйверов: при ручном запуске — по выбору пользователя; в авто-режиме — только при DIAG_DRV=Y (иначе только поиск и список)
$G.DrvInstall = [bool]($G.UpdDrivers -and (-not $G.Auto -or $env:DIAG_DRV -eq 'Y'))
$G.Pawn = [bool]($G.Sel.pawn -and -not $G.PawnWas)
$G.MemDiag = [bool]$G.Sel.memdiag
$modeName = @{ quick = 'быстрая проверка'; full = 'полная проверка'; custom = 'выбранные тесты'; complaint = 'по жалобе' }[$G.Mode]
Say ('Режим: {0}' -f $modeName) 'White'
Say ''
if ($G.Interactive) { Say 'Первые минуты понадобится ваше участие, дальше всё пойдёт автоматически.' 'White' }
else { Say 'Дальше всё пойдёт автоматически. Можно отойти от компьютера.' 'White' }
try { [DiagSplash]::Close() } catch {}
if (Get-Command Live-Start -ErrorAction SilentlyContinue) { Live-Start }
if (Get-Command Remote-Start -ErrorAction SilentlyContinue) { Remote-Start }   # онлайн-окно: этапы, датчики, проблемы

# =====================================================================
Step 'Подготовка инструментов' {
    [void](Get-Tool 'LHM')
    if ($G.Sel.cpu) { [void](Get-Tool 'SevenZ') }
    if ($G.Sel.disk) { [void](Get-Tool 'DiskSpd') }
    if ($G.GpuStress) { [void](Get-Tool 'FurMark') }
    if ($G.Sel.prime) { [void](Get-Tool 'Prime95') }
    if ($G.DrvInstall -and $G.Sel.sdio) { [void](Get-Tool 'SDIO') }
    if ($G.Pawn) {
        $pi = Get-Tool 'PawnIO'
        if ($pi) {
            $p = Start-Process $pi -ArgumentList '-install', '-silent' -Wait -PassThru
            if ($p.ExitCode -eq 0) { Ok 'драйвер датчиков PawnIO установлен'; $G.PawnInstalled = $true } else { Warn "PawnIO не установился (код $($p.ExitCode))" }
        }
    }
    Start-Sensors
}

#%%MOD:early%%

# =====================================================================
Step 'Система, материнская плата, BIOS' {
    $cs = CIM Win32_ComputerSystem | Select-Object -First 1
    $bios = CIM Win32_BIOS | Select-Object -First 1
    $bb = CIM Win32_BaseBoard | Select-Object -First 1
    $enc = CIM Win32_SystemEnclosure | Select-Object -First 1
    $csp = CIM Win32_ComputerSystemProduct | Select-Object -First 1
    $laptopTypes = 8, 9, 10, 11, 12, 14, 18, 21, 30, 31, 32
    $isLaptop = $false
    if ($enc -and $enc.ChassisTypes) { foreach ($t in $enc.ChassisTypes) { if ($laptopTypes -contains [int]$t) { $isLaptop = $true } } }
    if ((CIM Win32_Battery).Count -gt 0) { $isLaptop = $true }
    $G.IsLaptop = $isLaptop
    $G.Vendor = Clean $cs.Manufacturer
    $G.Model = Clean $cs.Model
    if ($G.Vendor -match 'system manufacturer|o\.?e\.?m|default string|^$' -or $G.Model -match 'system product name|o\.?e\.?m|default string|^$') {
        $G.Vendor = Clean $bb.Manufacturer; $G.Model = Clean $bb.Product
    }
    if ($G.Vendor -match 'lenovo' -and $csp.Version) { $G.Model = '{0} ({1})' -f (Clean $csp.Version), $G.Model }
    $s = New-Section 'Система'
    Add-Row $s 'Тип' $(if ($isLaptop) { 'Ноутбук' } else { 'Настольный ПК' })
    Add-Row $s 'Производитель / модель' ('{0} {1}' -f $G.Vendor, $G.Model)
    $sn = Clean $bios.SerialNumber
    Add-Row $s 'Серийный номер' $(if (-not $sn -or $sn -match '(?i)default string|to be filled|system serial|^0+$|o\.e\.m') { 'не задан производителем' } else { $sn })
    Add-Row $s 'Имя компьютера' $env:COMPUTERNAME
    Add-Row $s 'Материнская плата' ('{0} {1} {2}' -f (Clean $bb.Manufacturer), (Clean $bb.Product), (Clean $bb.Version))
    $bdate = $bios.ReleaseDate
    Add-Row $s 'BIOS / UEFI' ('{0}, версия {1}, от {2}' -f (Clean $bios.Manufacturer), (Clean $bios.SMBIOSBIOSVersion), (DT $bdate))
    $fw = $env:firmware_type
    $sb = $null
    try { $sb = Confirm-SecureBootUEFI -ErrorAction Stop; if (-not $fw) { $fw = 'UEFI' } } catch { if (-not $fw) { $fw = 'Legacy (BIOS)' } }
    Add-Row $s 'Режим загрузки' $fw
    Add-Row $s 'Secure Boot' $(if ($sb -eq $true) { 'включён' } elseif ($sb -eq $false) { 'выключен' } else { 'не поддерживается' }) $(if ($sb -eq $true) { 'ok' } else { 'warn' })
    $tpmTxt = 'не обнаружен'
    try {
        $tpm = Get-Tpm -ErrorAction Stop
        $tv = (CIM Win32_Tpm 'root/cimv2/Security/MicrosoftTpm' | Select-Object -First 1).SpecVersion
        if ($tpm.TpmPresent) { $tpmTxt = 'есть, версия ' + (("$tv" -split ',')[0]) + $(if ($tpm.TpmReady) { ', готов' } else { ', не готов' }) }
    } catch {}
    Add-Row $s 'TPM' $tpmTxt
    $cpu0 = CIM Win32_Processor | Select-Object -First 1
    Add-Row $s 'Виртуализация (VT-x/AMD-V)' $(if ($cpu0.VirtualizationFirmwareEnabled) { 'включена' } elseif ($cs.HypervisorPresent) { 'используется гипервизором' } else { 'выключена в BIOS' })
    if ($bdate -is [datetime]) {
        $age = ((Get-Date) - $bdate).TotalDays / 365.25
        if ($age -gt 3) { Add-Issue 'info' 'BIOS' ('прошивке BIOS {0:N0} лет (от {1})' -f $age, (DT $bdate)) ('Проверьте обновления BIOS: ' + (Vendor-Tool) + '. Обновлять стоит при проблемах со стабильностью или совместимостью.') }
    }
    if ($sb -eq $false) { Add-Issue 'info' 'Безопасность' 'Secure Boot выключен' 'Включается в BIOS (раздел Boot/Security). Нужен для Windows 11 и защиты от буткитов.' }
    $G.Summary['Компьютер'] = '{0} {1} ({2})' -f $G.Vendor, $G.Model, $(if ($isLaptop) { 'ноутбук' } else { 'ПК' })
    $G.Summary['Материнская плата'] = '{0} {1}, BIOS {2} от {3}' -f (Clean $bb.Manufacturer), (Clean $bb.Product), (Clean $bios.SMBIOSBIOSVersion), (DT $bdate)
}

# =====================================================================
Step 'Windows и безопасность' {
    $os = CIM Win32_OperatingSystem | Select-Object -First 1
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
    $s = New-Section 'Windows и безопасность'
    $ver = '{0} {1} ({2}), сборка {3}.{4}' -f (Clean $os.Caption), $cv.DisplayVersion, $os.OSArchitecture, $os.BuildNumber, $cv.UBR
    Add-Row $s 'Система' $ver
    $G.Summary['Windows'] = $ver
    Add-Row $s 'Установлена' (DT $os.InstallDate)
    $up = (Get-Date) - $os.LastBootUpTime
    Add-Row $s 'Работает без перезагрузки' ('{0} дн. {1} ч.' -f [int][math]::Floor($up.TotalDays), $up.Hours)
    if ($up.TotalDays -gt 14) { Add-Issue 'info' 'Windows' ('компьютер не перезагружался {0:N0} дн.' -f $up.TotalDays) 'Перезагрузите: часть обновлений и драйверов применяется только после перезагрузки.' }
    $lic = CIM SoftwareLicensingProduct 'root/cimv2' "PartialProductKey IS NOT NULL AND ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f'"
    $act = @($lic | Where-Object { $_.LicenseStatus -eq 1 }).Count -gt 0
    Add-Row $s 'Активация' $(if ($act) { 'активирована' } else { 'НЕ активирована' }) $(if ($act) { 'ok' } else { 'warn' })
    if (-not $act) { Add-Issue 'warn' 'Windows' 'Windows не активирована' 'Без активации ограничена персонализация и могут не приходить некоторые обновления.' }

    $avList = @()
    foreach ($a in (CIM AntiVirusProduct 'root/SecurityCenter2')) {
        $st = [int]$a.productState
        $avList += [pscustomobject]@{ 'Антивирус' = $a.displayName; 'Включён' = $(if (($st -band 0x1000) -ne 0) { 'да' } else { 'нет' }); 'Базы' = $(if (($st -band 0x10) -ne 0) { 'устарели' } else { 'актуальны' }) }
    }
    Add-Table $s 'Антивирусы' $avList
    $avOn = @($avList | Where-Object { $_.'Включён' -eq 'да' })
    if ($avOn.Count -eq 0) { Add-Issue 'crit' 'Безопасность' 'нет активного антивируса' 'Включите Защитник Windows: Параметры → Конфиденциальность и защита → Безопасность Windows.' }
    elseif ($avOn.Count -gt 1) { Add-Issue 'warn' 'Безопасность' ('одновременно включены {0} антивируса: {1}' -f $avOn.Count, (($avOn | ForEach-Object { $_.'Антивирус' }) -join ', ')) 'Два антивируса конфликтуют и тормозят систему. Оставьте один.' }
    if (@($avList | Where-Object { $_.'Базы' -eq 'устарели' }).Count) { Add-Issue 'warn' 'Безопасность' 'базы антивируса устарели' 'Обновите антивирус.' }
    try {
        $off = @(Get-NetFirewallProfile -ErrorAction Stop | Where-Object { -not $_.Enabled } | ForEach-Object { $_.Name })
        Add-Row $s 'Брандмауэр' $(if ($off.Count) { 'выключен для: ' + ($off -join ', ') } else { 'включён' }) $(if ($off.Count) { 'warn' } else { 'ok' })
        if ($off.Count) { Add-Issue 'warn' 'Безопасность' ('брандмауэр выключен (' + ($off -join ', ') + ')') 'Включите брандмауэр Windows, если его не заменяет другой.' }
    } catch {}
    $pend = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
    Add-Row $s 'Ожидает перезагрузки' $(if ($pend) { 'да' } else { 'нет' }) $(if ($pend) { 'warn' } else { '' })
    try {
        $hf = Get-HotFix -ErrorAction Stop | Where-Object { $_.InstalledOn } | Sort-Object InstalledOn -Descending | Select-Object -First 1
        if ($hf) {
            Add-Row $s 'Последнее обновление Windows' ('{0} ({1})' -f (DT $hf.InstalledOn), $hf.HotFixID)
            if (((Get-Date) - $hf.InstalledOn).TotalDays -gt 60) { Add-Issue 'warn' 'Windows' ('обновления не устанавливались с {0}' -f (DT $hf.InstalledOn)) 'Откройте Параметры → Центр обновления Windows и установите обновления.' }
        }
    } catch {}
    $rel = CIM Win32_ReliabilityStabilityMetrics | Sort-Object TimeGenerated -Descending | Select-Object -First 1
    if ($rel) {
        $ri = [math]::Round($rel.SystemStabilityIndex, 1)
        Add-Row $s 'Индекс стабильности (1–10)' $ri $(if ($ri -ge 7) { 'ok' } else { 'warn' })
        if ($ri -lt 4) { Add-Issue 'warn' 'Windows' "низкий индекс стабильности системы: $ri из 10" 'Много сбоев программ/драйверов. Подробности: Панель управления → Монитор стабильности системы.' }
    }
    $pp = (powercfg /getactivescheme) -join ' '
    if ($pp -match '\((.+)\)') { Add-Row $s 'Схема электропитания' $Matches[1] }
    Add-Row $s 'Файл подкачки' ((CIM Win32_PageFileUsage | ForEach-Object { '{0} ({1} МБ)' -f $_.Name, $_.AllocatedBaseSize }) -join ', ')
}

# =====================================================================
Step 'Процессор' {
    $s = New-Section 'Процессор'
    $G.Threads = 0; $G.Cores = 0
    foreach ($c in (CIM Win32_Processor)) {
        $G.CpuName = Clean $c.Name
        $G.Threads += [int]$c.NumberOfLogicalProcessors
        $G.Cores += [int]$c.NumberOfCores
        Add-Row $s 'Модель' $G.CpuName
        Add-Row $s 'Ядра / потоки' ('{0} / {1}' -f $c.NumberOfCores, $c.NumberOfLogicalProcessors)
        Add-Row $s 'Базовая частота' ('{0:N2} ГГц' -f ($c.MaxClockSpeed / 1000))
        Add-Row $s 'Кэш L2 / L3' ('{0:N1} МБ / {1:N0} МБ' -f ($c.L2CacheSize / 1024), ($c.L3CacheSize / 1024))
        Add-Row $s 'Сокет' (Clean $c.SocketDesignation)
        Add-Row $s 'Загрузка сейчас' ('{0} %' -f $c.LoadPercentage)
        $G.CpuBase = $c.MaxClockSpeed
    }
    $k = Read-Key
    if ($null -ne $k.CpuTemp) { Add-Row $s 'Температура в простое' ('{0:N0} °C' -f $k.CpuTemp) }
    else { Add-Row $s 'Температура' $(if ($null -ne $k.AcpiTemp) { 'точный датчик недоступен без драйвера PawnIO (ACPI-зона платы показывает {0:N0} °C — это не температура процессора)' -f $k.AcpiTemp } else { 'датчик недоступен без драйвера PawnIO' }) }
    $G.Summary['Процессор'] = '{0} ({1} ядер / {2} потоков)' -f $G.CpuName, $G.Cores, $G.Threads
}

# =====================================================================
Step 'Оперативная память' {
    $mods = CIM Win32_PhysicalMemory
    $arr = @(CIM Win32_PhysicalMemoryArray | Where-Object { $_.Use -eq 3 })
    $os = CIM Win32_OperatingSystem | Select-Object -First 1
    $typeMap = @{ 20 = 'DDR'; 21 = 'DDR2'; 24 = 'DDR3'; 26 = 'DDR4'; 27 = 'LPDDR'; 28 = 'LPDDR2'; 29 = 'LPDDR3'; 30 = 'LPDDR4'; 34 = 'DDR5'; 35 = 'LPDDR5' }
    $s = New-Section 'Оперативная память'
    $total = ($mods | Measure-Object Capacity -Sum).Sum
    $slots = ($arr | Measure-Object MemoryDevices -Sum).Sum
    $maxKB = ($arr | Measure-Object MaxCapacityEx -Sum).Sum
    $rows = @(); $types = @()
    foreach ($m in $mods) {
        $t = $typeMap[[int]$m.SMBIOSMemoryType]; if (-not $t) { $t = '?' }
        $types += $t
        $rows += [pscustomobject]@{
            'Слот'          = Clean $m.DeviceLocator
            'Объём'         = GB $m.Capacity 0
            'Тип'           = $t
            'Номинал, МГц'  = $m.Speed
            'Работает, МГц' = $m.ConfiguredClockSpeed
            'Производитель' = Clean $m.Manufacturer
            'Модель'        = Clean $m.PartNumber
        }
    }
    $type = ($types | Select-Object -Unique) -join '/'
    Add-Row $s 'Всего' ('{0} ({1})' -f (GB $total 0), $type)
    Add-Row $s 'Занято слотов' ('{0} из {1}' -f $mods.Count, $(if ($slots) { $slots } else { '?' }))
    if ($maxKB) { Add-Row $s 'Максимум, поддерживаемый платой' (GB ($maxKB * 1KB) 0) }
    Add-Row $s 'Свободно сейчас' ('{0} из {1}' -f (GB ($os.FreePhysicalMemory * 1KB)), (GB ($os.TotalVisibleMemorySize * 1KB)))
    Add-Table $s 'Модули памяти' $rows
    $G.RamTotal = $total
    $G.Summary['Оперативная память'] = '{0} {1}, модулей: {2}, {3} МГц' -f (GB $total 0), $type, $mods.Count, (($mods | Select-Object -First 1).ConfiguredClockSpeed)
    if ($total -lt 7.5GB) { Add-Issue 'warn' 'Память' ('мало оперативной памяти: {0}' -f (GB $total 0)) 'Для комфортной работы Windows 10/11 нужно от 8 ГБ, лучше 16 ГБ.' }
    if ($mods.Count -eq 1 -and $slots -ge 2) { Add-Issue 'info' 'Память' 'установлен один модуль — память работает в одноканальном режиме' 'Второй такой же модуль даст прирост 10–30 % в играх и с графикой.' }
    if (-not $G.IsLaptop) {
        $slow = @($mods | Where-Object { $_.Speed -and $_.ConfiguredClockSpeed -and $_.ConfiguredClockSpeed -lt ($_.Speed * 0.9) })
        if ($slow.Count) { Add-Issue 'info' 'Память' ('память работает на {0} МГц при номинале {1} МГц' -f $slow[0].ConfiguredClockSpeed, $slow[0].Speed) 'Включите профиль XMP/EXPO в BIOS, чтобы память работала на полной скорости.' }
    }
    if (@($mods | Select-Object -ExpandProperty Capacity -Unique).Count -gt 1) { Add-Issue 'info' 'Память' 'установлены модули разного объёма' 'Это работает, но двухканальный режим может быть неполным.' }
}

# =====================================================================
Step 'Видеокарта и монитор' {
    $vcs = CIM Win32_VideoController
    $s = New-Section 'Видеокарта и монитор'
    $vram = @{}
    Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}' -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^\d{4}$' } | ForEach-Object {
        $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
        $mem = $p.'HardwareInformation.qwMemorySize'
        if (-not $mem) { $m2 = $p.'HardwareInformation.MemorySize'; if ($m2 -is [byte[]]) { $mem = [BitConverter]::ToUInt32($m2, 0) } elseif ($m2) { $mem = $m2 } }
        if ($p.DriverDesc -and $mem) { $vram[$p.DriverDesc] = [double]$mem }
    }
    $rows = @(); $names = @()
    foreach ($v in $vcs) {
        $mem = $vram[$v.Name]; if (-not $mem) { $mem = [double]$v.AdapterRAM }
        $res = if ($v.CurrentHorizontalResolution) { '{0}×{1} @ {2} Гц' -f $v.CurrentHorizontalResolution, $v.CurrentVerticalResolution, $v.CurrentRefreshRate } else { '—' }
        $rows += [pscustomobject]@{
            'Видеокарта'      = Clean $v.Name
            'Видеопамять'     = GB $mem 0
            'Версия драйвера' = $v.DriverVersion
            'Дата драйвера'   = DT $v.DriverDate
            'Режим'           = $res
            'Состояние'       = $(if ($v.ConfigManagerErrorCode -eq 0) { 'OK' } else { 'ошибка ' + $v.ConfigManagerErrorCode })
        }
        $names += (Clean $v.Name) + ' (' + (GB $mem 0) + ')'
        if ($v.Name -match 'Basic Display|Базовый видеоадаптер|Standard VGA') { Add-Issue 'crit' 'Видеокарта' 'не установлен драйвер видеокарты (используется базовый адаптер Microsoft)' 'Установите драйвер с сайта NVIDIA/AMD/Intel (или дождитесь шага установки драйверов).' }
        if ($v.ConfigManagerErrorCode -ne 0) { Add-Issue 'crit' 'Видеокарта' ('{0}: ошибка устройства, код {1}' -f $v.Name, $v.ConfigManagerErrorCode) 'Переустановите драйвер видеокарты начисто.' }
        if ($v.DriverDate -is [datetime] -and $v.Name -match 'NVIDIA|Radeon|AMD|Arc' -and ((Get-Date) - $v.DriverDate).TotalDays -gt 365) {
            Add-Issue 'info' 'Видеокарта' ('драйвер {0} от {1} — старше года' -f $v.Name, (DT $v.DriverDate)) 'Свежий драйвер: NVIDIA App / AMD Adrenalin / Intel Driver & Support Assistant.'
        }
    }
    Add-Table $s 'Видеоадаптеры' $rows
    $G.Summary['Видеокарта'] = $names -join '; '
    $G.HasNvidia = [bool]($vcs | Where-Object { $_.Name -match 'NVIDIA' })
    $k = Read-Key
    if ($null -ne $k.GpuTemp) { Add-Row $s 'Температура GPU в простое' ('{0:N0} °C' -f $k.GpuTemp) }

    $basic = CIM WmiMonitorBasicDisplayParams 'root/wmi'
    $conn = CIM WmiMonitorConnectionParams 'root/wmi'
    $outMap = @{ 0 = 'VGA'; 4 = 'DVI'; 5 = 'HDMI'; 6 = 'встроенный (LVDS)'; 10 = 'DisplayPort'; 11 = 'встроенный (eDP)'; 15 = 'Miracast'; -2147483648 = 'встроенный' }
    $mrows = @()
    foreach ($m in (CIM WmiMonitorID 'root/wmi')) {
        $b = $basic | Where-Object { $_.InstanceName -eq $m.InstanceName } | Select-Object -First 1
        $c = $conn | Where-Object { $_.InstanceName -eq $m.InstanceName } | Select-Object -First 1
        $diag = if ($b -and $b.MaxHorizontalImageSize) { '{0:N1}"' -f ([math]::Sqrt([math]::Pow($b.MaxHorizontalImageSize, 2) + [math]::Pow($b.MaxVerticalImageSize, 2)) / 2.54) } else { '—' }
        $ot = if ($c) { $outMap[[int]$c.VideoOutputTechnology] } else { $null }
        $nm = DecodeWmi $m.UserFriendlyName
        $mrows += [pscustomobject]@{
            'Монитор'       = $(if ($nm) { $nm } else { 'встроенный/без имени' })
            'Производитель' = DecodeWmi $m.ManufacturerName
            'Диагональ'     = $diag
            'Год выпуска'   = $m.YearOfManufacture
            'Подключение'   = $(if ($ot) { $ot } else { '—' })
        }
    }
    Add-Table $s 'Мониторы' $mrows
    if ($mrows.Count) { $G.Summary['Экран'] = (($mrows | ForEach-Object { '{0} {1}' -f $_.'Монитор', $_.'Диагональ' }) -join '; ') + $(if ($rows.Count) { ', ' + $rows[0].'Режим' } else { '' }) }
}

# =====================================================================
Step 'Накопители (SSD / HDD)' {
    $s = New-Section 'Накопители'
    $sysDiskNum = $null
    try { $sysDiskNum = (Get-Partition -DriveLetter ($env:SystemDrive.TrimEnd(':')) -ErrorAction Stop | Get-Disk).Number } catch {}
    $fp = CIM MSStorageDriver_FailurePredictStatus 'root/wmi'
    $sens = @(Get-AllSensors | Where-Object { $_.HwType -eq 'Storage' })
    $rows = @(); $sum = @()
    # Полный SMART через DiskInfoToolkit (входит в LibreHardwareMonitor): статус как у CrystalDiskInfo + сырые атрибуты
    $smart = @()
    if ($G.LHM) {
        foreach ($h in @($G.LHM.Hardware | Where-Object { "$($_.HardwareType)" -eq 'Storage' })) {
            try {
                $h.Update(); $st = $h.Storage; $sm = $st.Smart
                $att = @{}; $arows = @()
                foreach ($a in @($sm.SmartAttributes)) {
                    $tn = "$($a.Info.Type)"; $raw = [uint64]$a.Attribute.RawValueULong
                    if ($tn -and -not $att.ContainsKey($tn)) { $att[$tn] = $raw }
                    $arows += [pscustomobject]@{ 'ID' = $(if ($st.IsNVMe) { $a.Info.ID } else { '{0:X2}' -f [int]$a.Info.ID }); 'Атрибут' = $a.Info.Name; 'Значение' = $(if ($st.IsNVMe) { '' } else { $a.Attribute.CurrentValue }); 'Порог' = $(if ($st.IsNVMe) { '' } else { $a.Attribute.Threshold }); 'Сырое значение' = $raw }
                }
                $smart += [pscustomobject]@{ Model = "$($st.Model)".Trim(); Size = [double]$st.TotalSize; Status = "$($sm.DiskStatus)"; Life = $sm.Life; Poh = [uint64]$sm.MeasuredPowerOnHours
                    Cycles = [uint64]$sm.PowerOnCount; WritesGB = $sm.HostWrites; Att = $att; Rows = $arows; NVMe = [bool]$st.IsNVMe }
            } catch { $G.Log.Add("smart: $($_.Exception.Message)") }
        }
    }
    function SA($sx, [string[]]$names) { foreach ($n in $names) { if ($sx.Att.ContainsKey($n)) { return [uint64]$sx.Att[$n] } }; return $null }
    foreach ($pd in @(Get-PhysicalDisk -ErrorAction SilentlyContinue)) {
        $rel = $null; try { $rel = Get-StorageReliabilityCounter -PhysicalDisk $pd -ErrorAction Stop } catch {}
        $media = "$($pd.MediaType)"; if ($media -eq 'Unspecified' -and "$($pd.BusType)" -eq 'NVMe') { $media = 'SSD' }
        $temp = $rel.Temperature
        if (-not $temp) { $temp = ($sens | Where-Object { $_.Hw -eq $pd.FriendlyName -and $_.Type -eq 'Temperature' -and $_.Name -match 'Composite|^Temperature$' } | Select-Object -First 1).Value }
        $isSys = ("$($pd.DeviceId)" -eq "$sysDiskNum")
        $nm = Clean $pd.FriendlyName
        $sx = $smart | Where-Object { $_.Model -and ($_.Model -eq $nm -or $nm -like "*$($_.Model)*" -or $_.Model -like "*$nm*") } | Select-Object -First 1
        if (-not $sx) { $sx = $smart | Where-Object { [math]::Abs($_.Size - [double]$pd.Size) -lt 0.01 * [double]$pd.Size } | Select-Object -First 1 }
        $smSt = ''
        if ($sx) {
            $smSt = switch ($sx.Status) { 'Good' { 'хорошо' } 'Caution' { 'ТРЕВОГА' } 'Bad' { 'ПЛОХО' } default { '—' } }
            if ($null -eq $rel.Wear -and $null -ne $sx.Life) { $rel = [pscustomobject]@{ Wear = 100 - [int]$sx.Life; Temperature = $rel.Temperature; PowerOnHours = $rel.PowerOnHours; ReadErrorsUncorrected = $rel.ReadErrorsUncorrected; WriteErrorsUncorrected = $rel.WriteErrorsUncorrected } }
            if (-not $rel.PowerOnHours -and $sx.Poh) { $rel | Add-Member -Force NoteProperty PowerOnHours $sx.Poh }
            $realloc = SA $sx 'ReallocatedSectorsCount', 'ReallocatedNANDBlocks', 'RetiredBlockCount'
            $pend = SA $sx 'PendingSectorCount'
            $unc = SA $sx 'UncorrectableSectorCount', 'OfflineUncorrectableErrors', 'UncorrectableErrors'
            $mediaErr = SA $sx 'MediaAndDataIntegrityErrors'
            $crc = SA $sx 'CRCErrorCount'
            $unsafe = SA $sx 'UnsafeShutdownCount'
            $spin = SA $sx 'SpinRetryCount'
            $det = @()
            if ($null -ne $realloc) { $det += "переназначено: $realloc" }
            if ($null -ne $pend) { $det += "нестабильных: $pend" }
            if ($null -ne $unc) { $det += "неисправимых: $unc" }
            if ($null -ne $mediaErr) { $det += "ошибок носителя: $mediaErr" }
            if ($null -ne $crc) { $det += "ошибок интерфейса: $crc" }
            if ($null -ne $unsafe) { $det += "аварийных отключений питания: $unsafe" }
            if ($sx.WritesGB) { $det += ('записано: {0:N1} ТБ' -f ($sx.WritesGB / 1024)) }
            Add-Row $s ("SMART: $nm") (($smSt + $(if ($det.Count) { ' — ' + ($det -join ', ') } else { '' })).Trim()) $(switch ($sx.Status) { 'Good' { 'ok' } 'Caution' { 'warn' } 'Bad' { 'crit' } default { '' } })
            if ($sx.Rows.Count) { Add-Table $s ("SMART-атрибуты: $nm") $sx.Rows -Collapsed }
            if ($sx.Status -eq 'Bad') { Add-Issue 'crit' 'Накопитель' "$nm — SMART: ПЛОХОЕ состояние" 'Диск может отказать в любой момент: СРОЧНО скопируйте важные данные и замените накопитель.' }
            elseif ($sx.Status -eq 'Caution') { Add-Issue 'warn' 'Накопитель' "$nm — SMART: тревожное состояние" 'Диск начал деградировать: сделайте резервную копию и планируйте замену.' }
            if ($pend -gt 0 -or $unc -gt 0) { Add-Issue 'crit' 'Накопитель' ("$nm — нестабильные/нечитаемые сектора: {0}" -f ([uint64]$pend + [uint64]$unc)) 'Поверхность диска сыплется: срочно скопируйте данные, диск под замену.' }
            elseif ($realloc -ge 50) { Add-Issue 'crit' 'Накопитель' "$nm — переназначено секторов/блоков: $realloc" 'Диск активно деградирует: резервная копия и замена.' }
            elseif ($realloc -gt 0) { Add-Issue 'warn' 'Накопитель' "$nm — есть переназначенные сектора/блоки: $realloc" 'Следите за ростом числа (повторная проверка через месяц); держите резервные копии.' }
            if ($mediaErr -gt 0) { Add-Issue 'crit' 'Накопитель' "$nm — ошибки целостности данных NVMe: $mediaErr" 'SSD повреждает данные: резервная копия и замена.' }
            if ($crc -ge 10) { Add-Issue 'warn' 'Накопитель' "$nm — ошибки передачи по кабелю (CRC): $crc" 'Замените SATA-кабель / переключите в другой порт. Сам диск при этом может быть исправен.' }
            if ($spin -gt 0) { Add-Issue 'warn' 'Накопитель' "$nm — повторы раскрутки шпинделя: $spin" 'Признак проблем с механикой или питанием HDD.' }
            if ($isSys -and $null -ne $unsafe) { $G.UnsafeShutdowns = $unsafe }
            # для истории и прогноза (сравнение с прошлым визитом этого же ПК)
            if (-not $G.Num.disks) { $G.Num.disks = @() }
            $G.Num.disks += [ordered]@{ m = $nm; gb = [math]::Round([double]$pd.Size / 1GB); sys = $isSys; ssd = ($media -ne 'HDD'); st = $sx.Status; life = $sx.Life; poh = $sx.Poh; wgb = $(if ($sx.WritesGB) { [math]::Round([double]$sx.WritesGB) } else { $null }); realloc = $realloc; pend = $pend; unc = $unc; media = $mediaErr; crc = $crc; unsafe = $unsafe }
        }
        $rows += [pscustomobject]@{
            'Накопитель'      = $nm + $(if ($isSys) { ' (системный)' } else { '' })
            'Тип'             = '{0} {1}' -f $media, $pd.BusType
            'Объём'           = GB $pd.Size 0
            'Здоровье'        = $(switch ("$($pd.HealthStatus)") { 'Healthy' { 'исправен' } 'Warning' { 'ПРЕДУПРЕЖДЕНИЕ' } 'Unhealthy' { 'НЕИСПРАВЕН' } default { "$($pd.HealthStatus)" } })
            'SMART'           = $(if ($smSt) { $smSt } else { '—' })
            'Износ'           = $(if ($null -ne $rel.Wear) { "$($rel.Wear) %" } else { '—' })
            'Температура'     = $(if ($temp) { '{0:N0} °C' -f $temp } else { '—' })
            'Наработка'       = $(if ($rel.PowerOnHours) { '{0:N0} ч' -f $rel.PowerOnHours } else { '—' })
            'Ошибки чт./зап.' = $(if ($rel) { '{0} / {1}' -f [int]$rel.ReadErrorsUncorrected, [int]$rel.WriteErrorsUncorrected } else { '—' })
            'Прошивка'        = $pd.FirmwareVersion
        }
        $sum += '{0} {1} {2}' -f $nm, $media, (GB $pd.Size 0)
        if ("$($pd.HealthStatus)" -ne 'Healthy') { Add-Issue 'crit' 'Накопитель' "$nm — состояние: $($pd.HealthStatus)" 'СРОЧНО скопируйте важные данные и замените накопитель.' }
        if ($null -ne $rel.Wear) {
            if ($rel.Wear -ge 90) { Add-Issue 'crit' 'Накопитель' "$nm изношен на $($rel.Wear) %" 'Ресурс SSD почти исчерпан — сделайте резервную копию и замените диск.' }
            elseif ($rel.Wear -ge 70) { Add-Issue 'warn' 'Накопитель' "$nm изношен на $($rel.Wear) %" 'Планируйте замену SSD, держите резервные копии.' }
        }
        if ($rel -and ([int]$rel.ReadErrorsUncorrected -gt 0 -or [int]$rel.WriteErrorsUncorrected -gt 0)) { Add-Issue 'crit' 'Накопитель' "$nm — неисправимые ошибки чтения/записи" 'Признак деградации диска: сделайте резервную копию и проверьте/замените диск.' }
        if ($temp -and $temp -ge 70) { Add-Issue 'warn' 'Накопитель' ('{0} — высокая температура {1:N0} °C в простое' -f $nm, $temp) 'Улучшите обдув, поставьте радиатор на NVMe.' }
        if ($isSys -and $media -eq 'HDD') { Add-Issue 'warn' 'Накопитель' 'Windows установлена на жёсткий диск (HDD)' 'Замена на SSD ускорит загрузку и работу в 3–10 раз — самый заметный апгрейд.' }
        if ("$($pd.BusType)" -eq 'USB') { Add-Issue 'info' 'Накопитель' "$nm подключён по USB" '' }
    }
    foreach ($f in ($fp | Where-Object { $_.PredictFailure })) { Add-Issue 'crit' 'Накопитель' ('SMART предсказывает отказ диска (' + $f.InstanceName + ')') 'СРОЧНО скопируйте данные и замените диск.' }
    Add-Table $s 'Физические диски' $rows
    $G.Summary['Накопители'] = $sum -join '; '
    $G.SysDiskType = ($rows | Where-Object { $_.'Накопитель' -match 'системный' } | Select-Object -First 1).'Тип'

    $vrows = @()
    foreach ($v in (Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveType -eq 'Fixed' -and $_.DriveLetter } | Sort-Object DriveLetter)) {
        $pf = Pct $v.SizeRemaining $v.Size
        $vrows += [pscustomobject]@{ 'Диск' = "$($v.DriveLetter):"; 'Метка' = $v.FileSystemLabel; 'ФС' = $v.FileSystem; 'Объём' = GB $v.Size; 'Свободно' = '{0} ({1} %)' -f (GB $v.SizeRemaining), $pf; 'Состояние' = "$($v.HealthStatus)" }
        $isC = ("$($v.DriveLetter):" -eq $env:SystemDrive)
        if ($v.Size -gt 5GB) {
            if ($pf -lt 5 -or ($isC -and $v.SizeRemaining -lt 5GB)) { Add-Issue 'crit' 'Диск' ('на диске {0}: почти нет места: {1} ({2} %)' -f $v.DriveLetter, (GB $v.SizeRemaining), $pf) 'Освободите место (Очистка диска, удаление ненужного). Без места Windows тормозит и не обновляется.' }
            elseif ($pf -lt 12 -or ($isC -and $v.SizeRemaining -lt 15GB)) { Add-Issue 'warn' 'Диск' ('на диске {0}: мало места: {1} ({2} %)' -f $v.DriveLetter, (GB $v.SizeRemaining), $pf) 'Освободите хотя бы 15–20 % объёма.' }
        }
    }
    Add-Table $s 'Разделы' $vrows
    $trim = (fsutil behavior query DisableDeleteNotify) -join ' '
    if ($trim -match 'NTFS\s+DisableDeleteNotify\s*=\s*(\d)') {
        Add-Row $s 'TRIM для SSD' $(if ($Matches[1] -eq '0') { 'включён' } else { 'ВЫКЛЮЧЕН' }) $(if ($Matches[1] -eq '0') { 'ok' } else { 'warn' })
        if ($Matches[1] -ne '0' -and ($rows | Where-Object { $_.'Тип' -match 'SSD' })) { Add-Issue 'warn' 'Накопитель' 'TRIM выключен' 'Выполните: fsutil behavior set DisableDeleteNotify 0 — иначе SSD со временем замедляется.' }
    }
    try {
        $bl = @(Get-BitLockerVolume -ErrorAction Stop | Where-Object { "$($_.ProtectionStatus)" -eq 'On' } | ForEach-Object { $_.MountPoint })
        Add-Row $s 'Шифрование BitLocker' $(if ($bl.Count) { 'включено на ' + ($bl -join ', ') } else { 'не используется' })
    } catch {}
}

# =====================================================================
Step 'Аккумулятор' {
    $b = CIM Win32_Battery
    if ($b.Count -eq 0) { Info 'аккумулятор не обнаружен (настольный ПК)'; return }
    $s = New-Section 'Аккумулятор'
    $xmlp = Join-Path $G.Temp 'battery.xml'
    $null = powercfg /batteryreport /xml /output "$xmlp" 2>&1
    $stMap = @{ 1 = 'разряжается'; 2 = 'питание от сети'; 3 = 'полностью заряжен'; 4 = 'низкий заряд'; 5 = 'критический заряд'; 6 = 'заряжается'; 7 = 'заряжается'; 8 = 'заряжается'; 9 = 'заряжается'; 11 = 'частично заряжен' }
    Add-Row $s 'Заряд сейчас' ('{0} % — {1}' -f $b[0].EstimatedChargeRemaining, $stMap[[int]$b[0].BatteryStatus])
    if (Test-Path $xmlp) {
        [xml]$x = Get-Content $xmlp -Raw -Encoding UTF8
        $sumB = @()
        foreach ($bt in @($x.BatteryReport.Batteries.Battery)) {
            $d = [double]$bt.DesignCapacity; $f = [double]$bt.FullChargeCapacity
            $h = if ($d -gt 0) { [math]::Round($f / $d * 100, 0) } else { 0 }
            Add-Row $s 'Модель' ('{0} {1} ({2})' -f $bt.Manufacturer, $bt.Id, $bt.Chemistry)
            Add-Row $s 'Ёмкость: заводская / сейчас' ('{0:N0} / {1:N0} мВт·ч' -f $d, $f)
            Add-Row $s 'Здоровье аккумулятора' ("$h % (износ {0} %)" -f (100 - $h)) $(if ($h -ge 80) { 'ok' } elseif ($h -ge 60) { 'warn' } else { 'crit' })
            Add-Row $s 'Циклов заряда' $bt.CycleCount
            $sumB += "здоровье $h %, циклов $($bt.CycleCount)"
            if ($null -eq $G.Num.bat_health) { $G.Num.bat_health = $h; $G.Num.bat_cycles = [int]$bt.CycleCount; $G.Num.bat_design = $d }
            if ($h -lt 50) { Add-Issue 'crit' 'Аккумулятор' "аккумулятор сильно изношен: осталось $h % ёмкости" 'Рекомендуется замена аккумулятора.' }
            elseif ($h -lt 70) { Add-Issue 'warn' 'Аккумулятор' "аккумулятор изношен: осталось $h % ёмкости" 'Время автономной работы заметно снижено, планируйте замену.' }
            elseif ($h -lt 80) { Add-Issue 'info' 'Аккумулятор' "износ аккумулятора: осталось $h % ёмкости" '' }
        }
        $G.Summary['Аккумулятор'] = $sumB -join '; '
    }

    # ---- Зарядка: приходит ли питание и заряжается ли батарея ----
    function BatSt { CIM BatteryStatus 'root/wmi' | Where-Object { $_.Active -ne $false } | Select-Object -First 1 }
    $bs = BatSt
    if ($bs) {
        $pct = [int]$b[0].EstimatedChargeRemaining
        if ($bs.PowerOnline) {
            if (-not $bs.Charging -and $pct -lt 95) { Start-Sleep -Seconds 15; $bs = BatSt }
            $rate = [double]$bs.ChargeRate / 1000
            if ($bs.Charging -and $rate -gt 0) {
                Add-Row $s 'Зарядное устройство' ('подключено, батарея заряжается: {0:N1} Вт' -f $rate) 'ok'
                if ($rate -lt 12 -and $pct -lt 60) { Add-Issue 'info' 'Зарядка' ('аккумулятор заряжается медленно: {0:N1} Вт при заряде {1} %' -f $rate, $pct) 'Возможно, зарядное слабее штатного (неоригинальное/USB-C малой мощности) или ноутбук под нагрузкой. Проверьте мощность на наклейке блока питания.' }
            } elseif ($pct -ge 95) {
                Add-Row $s 'Зарядное устройство' 'подключено, батарея заряжена' 'ok'
            } elseif ($pct -ge 50) {
                Add-Row $s 'Зарядное устройство' "подключено, но батарея не заряжается (заряд $pct %)" 'warn'
                Add-Issue 'info' 'Зарядка' "подключено зарядное устройство, но заряд стоит на $pct %" 'Чаще всего это включённое ограничение заряда для сбережения батареи (60/80 % в утилите производителя: Lenovo Vantage, MyASUS, Dell Power Manager и т. п.) — тогда всё в порядке. Если ограничения нет — проверьте зарядку и разъём.'
            } else {
                Add-Row $s 'Зарядное устройство' "подключено, но батарея НЕ заряжается (заряд $pct %)" 'crit'
                Add-Issue 'crit' 'Зарядка' "батарея не заряжается при подключённой зарядке (заряд $pct %)" 'Проверьте зарядное устройство (другое, той же мощности), разъём питания на ноутбуке и контроллер заряда; если зарядка исправна — аккумулятор или цепь заряда на плате.'
            }
        } else {
            $dis = [double]$bs.DischargeRate / 1000
            Add-Row $s 'Зарядное устройство' ('не подключено{0}' -f $(if ($dis -gt 0) { ', ноутбук потребляет {0:N1} Вт от батареи' -f $dis } else { '' }))
            Add-Issue 'info' 'Зарядка' 'зарядное устройство не было подключено во время проверки' 'Подключите зарядку и запустите проверку ещё раз, чтобы проверить зарядное и цепь заряда.'
        }
    }
}

#%%MOD:hw%%

# =====================================================================
Step 'Устройства и драйверы' {
    $s = New-Section 'Устройства и драйверы'
    $codes = @{ 1 = 'не настроено'; 3 = 'драйвер повреждён или нехватка ресурсов'; 10 = 'не удаётся запустить'; 12 = 'конфликт ресурсов'; 14 = 'нужна перезагрузка'; 18 = 'нужно переустановить драйвер'; 19 = 'ошибка реестра'; 21 = 'удаляется'; 22 = 'отключено'; 24 = 'отсутствует или не работает'; 28 = 'драйвер не установлен'; 29 = 'отключено в BIOS'; 31 = 'работает неправильно'; 32 = 'служба драйвера отключена'; 37 = 'ошибка инициализации драйвера'; 39 = 'драйвер повреждён/отсутствует'; 43 = 'устройство сообщило о сбое'; 47 = 'подготовлено к извлечению'; 48 = 'драйвер заблокирован'; 52 = 'нет цифровой подписи драйвера' }
    $bad = @(CIM Win32_PnPEntity | Where-Object { $_.ConfigManagerErrorCode -and $_.ConfigManagerErrorCode -notin 0, 24, 45 })
    $G.BadDevBefore = @($bad | Where-Object { $_.ConfigManagerErrorCode -ne 22 }).Count
    $brows = @()
    foreach ($d in $bad) {
        $c = [int]$d.ConfigManagerErrorCode
        $nm = if ($d.Name) { Clean $d.Name } else { 'Неизвестное устройство' }
        $brows += [pscustomobject]@{ 'Устройство' = $nm; 'Класс' = $d.PNPClass; 'Проблема' = ('код {0}: {1}' -f $c, $codes[$c]); 'ID' = $d.DeviceID }
        if ($c -eq 22) { Add-Issue 'info' 'Устройства' "$nm — отключено вручную" '' }
        elseif ($c -eq 28 -or $c -eq 1) { Add-Issue 'warn' 'Устройства' "$nm — нет драйвера" $(if ($G.UpdDrivers) { 'Программа поищет драйвер в Windows Update на шаге обновления драйверов.' } else { 'Установите драйвер: Центр обновления Windows → Дополнительные обновления, или найдите по ИД оборудования на catalog.update.microsoft.com / сайте производителя.' }) }
        else { Add-Issue 'warn' 'Устройства' "$nm — $($codes[$c]) (код $c)" 'Переустановите драйвер; при коде 43 проверьте подключение/устройство.' }
    }
    Add-Row $s 'Устройств с проблемами' $G.BadDevBefore $(if ($G.BadDevBefore) { 'warn' } else { 'ok' })
    Add-Table $s 'Проблемные устройства (Диспетчер устройств)' $brows

    $pnp = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.ConfigManagerErrorCode -ne 24 })
    $kb = @($pnp | Where-Object { $_.Class -eq 'Keyboard' })
    $ms = @($pnp | Where-Object { $_.Class -eq 'Mouse' })
    $tp = @($pnp | Where-Object { ($_.Class -in 'Mouse', 'HIDClass') -and $_.FriendlyName -match 'touch ?pad|сенсорн\w* панел|precision|synaptics|elan|alps' })
    $cam = @($pnp | Where-Object { $_.Class -in 'Camera', 'Image' })
    $aud = @($pnp | Where-Object { $_.Class -eq 'AudioEndpoint' })
    $bt = @($pnp | Where-Object { $_.Class -eq 'Bluetooth' -and $_.FriendlyName -notmatch 'Enumerator|перечислител|RFCOMM|LE Generic|Device \(|Avrcp|Hands-?Free|Audio Gateway|Transport|Service' })
    $bio = @($pnp | Where-Object { $_.Class -eq 'Biometric' })
    $net = @($pnp | Where-Object { $_.Class -eq 'Net' -and $_.FriendlyName -notmatch 'WAN Miniport|Минипорт|Kernel Debug|Virtual|Hyper-V|TAP|Wintun|Loopback|Wi-Fi Direct|Bluetooth Device|VPN' })
    $per = @()
    foreach ($pair in @(@('Клавиатура', $kb), @('Мышь / указатель', $ms), @('Тачпад', $tp), @('Камера', $cam), @('Звук (вход/выход)', $aud), @('Bluetooth', $bt), @('Биометрия', $bio), @('Сетевой адаптер', $net))) {
        foreach ($d in $pair[1]) { $per += [pscustomobject]@{ 'Тип' = $pair[0]; 'Устройство' = Clean $d.FriendlyName; 'Состояние' = $(switch ("$($d.Status)") { 'OK' { 'OK' } 'Error' { 'ОШИБКА' } 'Degraded' { 'сбой' } default { "$($d.Status)" } }) } }
    }
    $per = @($per | Group-Object 'Тип', 'Устройство', 'Состояние' | ForEach-Object { $o = $_.Group[0]; if ($_.Count -gt 1) { $o.'Устройство' = '{0} (×{1})' -f $o.'Устройство', $_.Count }; $o })
    Add-Table $s 'Периферия и встроенные устройства' $per
    $G.HasTouchpad = $tp.Count -gt 0
    $G.HasCamera = $cam.Count -gt 0
    $G.MicCount = @($aud | Where-Object { $_.FriendlyName -match 'микрофон|microphone|mic\b|массив' }).Count
    $G.HasMic = $G.MicCount -gt 0
    if ($G.IsLaptop -and -not $G.HasCamera) { Add-Issue 'info' 'Камера' 'веб-камера не обнаружена' 'Проверьте, не выключена ли она клавишей/шторкой или в BIOS.' }
    if ($G.IsLaptop -and -not $G.HasTouchpad -and $ms.Count -eq 0) { Add-Issue 'warn' 'Тачпад' 'тачпад не обнаружен' 'Возможно, отключён клавишей Fn или нет драйвера.' }

    $drv = @(CIM Win32_PnPSignedDriver | Where-Object { $_.DeviceName -and $_.DriverProviderName -and $_.DriverProviderName -notmatch '^Microsoft|^Майкрософт' -and $_.DeviceClass -notmatch '^(VOLUME|VOLUMESNAPSHOT|LEGACYDRIVER|SOFTWARECOMPONENT|PRINTQUEUE)$' -and -not ($G.PawnInstalled -and $_.DeviceName -eq 'PawnIO') })
    $drows = @($drv | Sort-Object DeviceClass, DeviceName | ForEach-Object { [pscustomobject]@{ 'Класс' = $_.DeviceClass; 'Устройство' = Clean $_.DeviceName; 'Поставщик' = Clean $_.DriverProviderName; 'Версия' = $_.DriverVersion; 'Дата' = DT $_.DriverDate; 'Подпись' = $(if ($_.IsSigned) { 'да' } else { 'НЕТ' }) } })
    Add-Table $s ('Драйверы сторонних производителей ({0})' -f $drows.Count) $drows -Collapsed
    $unsigned = @($drv | Where-Object { -not $_.IsSigned })
    if ($unsigned.Count) { Add-Issue 'warn' 'Драйверы' ('неподписанные драйверы: ' + (($unsigned | ForEach-Object { Clean $_.DeviceName } | Select-Object -Unique) -join ', ')) 'Неподписанные драйверы могут вызывать сбои; замените на официальные.' }
}

# =====================================================================
Step 'Установленные программы' {
    $s = New-Section 'Программы'
    $keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    $apps = @(Get-ItemProperty $keys -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -and $_.SystemComponent -ne 1 -and -not $_.ParentKeyName -and "$($_.ReleaseType)" -notmatch 'Update|Hotfix' } | Sort-Object DisplayName -Unique)
    $rows = @()
    foreach ($a in $apps) {
        $d = $null
        if ("$($a.InstallDate)" -match '^(\d{4})(\d{2})(\d{2})$') { try { $d = Get-Date -Year $Matches[1] -Month $Matches[2] -Day $Matches[3] } catch {} }
        $rows += [pscustomobject]@{
            'Программа'   = Clean $a.DisplayName
            'Версия'      = Clean $a.DisplayVersion
            'Издатель'    = Clean $a.Publisher
            'Установлена' = $(if ($d) { $d.ToString('dd.MM.yyyy') } else { '' })
            'Размер'      = $(if ($a.EstimatedSize) { '{0:N0} МБ' -f ($a.EstimatedSize / 1024) } else { '' })
            _Date         = $d
            _Size         = [double]$a.EstimatedSize
        }
    }
    Add-Row $s 'Всего установлено программ' $rows.Count
    $store = @()
    try { $store = @(Get-AppxPackage -ErrorAction Stop | Where-Object { -not $_.IsFramework -and "$($_.SignatureKind)" -eq 'Store' -and $_.Name -notmatch '^Microsoft\.(VCLibs|NET|UI\.Xaml|Services|DesktopAppInstaller|WindowsAppRuntime)' }) } catch {}
    if ($store.Count) { Add-Row $s 'Приложений из Microsoft Store' $store.Count }
    $recent = @($rows | Where-Object { $_._Date -and ((Get-Date) - $_._Date).TotalDays -le 30 })
    Add-Row $s 'Установлено за последние 30 дней' $(if ($recent.Count) { '{0}: {1}' -f $recent.Count, (($recent | ForEach-Object { $_.'Программа' }) -join ', ') } else { '0' })
    $big = @($rows | Where-Object { $_._Size -gt 0 } | Sort-Object _Size -Descending | Select-Object -First 8)
    Add-Row $s 'Самые большие' (($big | ForEach-Object { '{0} ({1})' -f $_.'Программа', $_.'Размер' }) -join '; ')
    $browsers = @($rows | Where-Object { $_.'Программа' -match '^(Google Chrome|Mozilla Firefox|Opera|Yandex|Яндекс|Microsoft Edge$|Brave|Vivaldi|Tor Browser|Arc)' } | ForEach-Object { $_.'Программа' })
    if ($browsers.Count) { Add-Row $s 'Браузеры' ($browsers -join ', ') }
    $games = @($rows | Where-Object { $_.'Программа' -match '^(Steam|Epic Games Launcher|EA app|Ubisoft Connect|Battle\.net|GOG GALAXY|Riot Client|VK Play|Lesta Game Center|Wargaming)' } | ForEach-Object { $_.'Программа' })
    if ($games.Count) { Add-Row $s 'Игровые лаунчеры' ($games -join ', ') }

    $pup = 'Driver ?Booster|DriverPack|Driver ?Easy|Driver ?Genius|Advanced ?SystemCare|IObit Malware|Smart Defrag|Reimage|Restoro|Fortect|PC ?Accelerate|Speedy ?PC|Segurazo|SAntivirus|ByteFence|Web ?Companion|OneLaunch|Wave ?Browser|Shift ?Browser|PC App Store|Baidu|Tencent|360 Total|Amigo|Амиго|Guard\.Mail|Mail\.Ru Agent|MediaGet|Ускоритель компьютера|Auslogics BoostSpeed|WinZip (Driver|System)|Avast Cleanup|AVG TuneUp|McAfee WebAdvisor|Search ?Protect|Conduit|Ask Toolbar|Hola|RAM Saver|Memory Optimizer|Mem Reduct|Wise Memory|Razer Cortex|Glary|Clean Master|SlimCleaner|WinOptimizer|PC Cleaner|System Mechanic|Carambis|Ускоритель'
    $remote = 'AnyDesk|TeamViewer|RustDesk|Ammyy|Remote Manipulator|LiteManager|Radmin|Supremo|UltraViewer|AeroAdmin|Splashtop|Chrome Remote Desktop|RemotePC|ScreenConnect|DWService|RMS Host|RMS Viewer'
    $old = 'Adobe Flash|Silverlight|QuickTime|Java\(TM\) [67]|Java [67] Update|Adobe Reader (X|[7-9])'
    $flag = @()
    foreach ($r in $rows) {
        $n = $r.'Программа'
        if ($n -match $pup) { $flag += [pscustomobject]@{ 'Программа' = $n; 'Почему' = 'нежелательная/рекламная или бесполезная «оптимизирующая» программа'; 'Совет' = 'удалить' } }
        elseif ($n -match $remote) { $flag += [pscustomobject]@{ 'Программа' = $n; 'Почему' = 'программа удалённого доступа'; 'Совет' = 'если ставили не вы — удалите (часто используется мошенниками)' } }
        elseif ($n -match '^(µTorrent|uTorrent|BitTorrent)') { $flag += [pscustomobject]@{ 'Программа' = $n; 'Почему' = 'показывает рекламу, в установщиках бывают нежелательные «довески»'; 'Совет' = 'заменить на qBittorrent (бесплатный, без рекламы)' } }
        elseif ($n -match $old) { $flag += [pscustomobject]@{ 'Программа' = $n; 'Почему' = 'устаревшая, с известными уязвимостями'; 'Совет' = 'удалить или обновить' } }
    }
    Add-Table $s 'Программы, на которые стоит обратить внимание' $flag
    $np = @($flag | Where-Object { $_.'Совет' -eq 'удалить' })
    if ($np.Count) { Add-Issue 'warn' 'Программы' ('нежелательные программы: ' + (($np | ForEach-Object { $_.'Программа' }) -join ', ')) 'Удалите через Параметры → Приложения. Они тормозят систему и показывают рекламу.' }
    $ra = @($flag | Where-Object { $_.'Почему' -match 'удалённого' })
    if ($ra.Count) { Add-Issue 'info' 'Программы' ('установлены программы удалённого доступа: ' + (($ra | ForEach-Object { $_.'Программа' }) -join ', ')) 'Убедитесь, что их ставили вы. Никогда не давайте доступ незнакомым «специалистам банка/поддержки».' }
    $ov = @($flag | Where-Object { $_.'Почему' -match 'устаревшая' })
    if ($ov.Count) { Add-Issue 'warn' 'Программы' ('устаревшие уязвимые программы: ' + (($ov | ForEach-Object { $_.'Программа' }) -join ', ')) 'Удалите или обновите.' }

    $strows = @(CIM Win32_StartupCommand | ForEach-Object { [pscustomobject]@{ 'Программа' = Clean $_.Name; 'Команда' = Clean $_.Command; 'Где' = Clean $_.Location } })
    Add-Row $s 'Программ в автозагрузке' $strows.Count $(if ($strows.Count -gt 15) { 'warn' } else { '' })
    Add-Table $s 'Автозагрузка' $strows
    if ($strows.Count -gt 15) { Add-Issue 'warn' 'Программы' ('в автозагрузке {0} программ' -f $strows.Count) 'Отключите лишнее: Диспетчер задач → Автозагрузка. Это ускорит включение.' }
    $top = @(Get-Process -ErrorAction SilentlyContinue | Group-Object ProcessName | ForEach-Object { [pscustomobject]@{ N = $_.Name; M = ($_.Group | Measure-Object WorkingSet64 -Sum).Sum } } | Sort-Object M -Descending | Select-Object -First 8)
    Add-Row $s 'Больше всего памяти сейчас занимают' (($top | ForEach-Object { '{0} ({1:N0} МБ)' -f $_.N, ($_.M / 1MB) }) -join ', ')
    Add-Table $s ('Полный список программ ({0})' -f $rows.Count) ($rows | Sort-Object 'Программа' | Select-Object 'Программа', 'Версия', 'Издатель', 'Установлена', 'Размер') -Collapsed
    $G.Summary['Программы'] = '{0} установлено, {1} в автозагрузке{2}' -f $rows.Count, $strows.Count, $(if ($flag.Count) { ", требуют внимания: $($flag.Count)" } else { '' })
}

# =====================================================================
Step 'Журналы ошибок за 30 дней' {
    $s = New-Section 'Журналы ошибок (30 дней)'
    function Ev($prov, $ids, $lvl = $null, $days = 30) {
        $f = @{ LogName = 'System'; ProviderName = $prov; StartTime = (Get-Date).AddDays(-$days) }
        if ($ids) { $f.Id = $ids }
        if ($lvl) { $f.Level = $lvl }
        try { return @(Get-WinEvent -FilterHashtable $f -ErrorAction Stop) } catch { return @() }
    }
    $kp = Ev 'Microsoft-Windows-Kernel-Power' 41
    $bsod = @(Ev 'Microsoft-Windows-WER-SystemErrorReporting' 1001) + @(Ev 'BugCheck' 1001)
    $wheaE = Ev 'Microsoft-Windows-WHEA-Logger' $null @(1, 2)
    $wheaW = Ev 'Microsoft-Windows-WHEA-Logger' $null 3
    $disk = @(Ev 'disk' @(7, 11, 51, 153)) + @(Ev 'Microsoft-Windows-StorPort' 129) + @(Ev 'stornvme' 11)
    $ntfs = @(Ev 'Microsoft-Windows-Ntfs' 55) + @(Ev 'Ntfs' 55)
    $tdr = Ev 'Display' 4101
    $bugs = @($bsod | ForEach-Object { if ($_.Message -match '0x[0-9a-fA-F]{8}') { $Matches[0] } } | Select-Object -Unique)
    Add-Row $s 'Синие экраны (BSOD)' ($bsod.Count.ToString() + $(if ($bugs.Count) { ' — коды: ' + ($bugs -join ', ') } else { '' })) $(if ($bsod.Count) { 'crit' } else { 'ok' })
    Add-Row $s 'Внезапные выключения/перезагрузки' $kp.Count $(if ($kp.Count -ge 3) { 'warn' } else { 'ok' })
    Add-Row $s 'Аппаратные ошибки WHEA (критические / исправленные)' ('{0} / {1}' -f $wheaE.Count, $wheaW.Count) $(if ($wheaE.Count) { 'crit' } elseif ($wheaW.Count -gt 20) { 'warn' } else { 'ok' })
    Add-Row $s 'Ошибки дисков' $disk.Count $(if ($disk.Count) { 'warn' } else { 'ok' })
    Add-Row $s 'Повреждения файловой системы' $ntfs.Count $(if ($ntfs.Count) { 'warn' } else { 'ok' })
    Add-Row $s 'Сбои драйвера видеокарты (TDR)' $tdr.Count $(if ($tdr.Count) { 'warn' } else { 'ok' })
    # вывод и виновник синих экранов — в шаге «Синие экраны: разбор дампов» (модуль logs-10-bsod)
    # Разбор каждого внезапного выключения (Kernel-Power 41): что именно произошло
    if ($kp.Count) {
        $kinds = @{ power = 0; button = 0; bsod = 0; sleep = 0 }
        $krows = @()
        $times = @($kp | ForEach-Object { $_.TimeCreated } | Sort-Object)
        foreach ($e in ($kp | Sort-Object TimeCreated -Descending)) {
            $d = @{}
            try { foreach ($n in ([xml]$e.ToXml()).Event.EventData.Data) { $d[$n.Name] = "$($n.'#text')" } } catch {}
            $bc = 0L; [void][int64]::TryParse($d['BugcheckCode'], [ref]$bc)
            $pb = 0L; [void][int64]::TryParse($d['PowerButtonTimestamp'], [ref]$pb)
            $sl = 0L; [void][int64]::TryParse($d['SleepInProgress'], [ref]$sl)
            if ($bc -ne 0) { $k = 'bsod'; $txt = 'синий экран (код 0x{0:X})' -f $bc }
            elseif ($pb -ne 0 -or $d['LongPowerButtonPressDetected'] -eq 'true') { $k = 'button'; $txt = 'завис — выключен удержанием кнопки питания' }
            elseif ($sl -ne 0) { $k = 'sleep'; $txt = 'сбой при уходе в сон / выходе из сна' }
            else { $k = 'power'; $txt = 'резко пропало питание (без зависания и синего экрана)' }
            $kinds[$k]++
            $near = @($times | Where-Object { $_ -ne $e.TimeCreated -and [math]::Abs(($_ - $e.TimeCreated).TotalMinutes) -le 20 }).Count
            $krows += [pscustomobject]@{ 'Время (запись при загрузке)' = $e.TimeCreated.ToString('dd.MM.yyyy HH:mm'); 'Что произошло' = $txt + $(if ($near) { ' · серия сбоев подряд' } else { '' }) }
        }
        Add-Table $s 'Внезапные выключения: разбор' $krows
        $G.Shutdowns = $kinds
        $ups = @(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -match '(?i)winpower|powerchute|viewpower|upsilon|powermaster|ups ?monitor|powercom|ippon|eaton|ИБП' } | ForEach-Object { $_.DisplayName } | Select-Object -Unique)
        $parts = @(); foreach ($kv in @(@('power', 'пропадание питания'), @('button', 'зависание'), @('bsod', 'синий экран'), @('sleep', 'сбой сна'))) { if ($kinds[$kv[0]]) { $parts += '{0}: {1}' -f $kv[1], $kinds[$kv[0]] } }
        Add-Row $s 'Причины выключений' ($parts -join ', ')
        if ($G.UnsafeShutdowns) { Add-Row $s 'Системный SSD зафиксировал аварийных отключений питания (за всё время)' $G.UnsafeShutdowns }
        if ($kp.Count -ge 3) {
            $main = ($kinds.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1).Key
            $fix = switch ($main) {
                'power' {
                    $f = 'Компьютер выключается так, будто выдернули шнур — это питание, а не Windows. Если выключается в играх/под нагрузкой — скорее всего блок питания (слабый или изношенный); если в простое — розетка, удлинитель, кабель питания, перепады сети.'
                    if ($ups.Count) { $f += " Установлено ПО ИБП ($($ups -join ', ')): проверьте аккумулятор ИБП (самотест) и не перегружен ли он — мощная видеокарта под нагрузкой может превышать его мощность." }
                    if ($G.IsLaptop) { $f += ' У ноутбука — аккумулятор и разъём/кабель зарядки.' }
                    $f }
                'button' { 'Компьютер зависал намертво и его выключали кнопкой. Частые причины: перегрев, нестабильная память (XMP/разгон), драйвер видеокарты, сбоящий диск.' }
                'bsod' { 'Выключения из-за синих экранов: смотрите коды ошибок выше — по ним находится драйвер или устройство-виновник.' }
                'sleep' { 'Сбои при сне/пробуждении: обновите BIOS, драйвер чипсета и видеокарты; можно отключить быстрый запуск и гибридный сон.' }
            }
            Add-Issue $(if ($kp.Count -ge 10) { 'crit' } else { 'warn' }) 'Стабильность' ('внезапных выключений за 30 дней: {0} ({1})' -f $kp.Count, ($parts -join ', ')) $fix
        }
    }
    if ($wheaE.Count) { Add-Issue 'crit' 'Оборудование' "критические аппаратные ошибки WHEA: $($wheaE.Count)" 'Признак сбоя процессора, памяти или PCIe-устройства. Уберите разгон, проверьте память.' }
    elseif ($wheaW.Count -gt 20) { Add-Issue 'warn' 'Оборудование' "исправленных аппаратных ошибок WHEA: $($wheaW.Count)" 'Часто это PCIe (видеокарта/NVMe) — обновите BIOS и драйвер чипсета.' }
    if ($disk.Count) { Add-Issue 'warn' 'Накопитель' "ошибки дисковой подсистемы в журнале: $($disk.Count)" 'Проверьте кабели/разъём, обновите прошивку SSD, сделайте резервную копию.' }
    if ($ntfs.Count) { Add-Issue 'warn' 'Диск' 'обнаружены повреждения файловой системы' 'Выполните chkdsk C: /f (с перезагрузкой).' }
    if ($tdr.Count) { Add-Issue 'warn' 'Видеокарта' ('драйвер видеокарты сбоил {0} раз' -f $tdr.Count) 'Обновите драйвер видеокарты, проверьте температуру и разгон.' }
    # коды MemoryDiagnostics-Results: 1101/1201 — ошибок нет, 1102/1202 — ошибки, 1103 — отменена, 1104 — не завершена
    $mres = @(Ev 'Microsoft-Windows-MemoryDiagnostics-Results' @(1101, 1102, 1103, 1104, 1201, 1202) $null 365 | Sort-Object TimeCreated -Descending)
    if ($mres.Count) {
        $last = $mres[0]
        $mdTxt = switch ($last.Id) { { $_ -in 1101, 1201 } { 'ошибок нет' } { $_ -in 1102, 1202 } { 'НАЙДЕНЫ ОШИБКИ' } 1103 { 'отменена' } default { 'не завершилась' } }
        $ok = $last.Id -in 1101, 1201
        Add-Row $s 'Последняя проверка памяти Windows' ('{0}: {1}' -f (DT $last.TimeCreated), $mdTxt) $(if ($ok) { 'ok' } elseif ($last.Id -in 1102, 1202) { 'crit' } else { 'warn' })
        # свежий результат после планирования уже выдан шагом 'Результат проверки памяти Windows' — не дублируем
        if ($last.Id -in 1102, 1202 -and -not $G.MemDiagReported) { Add-Issue 'crit' 'Память' 'Windows Memory Diagnostic нашёл ошибки оперативной памяти' 'Проверьте планки по одной (MemTest86), замените сбойную.' }
    }
    $all = @($bsod) + @($kp) + @($wheaE) + @($disk) + @($tdr)
    $crow = @($all | Sort-Object TimeCreated -Descending | Select-Object -First 25 | ForEach-Object {
            $msg = Clean $_.Message; if ($msg.Length -gt 220) { $msg = $msg.Substring(0, 220) + '…' }
            [pscustomobject]@{ 'Время' = $_.TimeCreated.ToString('dd.MM.yyyy HH:mm'); 'Источник' = $_.ProviderName; 'Код' = $_.Id; 'Сообщение' = $msg } })
    Add-Table $s 'Последние важные события' $crow -Collapsed
}

#%%MOD:logs%%

# =====================================================================
Step 'Сеть и интернет' {
    $s = New-Section 'Сеть и интернет'
    $ad = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue)
    $ar = @($ad | ForEach-Object { [pscustomobject]@{ 'Адаптер' = Clean $_.InterfaceDescription; 'Имя' = $_.Name; 'Состояние' = $(if ($_.Status -eq 'Up') { 'подключён' } else { "$($_.Status)" }); 'Скорость' = $_.LinkSpeed; 'MAC' = $_.MacAddress; 'Драйвер' = '{0} от {1}' -f $_.DriverVersion, (DT $_.DriverDate) } })
    Add-Table $s 'Сетевые адаптеры' $ar
    foreach ($e in @($ad | Where-Object { $_.Status -eq 'Up' -and "$($_.PhysicalMediaType)" -match '802\.3' })) {
        if ($e.LinkSpeed -match '^(10|100) Mbps') { Add-Issue 'warn' 'Сеть' ('проводное подключение работает на {0}' -f $e.LinkSpeed) 'Обычно это плохой/старый кабель (нужен Cat5e+) или порт роутера. Норма — 1 Гбит/с и выше.' }
    }
    $wi = (netsh wlan show interfaces 2>$null) -join "`n"
    $wd = (netsh wlan show drivers 2>$null) -join "`n"
    if ($wd -match '802\.11') {
        $sup = @([regex]::Matches($wd, '802\.11[a-z]{1,2}') | ForEach-Object { $_.Value } | Select-Object -Unique)
        $gen = if ($sup -contains '802.11be') { 'Wi-Fi 7' } elseif ($sup -contains '802.11ax') { 'Wi-Fi 6/6E' } elseif ($sup -contains '802.11ac') { 'Wi-Fi 5' } elseif ($sup -contains '802.11n') { 'Wi-Fi 4' } else { 'устаревший' }
        Add-Row $s 'Wi-Fi адаптер поддерживает' ('{0} ({1})' -f $gen, ($sup -join ', '))
        if ($wi -match '(?m)^\s*SSID\s*:\s*(.+)$') {
            $ssid = $Matches[1].Trim()
            $sig = if ($wi -match '(?m)^\s*(Signal|Сигнал)\s*:\s*(\d+)\s*%') { [int]$Matches[2] } else { $null }
            $radio = if ($wi -match '(802\.11[a-z]{1,2})') { $Matches[1] } else { '' }
            $ch = if ($wi -match '(?m)^\s*(Channel|Канал)\s*:\s*(\d+)') { [int]$Matches[2] } else { $null }
            $rx = if ($wi -match '(?m)^\s*(Receive rate|Скорость при[её]ма)[^:]*:\s*([\d\.,]+)') { $Matches[2] } else { '' }
            $band = if ($ch) { if ($ch -le 14) { '2,4 ГГц' } elseif ($wi -match '6 ?G[Hh]z|6 ГГц') { '6 ГГц' } else { '5 ГГц' } } else { '' }
            Add-Row $s 'Wi-Fi подключение' ('«{0}», {1}, канал {2} ({3}), сигнал {4} %, скорость соединения {5} Мбит/с' -f $ssid, $radio, $ch, $band, $sig, $rx) $(if ($sig -ge 60) { 'ok' } elseif ($sig -ge 40) { 'warn' } else { 'crit' })
            if ($null -ne $sig -and $sig -lt 40) { Add-Issue 'warn' 'Wi-Fi' "слабый сигнал Wi-Fi: $sig %" 'Подойдите ближе к роутеру, уберите препятствия или поставьте усилитель/mesh.' }
            if ($band -eq '2,4 ГГц' -and ($sup -contains '802.11ac' -or $sup -contains '802.11ax')) { Add-Issue 'info' 'Wi-Fi' 'подключение в диапазоне 2,4 ГГц, хотя адаптер умеет 5 ГГц' 'Подключитесь к 5 ГГц-сети роутера — скорость будет в разы выше.' }
        }
    }
    $gw = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object RouteMetric | Select-Object -First 1).NextHop
    $pr = @(); $inet = $false
    foreach ($h in @($gw, '1.1.1.1', '8.8.8.8', 'ya.ru') | Where-Object { $_ }) {
        $p = New-Object System.Net.NetworkInformation.Ping
        $t = @()
        for ($i = 0; $i -lt 10; $i++) { try { $r = $p.Send($h, 1500); if ($r.Status -eq 'Success') { $t += [int]$r.RoundtripTime } } catch {}; Start-Sleep -Milliseconds 150 }
        $loss = [math]::Round(100 * (10 - $t.Count) / 10)
        $avg = if ($t.Count) { [math]::Round(($t | Measure-Object -Average).Average, 1) } else { $null }
        $jit = if ($t.Count -gt 1) { [math]::Round(((1..($t.Count - 1)) | ForEach-Object { [math]::Abs($t[$_] - $t[$_ - 1]) } | Measure-Object -Average).Average, 1) } else { 0 }
        $isGw = ($h -eq $gw)
        if (-not $isGw -and $t.Count) { $inet = $true }
        $pr += [pscustomobject]@{ 'Узел' = $(if ($isGw) { "$h (роутер)" } else { $h }); 'Пинг, мс' = $(if ($null -ne $avg) { $avg } else { 'нет ответа' }); 'Разброс, мс' = $jit; 'Потери' = "$loss %" }
        if ($isGw -and $null -ne $avg -and $avg -gt 15) { Add-Issue 'warn' 'Сеть' ('большая задержка до роутера: {0} мс' -f $avg) 'Норма — 1–5 мс. Причина обычно в слабом/загруженном Wi-Fi.' }
        if ($loss -gt 0 -and $loss -lt 100) { Add-Issue 'warn' 'Сеть' ('потери пакетов до {0}: {1} %' -f $h, $loss) 'Нестабильная связь: проверьте Wi-Fi/кабель/провайдера.' }
    }
    Add-Table $s 'Задержка (пинг)' $pr
    try { $sw = [Diagnostics.Stopwatch]::StartNew(); [void][Net.Dns]::GetHostAddresses('ya.ru'); $dnsMs = $sw.ElapsedMilliseconds; Add-Row $s 'Время ответа DNS' "$dnsMs мс" $(if ($dnsMs -gt 300) { 'warn' } else { 'ok' }); $inet = $true } catch { Add-Row $s 'DNS' 'не работает' 'crit' }
    if (-not $inet) { Add-Issue 'crit' 'Интернет' 'нет доступа в интернет' 'Проверьте подключение к роутеру и работу провайдера.'; return }
    if ($G.SpeedtestOk) { Add-Row $s 'Скорость интернета' 'см. раздел «Сеть: скорость интернета (Speedtest by Ookla)»' }
    else {
        $mbps = $null; $src = ''
        foreach ($u in 'https://speed.cloudflare.com/__down?bytes=200000000', 'https://proof.ovh.net/files/100Mb.dat', 'http://speedtest.tele2.net/100MB.zip') {
            try {
                $req = [Net.HttpWebRequest]::Create($u); $req.Timeout = 15000; $req.ReadWriteTimeout = 15000; $req.UserAgent = 'Mozilla/5.0'
                $resp = $req.GetResponse(); $st = $resp.GetResponseStream()
                $buf = New-Object byte[] 262144; $total = 0; $sw = [Diagnostics.Stopwatch]::StartNew()
                while (($n = $st.Read($buf, 0, $buf.Length)) -gt 0) { $total += $n; if ($sw.Elapsed.TotalSeconds -gt 12) { break } }
                $sec = $sw.Elapsed.TotalSeconds; $resp.Close()
                if ($total -gt 2MB) { $mbps = [math]::Round($total * 8 / 1e6 / $sec, 1); $src = ([uri]$u).Host; break }
            } catch {}
        }
        if ($mbps) {
            Add-Row $s 'Скорость загрузки' ('{0} Мбит/с (сервер {1})' -f $mbps, $src)
            $G.Summary['Интернет'] = '{0} Мбит/с' -f $mbps
            $G.Bench['Интернет, загрузка'] = '{0} Мбит/с' -f $mbps
        } else { Add-Row $s 'Скорость загрузки' 'измерить не удалось' }
        Add-Row $s 'Примечание' 'Скорость ограничена тарифом, Wi-Fi и VPN. Тестовый сервер за рубежом — в РФ результат может быть ниже реального.'
    }
}

# =====================================================================
Step 'Тесты с вашим участием' {
    if (-not $G.Interactive) { Info 'пропущено по вашему выбору'; return }
    if (-not $G.UiOk) { Warn 'модуль окон не загрузился — тесты невозможны'; return }
    $s = New-Section 'Проверки с участием пользователя'
    if ($G.Sel.kbd) {
    Say '  Откроется окно проверки клавиатуры, мыши и тачпада...' 'White'
    $f = New-Object DiagInputForm($G.HasTouchpad)
    [void]$f.ShowDialog()
    $vmap = @{ ok = 'работает'; bad = 'ЕСТЬ ПРОБЛЕМЫ'; none = 'нет устройства'; skip = 'не отмечено' }
    Add-Row $s 'Клавиатура' ('{0}; нажато {1} из {2} клавиш' -f $vmap[$f.KeyboardVerdict], $f.PressedKeys, $f.TotalKeys) $(if ($f.KeyboardVerdict -eq 'ok') { 'ok' } elseif ($f.KeyboardVerdict -eq 'bad') { 'crit' } else { '' })
    if ($f.PressedKeys -lt $f.TotalKeys) { Add-Row $s 'Не нажимались клавиши' $f.Untested() }
    Add-Row $s 'Мышь' ('{0}; кнопки: {1}; прокрутка вверх {2} / вниз {3}' -f $vmap[$f.MouseVerdict], $f.ButtonsText(), $f.WheelUp, $f.WheelDown) $(if ($f.MouseVerdict -eq 'ok') { 'ok' } elseif ($f.MouseVerdict -eq 'bad') { 'crit' } else { '' })
    Add-Row $s 'Тачпад' ('{0}; горизонтальная прокрутка: {1}' -f $vmap[$f.TouchpadVerdict], $f.HWheel) $(if ($f.TouchpadVerdict -eq 'ok') { 'ok' } elseif ($f.TouchpadVerdict -eq 'bad') { 'crit' } else { '' })
    if ($f.Comment) { Add-Row $s 'Комментарий пользователя' $f.Comment }
    if ($f.KeyboardVerdict -eq 'bad') { Add-Issue 'crit' 'Клавиатура' ('пользователь отметил проблемы с клавиатурой' + $(if ($f.Comment) { ': ' + $f.Comment } else { '' })) 'Проверьте клавиши из списка «не нажимались»; после залития — чистка или замена клавиатуры.' }
    if ($f.MouseVerdict -eq 'bad') { Add-Issue 'warn' 'Мышь' 'пользователь отметил проблемы с мышью' 'Проверьте на другом USB-порту/с другой мышью.' }
    if ($f.TouchpadVerdict -eq 'bad') { Add-Issue 'warn' 'Тачпад' 'пользователь отметил проблемы с тачпадом' 'Проверьте драйвер тачпада и не выключен ли он клавишей Fn.' }
    $f.Dispose()
    }

    if ($G.Sel.screen -and ([DiagUi]::Ask("Проверка экрана: экран по очереди зальётся 6 цветами.`nОсмотрите его на битые пиксели, полосы и пятна.`n`nНачать?", 'Проверка экрана', $true)) -eq 'yes') {
        $r = [DiagUi]::ScreenTest()
        Add-Row $s 'Экран (битые пиксели, засветы)' $(switch ($r) { 'ok' { 'дефектов не замечено' } 'bad' { 'ЗАМЕЧЕНЫ ДЕФЕКТЫ' } default { 'проверка прервана' } }) $(if ($r -eq 'ok') { 'ok' } elseif ($r -eq 'bad') { 'crit' } else { '' })
        if ($r -eq 'bad') { Add-Issue 'warn' 'Экран' 'пользователь заметил дефекты экрана (битые пиксели/полосы/засветы)' 'Если экран на гарантии — обратитесь в сервис.' }
    }

    if ($G.Sel.sound -and ([DiagUi]::Ask("Проверка динамиков: сделайте громкость около 50 % и нажмите OK.`nПрозвучит сигнал сначала СЛЕВА, потом СПРАВА.", 'Проверка звука', $false)) -eq 'yes') {
        try {
            foreach ($ch in 0, 1) {
                $bytes = [DiagCore]::MakeTone($(if ($ch -eq 0) { 523 } else { 784 }), 1300, $ch)
                $sp = New-Object System.Media.SoundPlayer -ArgumentList (New-Object IO.MemoryStream -ArgumentList (, $bytes))
                $sp.PlaySync(); Start-Sleep -Milliseconds 300
            }
            if (([DiagUi]::Ask('Вы слышали ОБА сигнала — и слева, и справа?', 'Проверка звука', $true)) -eq 'yes') { Add-Row $s 'Динамики' 'оба канала работают' 'ok' }
            elseif (([DiagUi]::Ask('Слышали хотя бы один сигнал?', 'Проверка звука', $true)) -eq 'yes') { Add-Row $s 'Динамики' 'РАБОТАЕТ ТОЛЬКО ОДИН КАНАЛ' 'warn'; Add-Issue 'warn' 'Звук' 'звук слышен только с одной стороны' 'Проверьте баланс в настройках звука; если он в порядке — неисправен динамик.' }
            else { Add-Row $s 'Динамики' 'ЗВУКА НЕТ' 'crit'; Add-Issue 'crit' 'Звук' 'звук не воспроизводится' 'Проверьте устройство вывода по умолчанию, громкость и драйвер звука; затем — динамики.' }
        } catch { Add-Row $s 'Динамики' ('не удалось воспроизвести звук: ' + $_.Exception.Message) 'crit'; Add-Issue 'crit' 'Звук' 'не удалось воспроизвести звук' 'Нет устройства вывода звука или не работает драйвер.' }
    }

    if ($G.Sel.mic -and $G.HasMic) {
        if (([DiagUi]::Ask('Проверка микрофона: после нажатия OK в течение 5 секунд говорите что-нибудь обычным голосом.', 'Проверка микрофона', $false)) -eq 'yes') {
            $wav = Join-Path $G.Temp 'mic.wav'
            $lvl = [DiagCore]::RecordLevel(5000, $wav)
            if ($lvl -ge 0 -and $lvl -lt 0.008 -and ([DiagUi]::Ask(("Голос не уловлен (записывается микрофон по умолчанию; найдено микрофонов: {0}).`nВыберите нужный: Параметры → Система → Звук → Ввод, проверьте кнопку отключения на гарнитуре.`nПопробовать ещё раз?" -f $G.MicCount), 'Проверка микрофона', $true)) -eq 'yes') {
                [void][DiagUi]::Ask('После нажатия OK в течение 5 секунд говорите что-нибудь обычным голосом.', 'Проверка микрофона', $false)
                $lvl = [DiagCore]::RecordLevel(5000, $wav)
            }
            if ($lvl -lt 0) { Add-Row $s 'Микрофон' 'записать звук не удалось' 'crit'; Add-Issue 'warn' 'Микрофон' 'не удалось записать звук' 'Проверьте: Параметры → Конфиденциальность → Микрофон → «Разрешить классическим приложениям доступ к микрофону».' }
            else {
                $p = [math]::Round($lvl * 100, 1)
                if ($lvl -ge 0.03) {
                    [void][DiagUi]::Ask('Голос записан. Нажмите OK — прозвучит ваша запись.', 'Проверка микрофона', $false)
                    try { (New-Object System.Media.SoundPlayer $wav).PlaySync() } catch {}
                    $good = ([DiagUi]::Ask('Запись звучит нормально (без хрипов, треска, не слишком тихо)?', 'Проверка микрофона', $true)) -eq 'yes'
                    Add-Row $s 'Микрофон' ('работает, уровень {0} %{1}' -f $p, $(if ($good) { '' } else { ', но качество записи плохое' })) $(if ($good) { 'ok' } else { 'warn' })
                    if (-not $good) { Add-Issue 'warn' 'Микрофон' 'пользователь отметил плохое качество записи микрофона' 'Проверьте драйвер звука и эффекты/шумоподавление.' }
                } elseif ($lvl -ge 0.008) { Add-Row $s 'Микрофон' "очень тихий (уровень $p %)" 'warn'; Add-Issue 'warn' 'Микрофон' 'микрофон очень тихий' 'Увеличьте громкость/усиление микрофона в настройках звука.' }
                else { Add-Row $s 'Микрофон' "звук не уловлен (уровень $p %)" 'warn'; Add-Issue 'warn' 'Микрофон' 'микрофон по умолчанию не уловил голос' $(if ($G.MicCount -gt 1) { "Микрофонов в системе: $($G.MicCount). Скорее всего, по умолчанию выбран не тот (например, пустой разъём на плате): Параметры → Система → Звук → Ввод." } else { 'Возможно, выключен кнопкой, заглушён или не подключён.' }) }
            }
        }
    } elseif ($G.Sel.mic) { Add-Row $s 'Микрофон' 'не обнаружен' }

    if ($G.Sel.cam -and $G.HasCamera) {
        if (([DiagUi]::Ask("Проверить веб-камеру? Откроется приложение «Камера».`nУбедитесь, что есть изображение, затем ЗАКРОЙТЕ приложение.", 'Проверка камеры', $true)) -eq 'yes') {
            try {
                Start-Process 'microsoft.windows.camera:' -ErrorAction Stop
                Start-Sleep -Seconds 3
                $okc = ([DiagUi]::Ask('Камера показывала изображение?', 'Проверка камеры', $true)) -eq 'yes'
                Add-Row $s 'Веб-камера' $(if ($okc) { 'работает' } else { 'НЕТ ИЗОБРАЖЕНИЯ' }) $(if ($okc) { 'ok' } else { 'crit' })
                if (-not $okc) { Add-Issue 'warn' 'Камера' 'камера не показывает изображение' 'Проверьте шторку/клавишу отключения камеры, разрешения (Параметры → Конфиденциальность → Камера) и драйвер.' }
                Get-Process WindowsCamera -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            } catch { Add-Row $s 'Веб-камера' 'не удалось открыть приложение «Камера»' }
        }
    }
}

# =====================================================================
Step 'Процессор: бенчмарки и стресс-тест' {
    $s = New-Section 'Тест процессора'
    if (-not $G.CoreOk) { Warn 'модуль тестов не загрузился'; return }
    $thr = [Environment]::ProcessorCount
    if ($G.Sel.cpu) {
    Info 'однопоточная производительность (8 с)...'
    [DiagCore]::Start(1, 8); [DiagCore]::Wait()
    $single = [DiagCore]::BlocksPerSec; $errS = [DiagCore]::Errors

    $z = Get-Tool 'SevenZ'
    if ($z) {
        Info '7-Zip benchmark (все потоки и один поток)...'
        foreach ($mode in @(@('все потоки', 'b -y'), @('1 поток', 'b -mmt1 -y'))) {
            $r = Run-Exe $z $mode[1] 300
            $tot = ($r.Out -split "`n" | Where-Object { $_ -match '^Tot:' } | Select-Object -Last 1)
            if ($tot) {
                $mips = @([regex]::Matches($tot, '\d+') | ForEach-Object { [int]$_.Value })[-1]
                Add-Row $s ('7-Zip, ' + $mode[0]) ('{0:N0} MIPS' -f $mips)
                $G.Bench['7-Zip (' + $mode[0] + ')'] = '{0:N0} MIPS' -f $mips
                if ($mode[0] -eq 'все потоки') { $G.Num.cpu_mips = $mips } else { $G.Num.cpu_1t = $mips }
            }
        }
        Add-Row $s 'Сравнить с другими процессорами' '7-cpu.com (столбец Total Rating = результат 7-Zip benchmark)'
    }

    $dur = [int]$G.Sel.cpusec
    Info ('стресс-тест всех {0} потоков, {1} с — следим за температурой и частотой...' -f $thr, $dur)
    $samples = New-Object System.Collections.Generic.List[object]
    $idle = Read-Key
    [DiagCore]::Start($thr, $dur)
    $t0 = Get-Date
    while ([DiagCore]::IsRunning) {
        Start-Sleep -Seconds 3
        if (-not [DiagCore]::IsRunning) { break }
        $k = Read-Key
        if (Stop-Requested) { Write-Host ''; Warn (Stop-Text); break }
        $eff = $null
        $perf = CIM Win32_PerfFormattedData_Counters_ProcessorInformation 'root/cimv2' "Name='_Total'" | Select-Object -First 1
        if ($perf -and $perf.ProcessorFrequency) { $eff = [double]$perf.ProcessorFrequency * [double]$perf.PercentProcessorPerformance / 100 }
        if ($k.CpuClock) { $eff = $k.CpuClock }
        $temp = $k.CpuTemp
        $samples.Add([pscustomobject]@{ Temp = $temp; Clock = $eff; Power = $k.CpuPower })
        Write-Host -NoNewline ("`r    {0,4:N0} с | темп. {1,4} °C | частота {2,6} МГц | мощность {3,4} Вт   " -f ((Get-Date) - $t0).TotalSeconds, $(if ($null -ne $temp) { '{0:N0}' -f $temp } else { '—' }), $(if ($eff) { '{0:N0}' -f $eff } else { '—' }), $(if ($k.CpuPower) { '{0:N0}' -f $k.CpuPower } else { '—' }))
    }
    Write-Host ''
    [DiagCore]::Wait()
    $multi = [DiagCore]::BlocksPerSec; $err = [DiagCore]::Errors + $errS
    $scale = if ($single -gt 0) { $multi / $single } else { 0 }
    Add-Row $s 'Однопоточный тест' ('{0:N0} баллов' -f ($single * 10))
    Add-Row $s 'Многопоточный тест' ('{0:N0} баллов' -f ($multi * 10))
    Add-Row $s 'Масштабирование на все потоки' ('×{0:N1} (потоков: {1})' -f $scale, $thr)
    $G.Bench['CPU 1 поток (собственный тест)'] = '{0:N0} баллов' -f ($single * 10)
    $G.Bench['CPU все потоки (собственный тест)'] = '{0:N0} баллов' -f ($multi * 10)
    Add-Row $s 'Ошибки вычислений' $err $(if ($err) { 'crit' } else { 'ok' })
    if ($err -gt 0) { Add-Issue 'crit' 'Процессор' "ошибки вычислений под нагрузкой: $err" 'Система нестабильна: уберите разгон/андервольт, проверьте память, охлаждение и блок питания.' }

    $ts = @($samples | Where-Object { $null -ne $_.Temp } | ForEach-Object { [double]$_.Temp })
    $cs = @($samples | Where-Object { $_.Clock } | ForEach-Object { [double]$_.Clock })
    $ps = @($samples | Where-Object { $_.Power } | ForEach-Object { [double]$_.Power })
    if ($ts.Count) {
        $tmax = ($ts | Measure-Object -Maximum).Maximum
        Add-Row $s 'Температура: простой → максимум' ('{0} → {1:N0} °C' -f $(if ($null -ne $idle.CpuTemp) { '{0:N0}' -f $idle.CpuTemp } else { '—' }), $tmax) $(if ($tmax -ge 95) { 'crit' } elseif ($tmax -ge 88) { 'warn' } else { 'ok' })
        $G.Bench['CPU макс. температура (стресс)'] = '{0:N0} °C' -f $tmax
        $G.CpuTmax = $tmax
        if ($tmax -ge 95) { Add-Issue 'crit' 'Охлаждение' ('процессор перегревается: {0:N0} °C под нагрузкой' -f $tmax) 'Почистите систему охлаждения от пыли, замените термопасту; у ноутбука — чистка и подставка.' }
        elseif ($tmax -ge 88) { Add-Issue 'warn' 'Охлаждение' ('высокая температура процессора: {0:N0} °C под нагрузкой' -f $tmax) 'Желательно почистить охлаждение и заменить термопасту.' }
    } else { Add-Row $s 'Температура под нагрузкой' 'датчик недоступен (нужен драйвер PawnIO)' }
    if ($cs.Count -ge 6) {
        $n3 = [math]::Max(2, [math]::Floor($cs.Count / 4))
        $first = ($cs[0..($n3 - 1)] | Measure-Object -Average).Average
        $last = ($cs[($cs.Count - $n3)..($cs.Count - 1)] | Measure-Object -Average).Average
        $drop = if ($first) { [math]::Round(100 * ($first - $last) / $first, 0) } else { 0 }
        Add-Row $s 'Частота: начало → конец теста' ('{0:N0} → {1:N0} МГц ({2} %)' -f $first, $last, $(if ($drop -gt 0) { "−$drop" } else { '+' + [math]::Abs($drop) })) $(if ($drop -ge 20) { 'warn' } else { 'ok' })
        $G.Bench['CPU частота под нагрузкой'] = '{0:N0} МГц' -f $last
        $G.CpuDrop = $drop
        if ($drop -ge 20) { Add-Issue 'warn' 'Процессор' ('частота под нагрузкой упала на {0} % (троттлинг)' -f $drop) $(if ($ts.Count -and ($ts | Measure-Object -Maximum).Maximum -ge 90) { 'Причина — перегрев: почистите охлаждение, замените термопасту.' } else { 'Причина — ограничения питания или схема электропитания. Выберите «Высокая производительность».' }) }
        if ($G.CpuBase -and $last -lt $G.CpuBase * 0.8) { Add-Issue 'warn' 'Процессор' ('под нагрузкой частота ниже базовой: {0:N0} МГц при базовой {1} МГц' -f $last, $G.CpuBase) 'Проверьте схему питания и охлаждение; у ноутбука — подключено ли родное зарядное устройство.' }
    }
    if ($ps.Count) { Add-Row $s 'Мощность процессора (макс.)' ('{0:N0} Вт' -f ($ps | Measure-Object -Maximum).Maximum); $G.CpuPmax = ($ps | Measure-Object -Maximum).Maximum }

    }
    if ($G.Sel.prime) {
        $p95 = Get-Tool 'Prime95'
        if ($p95) {
            $pd = Split-Path $p95
            $mins = [int]$G.Sel.primemin
            Info ('Prime95 Small FFT — {0} минут жёсткой нагрузки...' -f $mins)
            Remove-Item (Join-Path $pd 'results.txt') -ErrorAction SilentlyContinue
            @('V30OptionsConverted=1', 'StressTester=1', 'UsePrimenet=0', 'MinTortureFFT=4', 'MaxTortureFFT=32', 'TortureMem=0', 'TortureTime=3', "TortureThreads=$thr", 'TortureHyperthreading=1') | Set-Content (Join-Path $pd 'prime.txt') -Encoding ascii
            $pp = Start-Process $p95 -ArgumentList '-t' -WorkingDirectory $pd -PassThru -WindowStyle Normal
            if (Get-Command Guard-Register -ErrorAction SilentlyContinue) { Guard-Register $pp }
            $pmax = $null; $t0 = Get-Date; $pclk = New-Object System.Collections.Generic.List[double]; $ppow = $null
            while (((Get-Date) - $t0).TotalMinutes -lt $mins -and -not $pp.HasExited) {
                Start-Sleep -Seconds 5
                $k = Read-Key
                if (Stop-Requested) { Write-Host ''; Warn (Stop-Text); break }
                $tt = $k.CpuTemp
                if ($null -ne $tt -and ($null -eq $pmax -or $tt -gt $pmax)) { $pmax = $tt }
                if (((Get-Date) - $t0).TotalSeconds -gt 10) {
                    $ck = $k.CpuClock
                    if (-not $ck) { $pf = CIM Win32_PerfFormattedData_Counters_ProcessorInformation 'root/cimv2' "Name='_Total'" | Select-Object -First 1; if ($pf -and $pf.ProcessorFrequency) { $ck = [double]$pf.ProcessorFrequency * [double]$pf.PercentProcessorPerformance / 100 } }
                    if ($ck) { $pclk.Add([double]$ck) }
                    if ($k.CpuPower -and ($null -eq $ppow -or $k.CpuPower -gt $ppow)) { $ppow = [double]$k.CpuPower }
                }
                Write-Host -NoNewline ("`r    {0,4:N0} с | темп. {1} °C | макс. {2} °C   " -f ((Get-Date) - $t0).TotalSeconds, $(if ($null -ne $tt) { '{0:N0}' -f $tt } else { '—' }), $(if ($null -ne $pmax) { '{0:N0}' -f $pmax } else { '—' }))
                if ($null -ne $tt -and $tt -ge 100) { Write-Host ''; Warn 'температура 100 °C — тест остановлен досрочно для защиты'; break }
            }
            Write-Host ''
            try { if (-not $pp.HasExited) { $pp.Kill() } } catch {}
            Start-Sleep -Seconds 1
            $rf = Join-Path $pd 'results.txt'
            $res = if (Test-Path $rf) { Get-Content $rf -Raw } else { '' }
            $fails = @([regex]::Matches($res, '(?im)^.*(FATAL ERROR|Hardware failure|ILLEGAL SUMOUT|SUM\(INPUTS\) != SUM\(OUTPUTS\)|Rounding was .* expected less than|possible hardware failure).*$') | ForEach-Object { $_.Value.Trim() })
            $passed = @([regex]::Matches($res, '(?i)passed')).Count
            Add-Row $s ('Prime95 Small FFT, {0} мин' -f $mins) $(if ($fails.Count) { 'ОШИБКИ: ' + $fails.Count } else { "ошибок нет (пройдено тестов: $passed)" }) $(if ($fails.Count) { 'crit' } else { 'ok' })
            if ($null -ne $pmax) { Add-Row $s 'Prime95: максимальная температура' ('{0:N0} °C' -f $pmax) $(if ($pmax -ge 95) { 'crit' } elseif ($pmax -ge 90) { 'warn' } else { 'ok' }); $G.Bench['CPU макс. температура (Prime95)'] = '{0:N0} °C' -f $pmax
                if ($null -eq $G.CpuTmax -or $pmax -gt $G.CpuTmax) { $G.CpuTmax = $pmax } }
            if ($ppow) { Add-Row $s 'Prime95: мощность процессора (макс.)' ('{0:N0} Вт' -f $ppow); if (-not $G.CpuPmax -or $ppow -gt $G.CpuPmax) { $G.CpuPmax = $ppow } }
            if ($pclk.Count -ge 6) {
                $q = [math]::Max(2, [math]::Floor($pclk.Count / 4))
                $f1 = ($pclk.GetRange(0, $q) | Measure-Object -Average).Average; $f2 = ($pclk.GetRange($pclk.Count - $q, $q) | Measure-Object -Average).Average
                $pdrop = if ($f1) { [math]::Round(100 * ($f1 - $f2) / $f1) } else { 0 }
                Add-Row $s 'Prime95: частота начало → конец' ('{0:N0} → {1:N0} МГц ({2}{3} %)' -f $f1, $f2, $(if ($pdrop -gt 0) { '−' } else { '+' }), [math]::Abs($pdrop)) $(if ($pdrop -ge 15) { 'warn' } else { 'ok' })
                if ($null -eq $G.CpuDrop -or $pdrop -gt $G.CpuDrop) { $G.CpuDrop = $pdrop }
            }
            if ($fails.Count) { Add-Issue 'crit' 'Процессор' "Prime95 обнаружил ошибки вычислений ($($fails.Count))" 'Нестабильность процессора/памяти/питания: уберите разгон, проверьте охлаждение и память.' }
        }
    }

    # ---- Итоговый вердикт по охлаждению процессора (по обоим тестам) ----
    $tm = $G.CpuTmax; $dr = [int]$G.CpuDrop; $lap = [bool]$G.IsLaptop
    $G.Issues.RemoveAll([Predicate[object]] { param($i) $i.Area -eq 'Охлаждение' }) | Out-Null
    if ($null -ne $tm) {
        $hot = if ($lap) { 93 } else { 90 }
        if ($tm -ge 97 -or ($tm -ge 92 -and $dr -ge 15)) {
            $v = 'ПЕРЕГРЕВ'; $st = 'crit'
            Add-Issue 'crit' 'Охлаждение' ('процессор перегревается: до {0:N0} °C{1}' -f $tm, $(if ($dr -ge 10) { ", частота сброшена на $dr %" } else { '' })) $(if ($lap) { 'Нужна чистка системы охлаждения от пыли и замена термопасты (у ноутбуков 2+ лет почти всегда). Пока — не закрывайте решётки, используйте подставку.' } else { 'Почистите радиатор и вентиляторы от пыли, замените термопасту, проверьте, что кулер крутится и плотно прижат. Если не поможет — кулер мощнее.' })
        } elseif ($tm -ge $hot -or ($tm -ge 85 -and $dr -ge 15)) {
            $v = 'на пределе — пора чистить'; $st = 'warn'
            Add-Issue 'warn' 'Охлаждение' ('охлаждение процессора на пределе: до {0:N0} °C под полной нагрузкой' -f $tm) 'Желательна чистка от пыли и замена термопасты — иначе летом начнётся перегрев и сброс частот.'
        } else {
            $v = 'в норме'; $st = 'ok'
        }
        $txt = '{0}: максимум {1:N0} °C{2}{3}' -f $v, $tm, $(if ($null -ne $G.CpuDrop) { ", частота под нагрузкой {0}" -f $(if ($dr -gt 3) { "падает на $dr %" } else { 'стабильна' }) } else { '' }), $(if ($G.CpuPmax) { ', мощность {0:N0} Вт' -f $G.CpuPmax } else { '' })
        Add-Row $s 'ВЕРДИКТ ПО ОХЛАЖДЕНИЮ' $txt $st
        $G.Summary['Охлаждение процессора'] = $txt
        $G.Cooling = $v
    } elseif ($dr -ge 25) {
        Add-Row $s 'ВЕРДИКТ ПО ОХЛАЖДЕНИЮ' "датчик температуры недоступен, но частота под нагрузкой падает на $dr % — возможен перегрев" 'warn'
        Add-Issue 'warn' 'Охлаждение' "частота процессора под нагрузкой падает на $dr % (датчик температуры недоступен)" 'Вероятен перегрев или ограничение питания. Для точного ответа запустите проверку с драйвером датчиков PawnIO.'
    } else {
        Add-Row $s 'ВЕРДИКТ ПО ОХЛАЖДЕНИЮ' 'не определён: нет датчика температуры (включите «Драйвер датчиков PawnIO»)'
    }
}

# =====================================================================
Step 'Процессор и память: y-cruncher' {
    $s = New-Section 'Процессор и память: y-cruncher'
    $yc = Get-Tool 'YCruncher'
    if (-not $yc) { Add-Row $s 'y-cruncher' 'не удалось скачать' 'warn'; return }
    $yd = Split-Path $yc
    $freeMB = [int]((CIM Win32_OperatingSystem | Select-Object -First 1).FreePhysicalMemory / 1024)
    function YRun($argz, $sec) {
        $log = Join-Path $G.Temp ('yc_' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.txt')
        $p = Start-Process $yc -ArgumentList (@('skip-warnings', 'pause:-2', 'colors:0', 'priority:0', "logfile:`"$log`"") + $argz) -WorkingDirectory $yd -PassThru -WindowStyle Normal
        if (Get-Command Guard-Register -ErrorAction SilentlyContinue) { Guard-Register $p }
        $t0 = Get-Date; $tmax = $null
        while (-not $p.HasExited -and ((Get-Date) - $t0).TotalSeconds -lt $sec) {
            Start-Sleep -Seconds 3
            $k = Read-Key; if ($null -ne $k.CpuTemp -and ($null -eq $tmax -or $k.CpuTemp -gt $tmax)) { $tmax = $k.CpuTemp }
            if (Stop-Requested) { Write-Host ''; Warn (Stop-Text); break }
            Write-Host -NoNewline ("`r    {0,4:N0} с | темп. {1} °C   " -f ((Get-Date) - $t0).TotalSeconds, $(if ($null -ne $k.CpuTemp) { '{0:N0}' -f $k.CpuTemp } else { '—' }))
            if ($null -ne $k.CpuTemp -and $k.CpuTemp -ge 100) { Warn 'температура 100 °C — тест остановлен'; break }
        }
        Write-Host ''
        $killed = -not $p.HasExited
        if ($killed) { try { $p.Kill() } catch {} ; Start-Sleep -Seconds 1 }
        $txt = if (Test-Path $log) { Get-Content $log -Raw -ErrorAction SilentlyContinue } else { '' }
        return [pscustomobject]@{ Out = "$txt"; Code = $(if ($killed) { -1 } else { $p.ExitCode }); Killed = $killed; TMax = $tmax }
    }
    # Бенчмарк: π до 1 млрд знаков (нужно ~4,7 ГБ свободной памяти) или 500 млн
    $digits = if ($freeMB -gt 7000) { '1b' } elseif ($freeMB -gt 3500) { '500m' } else { '250m' }
    $dl = @{ '1b' = '1 млрд'; '500m' = '500 млн'; '250m' = '250 млн' }[$digits]
    Info "бенчмарк: число π до $dl знаков..."
    $r = YRun @('bench', $digits) 900
    Remove-Item (Join-Path $yd 'Pi - *.txt') -Force -ErrorAction SilentlyContinue
    $tc = [regex]::Match($r.Out, '(?im)^\s*Total Computation Time:\s*([\d.]+)\s*seconds')
    $bad = ($r.Out -match '(?i)(error|failed|mismatch|coefficient is too large)' -and $r.Out -notmatch '(?i)0 errors') -or ($r.Out -match '(?im)^\s*Spot Check:' -and $r.Out -notmatch '(?im)^\s*Spot Check:\s*Good')
    if ($tc.Success -and -not $bad) {
        $sec = [double]::Parse($tc.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture)
        Add-Row $s "Бенчмарк: π до $dl знаков" ('{0:N2} с (меньше — лучше)' -f $sec) 'ok'
        $G.Bench["y-cruncher: π $dl знаков"] = '{0:N2} с' -f $sec
        if ($digits -eq '1b') { $G.Num.ycr_pi1b = [math]::Round($sec, 2) }
        Add-Row $s 'Сравнить' 'hwbot.org → y-cruncher Pi-1b (время для вашего процессора)'
    } elseif ($r.Out -match '(?i)msvcp|vcruntime|\.dll') {
        Add-Row $s 'y-cruncher' 'не запустился: нужен Microsoft Visual C++ Redistributable (x64)' 'warn'; return
    } else {
        Add-Row $s "Бенчмарк: π до $dl знаков" $(if ($bad) { 'ОШИБКА вычислений' } else { "не завершился (код $($r.Code))" }) $(if ($bad) { 'crit' } else { 'warn' })
        if ($bad) { Add-Issue 'crit' 'Процессор' 'y-cruncher: ошибка вычислений в бенчмарке' 'Нестабильна система: процессор, память или питание. Уберите разгон/XMP, проверьте память и охлаждение.' }
    }
    # Стресс: процессор + контроллер памяти + сама память
    $min = [int]$G.Sel.ycrmin; if ($min -lt 1) { $min = 2 }
    $mem = [math]::Max(1024, [math]::Min([int]($freeMB * 0.6), 16384))
    Info ("стресс-тест y-cruncher: {0} мин, память {1:N1} ГБ — ловит нестабильный разгон и XMP..." -f $min, ($mem / 1024))
    $per = [math]::Max(20, [int]($min * 60 / 6))
    $r = YRun @('stress', ('-M:{0}M' -f $mem), "-D:$per", ('-TL:{0}' -f ($min * 60))) ($min * 60 + 90)
    # вывод: меню настроек (там есть «Stop on Error: Enabled» — не ошибка), затем «Iteration: N» и строки «Running BKT: Passed»
    $i0 = $r.Out.IndexOf('Iteration:'); $run = if ($i0 -ge 0) { $r.Out.Substring($i0) } else { '' }
    $errs = @([regex]::Matches($run, '(?im)^.*(error|fail|mismatch|coefficient is too large|redundancy check).*$') | ForEach-Object { $_.Value.Trim() } | Where-Object { $_ -notmatch '(?i)\b0 errors|stop on error' })
    $passed = @([regex]::Matches($run, '(?im)^\s*Running\s+\S+:\s*Passed')).Count
    if ($errs.Count) {
        Add-Row $s "Стресс-тест, $min мин" ('ОШИБКИ: ' + ($errs | Select-Object -First 3) -join ' | ') 'crit'
        Add-Issue 'crit' 'Процессор' 'y-cruncher нашёл ошибки вычислений под нагрузкой' 'Система нестабильна. Чаще всего — оперативная память или её разгон (XMP/EXPO): отключите XMP и проверьте снова; затем — планки по одной, питание и охлаждение процессора.'
    } elseif ($passed -gt 0) {
        Add-Row $s "Стресс-тест, $min мин" "ошибок нет (пройдено тестов: $passed)" 'ok'
    } else {
        Add-Row $s "Стресс-тест, $min мин" $(if ($r.Killed) { 'остановлен по времени, результат не распознан' } else { "результат не распознан (код $($r.Code))" }) 'warn'
    }
    if ($null -ne $r.TMax) { Add-Row $s 'Максимальная температура' ('{0:N0} °C' -f $r.TMax); if ($null -eq $G.CpuTmax -or $r.TMax -gt $G.CpuTmax) { $G.CpuTmax = $r.TMax } }
    $G.Log.Add('y-cruncher stress tail: ' + (($r.Out -split "`n" | Select-Object -Last 15) -join ' / '))
}

# =====================================================================
Step 'Оперативная память: тест' {
    $s = New-Section 'Тест оперативной памяти'
    if (-not $G.CoreOk) { return }
    $os = CIM Win32_OperatingSystem | Select-Object -First 1
    $freeMB = [int]($os.FreePhysicalMemory / 1024)
    $mb = if ($G.Sel.ramfull) { [math]::Min([int]($freeMB * 0.75), 24576) } else { [math]::Min([int]($freeMB * 0.5), 4096) }
    $mb = [math]::Max(256, $mb - ($mb % 64))
    Info "запись и проверка $mb МБ памяти пятью шаблонами..."
    $r = [DiagCore]::MemTest($mb)
    Add-Row $s 'Проверено' ('{0:N0} МБ ({1} % всей памяти)' -f $r.TestedMB, $(if ($G.RamTotal) { [math]::Round(100 * $r.TestedMB * 1MB / $G.RamTotal) } else { '?' }))
    Add-Row $s 'Ошибки' $r.Errors $(if ($r.Errors) { 'crit' } else { 'ok' })
    Add-Row $s 'Скорость записи / чтения (один поток)' ('{0:N1} / {1:N1} ГБ/с' -f ($r.WriteMBs / 1024), ($r.ReadMBs / 1024))
    $G.Bench['Память: запись / чтение (1 поток)'] = '{0:N1} / {1:N1} ГБ/с' -f ($r.WriteMBs / 1024), ($r.ReadMBs / 1024)
    $G.Num.ram_read = [math]::Round($r.ReadMBs / 1024, 1)
    if ($r.Note) { Add-Row $s 'Примечание' $r.Note }
    Add-Row $s 'Важно' 'Тест проверяет свободную часть памяти из-под Windows. Самая полная проверка — MemTest86 с флешки или Windows Memory Diagnostic при перезагрузке.'
    if ($r.Errors -gt 0) { Add-Issue 'crit' 'Память' "найдены ошибки оперативной памяти: $($r.Errors)" 'Неисправна память! Уберите разгон/XMP, проверьте планки по одной в MemTest86 и замените сбойную.' }
}

# =====================================================================
Step 'Накопитель: тест скорости (DiskSpd)' {
    $s = New-Section 'Тест скорости диска'
    $ds = Get-Tool 'DiskSpd'
    if (-not $ds) { Warn 'DiskSpd недоступен'; return }
    $drive = $env:SystemDrive
    $vol = Get-Volume -DriveLetter $drive.TrimEnd(':') -ErrorAction SilentlyContinue
    $sizeGB = if ($G.Full) { 4 } else { 1 }
    if ($vol -and $vol.SizeRemaining -lt ($sizeGB * 3GB)) { Warn 'мало места для теста диска — пропуск'; return }
    $file = Join-Path $drive 'pcdiag_disktest.dat'
    $dur = if ($G.Full) { 15 } else { 8 }
    $tests = @(
        @{ N = 'Последовательное чтение (1 МБ, Q8)'; A = '-b1M -o8 -t1 -w0'; K = 'SEQ R'; Mb = $true },
        @{ N = 'Случайное чтение 4К (Q32, 4 потока)'; A = '-b4K -o32 -t4 -w0 -r'; K = 'RND4K R'; Mb = $false },
        @{ N = 'Случайное чтение 4К (Q1, отклик)'; A = '-b4K -o1 -t1 -w0 -r'; K = 'RND4K Q1'; Mb = $false },
        @{ N = 'Случайная запись 4К (Q32, 4 потока)'; A = '-b4K -o32 -t4 -w100 -r'; K = 'RND4K W'; Mb = $false },
        @{ N = 'Последовательная запись (1 МБ, Q8)'; A = '-b1M -o8 -t1 -w100'; K = 'SEQ W'; Mb = $true }
    )
    $rows = @()
    foreach ($t in $tests) {
        Info $t.N
        Start-Sleep -Seconds 3
        $r = Run-Exe $ds ('-c{0}G -d{1} -W2 -Sh -L -Rxml {2} "{3}"' -f $sizeGB, $dur, $t.A, $file) 240
        try {
            $i1 = $r.Out.IndexOf('<Results'); $i2 = $r.Out.LastIndexOf('</Results>')
            [xml]$x = $r.Out.Substring($i1, $i2 + 10 - $i1)
            $sec = [double]$x.Results.TimeSpan.TestTimeSeconds
            $bytes = 0.0; $ios = 0.0
            foreach ($th in @($x.Results.TimeSpan.Thread)) { foreach ($tg in @($th.Target)) { $bytes += [double]$tg.BytesCount; $ios += [double]$tg.IOCount } }
            $mbs = $bytes / 1MB / $sec; $iops = $ios / $sec
            $lat = $null
            try { $lat = [double]$x.Results.TimeSpan.Latency.AverageTotalMilliseconds } catch {}
            $rows += [pscustomobject]@{ 'Тест' = $t.N; 'МБ/с' = '{0:N0}' -f $mbs; 'IOPS' = '{0:N0}' -f $iops; 'Задержка' = $(if ($lat) { '{0:N3} мс' -f $lat } else { '—' }) }
            $G.Bench['Диск ' + $t.K] = $(if ($t.Mb) { '{0:N0} МБ/с' -f $mbs } else { '{0:N0} IOPS ({1:N0} МБ/с)' -f $iops, $mbs })
            if ($t.K -eq 'SEQ R') { $G.DiskSeqR = $mbs; $G.Num.disk_seq_r = [int]$mbs }
            if ($t.K -eq 'RND4K R') { $G.Num.disk_rnd_iops = [int]$iops }
        } catch { $rows += [pscustomobject]@{ 'Тест' = $t.N; 'МБ/с' = 'ошибка'; 'IOPS' = ''; 'Задержка' = '' } }
    }
    Remove-Item $file -Force -ErrorAction SilentlyContinue
    Add-Row $s 'Диск' ('{0} {1}' -f $drive, $G.SysDiskType)
    Add-Table $s 'Результаты (кэш Windows отключён)' $rows
    Add-Row $s 'Справка' 'Типично: HDD — 100–200 МБ/с; SATA SSD — ~550 МБ/с; NVMe PCIe 3.0 — 2000–3500 МБ/с; NVMe PCIe 4.0 — 5000–7000 МБ/с.'
    if ($G.DiskSeqR) {
        if ($G.SysDiskType -match 'NVMe' -and $G.DiskSeqR -lt 1000) { Add-Issue 'warn' 'Накопитель' ('NVMe читает всего {0:N0} МБ/с — ниже нормы' -f $G.DiskSeqR) 'Причины: перегрев, почти заполненный диск, слот PCIe с урезанными линиями или деградация SSD.' }
        elseif ($G.SysDiskType -match 'SSD' -and $G.SysDiskType -match 'SATA' -and $G.DiskSeqR -lt 350) { Add-Issue 'warn' 'Накопитель' ('SATA SSD читает всего {0:N0} МБ/с — ниже нормы' -f $G.DiskSeqR) 'Проверьте режим AHCI в BIOS, SATA-кабель и порт (SATA3 6 Гбит/с).' }
        elseif ($G.SysDiskType -match 'HDD' -and $G.DiskSeqR -lt 60) { Add-Issue 'warn' 'Накопитель' ('жёсткий диск читает всего {0:N0} МБ/с' -f $G.DiskSeqR) 'Возможен износ HDD: сделайте резервную копию.' }
    }
}

# =====================================================================
Step 'Видеокарта: бенчмарк и стресс-тест (FurMark)' {
    if (-not $G.GpuStress) { Info 'пропущено по вашему выбору'; return }
    $s = New-Section 'Тест видеокарты'
    $fm = Get-Tool 'FurMark'
    if (-not $fm) { Warn 'FurMark недоступен'; return }
    $fd = Split-Path $fm
    $sec = [int]$G.Sel.gpusec
    Info ('FurMark 1920×1080, {0} с. Появится окно с «меховым бубликом» — это нормально, не трогайте его.' -f $sec)
    $argsFm = '--demo furmark-gl --benchmark --width 1920 --height 1080 --max-time {0} --no-score-box --disable-demo-options' -f $sec
    if ($G.IsLaptop) { $argsFm += ' --hpgfx 1' }
    $t0 = Get-Date
    $smiH = if (Get-Command Start-SmiLog -ErrorAction SilentlyContinue) { Start-SmiLog } else { $null }
    $p = Start-Process $fm -ArgumentList $argsFm -WorkingDirectory $fd -PassThru
    if (Get-Command Guard-Register -ErrorAction SilentlyContinue) { Guard-Register $p }
    $mx = @{ T = $null; H = $null; P = $null; L = $null; F = $null; M = $null }
    $cl = New-Object System.Collections.Generic.List[double]
    while (-not $p.HasExited -and ((Get-Date) - $t0).TotalSeconds -lt ($sec + 60)) {
        Start-Sleep -Seconds 3
        $k = Read-Key
        if (Stop-Requested) { Write-Host ''; Warn (Stop-Text); break }
        foreach ($pair in @(@('T', $k.GpuTemp), @('H', $k.GpuHot), @('P', $k.GpuPower), @('L', $k.GpuLoad), @('F', $k.GpuFan), @('M', $k.GpuMemT))) { if ($null -ne $pair[1] -and ($null -eq $mx[$pair[0]] -or $pair[1] -gt $mx[$pair[0]])) { $mx[$pair[0]] = $pair[1] } }
        if ($k.GpuClock -and $k.GpuLoad -gt 80) { $cl.Add([double]$k.GpuClock) }
        Write-Host -NoNewline ("`r    {0,4:N0} с | GPU {1} °C | {2} МГц | {3} Вт | загрузка {4} %   " -f ((Get-Date) - $t0).TotalSeconds, $(if ($null -ne $k.GpuTemp) { '{0:N0}' -f $k.GpuTemp } else { '—' }), $(if ($k.GpuClock) { '{0:N0}' -f $k.GpuClock } else { '—' }), $(if ($k.GpuPower) { '{0:N0}' -f $k.GpuPower } else { '—' }), $(if ($null -ne $k.GpuLoad) { '{0:N0}' -f $k.GpuLoad } else { '—' }))
        if ($null -ne $k.GpuTemp -and $k.GpuTemp -ge 95) { Write-Host ''; Warn 'GPU 95 °C — тест остановлен для защиты'; break }
    }
    Write-Host ''
    try { if (-not $p.HasExited) { $p.Kill() } } catch {}
    $G.SmiRows = if ($smiH) { Stop-SmiLog $smiH } else { @() }
    $G.GpuStressMax = $mx
    $elapsed = ((Get-Date) - $t0).TotalSeconds
    $score = $null; $fps = $null
    $sc = Join-Path $fd '_scores.csv'
    if ((Test-Path $sc) -and (Get-Item $sc).LastWriteTime -gt $t0) {
        $last = @(Import-Csv $sc) | Select-Object -Last 1
        if ($last) {
            $score = [double]$last.score; $fps = $last.avg_fps
            if ([double]$last.duration -gt 0) { $score = [math]::Round($score * 60000 / [double]$last.duration) }
            if ($null -eq $mx.T -and $last.max_gpu_temp) { $mx.T = [double]$last.max_gpu_temp }
            Add-Row $s 'FPS: средний / мин / макс' ('{0} / {1} / {2}' -f $last.avg_fps, $last.min_fps, $last.max_fps)
            Add-Row $s 'API / драйвер' $last.api_version
        }
    }
    if ($score) { Add-Row $s 'FurMark 1080p (OpenGL): баллы за 60 с' ('{0:N0}' -f $score); $G.Bench['GPU FurMark 1080p (баллы за 60 с)'] = '{0:N0}, средний FPS {1}' -f $score, $fps; $G.Num.gpu_score = [int]$score }
    Add-Row $s 'Сравнить с другими видеокартами' 'gpumagick.com/scores (тест FurMark 1920×1080, OpenGL)'
    Add-Row $s 'Длительность теста' ('{0:N0} с' -f $elapsed)
    if ($null -ne $mx.T) {
        Add-Row $s 'Температура GPU (макс.)' ('{0:N0} °C' -f $mx.T) $(if ($mx.T -ge 90) { 'crit' } elseif ($mx.T -ge 84) { 'warn' } else { 'ok' })
        $G.Bench['GPU макс. температура (FurMark)'] = '{0:N0} °C' -f $mx.T
        if ($mx.T -ge 90) { Add-Issue 'crit' 'Видеокарта' ('перегрев видеокарты: {0:N0} °C' -f $mx.T) 'Почистите видеокарту от пыли, проверьте вентиляторы; часто нужна замена термопасты/термопрокладок.' }
        elseif ($mx.T -ge 84) { Add-Issue 'warn' 'Видеокарта' ('видеокарта горячая: {0:N0} °C под нагрузкой' -f $mx.T) 'Улучшите обдув корпуса, почистите от пыли.' }
    }
    if ($null -ne $mx.H) {
        Add-Row $s 'Горячая точка (Hot Spot), макс.' ('{0:N0} °C' -f $mx.H) $(if ($mx.H -ge 105) { 'crit' } elseif ($mx.H -ge 95) { 'warn' } else { 'ok' })
        if ($null -ne $mx.T -and ($mx.H - $mx.T) -ge 25) { Add-Issue 'warn' 'Видеокарта' ('большая разница ядро / hot spot: {0:N0} °C' -f ($mx.H - $mx.T)) 'Признак высохшей термопасты на GPU — нужна замена.' }
    }
    if ($null -ne $mx.P) { Add-Row $s 'Потребление (макс.)' ('{0:N0} Вт' -f $mx.P); $G.Bench['GPU потребление (макс.)'] = '{0:N0} Вт' -f $mx.P }
    if ($cl.Count) { Add-Row $s 'Частота ядра под нагрузкой (средн.)' ('{0:N0} МГц' -f ($cl | Measure-Object -Average).Average) }
    if ($null -ne $mx.F) { Add-Row $s 'Вентиляторы (макс.)' ('{0:N0} об/мин' -f $mx.F) }
    if ($null -ne $mx.L) { Add-Row $s 'Загрузка GPU (макс.)' ('{0:N0} %' -f $mx.L) }
    $tdr = @()
    try { $tdr = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Display'; Id = 4101; StartTime = $t0 } -ErrorAction Stop) } catch {}
    if ($tdr.Count) { Add-Issue 'crit' 'Видеокарта' 'во время стресс-теста драйвер видеокарты упал (TDR)' 'Нестабильность видеокарты: уберите разгон, проверьте питание и температуру; возможна неисправность.' }
    elseif ($elapsed -lt ($sec - 10) -and $null -eq $mx.L) { Add-Issue 'info' 'Видеокарта' 'FurMark не отработал полностью' 'Запустите FurMark вручную: папка tools\FurMark.' }
    else { Add-Row $s 'Стабильность под нагрузкой' 'сбоев драйвера не было' 'ok' }
}

#%%MOD:stress%%

# =====================================================================
Step 'Проверка на вирусы (Microsoft Defender)' {
    $s = New-Section 'Проверка на вирусы'
    $mp = $null; try { $mp = Get-MpComputerStatus -ErrorAction Stop } catch {}
    $av = @(CIM AntiVirusProduct 'root/SecurityCenter2' | Where-Object { $_.displayName -notmatch 'Windows Defender|Microsoft Defender' } | ForEach-Object { $_.displayName })
    if (-not $mp -or -not $mp.AntivirusEnabled -or "$($mp.AMRunningMode)" -match 'Passive|Disabled|Not running') {
        Add-Row $s 'Microsoft Defender' $(if ($av.Count) { 'не активен — защиту выполняет ' + ($av -join ', ') + '. Проверьте компьютер его средствами.' } else { 'ВЫКЛЮЧЕН, другого антивируса не найдено' }) $(if ($av.Count) { '' } else { 'crit' })
        if (-not $av.Count) { Add-Issue 'crit' 'Безопасность' 'антивирусная защита выключена' 'Включите Microsoft Defender: Параметры → Конфиденциальность и защита → Безопасность Windows.' }
        return
    }
    Info 'обновление антивирусных баз...'
    try { $j = Start-Job { Update-MpSignature -ErrorAction SilentlyContinue }; [void](Wait-Job $j -Timeout 120); Remove-Job $j -Force -ErrorAction SilentlyContinue } catch {}
    Info 'быстрая проверка Microsoft Defender (обычно 2–10 мин)...'
    $t0 = Get-Date
    $j = Start-Job { Start-MpScan -ScanType QuickScan }
    while ($j.State -eq 'Running' -and ((Get-Date) - $t0).TotalMinutes -lt 30) {
        Start-Sleep -Seconds 5
        Write-Host -NoNewline ("`r    проверка идёт {0:N0} мин...   " -f ((Get-Date) - $t0).TotalMinutes)
    }
    Write-Host ''
    $timeout = $j.State -eq 'Running'
    if ($timeout) { Stop-Job $j -ErrorAction SilentlyContinue }
    Remove-Job $j -Force -ErrorAction SilentlyContinue
    $mins = ((Get-Date) - $t0).TotalMinutes
    $names = @{}; foreach ($t in @(Get-MpThreat -ErrorAction SilentlyContinue)) { $names["$($t.ThreatID)"] = $t }
    $det = @(Get-MpThreatDetection -ErrorAction SilentlyContinue | Where-Object { $_.InitialDetectionTime -ge (Get-Date).AddDays(-30) } | Sort-Object InitialDetectionTime -Descending)
    $new = @($det | Where-Object { $_.InitialDetectionTime -ge $t0.AddMinutes(-1) })
    $active = @($names.Values | Where-Object { $_.IsActive })
    $sev = @{ 1 = 'низкая'; 2 = 'средняя'; 4 = 'высокая'; 5 = 'критическая' }
    Add-Row $s 'Быстрая проверка' $(if ($timeout) { 'не завершилась за 30 мин' } elseif ($new.Count) { "НАЙДЕНО угроз: $($new.Count)" } else { 'угроз не найдено ({0:N0} мин)' -f $mins }) $(if ($new.Count) { 'crit' } elseif ($timeout) { 'warn' } else { 'ok' })
    Add-Row $s 'Антивирусные базы' ('от {0}' -f (DT (Get-MpComputerStatus).AntivirusSignatureLastUpdated))
    if ($det.Count) {
        $rows = @($det | Select-Object -First 30 | ForEach-Object { $t = $names["$($_.ThreatID)"]
                [pscustomobject]@{ 'Когда' = $_.InitialDetectionTime.ToString('dd.MM.yyyy HH:mm'); 'Угроза' = $(if ($t) { $t.ThreatName } else { $_.ThreatID }); 'Опасность' = $(if ($t) { $sev[[int]$t.SeverityID] } else { '' })
                    'Состояние' = $(if ($_.ActionSuccess) { 'обезврежена' } else { 'НЕ обезврежена' }); 'Файл' = ((@($_.Resources) | Select-Object -First 1) -replace '^\w+:_', '') } })
        Add-Table $s 'Обнаружения за 30 дней' $rows
    }
    if ($active.Count) { Add-Issue 'crit' 'Безопасность' ('активные угрозы: ' + (($active | ForEach-Object { $_.ThreatName } | Select-Object -First 5) -join ', ')) 'Откройте «Безопасность Windows» → «Защита от вирусов и угроз» → удалите угрозы, затем запустите полную проверку и автономную проверку Defender.' }
    elseif ($det.Count) { Add-Issue 'warn' 'Безопасность' "за 30 дней Defender обезвредил угроз: $($det.Count)" 'Угрозы удалены, но откуда-то приходят: проверьте, что и откуда скачивается (кряки, «активаторы», сомнительные расширения браузера).' }
    $G.AvThreats = $det.Count
}

# =====================================================================
Step 'Оценка WinSAT и целостность Windows' {
    $s = New-Section 'Оценка и целостность Windows'
    Info 'WinSAT formal (2–5 мин)...'
    $null = Run-Exe "$env:windir\System32\winsat.exe" 'formal -restart clean' 900
    $w = CIM Win32_WinSAT | Select-Object -First 1
    if ($w -and $w.WinSATAssessmentState -eq 1) {
        Add-Row $s 'Индекс WinSAT (макс. 9,9)' ('Процессор {0} · Память {1} · Графика {2} · Игры {3} · Диск {4} → общий {5}' -f $w.CPUScore, $w.MemoryScore, $w.GraphicsScore, $w.D3DScore, $w.DiskScore, $w.WinSPRLevel)
        $G.Bench['WinSAT (CPU / RAM / графика / игры / диск)'] = '{0} / {1} / {2} / {3} / {4}' -f $w.CPUScore, $w.MemoryScore, $w.GraphicsScore, $w.D3DScore, $w.DiskScore
    } else { Add-Row $s 'WinSAT' 'оценка не выполнена (у ноутбука — подключите зарядку)' }

    Info 'DISM: проверка хранилища компонентов (5–15 мин)...'
    $r = Run-Exe "$env:windir\System32\dism.exe" '/Online /Cleanup-Image /ScanHealth' 1800
    $dismTxt = if ($r.Out -match '(?i)no component store corruption|не обнаружено') { 'повреждений нет' } elseif ($r.Out -match '(?i)repairable|подлежит восстановлению|можно восстановить') { 'REPAIR' } else { 'результат неизвестен (код ' + $r.Code + ')' }
    if ($dismTxt -eq 'REPAIR') {
        Info 'обнаружены повреждения — DISM RestoreHealth...'
        $r2 = Run-Exe "$env:windir\System32\dism.exe" '/Online /Cleanup-Image /RestoreHealth' 3600
        $dismTxt = if ($r2.Code -eq 0) { 'были повреждения — ВОССТАНОВЛЕНО' } else { 'были повреждения — восстановить не удалось' }
        Add-Issue $(if ($r2.Code -eq 0) { 'info' } else { 'warn' }) 'Windows' ('хранилище компонентов: ' + $dismTxt) 'При неудаче — «Вернуть компьютер в исходное состояние» с сохранением файлов.'
    }
    Add-Row $s 'DISM (хранилище компонентов)' $dismTxt $(if ($dismTxt -match 'нет|ВОССТАНОВЛЕНО') { 'ok' } else { 'warn' })

    Info 'SFC: проверка и восстановление системных файлов (5–15 мин)...'
    $r = Run-Exe "$env:windir\System32\sfc.exe" '/scannow' 3600 -Unicode
    $sfcTxt = if ($r.Out -match '(?i)did not find any integrity violations|не обнаружила нарушений целостности') { 'нарушений нет' }
    elseif ($r.Out -match '(?i)successfully repaired|успешно их восстановила|успешно восстановила') { 'найдены и ИСПРАВЛЕНЫ повреждённые файлы' }
    elseif ($r.Out -match '(?i)unable to fix|не может восстановить|не удалось восстановить') { 'найдены повреждения, НЕ исправлены' }
    else { 'результат неизвестен' }
    Add-Row $s 'SFC (системные файлы)' $sfcTxt $(if ($sfcTxt -match 'нет|ИСПРАВЛЕНЫ') { 'ok' } else { 'warn' })
    if ($sfcTxt -match 'НЕ исправлены') { Add-Issue 'warn' 'Windows' 'повреждены системные файлы, автоматически не исправлены' 'DISM /Online /Cleanup-Image /RestoreHealth, затем sfc /scannow; или «Вернуть компьютер в исходное состояние» с сохранением файлов.' }

    Info 'CHKDSK: онлайн-проверка файловой системы...'
    $r = Run-Exe "$env:windir\System32\chkdsk.exe" "$env:SystemDrive /scan" 3600
    Add-Row $s 'CHKDSK (файловая система)' $(if ($r.Code -eq 0) { 'ошибок нет' } else { 'НАЙДЕНЫ ПРОБЛЕМЫ (код ' + $r.Code + ')' }) $(if ($r.Code -eq 0) { 'ok' } else { 'warn' })
    if ($r.Code -ne 0) { Add-Issue 'warn' 'Диск' 'chkdsk нашёл проблемы файловой системы' 'Выполните chkdsk C: /f и перезагрузите компьютер.' }
}

# =====================================================================
Step 'Драйверы: установка и обновление' {
    # Основной путь — Windows Update (каталог Microsoft: драйверы производителей, скачивание по HTTPS, надёжно).
    # SDIO — только по явному выбору (ключ 'sdio', по умолчанию выключен): он качает ЦЕЛЫЕ драйверпаки торрентом
    # (на тестовом ПК под 11 драйверов нужно 8 паков ≈ 4,3 ГБ) и не укладывался в лимит 25/45 мин — ничего не ставилось.
    # $G.DrvInstall = $false (авто-режим без DIAG_DRV=Y) — только поиск и список, без установки.
    if (-not $G.UpdDrivers) { Info 'пропущено по вашему выбору'; return }
    $s = New-Section 'Установка и обновление драйверов'
    $drvInst = [bool]$G.DrvInstall
    if (-not $drvInst) { Add-Row $s 'Режим' 'только поиск — драйверы не устанавливались (авто-режим; для установки DIAG_DRV=Y)' }

    # ---- 1. Windows Update: поиск (и установка) драйверов
    Info 'Windows Update: поиск драйверов (обычно до минуты)...'
    $wuT0 = Get-Date
    try {
        $sess = New-Object -ComObject Microsoft.Update.Session
        $sess.ClientApplicationID = 'PC Diagnostika'
        $srch = $sess.CreateUpdateSearcher()
        $srch.Online = $true
        $res = $null
        # ServerSelection 2 = напрямую Windows Update (если ПК привязан к корпоративному WSUS, драйверов там обычно нет)
        try { $srch.ServerSelection = 2; $res = $srch.Search("IsInstalled=0 and Type='Driver' and IsHidden=0") }
        catch { $G.Log.Add("WU ss=2: $($_.Exception.Message)"); $srch.ServerSelection = 0; $res = $srch.Search("IsInstalled=0 and Type='Driver' and IsHidden=0") }
        $list = @()
        foreach ($u in $res.Updates) { $list += [pscustomobject]@{ U = $u; Fw = (("$($u.DriverClass)" -match 'firmware') -or ($u.Title -match '(?i)firmware|bios|uefi|прошив')) } }
        $onBattery = [bool](CIM Win32_Battery | Where-Object { $_.BatteryStatus -eq 1 })
        $skipFw = @($list | Where-Object { $_.Fw -and (-not $G.UpdFirmware -or $onBattery) })
        $todo = @($list | Where-Object { -not $_.Fw -or ($G.UpdFirmware -and -not $onBattery) })
        Add-Row $s 'Windows Update: найдено драйверов' ('{0} (поиск занял {1:N0} с)' -f $list.Count, ((Get-Date) - $wuT0).TotalSeconds) $(if ($list.Count) { 'warn' } else { 'ok' })
        Info ('Windows Update: найдено драйверов: {0}' -f $list.Count)
        if ($list.Count) {
            $lrows = @($list | ForEach-Object {
                    [pscustomobject]@{ 'Драйвер' = $_.U.Title; 'Класс' = "$($_.U.DriverClass)"; 'Производитель' = "$($_.U.DriverManufacturer)"; 'Дата версии' = (DT $_.U.DriverVerDate)
                        'Размер' = ('{0:N1} МБ' -f ($_.U.MaxDownloadSize / 1MB)); 'Действие' = $(if ($_.Fw -and ($skipFw -contains $_)) { 'пропущено (прошивка)' } elseif ($drvInst) { 'установка' } else { 'только найдено' }) } })
            Add-Table $s 'Windows Update: доступные драйверы' $lrows
        }
        if ($skipFw.Count) { Add-Row $s 'Пропущены обновления прошивок/BIOS' (($skipFw | ForEach-Object { $_.U.Title }) -join '; ') 'warn'; Add-Issue 'info' 'BIOS' ('доступно обновление прошивки: ' + (($skipFw | ForEach-Object { $_.U.Title }) -join '; ')) 'Установите через Центр обновления Windows (подключив зарядку).' }
        if ($todo.Count -and -not $drvInst) { Add-Issue 'info' 'Драйверы' ('Windows Update предлагает драйверов: {0}' -f $todo.Count) 'Центр обновления Windows → Дополнительные параметры → Необязательные обновления → Обновления драйверов.' }
        if ($todo.Count -and $drvInst) {
            $G.DrvRP = $true   # точка восстановления — одна на шаг (BTT-Drivers.ps1 получает -RestorePoint, только если её ещё нет)
            try {
                Checkpoint-Computer -Description 'Перед обновлением драйверов (BigTechoTest)' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
                Add-Row $s 'Точка восстановления' 'создана' 'ok'
            } catch { Add-Row $s 'Точка восстановления' 'не создана (защита системы выключена или точка уже создавалась сегодня)' 'warn' }
            $rc = @{ 2 = 'установлен'; 3 = 'установлен с ошибками'; 4 = 'ОШИБКА'; 5 = 'прерван' }
            $wrows = @(); $wi = 0; $wfail = 0
            foreach ($t in $todo) {
                $wi++
                $u = $t.U
                Info ('[{0}/{1}] {2} ({3:N1} МБ)' -f $wi, $todo.Count, $u.Title, ($u.MaxDownloadSize / 1MB))
                $one = New-Object -ComObject Microsoft.Update.UpdateColl
                if (-not $u.EulaAccepted) { try { $u.AcceptEula() } catch {} }
                [void]$one.Add($u)
                $wres = 'ОШИБКА'
                try {
                    if (-not $u.IsDownloaded) {
                        $dl = $sess.CreateUpdateDownloader(); $dl.Updates = $one
                        $dr = $dl.Download()
                        if ([int]$dr.ResultCode -notin 2, 3) { throw ('не скачался (код {0})' -f $dr.ResultCode) }
                    }
                    $ins = $sess.CreateUpdateInstaller(); $ins.Updates = $one
                    $ir = $ins.Install()
                    $wres = $rc[[int]$ir.ResultCode]
                    if (-not $wres) { $wres = 'код ' + $ir.ResultCode }
                    if ($ir.RebootRequired) { $G.RebootNeeded = $true }
                } catch { $wres = 'ОШИБКА: ' + $_.Exception.Message }
                if ($wres -notmatch '^установлен') { $wfail++ }
                $wrows += [pscustomobject]@{ 'Драйвер' = $u.Title; 'Результат' = $wres }
            }
            Add-Table $s 'Windows Update: установка драйверов' $wrows
            if ($wfail) { Add-Issue 'info' 'Драйверы' ('Windows Update не смог установить драйверов: {0}' -f $wfail) 'Повторите через Центр обновления Windows → Необязательные обновления или скачайте драйвер с сайта производителя.' }
        }
    } catch { Add-Row $s 'Windows Update' ('недоступен: ' + $_.Exception.Message) 'warn' }

    # ---- 2. (необязательно) Snappy Driver Installer — только по выбору пользователя (ключ 'sdio')
    $sdio = $null
    if ($G.Sel.sdio -and $drvInst) { $sdio = Get-Tool 'SDIO' }
    elseif ($G.Sel.sdio) { Add-Row $s 'Snappy Driver Installer' 'не запускался: режим «только поиск»' }
    if ($sdio) {
        $lim = if ($G.Full) { 45 } else { 25 }
        $sel = if ($G.Full) { 'select missing newer' } else { 'select missing' }
        Info ('Snappy Driver Installer: драйверпаки качаются торрентом, их размер — гигабайты (лимит {0} мин)...' -f $lim)
        $sd = Split-Path $sdio
        $w = Join-Path $G.Temp 'sdio'
        New-Item -ItemType Directory -Force $w | Out-Null
        # журнал — в папку SDIO (папка $G.Temp удаляется в конце, журнал нужен для разбора); недокачанные паки в SDIO\update докачиваются при следующем запуске
        $sdLogs = Join-Path $sd 'logs'
        @('verbose 384', "logdir $sdLogs", 'logging on', 'enableinstall on', 'init',
            'checkupdates', 'onerror goto :local', 'get indexes', 'init',
            ':local', $sel, 'install', 'end') | Set-Content (Join-Path $w 'script.txt') -Encoding ascii
        $t0 = Get-Date
        $p = Start-Process $sdio -ArgumentList ('-script:"{0}"' -f (Join-Path $w 'script.txt')) -WorkingDirectory $sd -PassThru -WindowStyle Minimized
        while (-not $p.HasExited -and ((Get-Date) - $t0).TotalMinutes -lt $lim) {
            Start-Sleep -Seconds 10
            Write-Host -NoNewline ("`r    SDIO работает {0:N0} мин...   " -f ((Get-Date) - $t0).TotalMinutes)
        }
        Write-Host ''
        $finished = $p.HasExited
        if (-not $finished) { try { Get-Process -Id $p.Id -ErrorAction SilentlyContinue | Stop-Process -Force } catch {}; Warn "SDIO не уложился в $lim мин (драйверпаки большие) — остановлен. Скачанное сохранено, следующий запуск докачает." }
        $log = Get-ChildItem $sdLogs -File -Filter '*_log.txt' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $t0.AddMinutes(-1) } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        $lt = if ($log) { Get-Content $log.FullName -Raw -ErrorAction SilentlyContinue } else { '' }
        $inst = @([regex]::Matches($lt, '(?im)^.*(install|extract|driver).*$') | ForEach-Object { Clean $_.Value } | Where-Object { $_ -match '(?i)install' -and $_ -notmatch '^Command:' } | Select-Object -Unique -First 80)
        $m = [regex]::Match($lt, '(?i)(\d+) drivers? installed, (\d+) drivers? failed')
        $selM = [regex]::Match($lt, '(?i)(\d+) drivers? selected')
        $txt = if ($finished) { 'завершён за {0:N0} мин' -f ((Get-Date) - $t0).TotalMinutes } else { "остановлен по тайм-ауту ($lim мин)" }
        if ($selM.Success) { $txt += '; выбрано драйверов: ' + $selM.Groups[1].Value }
        $st = if ($finished) { 'ok' } else { 'warn' }
        if ($m.Success) {
            $okN = [int]$m.Groups[1].Value; $failN = [int]$m.Groups[2].Value
            $txt += '; установлено: {0}, ошибок: {1}' -f $okN, $failN
            if ($failN -gt 0) { $st = 'warn'; Add-Issue 'info' 'Драйверы' ("SDIO не смог установить драйверов: $failN") 'Обычно драйверпак не успел скачаться торрентом. Запустите программу ещё раз — скачанное сохраняется.' }
        } elseif ($finished -and $lt -notmatch '(?i)installing') { $txt += '; подходящих обновлений нет' }
        if ($log) { $txt += ' (журнал: ' + $log.FullName + ')' }
        Add-Row $s 'Snappy Driver Installer' $txt $st
        if ($inst.Count) { Add-Table $s 'SDIO: журнал установки' ($inst | ForEach-Object { [pscustomobject]@{ 'Запись' = $_ } }) -Collapsed }
        if ($lt -match '(?i)reboot') { $G.RebootNeeded = $true }
    }

    # ---- 3. Автоустановка — отдельный скрипт BTT-Drivers.ps1 (файл выпуска, исходник pcdiag/ext/), запускается своим процессом:
    #         устройства без драйвера -> каталог Microsoft Update (.cab + pnputil), видеокарта NVIDIA -> свежий Game Ready с nvidia.com.
    #         Скрипт берётся из tools\ (если SHA-256 совпал с подписанным манифестом) или скачивается (GitHub)
    #         и сверяется с files.drivers подписанного version.json. Нет скрипта/проверка не прошла — только Windows Update (выше).
    $dsLocal = Join-Path $G.Tools 'BTT-Drivers.ps1'
    $dsPath = $null; $dsWhy = ''; $dsUnverified = $false
    $dsHash = { param($pth) try { return (Get-FileHash $pth -Algorithm SHA256 -ErrorAction Stop).Hash } catch { return '' } }
    $dsUrls = @(@{ U = "https://github.com/nigastyle/BigTechoTest-releases/releases/download/v$VER/BTT-Drivers.ps1"; T = $false })
    $dsWant = "$($G.ExtSha['drivers'])"
    # тестовая сборка (канал test) не выпущена на GitHub — берёт скрипт драйверов из своей папки
    if ($CHANNEL -ne 'stable') { $dsTest = Join-Path $G.Root 'BTT-Drivers.ps1'; if (Test-Path $dsTest) { $dsPath = $dsTest; $dsUnverified = $true } }
    if (-not $dsPath -and -not ($dsWant -and (Test-Path $dsLocal) -and (& $dsHash $dsLocal) -eq $dsWant)) {
        if (-not $dsWant) {
            $sm = Get-SignedManifest @(
                @{ Name = 'GitHub'; Manifest = "https://github.com/nigastyle/BigTechoTest-releases/releases/download/v$VER"; Files = 'https://github.com/nigastyle/BigTechoTest-releases/releases/download/v{0}'; Token = $false })
            if ($sm -and $sm.Info.files.drivers) {
                $dsWant = "$($sm.Info.files.drivers.sha256)".ToUpper()
                $dsUrls = @(@{ U = (($sm.Src.Files -f $sm.Info.version) + '/' + $sm.Info.files.drivers.name); T = [bool]$sm.Src.Token }) + $dsUrls
            } elseif ($sm) { $dsWhy = 'в манифесте выпуска нет скрипта драйверов' }
            else { $dsWhy = 'манифест выпуска недоступен (нет сети?)' }
        }
        if ($dsWant -and (Test-Path $dsLocal) -and (& $dsHash $dsLocal) -eq $dsWant) { $dsPath = $dsLocal }
        elseif ($dsWant) {
            Info 'скачиваю модуль автоустановки драйверов...'
            $dsTmp = Join-Path $G.Temp 'BTT-Drivers.ps1'
            foreach ($du in $dsUrls) {
                try {
                    Remove-Item $dsTmp -Force -ErrorAction SilentlyContinue
                    $wcd = New-Object Net.WebClient; if ($du.T) { $wcd.Headers.Add('X-Diag-Token', $UPLOAD.Token) }
                    $wcd.DownloadFile($du.U, $dsTmp)
                    if ((& $dsHash $dsTmp) -eq $dsWant) { try { Copy-Item $dsTmp $dsLocal -Force -ErrorAction Stop; $dsPath = $dsLocal } catch { $dsPath = $dsTmp }; break }
                    $dsWhy = 'контрольная сумма скачанного скрипта не совпала с подписанным манифестом'; $G.Log.Add("drvauto: SHA-256 не совпал: $($du.U)")
                } catch { if (-not $dsWhy) { $dsWhy = 'не удалось скачать скрипт драйверов' }; $G.Log.Add("drvauto: $($du.U): $($_.Exception.Message)") }
            }
            if ($dsPath) { $dsWhy = '' }
        }
        # сети нет и проверить нечем — копия в папке программы (там же, где сама программа)
        if (-not $dsPath -and -not $dsWant -and (Test-Path $dsLocal)) { $dsPath = $dsLocal; $dsUnverified = $true; $G.Log.Add('drvauto: манифест недоступен, используется tools\BTT-Drivers.ps1 без сверки') }
    } elseif (-not $dsPath) { $dsPath = $dsLocal }
    if (-not $dsPath) {
        if (-not $dsWhy) { $dsWhy = 'скрипт драйверов недоступен' }
        Warn ('автоустановка драйверов (каталог Microsoft, NVIDIA) пропущена: ' + $dsWhy)
        Add-Row $s 'Автоустановка драйверов (каталог Microsoft, NVIDIA)' ('не выполнялась: ' + $dsWhy + ' — драйверы ставились только через Windows Update (выше)') 'warn'
    } else {
        $dsJson = Join-Path $G.Temp 'drivers_result.json'; $dsLog = Join-Path $G.Temp 'drivers_log.txt'
        Remove-Item $dsJson, $dsLog -Force -ErrorAction SilentlyContinue
        $dsArgs = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Mode {1} -Nvidia -OutJson "{2}" -LogFile "{3}" -Root "{4}"' -f $dsPath, $(if ($drvInst) { 'Install' } else { 'Search' }), $dsJson, $dsLog, $G.Root.TrimEnd('\')
        if ($drvInst -and -not $G.DrvRP) { $dsArgs += ' -RestorePoint'; $G.DrvRP = $true }
        if ($G.UpdFirmware) { $dsArgs += ' -Firmware' }
        Info ('автоустановка драйверов: отдельное окно «BigTechoTest — драйверы» (до 40 мин){0}...' -f $(if ($CHANNEL -ne 'stable') { ', тестовая сборка' } elseif ($dsUnverified) { ', без сверки (нет сети)' } else { '' }))
        $dsT0 = Get-Date; $dsSeen = 0; $dsTimeout = $false
        try {
            $dsProc = Start-Process (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList $dsArgs -WindowStyle Minimized -PassThru
            $null = $dsProc.Handle
            while ($true) {
                $dsDone = $dsProc.WaitForExit(3000)
                # строки прогресса скрипта ('ЧЧ:ММ:СС > текст') — в основное окно
                try {
                    if (Test-Path $dsLog) {
                        $dsLines = @([IO.File]::ReadAllLines($dsLog, [Text.Encoding]::UTF8))
                        for ($k = $dsSeen; $k -lt $dsLines.Count; $k++) { if ($dsLines[$k] -match '^\d\d:\d\d:\d\d > (.*)$') { Info $Matches[1] } }
                        $dsSeen = $dsLines.Count
                    }
                } catch {}
                if ($dsDone) { break }
                if (((Get-Date) - $dsT0).TotalMinutes -gt 40) { $dsTimeout = $true; try { $dsProc.Kill() } catch {}; break }
            }
        } catch { $G.Log.Add('drvauto: запуск: ' + $_.Exception.Message) }
        try { $G.Log.Add(('drvauto: код выхода {0}, {1:N0} с; запуск: {2}' -f $dsProc.ExitCode, ((Get-Date) - $dsT0).TotalSeconds, $dsArgs)) } catch {}
        $dsRes = $null
        try { if (Test-Path $dsJson) { $dsRes = [IO.File]::ReadAllText($dsJson, [Text.Encoding]::UTF8) | ConvertFrom-Json } } catch { $G.Log.Add('drvauto: результат: ' + $_.Exception.Message) }
        if (-not $dsRes) {
            $dsWhy = $(if ($dsTimeout) { 'не уложилась в 40 мин и остановлена' } else { 'завершилась без результата' })
            Warn ('автоустановка драйверов ' + $dsWhy)
            Add-Row $s 'Автоустановка драйверов (каталог Microsoft, NVIDIA)' ($dsWhy + ' — см. журнал; драйверы из Windows Update (выше) установлены') 'warn'
            if ($dsTimeout) { $G.RebootNeeded = $true }
        } else {
            foreach ($ln in @($dsRes.log)) { $G.Log.Add('drvauto: ' + $ln) }
            if ($dsRes.restorePoint) { Add-Row $s 'Точка восстановления' $dsRes.restorePoint $(if ($dsRes.restorePoint -eq 'создана') { 'ok' } else { 'warn' }) }
            if ($dsRes.rebootNeeded) { $G.RebootNeeded = $true }
            $dsItems = @($dsRes.items | Where-Object { $_ })
            $ra = @($dsItems | ForEach-Object { [pscustomobject]@{ 'Устройство' = $_.device; 'Было' = $_.was; 'Поставлено' = $_.installed; 'Источник' = $_.source; 'Результат' = $_.result } })
            if ($ra.Count) { Add-Table $s 'Автоустановка драйверов: результат' $ra }
            # «не удалось узнать последнюю версию» — это не сбой установки, а несостоявшаяся проверка (нет связи с сайтом): в неудачи не считаем
            $dsNoChk = @($dsItems | Where-Object { "$($_.result)" -match 'не удалось узнать последнюю версию' })
            if ($dsNoChk.Count) { Add-Row $s 'Не проверено' ('свежесть драйвера не удалось проверить (нет связи с сайтом производителя): ' + (($dsNoChk | ForEach-Object { $_.device }) -join '; ')) 'warn' }
            $fa = @($dsItems | Where-Object { $_.link -and "$($_.result)" -notmatch 'не удалось узнать последнюю версию' } | ForEach-Object { [pscustomobject]@{ 'Устройство' = $_.device; 'ИД оборудования' = $_.hwid; 'Где искать' = $_.link } })
            if ($fa.Count) {
                Add-Table $s 'Не удалось установить автоматически — где искать вручную' $fa
                Add-Issue 'info' 'Устройства' ('не удалось автоматически установить драйверов: {0}' -f $fa.Count) 'См. таблицу «Не удалось установить автоматически» в разделе драйверов — там ссылки на поиск.'
            }
            $okN = @($ra | Where-Object { $_.'Результат' -match '^установлен' }).Count
            if ($okN) { Ok ('автоматически установлено драйверов: {0}' -f $okN) }
        }
    }
    if ($drvInst) { $null = pnputil /scan-devices 2>&1; Start-Sleep -Seconds 5 }
    $badNow = @(CIM Win32_PnPEntity | Where-Object { $_.ConfigManagerErrorCode -and $_.ConfigManagerErrorCode -notin 0, 22, 24, 45 })
    Add-Row $s 'Проблемных устройств: до → после' ('{0} → {1}' -f $G.BadDevBefore, $badNow.Count) $(if ($badNow.Count -eq 0) { 'ok' } else { 'warn' })
    if ($G.RebootNeeded) { Add-Issue 'info' 'Драйверы' 'для завершения установки драйверов нужна перезагрузка' 'Перезагрузите компьютер.' }
    Add-Row $s 'BIOS' ('Обновления BIOS (автоматически не ставятся): ' + (Vendor-Tool))
}

# =====================================================================
if ($G.MemDiag) {
    Step 'Планирование проверки памяти' {
        # Средство проверки памяти Windows (memtest.efi) запускается загрузчиком ОДИН раз при следующей загрузке:
        # bcdedit /bootsequence {memdiag} — то же, что делает mdsched.exe «проверить при следующем включении», но без окна.
        # Режим по умолчанию — «Обычный» (2 прохода); «Расширенный» можно выбрать клавишей F1 на экране проверки
        # (или заранее: bcdedit /set {memdiag} testmix extended — не меняем, расширенный идёт часами).
        # BitLocker не мешает: memtest.efi запускается из Диспетчера загрузки Windows и диск не трогает.
        $mdEnum = (bcdedit /enum '{memdiag}' 2>&1) -join "`n"
        if ($mdEnum -notmatch '(?i)memtest') {
            Warn 'в загрузчике нет средства проверки памяти Windows ({memdiag})'
            Add-Issue 'info' 'Память' 'не удалось запланировать проверку памяти Windows (нет записи {memdiag} в загрузчике)' 'Проверьте память MemTest86 с загрузочной флешки.'
            return
        }
        $null = bcdedit /bootsequence '{memdiag}' 2>&1
        $mdSet = ((bcdedit /enum '{bootmgr}' 2>&1) -join "`n") -match '(?im)^bootsequence\s+.*\{memdiag\}'
        if (-not $mdSet) {
            Warn 'не удалось запланировать — запустите mdsched.exe вручную'
            Add-Issue 'info' 'Память' 'не удалось запланировать проверку памяти Windows' 'Запустите mdsched.exe → «Выполнить перезагрузку и проверку».'
            return
        }
        try {
            if (-not (Test-Path 'HKCU:\Software\BigTechoTest')) { New-Item -Path 'HKCU:\Software\BigTechoTest' -Force | Out-Null }
            Set-ItemProperty -Path 'HKCU:\Software\BigTechoTest' -Name MemDiagScheduled -Value ((Get-Date).ToString('o')) -ErrorAction Stop
        } catch { $G.Log.Add("MemDiagScheduled: $($_.Exception.Message)") }
        $G.MemDiagScheduled = $true
        Ok 'проверка памяти запустится при следующей ПЕРЕЗАГРУЗКЕ (до загрузки Windows, ~20–40 мин)'
        Add-Issue 'info' 'Память' 'запланирована проверка памяти Windows при следующей перезагрузке' 'Перезагрузите компьютер (именно «Перезагрузка», не «Завершение работы»): проверка пройдёт до загрузки Windows, ~20–40 мин (F1 на экране проверки — расширенный режим, дольше). Результат программа покажет при следующем запуске.'
    }
}

# завершающий этап: разбор собранного и отчёт — выполняется и после кнопки «Остановить тесты», прерывания шагов отключены
$G.FinalPhase = $true
#%%MOD:final%%

# =====================================================================
Step 'Завершение' {
    if ($G.LHM) { try { $G.LHM.Close() } catch {} }
    if ($G.PawnInstalled) {
        $pi = Get-Tool 'PawnIO'
        if ($pi) { $p = Start-Process $pi -ArgumentList '-uninstall', '-silent' -Wait -PassThru; Info ('драйвер PawnIO удалён (код {0})' -f $p.ExitCode) }
    }
}

# =====================================================================
#  ОЦЕНКА И HTML-ОТЧЁТ
# =====================================================================
$pcId = ''
try { $u = (CIM Win32_ComputerSystemProduct | Select-Object -First 1).UUID; if ($u) { $pcId = -join ([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes("pcdiag:$u")) | Select-Object -First 8 | ForEach-Object { $_.ToString('x2') }) } } catch {}
$cmpRows = @()
if (-not $env:DIAG_NOSEND -and $G.Num.Count) {
    Info 'сравнение с другими компьютерами из базы...'
    $cmp = Get-Compare @{ pc_id = $pcId; num = $G.Num; cpu = $G.Summary['Процессор']; gpu = $G.Summary['Видеокарта']; disk = $G.Summary['Накопители']; ram = $G.Summary['Оперативная память'] }
    $labels = [ordered]@{ cpu_mips = @('Процессор: 7-Zip, все потоки', 'MIPS', 'cpu'); cpu_1t = @('Процессор: 7-Zip, 1 поток', 'MIPS', 'cpu'); gpu_score = @('Видеокарта: FurMark 1080p', 'баллов', 'gpu')
        disk_seq_r = @('Диск: последовательное чтение', 'МБ/с', 'disk'); disk_rnd_iops = @('Диск: случайное чтение 4К', 'IOPS', 'disk'); ram_read = @('Память: чтение, 1 поток', 'ГБ/с', 'ram') }
    if ($cmp -and $cmp.ok) {
        foreach ($k in $labels.Keys) {
            if ($null -eq $G.Num[$k]) { continue }
            $c = $cmp.metrics.$k; $lb = $labels[$k]
            $all = if (-not $c -or [int]$c.n_all -lt 5) { 'в базе пока мало данных' } else { 'лучше, чем у {0} % ПК (из {1})' -f [int]$c.pct, [int]$c.n_all }
            $same = '—'; $st = ''
            if ($c -and [int]$c.n_model -ge 1) {
                $d = if ([double]$c.median_model -gt 0) { ([double]$G.Num[$k] / [double]$c.median_model - 1) * 100 } else { 0 }
                $same = 'обычно {0:N0} {1} ({2} шт.), у вас {3}{4:N0} %' -f [double]$c.median_model, $lb[1], [int]$c.n_model, $(if ($d -ge 0) { '+' } else { '' }), $d
                if ([int]$c.n_model -ge 3) {
                    if ($d -le -15) {
                        $st = 'warn'
                        if ($lb[2] -in 'cpu', 'gpu') { Add-Issue 'warn' $(if ($lb[2] -eq 'cpu') { 'Процессор' } else { 'Видеокарта' }) ('{0}: на {1:N0} % ниже, чем у таких же компьютеров в базе' -f $lb[0], -$d) 'Частые причины: перегрев и троттлинг (пыль, засохшая термопаста), режим энергосбережения, ограничения в BIOS, фоновая нагрузка.' }
                    } elseif ($d -ge -5) { $st = 'ok' }
                }
            }
            $cmpRows += [pscustomobject]@{ N = $lb[0]; V = ('{0:N1} {1}' -f [double]$G.Num[$k], $lb[1]) -replace ',0 ', ' '; All = $all; Same = $same; St = $st }
        }
    }
}
$crit = @($G.Issues | Where-Object { $_.Sev -eq 'crit' }).Count
$warn = @($G.Issues | Where-Object { $_.Sev -eq 'warn' }).Count
$infoN = @($G.Issues | Where-Object { $_.Sev -eq 'info' }).Count
$score = [math]::Max(0, [math]::Min(100, 100 - 15 * $crit - 5 * $warn))
$verdict = if ($score -ge 90) { 'Отличное состояние' } elseif ($score -ge 75) { 'Хорошее состояние, есть рекомендации' } elseif ($score -ge 50) { 'Есть проблемы, требующие внимания' } else { 'Серьёзные проблемы' }
$color = if ($score -ge 90) { '#1f9d55' } elseif ($score -ge 75) { '#3b82f6' } elseif ($score -ge 50) { '#d98b00' } else { '#d64545' }
$dur = (Get-Date) - $G.Start

function HE($t) { return [System.Net.WebUtility]::HtmlEncode([string]$t) }
$sb = New-Object System.Text.StringBuilder
function A($t) { [void]$sb.Append($t) }
A '<!doctype html><html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
A ('<title>BigTechoTest — {0}</title>' -f (HE $G.Summary['Компьютер']))
A @'
<style>
:root{--bg:#f3f5f9;--card:#fff;--text:#1d2330;--muted:#687186;--line:#e3e7ee;--ok:#1f9d55;--warn:#c98200;--crit:#d64545;--info:#3b82f6;--accent:#2f6fde}
@media (prefers-color-scheme:dark){:root{--bg:#11151c;--card:#1a1f29;--text:#e6e9ef;--muted:#9aa3b5;--line:#2a313d}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:15px/1.55 "Segoe UI",system-ui,sans-serif}
.wrap{max-width:1150px;margin:0 auto;padding:24px 16px 60px}
header{display:flex;gap:28px;align-items:center;flex-wrap:wrap;background:var(--card);border:1px solid var(--line);border-radius:16px;padding:22px 26px}
h1{margin:0 0 4px;font-size:25px}.sub{color:var(--muted)}
.score{width:128px;height:128px;position:relative;flex:none}.score svg{transform:rotate(-90deg)}
.score .n{position:absolute;inset:0;display:flex;flex-direction:column;align-items:center;justify-content:center;font-size:34px;font-weight:700}
.score .n small{font-size:12px;font-weight:400;color:var(--muted)}
.verdict{font-size:19px;font-weight:600;margin-top:6px}
.counts span{display:inline-block;margin:8px 8px 0 0;padding:3px 12px;border-radius:99px;font-size:13px;font-weight:600;color:#fff}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(250px,1fr));gap:12px;margin:16px 0}
.card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:13px 16px}
.card .k{color:var(--muted);font-size:12px;text-transform:uppercase;letter-spacing:.04em}.card .v{font-weight:600;margin-top:3px;word-break:break-word}
section{background:var(--card);border:1px solid var(--line);border-radius:16px;padding:18px 22px;margin:16px 0}
h2{margin:0 0 12px;font-size:19px}h3{font-size:15px;margin:18px 0 6px}
table{width:100%;border-collapse:collapse;font-size:14px}td,th{padding:7px 10px;border-bottom:1px solid var(--line);text-align:left;vertical-align:top}
th{color:var(--muted);font-weight:600;font-size:12px;text-transform:uppercase;white-space:nowrap}
table.kv td:first-child{color:var(--muted);width:34%}
.tw{overflow-x:auto}
.issue{border-left:4px solid var(--info);padding:10px 14px;margin:8px 0;background:var(--bg);border-radius:0 10px 10px 0}
.issue.crit{border-color:var(--crit)}.issue.warn{border-color:var(--warn)}
.issue .a{font-size:12px;color:var(--muted);text-transform:uppercase;letter-spacing:.04em}.issue .t{font-weight:600}.issue .f{color:var(--muted);margin-top:3px}
.allok{border-left:4px solid var(--ok);padding:12px 16px;background:var(--bg);border-radius:0 10px 10px 0;font-weight:600}
.st-ok{color:var(--ok);font-weight:600}.st-warn{color:var(--warn);font-weight:600}.st-crit{color:var(--crit);font-weight:600}
details>summary{cursor:pointer;color:var(--accent);margin:14px 0 6px;font-weight:600}
footer{color:var(--muted);font-size:13px;text-align:center;margin-top:30px}
@media print{body{background:#fff}section,header,.card{break-inside:avoid}}
</style></head><body><div class="wrap">
'@
$circ = 2 * [math]::PI * 54
A '<header>'
A ('<div class="score"><svg width="128" height="128"><circle cx="64" cy="64" r="54" fill="none" stroke="var(--line)" stroke-width="12"/><circle cx="64" cy="64" r="54" fill="none" stroke="{0}" stroke-width="12" stroke-linecap="round" stroke-dasharray="{1} {2}"/></svg><div class="n">{3}<small>из 100</small></div></div>' -f $color, ($circ * $score / 100).ToString($IC), $circ.ToString($IC), $score)
A ('<div><h1>{0}</h1><div class="sub">Отчёт от {1} · режим: {2} · длительность {3:N0} мин · BigTechoTest v{4}</div>' -f (HE $G.Summary['Компьютер']), (Get-Date -Format 'dd.MM.yyyy HH:mm'), $(switch ($G.Mode) { 'full' { 'полный' } 'custom' { 'выбранные тесты' } default { 'быстрый' } }), $dur.TotalMinutes, $VER)
A ('<div class="verdict" style="color:{0}">{1}</div>' -f $color, (HE $verdict))
A ('<div class="counts"><span style="background:var(--crit)">Критично: {0}</span><span style="background:var(--warn)">Внимание: {1}</span><span style="background:var(--info)">Советы: {2}</span></div></div>' -f $crit, $warn, $infoN)
A '</header>'
A '<div class="grid">'
foreach ($k in $G.Summary.Keys) { A ('<div class="card"><div class="k">{0}</div><div class="v">{1}</div></div>' -f (HE $k), (HE $G.Summary[$k])) }
A '</div>'
A '<section><h2>Проблемы и рекомендации</h2>'
$ord = @{ crit = 0; warn = 1; info = 2 }
$iss = @($G.Issues | Sort-Object { $ord[$_.Sev] })
if (($crit + $warn) -eq 0) { A $(if ($G.Mode -eq 'custom') { '<div class="allok">В выбранных проверках серьёзных проблем не обнаружено.</div>' } else { '<div class="allok">Серьёзных проблем не обнаружено — компьютер в порядке.</div>' }) }
if ($G.Mode -eq 'custom') {
    $notRun = @($G.Skipped | ForEach-Object { $_ -replace '^Тесты с вашим участием$', 'тесты с участием пользователя' })
    if ($notRun.Count) { A ('<div class="issue"><div class="a">Выборочная проверка</div><div class="t">Не проверялось: {0}</div><div class="f">Для полной картины запустите быструю или полную диагностику.</div></div>' -f (HE ($notRun -join '; '))) }
}
foreach ($i in $iss) {
    $lbl = switch ($i.Sev) { 'crit' { 'Критично' } 'warn' { 'Внимание' } default { 'Совет' } }
    A ('<div class="issue {0}"><div class="a">{1} · {2}</div><div class="t">{3}</div>{4}</div>' -f $i.Sev, $lbl, (HE $i.Area), (HE $i.Text), $(if ($i.Fix) { '<div class="f">' + (HE $i.Fix) + '</div>' } else { '' }))
}
A '</section>'
if ($G.Bench.Count) {
    A '<section><h2>Бенчмарки и замеры</h2><table class="kv">'
    foreach ($k in $G.Bench.Keys) { A ('<tr><td>{0}</td><td>{1}</td></tr>' -f (HE $k), (HE $G.Bench[$k])) }
    A '</table>'
    if ($cmpRows.Count) {
        A '<h3>Сравнение с другими компьютерами из базы</h3><div class="tw"><table><tr><th>Тест</th><th>Ваш результат</th><th>Среди всех ПК</th><th>Среди таких же моделей</th></tr>'
        foreach ($r in $cmpRows) { A ('<tr><td>{0}</td><td>{1}</td><td>{2}</td><td{3}>{4}</td></tr>' -f (HE $r.N), (HE $r.V), (HE $r.All), $(if ($r.St) { ' class="st-' + $r.St + '"' } else { '' }), (HE $r.Same)) }
        A '</table></div>'
    }
    A '</section>'
}
foreach ($sec in $G.Sections) {
    if ($sec.Rows.Count -eq 0 -and $sec.Tables.Count -eq 0) { continue }
    A ('<section><h2>{0}</h2>' -f (HE $sec.Title))
    if ($sec.Rows.Count) {
        A '<table class="kv">'
        foreach ($r in $sec.Rows) { A ('<tr><td>{0}</td><td{1}>{2}</td></tr>' -f (HE $r.K), $(if ($r.St) { ' class="st-' + $r.St + '"' } else { '' }), (HE $r.V)) }
        A '</table>'
    }
    foreach ($t in $sec.Tables) {
        $cols = @($t.Data[0].PSObject.Properties | Where-Object { $_.Name -notlike '_*' } | ForEach-Object { $_.Name })
        $coll = $t.Collapsed -or $t.Data.Count -gt 25
        if ($coll) { A ('<details><summary>{0} — показать</summary>' -f (HE $t.Title)) } else { A ('<h3>{0}</h3>' -f (HE $t.Title)) }
        A '<div class="tw"><table><tr>'
        foreach ($c in $cols) { A ('<th>{0}</th>' -f (HE $c)) }
        A '</tr>'
        foreach ($row in $t.Data) {
            A '<tr>'
            foreach ($c in $cols) {
                $v = "$($row.$c)"
                $cls = if ($v -match '^(ОШИБКА|НЕИСПРАВЕН|ПРЕДУПРЕЖДЕНИЕ|НЕТ|сбой|устарели|ПЛОХО)$') { ' class="st-crit"' } elseif ($v -match '^(ТРЕВОГА)$') { ' class="st-warn"' } elseif ($v -match '^(OK|исправен|подключён|актуальны|установлен|хорошо)$') { ' class="st-ok"' } else { '' }
                A ('<td{0}>{1}</td>' -f $cls, (HE $v))
            }
            A '</tr>'
        }
        A '</table></div>'
        if ($coll) { A '</details>' }
    }
    A '</section>'
}
A '<section><details><summary>Технический журнал работы программы</summary><pre style="white-space:pre-wrap;font-size:12px">'
A (HE ($G.Log -join "`n"))
A '</pre></details></section>'
A '<button class="pbtn" onclick="window.print()">Сохранить в PDF / печать</button><style>.pbtn{position:fixed;right:18px;bottom:18px;padding:10px 16px;border:0;border-radius:10px;background:#2f6fde;color:#fff;font:600 14px Segoe UI,sans-serif;cursor:pointer;box-shadow:0 4px 14px rgba(0,0,0,.2)}@media print{.pbtn{display:none}details{display:block}details>*{display:block}}</style>'
A ('<footer>BigTechoTest v{0} · Big Techno Club · используются LibreHardwareMonitor, HWiNFO, FurMark 2, Prime95, y-cruncher, Intel MKL Linpack, TestMem5, memtest_vulkan, smartmontools, DiskSpd, 7-Zip, BlueScreenView, CPU-Z, Speedtest by Ookla, Snappy Driver Installer Origin</footer>' -f $VER)
$meta = [ordered]@{
    v = $VER; pc_id = $pcId; machine = $G.Summary['Компьютер']; kind = $(if ($G.IsLaptop) { 'laptop' } else { 'desktop' })
    board = $G.Summary['Материнская плата']; cpu = $G.Summary['Процессор']; gpu = $G.Summary['Видеокарта']; ram = $G.Summary['Оперативная память']
    disk = $G.Summary['Накопители']; os = $G.Summary['Windows']; battery = $G.Summary['Аккумулятор']
    mode = $G.Mode; tests = @($G.Sel.Keys | Where-Object { $G.Sel[$_] -is [bool] -and $G.Sel[$_] } | Sort-Object); duration_min = [math]::Round($dur.TotalMinutes)
    score = $score; crit = $crit; warn = $warn; info = $infoN
    cpu_mips = $G.Num.cpu_mips; gpu_score = $G.Num.gpu_score; num = $G.Num
    issues = @($G.Issues | ForEach-Object { [ordered]@{ level = $_.Sev; area = $_.Area; text = $_.Text } })
    bench = $G.Bench; cooling = $G.Cooling; shutdowns = $G.Shutdowns; av_threats = $G.AvThreats
}
A ('<script type="application/json" id="diag-meta">{0}</script>' -f (($meta | ConvertTo-Json -Depth 5 -Compress) -replace '</', '<\/'))
A '</div></body></html>'

$desk = [Environment]::GetFolderPath('Desktop')
if ($env:DIAG_OUT) { $desk = $env:DIAG_OUT }
$safe = ($G.Summary['Компьютер'] -replace '[\\/:*?"<>|()]', '' -replace '\s+', '_').Trim('_')
if ($safe.Length -gt 60) { $safe = $safe.Substring(0, 60) }
$out = Join-Path $desk ('Диагностика_{0}_{1}.html' -f $safe, (Get-Date -Format 'yyyy-MM-dd_HH-mm'))
[IO.File]::WriteAllText($out, $sb.ToString(), (New-Object Text.UTF8Encoding $true))
try { $rep = Join-Path $G.Root 'reports'; New-Item -ItemType Directory -Force $rep | Out-Null; if ((Resolve-Path $rep).Path -ne (Split-Path $out)) { Copy-Item $out $rep -Force } } catch {}

# ---- Короткий отчёт для владельца компьютера: одна страница, понятным языком ----
$cs = New-Object Text.StringBuilder
function C($t) { [void]$cs.Append($t) }
$groups = [ordered]@{
    'Процессор и охлаждение' = 'Процессор|Охлаждение'; 'Оперативная память' = 'Память'; 'Видеокарта' = 'Видеокарта'
    'Диски (SSD / HDD)' = 'Накопитель|Диск'; 'Аккумулятор и зарядка' = 'Аккумулятор|Зарядка'; 'Стабильность Windows' = 'Стабильность|Windows|Оборудование'
    'Безопасность и программы' = 'Безопасность|Программы'; 'Сеть и Wi-Fi' = 'Сеть|Wi-Fi|Интернет'; 'Устройства и драйверы' = 'Звук|Микрофон|Камера|Клавиатура|Тачпад|Мышь|Экран|Драйверы|Устройства|BIOS'
}
C '<!doctype html><html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
C ('<title>Итог диагностики — {0}</title><style>' -f (HE $G.Summary['Компьютер']))
C ':root{--bg:#f3f5f9;--card:#fff;--text:#1d2330;--muted:#687186;--line:#e3e7ee;--ok:#1f9d55;--warn:#c98200;--crit:#d64545;--accent:#2f6fde}'
C '*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:15px/1.55 "Segoe UI",system-ui,sans-serif}.wrap{max-width:820px;margin:0 auto;padding:24px 16px 40px}'
C '.card{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:18px 22px;margin:12px 0}h1{font-size:22px;margin:0}h2{font-size:17px;margin:0 0 10px}.sub{color:var(--muted);font-size:13px}'
C '.head{display:flex;gap:22px;align-items:center;flex-wrap:wrap}.ring{width:96px;height:96px;border-radius:50%;display:flex;align-items:center;justify-content:center;font-size:30px;font-weight:700;color:#fff;flex:none}'
C '.chk{display:grid;grid-template-columns:repeat(auto-fill,minmax(230px,1fr));gap:6px 18px}.chk div{padding:3px 0}.i{display:inline-block;width:22px;font-weight:700}'
C '.p{border-left:4px solid var(--warn);padding:8px 12px;margin:8px 0;background:var(--bg);border-radius:0 8px 8px 0}.p.crit{border-color:var(--crit)}.p .t{font-weight:600}.p .f{color:var(--muted);font-size:14px;margin-top:2px}'
C 'table{width:100%;border-collapse:collapse;font-size:14px}td{padding:5px 0;border-bottom:1px solid var(--line);vertical-align:top}td:first-child{color:var(--muted);width:42%;padding-right:10px}'
C '.btns{display:flex;gap:10px;flex-wrap:wrap;margin-top:6px}.btn{padding:9px 16px;border-radius:10px;border:1px solid var(--line);background:var(--card);color:var(--text);font:600 14px Segoe UI,sans-serif;cursor:pointer;text-decoration:none}.btn.pr{background:var(--accent);color:#fff;border-color:var(--accent)}'
C '@media print{body{background:#fff}.btns{display:none}.card{break-inside:avoid;border-color:#ccc}}</style></head><body><div class="wrap">'
C ('<div class="card head"><div class="ring" style="background:{0}">{1}</div><div><h1>Итог диагностики компьютера</h1><div class="sub">{2} · {3}</div><div style="font-size:18px;font-weight:600;color:{0};margin-top:4px">{4}</div></div></div>' -f $color, $score, (HE $G.Summary['Компьютер']), (Get-Date -Format 'dd.MM.yyyy'), (HE $verdict))
C '<div class="card"><h2>Что проверено</h2><div class="chk">'
# ВНИМАНИЕ: имена переменных в PowerShell не различают регистр — $g затёр бы глобальный $G
$need = @{ 'Процессор и охлаждение' = 'cpu', 'prime', 'ycr'; 'Оперативная память' = 'ram', 'ycr'; 'Видеокарта' = 'gpu'; 'Стабильность Windows' = 'logs'; 'Сеть и Wi-Fi' = 'net' }
foreach ($grpName in $groups.Keys) {
    if ($grpName -eq 'Аккумулятор и зарядка' -and -not $G.IsLaptop) { continue }
    $gi = @($G.Issues | Where-Object { $_.Area -match "^($($groups[$grpName]))" })
    $tested = -not $need.ContainsKey($grpName) -or @($need[$grpName] | Where-Object { $G.Sel[$_] }).Count -gt 0
    if (@($gi | Where-Object Sev -eq 'crit').Count) { $mark = '✗'; $cl = 'var(--crit)'; $tx = 'есть неисправности' }
    elseif (@($gi | Where-Object Sev -eq 'warn').Count) { $mark = '!'; $cl = 'var(--warn)'; $tx = 'требует внимания' }
    elseif (-not $tested) { $mark = '–'; $cl = 'var(--muted)'; $tx = 'не проверялось' }
    else { $mark = '✓'; $cl = 'var(--ok)'; $tx = 'в порядке' }
    C ('<div><span class="i" style="color:{0}">{1}</span>{2} — <span style="color:{0}">{3}</span></div>' -f $cl, $mark, (HE $grpName), $tx)
}
C '</div></div>'
$imp = @($G.Issues | Where-Object { $_.Sev -in 'crit', 'warn' } | Sort-Object @{ e = { if ($_.Sev -eq 'crit') { 0 } else { 1 } } })
C '<div class="card"><h2>Что нужно сделать</h2>'
if ($imp.Count) { foreach ($i in $imp) { C ('<div class="p {0}"><div class="t">{1}: {2}</div>{3}</div>' -f $i.Sev, (HE $i.Area), (HE $i.Text), $(if ($i.Fix) { '<div class="f">' + (HE $i.Fix) + '</div>' } else { '' })) } }
else { C '<div style="color:var(--ok);font-weight:600">Серьёзных проблем не найдено — компьютер в хорошем состоянии.</div>' }
$tips = @($G.Issues | Where-Object { $_.Sev -eq 'info' })
if ($tips.Count) { C ('<div class="sub" style="margin-top:10px">Ещё советов: {0} — см. подробный отчёт.</div>' -f $tips.Count) }
C '</div>'
# ---- обновление BIOS: файл уже скачан программой (lib-97-biosupd)
if ($G.BiosUpd -and $G.BiosUpd.State -eq 'update') {
    $bu = $G.BiosUpd
    C '<div class="card"><h2>Обновление BIOS</h2>'
    C ('<div class="p"><div class="t">BIOS устарел: установлена версия {0}, у производителя есть {1} от {2}</div>' -f (HE $bu.Inst), (HE $bu.NewVer), (HE (DT $bu.NewDate)))
    if ($bu.Notes) { C ('<div class="f">Что нового: {0}</div>' -f (HE $bu.Notes)) }
    C '</div>'
    if ($bu.Folder) {
        C ('<div><b>Файл для обновления уже скачан</b> — папка на рабочем столе:<br><a href="{0}">{1}</a></div>' -f (HE ([uri]$bu.Folder).AbsoluteUri), (HE (Split-Path $bu.Folder -Leaf)))
        C '<div class="sub" style="margin-top:6px">Внутри — файл прошивки от производителя и пошаговая инструкция «КАК ОБНОВИТЬ BIOS.txt». Программа сама BIOS не прошивает: обновлять нужно при стабильном питании, не выключая компьютер.'
        if ($bu.Kit) { C ' <b>В архиве готовый загрузочный комплект: копируется на флешку FAT32, прошивка запускается сама при загрузке с неё.</b>' }
        elseif ($bu.Manual) { C ' <b>Эта версия ставится вручную из UEFI Shell — читайте инструкцию.</b>' }
        C '</div>'
    } else {
        C ('<div>Скачать автоматически не получилось{0}. Страница модели у производителя: <a href="{1}">{2}</a></div>' -f $(if ($bu.Err) { ' (' + (HE $bu.Err) + ')' } else { '' }), (HE $bu.Page), (HE $bu.Page))
    }
    C '</div>'
}
C '<div class="card"><h2>Конфигурация</h2><table>'
foreach ($k in 'Процессор', 'Оперативная память', 'Видеокарта', 'Накопители', 'Охлаждение процессора', 'Аккумулятор', 'Windows') { if ($G.Summary[$k]) { C ('<tr><td>{0}</td><td>{1}</td></tr>' -f (HE $k), (HE $G.Summary[$k])) } }
C '</table></div>'
C ('<div class="btns"><button class="btn pr" onclick="window.print()">Сохранить в PDF / печать</button><a class="btn" href="{0}">Подробный технический отчёт</a></div>' -f [uri]::EscapeDataString((Split-Path $out -Leaf)))
C ('<div class="sub" style="margin-top:18px;text-align:center">BigTechoTest v{0} · Big Techno Club</div></div></body></html>' -f $VER)
$sumOut = Join-Path (Split-Path $out) ('Итог_диагностики_{0}_{1}.html' -f $safe, (Get-Date -Format 'yyyy-MM-dd_HH-mm'))
try { [IO.File]::WriteAllText($sumOut, $cs.ToString(), (New-Object Text.UTF8Encoding $true)) } catch { $sumOut = $null }

if (-not $env:DIAG_NOSEND) {
    Info 'отправка отчёта в сервис...'
    if (Send-Report $out) { Ok 'отчёт отправлен'; Send-Pending }
    else { $ud = Get-UnsentDir; if ($ud) { Copy-Item $out $ud -Force -ErrorAction SilentlyContinue }; Warn 'нет связи с сервером — отчёт отправится при следующем запуске программы' }
}

# временные файлы (скачанные архивы, записи микрофона, файлы тестов) больше не нужны
try { Remove-Item $G.Temp -Recurse -Force -ErrorAction SilentlyContinue } catch {}

Title 'ГОТОВО'
Say ('Оценка состояния: {0}/100 — {1}' -f $score, $verdict) 'White'
Say ('Критичных проблем: {0}, требуют внимания: {1}, советов: {2}' -f $crit, $warn, $infoN) 'White'
Say ('Отчёт сохранён: {0}' -f $out) 'Green'
if ($sumOut) { Say ('Краткий итог для владельца: {0}' -f $sumOut) 'Green' }
if ($G.BiosUpd -and $G.BiosUpd.State -eq 'update') {
    if ($G.BiosUpd.Folder) { Say ('BIOS УСТАРЕЛ: есть версия {0} от {1}. Файл для обновления и инструкция: {2}' -f $G.BiosUpd.NewVer, (DT $G.BiosUpd.NewDate), $G.BiosUpd.Folder) 'Yellow' }
    else { Say ('BIOS УСТАРЕЛ: есть версия {0} от {1}. Скачать: {2}' -f $G.BiosUpd.NewVer, (DT $G.BiosUpd.NewDate), $G.BiosUpd.Page) 'Yellow' }
}
if ($G.MemDiagScheduled) { if (MemResult-Register $out $sumOut) { Say 'После перезагрузки и проверки памяти программа сама покажет результат и допишет его в этот отчёт.' 'White' } }
if ($G.MemDiagScheduled) { Say 'ПЕРЕЗАГРУЗИТЕ КОМПЬЮТЕР — проверка памяти пройдёт до загрузки Windows (~20–40 мин), результат программа покажет при следующем запуске. Нужна именно «Перезагрузка», не «Завершение работы».' 'Yellow' }
if ($G.RemoteOn) { Remote-Finish ('Оценка {0}/100 · критично: {1}, внимание: {2}' -f $score, $crit, $warn) $score }
if (-not $G.Auto) {
    # из BigTechoTest.exe: итоговая панель онлайн-окна (кнопки отчётов), браузер сам не открываем
    $guiRun = ($env:DIAG_GUI -eq '1')
    if ($G.LiveOk) { Live-Finish ('Оценка {0}/100 · критично: {1}, внимание: {2}' -f $score, $crit, $warn) $score; Live-SetReports $out $sumOut (Split-Path $out) }
    if (-not ($guiRun -and $G.LiveOk)) { Start-Process $(if ($sumOut) { $sumOut } else { $out }) }
    if ($G.MemDiagScheduled) {
        # bootsequence {memdiag} срабатывает только при загрузке через загрузчик: нужна именно «Перезагрузка»
        if (AskYN 'Перезагрузить компьютер сейчас и начать проверку памяти (~20–40 мин, до загрузки Windows)?' 'N') { Restart-Computer -Force }
    }
    elseif ($G.RebootNeeded) { if (AskYN 'Для завершения установки драйверов нужна перезагрузка. Перезагрузить сейчас?' 'N') { Restart-Computer -Force } }
    if ($G.BiosUpd -and $G.BiosUpd.State -eq 'update' -and $G.BiosUpd.Folder) {
        $bq = "BIOS этого компьютера устарел.`nУстановлена версия: {0}`nУ производителя есть: {1} от {2} (пропущено версий: {3})`n`nФайл для обновления уже скачан, рядом лежит инструкция «КАК ОБНОВИТЬ BIOS.txt».{4}`nПрограмма сама BIOS не прошивает.`n`nОткрыть папку с файлом обновления?" -f $G.BiosUpd.Inst, $G.BiosUpd.NewVer, (DT $G.BiosUpd.NewDate), $G.BiosUpd.Skipped, $(if ($G.BiosUpd.Manual) { "`nВНИМАНИЕ: эта версия ставится вручную из UEFI Shell — сначала прочитайте инструкцию." } else { '' })
        if (AskYN $bq 'Y') { try { Start-Process explorer.exe ('"' + $G.BiosUpd.Folder + '"') } catch {} }
    }
    if ($guiRun) { Live-WaitClosed } else { [void](Read-Host 'Нажмите Enter для выхода') }
}
