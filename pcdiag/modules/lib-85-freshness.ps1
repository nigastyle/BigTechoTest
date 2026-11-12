# ---------------------------------------------------------------- актуальность драйверов и BIOS: веб-помощники
# Наружу уходят только названия моделей (видеокарта, материнская плата) — никаких серийных номеров и имени компьютера.
$FRESH = @{ Fails = 0 }
$FRESH_UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36'

# GET с таймаутом 15 с: Invoke-WebRequest, при сбое — curl.exe. Возвращает текст или $null (никогда не бросает исключение).
function Fresh-Get($Url) {
    if ($FRESH.Fails -ge 3) { return $null }   # сети явно нет — не тратим время
    $txt = $null
    try {
        $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -UserAgent $FRESH_UA -TimeoutSec 15 -ErrorAction Stop
        if ($r -and $r.Content) {
            if ($r.Content -is [byte[]]) { $txt = [Text.Encoding]::UTF8.GetString($r.Content) } else { $txt = [string]$r.Content }
        }
    } catch {}
    if (-not $txt) {
        try {
            $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
            if (Test-Path $curl) {
                $raw = & $curl -fsSL --max-time 15 -A $FRESH_UA $Url 2>$null
                if ($raw) { $txt = ($raw -join "`n") }
            }
        } catch {}
    }
    if ($txt) { $FRESH.Fails = 0; return $txt }
    $FRESH.Fails = $FRESH.Fails + 1
    return $null
}

function Fresh-ParseVer($v) {
    # '572.13' / '26.11.1' / '3645' -> [version] (или $null)
    try {
        $m = [regex]::Match("$v", '\d+(\.\d+){0,3}')
        if (-not $m.Success) { return $null }
        $t = $m.Value; if ($t -notmatch '\.') { $t = $t + '.0' }
        return [version]$t
    } catch { return $null }
}

# Даты разных форматов -> [datetime] или $null
function Fresh-ParseDate($t, $fmts) {
    foreach ($f in $fmts) {
        $d = [datetime]::MinValue
        if ([datetime]::TryParseExact("$t".Trim(), $f, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$d)) { return $d }
    }
    return $null
}

function Fresh-AgeText($d) {
    if (-not ($d -is [datetime]) -or $d.Year -lt 1990) { return '' }
    $mo = [int][math]::Floor(((Get-Date) - $d).TotalDays / 30.4)
    if ($mo -lt 1) { return 'менее месяца' }
    if ($mo -lt 24) { return ('{0} мес.' -f $mo) }
    return ('{0:N1} г.' -f ($mo / 12.0))
}

# NVIDIA: имя видеокарты -> psid/pfid (публичный lookup на nvidia.com), затем последняя версия Game Ready.
# Возвращает @{Version; Date; Url} или $null.
function Fresh-Nvidia($GpuName, $IsWin11) {
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
    $x = Fresh-Get "${base}?TypeID=2&ParentID=1"
    if (-not $x) { return $null }
    $series = @()
    foreach ($m in [regex]::Matches($x, '<Name>([^<]+)</Name><Value>(\d+)</Value>')) {
        $sn = $m.Groups[1].Value
        if ($sn -notmatch ('(?<!\d)' + $gen + '\s+Series')) { continue }
        $isNb = ($sn -match 'Notebook')
        if ($isNb -eq $mobile) { $series += ,@($sn, $m.Groups[2].Value) }
    }
    $psid = $null; $pfid = $null
    foreach ($sr in $series) {
        $p = Fresh-Get "${base}?TypeID=3&ParentID=$($sr[1])"
        if (-not $p) { continue }
        foreach ($m in [regex]::Matches($p, '<Name>([^<]+)</Name><Value>(\d+)</Value>')) {
            if ((& $norm $m.Groups[1].Value) -eq $want) { $psid = $sr[1]; $pfid = $m.Groups[2].Value; break }
        }
        if ($pfid) { break }
    }
    if (-not $pfid) { return $null }
    $os = 57; if ($IsWin11) { $os = 135 }
    $u = "https://gfwsl.geforce.com/services_toolkit/services/com/nvidia/services/AjaxDriverService.php?func=DriverManualLookup&psid=$psid&pfid=$pfid&osID=$os&languageCode=1033&isWHQL=1&dch=1&sort1=0&numberOfResults=1"
    $j = Fresh-Get $u
    if (-not $j) { return $null }
    $vm = [regex]::Match($j, '"Version"\s*:\s*"([\d\.]+)"')
    if (-not $vm.Success) { return $null }
    $res = @{ Version = $vm.Groups[1].Value; Date = $null; Url = 'https://www.nvidia.com/Download/index.aspx' }
    $dm = [regex]::Match($j, '"ReleaseDateTime"\s*:\s*"([^"]+)"')
    if ($dm.Success) { $res.Date = Fresh-ParseDate $dm.Groups[1].Value @('ddd MMM d, yyyy', 'ddd MMM dd, yyyy') }
    $um = [regex]::Match($j, '"DetailsURL"\s*:\s*"([^"]+)"')
    if ($um.Success) { $res.Url = $um.Groups[1].Value }
    return $res
}

# AMD: публичного API нет — берём максимальную версию Adrenalin со страницы загрузок (best-effort).
function Fresh-Amd {
    $h = Fresh-Get 'https://www.amd.com/en/support/downloads/drivers.html/graphics/radeon-rx/radeon-rx-7000-series/amd-radeon-rx-7900-xtx.html'
    if (-not $h) { return $null }
    $best = $null; $bestTxt = $null
    foreach ($m in [regex]::Matches($h, '(?i)adrenalin(?:-edition|\s+edition)?[\s-]+(\d{2}\.\d{1,2}\.\d{1,2})')) {
        $v = Fresh-ParseVer $m.Groups[1].Value
        if ($v -and $v.Major -ge 20 -and $v.Major -le 60 -and ((-not $best) -or $v -gt $best)) { $best = $v; $bestTxt = $m.Groups[1].Value }
    }
    if (-not $best) { return $null }
    return @{ Version = $bestTxt; Url = 'https://www.amd.com/en/support/download/drivers.html' }
}

# ASUS: публичный API rog.asus.com. Модель платы -> список BIOS (новейший первым). Возвращает @{Version; Date; Description; Url} или $null.
function Fresh-AsusBios($Model) {
    $slug = ("$Model" -replace '[\(\)]', ' ' -replace '\s+', ' ').Trim() -replace ' ', '-'
    if (-not $slug) { return $null }
    $j = Fresh-Get ('https://rog.asus.com/support/webapi/product/GetPDBIOS?website=global&model=' + [uri]::EscapeDataString($slug) + '&cpu=')
    if (-not $j) { return $null }
    try { $o = $j | ConvertFrom-Json -ErrorAction Stop } catch { return $null }
    if (-not $o -or -not $o.Result -or -not $o.Result.Obj) { return $null }
    $files = @()
    foreach ($grp in @($o.Result.Obj)) { if ($grp.Name -eq 'BIOS') { $files += @($grp.Files) } }
    $files = @($files | Where-Object { $_ -and $_.Version })
    if (-not $files.Count) { return $null }
    $best = $files | Sort-Object { Fresh-ParseDate $_.ReleaseDate @('yyyy/MM/dd', 'yyyy/M/d') } -Descending | Select-Object -First 1
    $desc = ("$($best.Description)" -replace '<[^>]+>', ' ' -replace '&nbsp;', ' ' -replace '\s+', ' ' -replace '["]', '').Trim()
    return @{ Version = "$($best.Version)"; Date = (Fresh-ParseDate $best.ReleaseDate @('yyyy/MM/dd', 'yyyy/M/d')); Description = $desc
        Url = ('https://www.asus.com/supportonly/' + $slug + '/helpdesk_bios/') }
}
