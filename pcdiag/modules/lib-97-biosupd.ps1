# ---------------------------------------------------------------- обновление BIOS: поиск у производителя, скачивание, инструкция
# Программа НИЧЕГО НЕ ПРОШИВАЕТ сама: находит свежий BIOS именно для этой платы/ноутбука, скачивает файл в папку рядом с отчётом,
# сверяет контрольную сумму (если производитель её публикует) и кладёт инструкцию. Наружу уходит только название модели.
# Производители: Colorful, ASUS, MSI, Gigabyte (платы), Lenovo, HP, Dell (ноутбуки/ПК). Остальные — прямая ссылка на страницу поддержки.
# Отключить скачивание: DIAG_BIOSDL=0 (поиск и сравнение версий остаются).
$BIOSUPD = @{ Log = (New-Object System.Collections.Generic.List[string]) }

function Bios-Log($t) { $BIOSUPD.Log.Add("$t"); $G.Log.Add("biosupd: $t") }
function Bios-Norm($t) { return (("$t" -replace '[^0-9A-Za-z]', '').ToUpper()) }
function Bios-Text($h) {
    $t = "$h" -replace '(?i)<br\s*/?>|</p>|</li>|</div>', "`n" -replace '<[^>]+>', ''
    $t = [System.Net.WebUtility]::HtmlDecode($t)
    $t = ($t -replace "[ \t ]+", ' ' -replace "\s*\r?\n\s*", "`n").Trim()
    return $t
}
# Описание только на китайском (старые версии Colorful): по-русски оставляем то, что можно понять без перевода
function Bios-NoteRu($n) {
    $n = "$n"
    if ($n -notmatch '[\u3000-\u9FFF\uFF00-\uFFEF]') { return $n }
    $t = '(описание производителя только на китайском — см. страницу модели)'
    if ($n -match '(?i)UEFI\s*DOS') { $t += "`nВНИМАНИЕ: в описании упомянут «UEFI DOS» — эта версия ставится только вручную из UEFI Shell." }
    $mc = [regex]::Matches($n, '(?i)0x[0-9a-f]{2,4}') | ForEach-Object { $_.Value } | Select-Object -Unique
    if ($mc) { $t += "`nМикрокод процессора: " + ($mc -join ', ') }
    return $t
}
function Bios-Date($t) {
    $t = "$t".Trim()
    if (-not $t) { return $null }
    $fm = 'yyyy/MM/dd', 'yyyy/M/d', 'yyyy-MM-dd', 'yyyy-M-d', 'yyyy.MM.dd', 'MM/dd/yyyy HH:mm:ss', 'M/d/yyyy H:mm:ss', 'MM/dd/yyyy', 'MMM d, yyyy', 'MMM dd, yyyy', 'MMMM d, yyyy', 'MMMM dd, yyyy', 'MMMM d,yyyy', 'MMMM dd,yyyy'
    foreach ($f in $fm) {
        $d = [datetime]::MinValue
        if ([datetime]::TryParseExact($t, $f, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$d)) { return $d }
    }
    return $null
}
function Bios-Entry($Version, $Date, $Url, $Notes, $Sha, $Extra) {
    return [pscustomobject]@{ Version = "$Version".Trim(); Date = $Date; Url = "$Url"; Notes = "$Notes"; Sha256 = ("$Sha" -replace '[^0-9A-Fa-f]', '').ToUpper(); Extra = $Extra }
}

# HTTP через встроенный curl.exe с «браузерными» заголовками (сайты производителей режут PowerShell) -> текст, либо файл ($OutFile).
# Скачиваем во временный файл с латинским именем (curl не дружит с кириллицей в путях), затем переносим средствами PowerShell.
function Bios-Http($Url, $Referer = '', $OutFile = '', $TimeoutSec = 25, $Accept = '') {
    $tmpDir = $G.Temp
    try { if (-not (Test-Path $tmpDir)) { New-Item -ItemType Directory -Force $tmpDir | Out-Null } } catch {}
    $leaf = 'bios_' + [guid]::NewGuid().ToString('N') + '.tmp'
    $tmp = Join-Path $tmpDir $leaf
    if (-not $Accept) { $Accept = 'text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8' }
    $u = "$Url"
    if ($u -match '[^\x21-\x7E]') { try { $u = [uri]::EscapeUriString($u) } catch {} }
    $done = $false; $httpErr = $false
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (Test-Path $curl) {
        # параметры — через файл конфигурации curl (-K): так заголовки с кавычками доходят без искажений.
        # Заголовки Sec-Fetch-* обязательны: без них msi.com и gigabyte.com (Akamai) отвечают 403.
        $q = { param($v) '"' + ("$v" -replace '\\', '\\' -replace '"', '\"') + '"' }
        foreach ($comp in $true, $false) {
            $c = New-Object System.Collections.Generic.List[string]
            foreach ($x in 'silent', 'location', 'fail', "max-time = $TimeoutSec", 'connect-timeout = 15') { $c.Add($x) }
            if ($comp) { $c.Add('compressed') }
            $c.Add('user-agent = ' + (& $q $FRESH_UA))
            foreach ($x in "Accept: $Accept", 'Accept-Language: en-US,en;q=0.9', 'Sec-Fetch-Dest: document', 'Sec-Fetch-Mode: navigate', 'Sec-Fetch-Site: none', 'Sec-Fetch-User: ?1', 'Upgrade-Insecure-Requests: 1') { $c.Add('header = ' + (& $q $x)) }
            if ($Referer) { $c.Add('referer = ' + (& $q $Referer)) }
            $c.Add('output = ' + (& $q $leaf)); $c.Add('url = ' + (& $q $u))
            $cfg = Join-Path $tmpDir ($leaf + '.cfg')
            $code = -1
            try {
                [IO.File]::WriteAllLines($cfg, $c.ToArray(), (New-Object Text.UTF8Encoding $false))
                Push-Location $tmpDir
                try { & $curl -K ($leaf + '.cfg') 2>$null | Out-Null; $code = $LASTEXITCODE } finally { Pop-Location }
            } catch {}
            Remove-Item $cfg -Force -ErrorAction SilentlyContinue
            if ($code -eq 0 -and (Test-Path $tmp) -and (Get-Item $tmp).Length -gt 0) { $done = $true; break }
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
            if ($code -eq 22) { $httpErr = $true } else { Bios-Log ('curl {0}: код {1}' -f ($u -replace '\?.*$', ''), $code) }
            if ($code -ne 2 -and $code -ne 4 -and $code -ne 61) { break }   # не «опция не поддерживается» — повтор без сжатия не поможет
        }
    }
    if (-not $done -and -not $httpErr) {
        try {
            $hd = @{ 'Accept' = $Accept; 'Accept-Language' = 'en-US,en;q=0.9' }
            if ($Referer) { $hd['Referer'] = $Referer }
            Invoke-WebRequest -Uri $u -OutFile $tmp -UseBasicParsing -UserAgent $FRESH_UA -Headers $hd -TimeoutSec $TimeoutSec -ErrorAction Stop
            if ((Test-Path $tmp) -and (Get-Item $tmp).Length -gt 0) { $done = $true }
        } catch { Bios-Log ("http {0}: {1}" -f ($u -replace '\?.*$', ''), $_.Exception.Message) }
    }
    if (-not $done) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue; return $null }
    if ($OutFile) {
        try { Move-Item -LiteralPath $tmp -Destination $OutFile -Force -ErrorAction Stop; return $true } catch { Bios-Log "move: $($_.Exception.Message)"; return $null }
    }
    $txt = $null
    try { $txt = [IO.File]::ReadAllText($tmp, [Text.Encoding]::UTF8) } catch {}
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    return $txt
}
function Bios-Json($Url, $Referer = '') {
    $t = Bios-Http $Url $Referer '' 25 'application/json, text/plain, */*'
    if (-not $t) { return $null }
    try { return ($t | ConvertFrom-Json -ErrorAction Stop) } catch { Bios-Log "json: $($_.Exception.Message)"; return $null }
}
# .cab -> папка (expand.exe есть в любой Windows); возвращает путь к первому .xml или $null
function Bios-Cab($Url) {
    $cab = Join-Path $G.Temp ('bios_' + [guid]::NewGuid().ToString('N') + '.cab')
    if (-not (Bios-Http $Url '' $cab 60)) { return $null }
    $dir = $cab + '_x'
    try {
        New-Item -ItemType Directory -Force $dir | Out-Null
        $ex = Join-Path $env:SystemRoot 'System32\expand.exe'
        & $ex $cab '-F:*' $dir 2>$null | Out-Null
        # если в .cab один файл, expand называет его именем самого архива — берём самый большой файл, а не «*.xml»
        $x = Get-ChildItem $dir -File -ErrorAction SilentlyContinue | Sort-Object Length -Descending | Select-Object -First 1
        if ($x) { return $x.FullName }
    } catch { Bios-Log "cab: $($_.Exception.Message)" }
    return $null
}

# ============================================================ Colorful
function Bios-Colorful($Product, $BoardVer) {
    $res = @{ Vendor = 'Colorful'; List = @(); Page = 'https://www.colorful.cn/home/download'; Model = ''; Why = ''; Guides = @() }
    $want0 = Bios-Norm $Product
    $want1 = ''; if ("$BoardVer" -match '^(?i)V\d+') { $want1 = Bios-Norm ($Product + $BoardVer) }
    if (-not $want0) { $res.Why = 'модель платы не определена'; return $res }
    $byVer = @{}
    foreach ($hostName in 'www.colorful.cn', 'www.colorfulgroup.com') {
        $ref = "https://$hostName/home/download"
        $sr = Bios-Json ("https://$hostName/home/DownSearchProduct?k=" + [uri]::EscapeDataString("$Product".Trim())) $ref
        if (-not $sr -or -not $sr.s) { continue }
        $cand = @()
        foreach ($it in (AsArr $sr.s)) { $cand += [pscustomobject]@{ It = $it; N = (Bios-Norm ("$($it.name)" -replace '[（(].*?[)）]', '')) } }
        $pick = $null
        if ($want1) { $pick = $cand | Where-Object { $_.N -eq $want1 } | Select-Object -First 1 }
        if (-not $pick) { $pick = $cand | Where-Object { $_.N -eq $want0 } | Select-Object -First 1 }
        if (-not $pick -and -not $want1) {
            $near = @($cand | Where-Object { $_.N.StartsWith($want0) -and $_.N.Substring($want0.Length) -match '^V\d+$' })
            if ($near.Count -eq 1) { $pick = $near[0] }
            elseif ($near.Count -gt 1) { $res.Why = 'у производителя несколько ревизий этой платы (' + (($near | ForEach-Object { "$($_.It.name)" }) -join '; ') + ') — ревизию нужно сверить по надписи на плате' }
        }
        if (-not $pick) { continue }
        $res.Model = ("$($pick.It.name)" -replace '[（(].*?[)）]', '').Trim()
        $res.Page = "https://$hostName/home/DownLoadInfo?mid=$($pick.It.mid)&id=$($pick.It.id)"
        $fl = Bios-Json ("https://$hostName/Home/GetProductDownload?mid=$($pick.It.mid)&id=$($pick.It.id)") $ref
        if (-not $fl) { continue }
        $typeId = '2899'
        $dic = Bios-Json "https://$hostName/Home/GetDictionary" $ref
        if ($dic) {
            $par = $dic | Where-Object { $_.title -eq '文件类型' } | Select-Object -First 1
            if ($par) { $bt = $dic | Where-Object { $_.parent_id -eq $par.id -and $_.title -eq 'BIOS' } | Select-Object -First 1; if ($bt) { $typeId = "$($bt.id)" } }
        }
        foreach ($f in (AsArr $fl)) {
            $ttl = "$($f.title)".Trim()
            if ("$($f.files)" -ne $typeId) {
                if ($ttl -match '(?i)BIOS' -and "$($f.fileurl)" -match '(?i)\.pdf$' -and $hostName -match 'colorfulgroup') { $res.Guides += [pscustomobject]@{ Title = $ttl; Url = "$($f.fileurl)" } }
                continue
            }
            if ("$($f.fileurl)" -notmatch '(?i)\.(zip|rar|7z)$') { continue }
            if ($ttl -notmatch '(?i)BIOS\s*([0-9A-Za-z][0-9A-Za-z\.]*)\s*$') { continue }
            $v = $Matches[1]
            $d = $null
            if ("$($f.content)" -match '(20\d\d)\s*[/\.\-]\s*(\d{1,2})\s*[/\.\-]\s*(\d{1,2})') { try { $d = Get-Date -Year ([int]$Matches[1]) -Month ([int]$Matches[2]) -Day ([int]$Matches[3]) -Hour 0 -Minute 0 -Second 0 } catch {} }
            if (-not $d) { $d = Bios-Date $f.edit_time }
            if (-not $d) { continue }
            # англоязычный сайт идёт вторым и перекрывает описание китайского
            $byVer[$v] = Bios-Entry $v $d.Date $f.fileurl (Bios-Text $f.content) '' $null
        }
    }
    $res.List = @($byVer.Values | Sort-Object Date -Descending)
    if (-not $res.List.Count -and -not $res.Why) { $res.Why = 'плата не найдена на сайте производителя' }
    return $res
}

# ============================================================ ASUS (платы и ноутбуки)
function Bios-Asus($Model) {
    $res = @{ Vendor = 'ASUS'; List = @(); Page = 'https://www.asus.com/support/'; Model = "$Model"; Why = '' }
    $m0 = ("$Model" -replace '\s+', ' ').Trim()
    if (-not $m0) { $res.Why = 'модель не определена'; return $res }
    $tries = @(
        ('https://www.asus.com/support/api/product.asmx/GetPDBIOS?website=global&model=' + [uri]::EscapeDataString($m0) + '&pdhashedid=&cpu='),
        ('https://rog.asus.com/support/webapi/product/GetPDBIOS?website=global&model=' + [uri]::EscapeDataString(($m0 -replace ' ', '-')) + '&cpu='),
        ('https://www.asus.com/support/api/product.asmx/GetPDBIOS?website=global&model=' + [uri]::EscapeDataString(($m0 -replace ' ', '-')) + '&pdhashedid=&cpu=')
    )
    foreach ($u in $tries) {
        $o = Bios-Json $u
        if (-not $o -or -not $o.Result -or -not $o.Result.Obj) { continue }
        $lst = @()
        foreach ($grp in (AsArr $o.Result.Obj)) {
            if ("$($grp.Name)" -ne 'BIOS') { continue }
            foreach ($f in (AsArr $grp.Files)) {
                if (-not $f -or -not $f.Version) { continue }
                if ("$($f.IsRelease)" -eq '0' -or "$($f.Title)$($f.Version)" -match '(?i)beta') { continue }   # бета-версии не предлагаем
                $dl = "$($f.DownloadUrl.Global)"; if (-not $dl) { continue }
                $d = Bios-Date $f.ReleaseDate; if (-not $d) { continue }
                $lst += Bios-Entry $f.Version $d $dl ((Bios-Text $f.Description) -replace '^"|"$', '') $f.sha256 $null
            }
        }
        if ($lst.Count) {
            $res.List = @($lst | Sort-Object Date -Descending)
            $res.Page = 'https://www.asus.com/supportonly/' + ($m0 -replace ' ', '-') + '/helpdesk_bios/'
            return $res
        }
    }
    $res.Why = 'модель не найдена в базе ASUS (или у неё нет стабильных версий BIOS)'
    return $res
}

# ============================================================ MSI
function Bios-Msi($Product) {
    $nm = ("$Product" -replace '\(.*?\)', '' -replace '\s+', ' ').Trim()
    $res = @{ Vendor = 'MSI'; List = @(); Page = 'https://www.msi.com/support/download'; Model = $nm; Why = '' }
    if (-not $nm) { $res.Why = 'модель не определена'; return $res }
    $slug = $nm -replace ' ', '-'
    $page = "https://www.msi.com/Motherboard/$slug/support"
    $o = Bios-Json ('https://www.msi.com/api/v1/product/support/panel?product=' + [uri]::EscapeDataString($slug) + '&type=bios') $page
    if (-not $o -or -not $o.result -or -not $o.result.downloads) { $res.Why = 'модель не найдена на сайте MSI (или сайт не ответил)'; return $res }
    if ((Bios-Norm $o.result.title) -ne (Bios-Norm $nm)) { $res.Why = "сайт MSI вернул другую модель ($($o.result.title))"; return $res }
    $res.Page = $page
    $lst = @()
    foreach ($pr in $o.result.downloads.PSObject.Properties) {
        if ($pr.Name -notmatch '(?i)BIOS') { continue }
        foreach ($f in (AsArr $pr.Value)) {
            if (-not $f.download_url -or "$($f.download_title)$($f.download_version)" -match '(?i)beta') { continue }
            $d = Bios-Date $f.download_release; if (-not $d) { continue }
            $sha = ''; if ("$($f.download_sha256)" -match '([0-9A-Fa-f]{64})') { $sha = $Matches[1] }
            $lst += Bios-Entry $f.download_version $d $f.download_url (Bios-Text $f.download_description) $sha $null
        }
    }
    $res.List = @($lst | Sort-Object Date -Descending)
    if (-not $res.List.Count) { $res.Why = 'на странице модели нет файлов BIOS' }
    return $res
}

# ============================================================ Gigabyte (ревизия платы в WMI обычно «x.x» — определяем по списку версий)
function Bios-Gigabyte($Product, $BoardVer, $InstVer) {
    $nm = ("$Product" -replace '\(.*?\)', '' -replace '\s+', ' ').Trim()
    $res = @{ Vendor = 'Gigabyte'; List = @(); Page = 'https://www.gigabyte.com/Support'; Model = $nm; Why = '' }
    if (-not $nm) { $res.Why = 'модель не определена'; return $res }
    $slug = $nm -replace ' ', '-'
    $revs = New-Object System.Collections.Generic.List[string]
    if ("$BoardVer" -match '^(\d)\.(\d)$') { $revs.Add("rev-$($Matches[1])$($Matches[2])"); $revs.Add("rev-$($Matches[1])x") }
    foreach ($r in 'rev-10', 'rev-1x', 'rev-11', 'rev-12', 'rev-13', 'rev-20') { if (-not $revs.Contains($r)) { $revs.Add($r) } }
    $found = @()
    $miss = 0
    foreach ($r in $revs) {
        if ($miss -ge 4 -and -not $found.Count) { break }
        $page = "https://www.gigabyte.com/Motherboard/$slug-$r/support"
        $h = Bios-Http $page
        if (-not $h -or $h -notmatch 'mb_bios') { $miss++; continue }
        $i = $h.IndexOf('<h2>BIOS</h2>'); if ($i -lt 0) { continue }
        $j = $h.IndexOf('<h2>', $i + 10); if ($j -lt 0) { $j = $h.Length }
        $seg = $h.Substring($i, $j - $i)
        $lst = @()
        foreach ($m in [regex]::Matches($seg, '(?s)<tr class="item-group".*?</tr>')) {
            $row = $m.Value
            $v = [regex]::Match($row, '(?s)class="item-version"[^>]*>(.*?)</td>').Groups[1].Value.Trim()
            $dt = Bios-Date ([regex]::Match($row, '(?s)class="item-date"[^>]*>(.*?)</td>').Groups[1].Value)
            $dl = [regex]::Match($row, 'href="(https://download\.gigabyte\.com/[^"]+)"').Groups[1].Value
            if (-not $v -or -not $dt -or -not $dl) { continue }
            $nt = Bios-Text ([regex]::Match($row, '(?s)class="support-item-desc"[^>]*>(.*?)</span>\s*</p>').Groups[1].Value)
            $lst += Bios-Entry $v $dt ([System.Net.WebUtility]::HtmlDecode($dl)) $nt '' $null
        }
        if ($lst.Count) { $found += [pscustomobject]@{ Rev = $r; Page = $page; All = @($lst | Sort-Object Date -Descending) } }
        # точное попадание по ревизии из WMI — дальше не ищем
        if ($found.Count -and "$BoardVer" -match '^\d\.\d$' -and $r -eq $revs[0]) { break }
    }
    if (-not $found.Count) { $res.Why = 'страница платы на gigabyte.com не найдена'; return $res }
    $sel = $null
    $iv = Bios-Norm $InstVer
    if ($iv) { $hit = @($found | Where-Object { @($_.All | Where-Object { (Bios-Norm $_.Version) -eq $iv }).Count -gt 0 }); if ($hit.Count -eq 1) { $sel = $hit[0] } }
    if (-not $sel -and $found.Count -eq 1) { $sel = $found[0] }
    if (-not $sel) {
        $res.Page = $found[0].Page
        $res.Why = 'у платы несколько ревизий (' + (($found | ForEach-Object { $_.Rev -replace 'rev-(\d)(\w)', 'rev. $1.$2' }) -join ', ') + '), а BIOS у них разный — сверьте надпись REV на плате и скачайте вручную'
        return $res
    }
    $res.Page = $sel.Page; $res.Model = $nm + ' (' + ($sel.Rev -replace 'rev-(\d)(\w)', 'rev. $1.$2') + ')'
    # версии с буквой в конце (F20c) — бета; предлагаем только стабильные
    $res.List = @($sel.All | Where-Object { $_.Version -match '^[A-Za-z]*\d+$' })
    $res.AllVersions = $sel.All
    if (-not $res.List.Count) { $res.Why = 'у производителя только бета-версии BIOS' }
    return $res
}

# ============================================================ Lenovo (каталог обновлений по типу машины: первые 4 символа модели)
function Bios-Lenovo($CsModel, $InstVer) {
    $res = @{ Vendor = 'Lenovo'; List = @(); Page = 'https://pcsupport.lenovo.com/'; Model = "$CsModel"; Why = ''; Kind = 'exe' }
    $mt = ''; if ("$CsModel".Trim() -match '^([0-9A-Za-z]{4})') { $mt = $Matches[1].ToUpper() }
    if (-not $mt) { $res.Why = 'тип машины Lenovo не определён'; return $res }
    $res.Page = "https://pcsupport.lenovo.com/products/$mt/downloads/driver-list/component?name=BIOS%2FUEFI"
    $cat = $null
    foreach ($os in 'Win11', 'Win10') { $cat = Bios-Http "https://download.lenovo.com/catalog/${mt}_$os.xml"; if ($cat -and $cat -match '<package') { break } else { $cat = $null } }
    if (-not $cat) { $res.Why = "для типа машины $mt нет каталога обновлений Lenovo"; return $res }
    $lst = @()
    $n = 0
    foreach ($m in [regex]::Matches($cat, '(?s)<package>(.*?)</package>')) {
        if ($m.Groups[1].Value -notmatch '<category>\s*BIOS') { continue }
        $loc = [regex]::Match($m.Groups[1].Value, '<location>\s*([^<\s]+)\s*</location>').Groups[1].Value
        if (-not $loc) { continue }
        $n++; if ($n -gt 4) { break }
        $px = Bios-Http $loc; if (-not $px) { continue }
        $v = [regex]::Match($px, '<Package[^>]*\sversion="([^"]+)"').Groups[1].Value
        $d = Bios-Date ([regex]::Match($px, '<ReleaseDate>\s*([^<]+?)\s*</ReleaseDate>').Groups[1].Value)
        $im = [regex]::Match($px, '(?s)<Installer>.*?<Name>\s*([^<]+?)\s*</Name>.*?<CRC>\s*([0-9A-Fa-f]+)\s*</CRC>')
        if (-not $v -or -not $d -or -not $im.Success) { continue }
        $ttl = [regex]::Match($px, '(?s)<Title[^>]*>.*?<Desc[^>]*>\s*([^<]+?)\s*</Desc>').Groups[1].Value
        $e = Bios-Entry $v $d (($loc -replace '[^/]+$', '') + $im.Groups[1].Value) $ttl $im.Groups[2].Value $null
        # <DetectInstall><_Bios><Level>N32ETA2*</Level> — шаблон версии, которая будет установлена
        $lv = [regex]::Match($px, '(?s)<DetectInstall>.*?<Level>\s*([^<]+?)\s*</Level>').Groups[1].Value
        if ($lv -and "$InstVer" -like $lv) { $e | Add-Member -NotePropertyName IsInstalled -NotePropertyValue $true }
        $lst += $e
    }
    $res.List = @($lst | Sort-Object Date -Descending)
    if (-not $res.List.Count) { $res.Why = 'в каталоге Lenovo для этой модели нет BIOS' }
    return $res
}

# ============================================================ HP (бизнес-линейки: каталог ftp.hp.com/pub/pcbios/<ID платы>)
function Bios-Hp($PlatformId) {
    $res = @{ Vendor = 'HP'; List = @(); Page = 'https://support.hp.com/drivers'; Model = ''; Why = ''; Kind = 'hpbin' }
    $id = "$PlatformId".Trim().ToUpper()
    if ($id -notmatch '^[0-9A-F]{4}$') { $res.Why = 'код платформы HP не определён'; return $res }
    $x = Bios-Http "https://ftp.hp.com/pub/pcbios/$id/$id.xml"
    if (-not $x -or $x -notmatch '<Rel ') { $res.Why = "для платформы HP $id нет открытого каталога BIOS (обычно так у домашних серий)"; return $res }
    $lst = @()
    foreach ($m in [regex]::Matches($x, '<Rel\s+([^>]+?)/?>')) {
        $at = @{}
        foreach ($k in [regex]::Matches($m.Groups[1].Value, '(\w+)="([^"]*)"')) { $at[$k.Groups[1].Value] = $k.Groups[2].Value }
        $d = Bios-Date $at['Date']
        if (-not $at['Ver'] -or -not $at['Bin'] -or -not $d) { continue }
        $base = "https://ftp.hp.com/pub/pcbios/$id/"
        $lst += Bios-Entry $at['Ver'] $d ($base + $at['Bin']) '' $at['Sha256'] @(($base + ($at['Bin'] -replace '\.bin$', '.sig')))
    }
    $res.List = @($lst | Sort-Object Date -Descending)
    if (-not $res.List.Count) { $res.Why = 'каталог HP пуст' }
    return $res
}

# ============================================================ Dell (каталог по System ID = SystemSKUNumber)
function Bios-Dell($Sku) {
    $res = @{ Vendor = 'Dell'; List = @(); Page = 'https://www.dell.com/support/home/'; Model = ''; Why = ''; Kind = 'exe' }
    $id = "$Sku".Trim().ToUpper()
    if ($id -notmatch '^[0-9A-F]{4}$') { $res.Why = 'System ID Dell не определён'; return $res }
    $ix = Bios-Cab 'https://downloads.dell.com/catalog/CatalogIndexPC.cab'
    if (-not $ix) { $res.Why = 'каталог Dell недоступен'; return $res }
    $t = [IO.File]::ReadAllText($ix, [Text.Encoding]::Unicode)
    $p = $t.IndexOf('systemID="' + $id + '"')
    if ($p -lt 0) { $res.Why = "System ID $id нет в каталоге Dell"; return $res }
    $q = $t.IndexOf('path="', $p); $e = $t.IndexOf('</GroupManifest>', $p)
    if ($q -lt 0 -or ($e -gt 0 -and $q -gt $e)) { $res.Why = 'каталог Dell: не найден путь'; return $res }
    $q += 6; $rel = $t.Substring($q, $t.IndexOf('"', $q) - $q)
    $t = $null
    $mx = Bios-Cab ('https://downloads.dell.com/' + $rel)
    if (-not $mx) { $res.Why = 'каталог модели Dell недоступен'; return $res }
    $t = [IO.File]::ReadAllText($mx, [Text.Encoding]::Unicode)
    $lst = @()
    foreach ($part in ($t -split '<SoftwareComponent ')) {
        if ($part -notmatch '<ComponentType value="BIOS"') { continue }
        $v = [regex]::Match($part, 'vendorVersion="([^"]+)"').Groups[1].Value
        $d = Bios-Date ([regex]::Match($part, 'releaseDate="([^"]+)"').Groups[1].Value)
        $pth = [regex]::Match($part, '\spath="([^"]+\.(?i:exe))"').Groups[1].Value
        if (-not $v -or -not $d -or -not $pth) { continue }
        $sha = [regex]::Match($part, '<Hash algorithm="SHA256">\s*([0-9A-Fa-f]{64})').Groups[1].Value
        $nm = [regex]::Match($part, '(?s)<Name>.*?<!\[CDATA\[(.*?)\]\]>').Groups[1].Value
        $lst += Bios-Entry $v $d ('https://downloads.dell.com/' + $pth) $nm $sha $null
    }
    $res.List = @($lst | Sort-Object Date -Descending)
    $res.Page = 'https://www.dell.com/support/home/product-support/'
    if (-not $res.List.Count) { $res.Why = 'в каталоге модели Dell нет BIOS' }
    return $res
}

# ============================================================ выбор производителя
# $Hw: @{ BbMan; BbProd; BbVer; CsMan; CsModel; Sku; BiosVer; BiosDate; IsLaptop; BitLocker }
function Bios-Lookup($Hw) {
    $man = "$($Hw.BbMan) $($Hw.CsMan)"
    $r = $null
    try {
        if ($man -match '(?i)Colorful') { $r = Bios-Colorful $Hw.BbProd $Hw.BbVer }
        elseif ($man -match '(?i)ASUS') { $r = Bios-Asus $Hw.BbProd }
        elseif ($man -match '(?i)\bMSI\b|Micro-Star') { if ($Hw.IsLaptop) { $r = @{ Vendor = 'MSI'; List = @(); Page = 'https://www.msi.com/support/download'; Why = 'для ноутбуков MSI автоматический поиск пока не поддерживается' } } else { $r = Bios-Msi $Hw.BbProd } }
        elseif ($man -match '(?i)Gigabyte|AORUS') { if ($Hw.IsLaptop) { $r = @{ Vendor = 'Gigabyte'; List = @(); Page = 'https://www.gigabyte.com/Support'; Why = 'для ноутбуков Gigabyte автоматический поиск пока не поддерживается' } } else { $r = Bios-Gigabyte $Hw.BbProd $Hw.BbVer $Hw.BiosVer } }
        elseif ($man -match '(?i)Lenovo') { $r = Bios-Lenovo $Hw.CsModel $Hw.BiosVer; if ($r -and $Hw.CsFamily) { $r.Model = ("Lenovo $($Hw.CsFamily) ($($Hw.CsModel))" -replace '\s+', ' ').Trim() } }
        elseif ($man -match '(?i)\bHP\b|Hewlett') { $r = Bios-Hp $Hw.BbProd; if ($r -and $Hw.CsModel) { $r.Model = ("$($Hw.CsModel)" -replace '\s+', ' ').Trim() + " (платформа $($Hw.BbProd))" } }
        elseif ($man -match '(?i)Dell') { $r = Bios-Dell $Hw.Sku; if ($r -and $Hw.CsModel) { $r.Model = ("Dell $($Hw.CsModel)" -replace '(?i)^Dell\s+Dell', 'Dell' -replace '\s+', ' ').Trim() } }
        elseif ($man -match '(?i)ASRock') { $r = @{ Vendor = 'ASRock'; List = @(); Page = 'https://www.asrock.com/support/index.asp?cat=BIOS'; Why = 'сайт ASRock закрыт защитой от автоматических запросов' } }
    } catch { Bios-Log "lookup: $($_.Exception.Message)"; $r = $null }
    if (-not $r) { $r = @{ Vendor = ''; List = @(); Page = ''; Why = 'для этого производителя автоматический поиск BIOS не поддерживается' } }
    if (-not $r.Model) { $r.Model = ("$($Hw.BbMan) $($Hw.BbProd)").Trim() }
    return $r
}

# Сравнение установленного BIOS со списком производителя.
# Возвращает @{ State = 'update'|'current'|'unknown'; Latest; Current (запись списка, совпавшая с установленной); Newer (все версии новее установленной); How }
function Bios-Decide($Res, $InstVer, $InstDate) {
    $o = @{ State = 'unknown'; Latest = $null; Current = $null; Newer = @(); How = '' }
    $lst = @($Res.List)
    if (-not $lst.Count) { return $o }
    $o.Latest = $lst[0]
    $pool = $lst; if ($Res.AllVersions) { $pool = @($Res.AllVersions) }
    $iv = Bios-Norm $InstVer
    $cur = $null
    foreach ($e in $pool) {
        if ($e.IsInstalled) { $cur = $e; break }
        $ev = Bios-Norm $e.Version
        if (-not $ev -or -not $iv) { continue }
        if ($ev -eq $iv) { $cur = $e; break }
        if ($ev.Length -ge 3 -and $iv.Length -gt $ev.Length -and $iv.EndsWith($ev)) { $cur = $e; break }
        if ($iv.Length -ge 3 -and $ev.Length -gt $iv.Length -and $ev.EndsWith($iv)) { $cur = $e; break }
    }
    if ($cur) {
        $o.Current = $cur; $o.How = 'версия найдена в списке производителя'
        $o.Newer = @($lst | Where-Object { $_.Date -gt $cur.Date -and $_.Version -ne $cur.Version })
        if ($o.Newer.Count) { $o.State = 'update' } else { $o.State = 'current' }
        return $o
    }
    if (-not ($InstDate -is [datetime])) { return $o }
    # по версии не сопоставить (у части плат в Windows видна только версия ядра AMI) — сравниваем даты.
    # Дата на сайте — дата публикации, обычно на 0–4 недели позже даты сборки, записанной в самом BIOS.
    $near = $pool | Where-Object { [math]::Abs(($_.Date - $InstDate).TotalDays) -le 31 } | Sort-Object { [math]::Abs(($_.Date - $InstDate).TotalDays) } | Select-Object -First 1
    if ($near) { $o.Current = $near }
    $o.How = 'сравнение по дате выпуска'
    $o.Newer = @($lst | Where-Object { ($_.Date - $InstDate).TotalDays -gt 31 })
    if ($o.Newer.Count) { $o.State = 'update' } else { $o.State = 'current' }
    return $o
}

function Bios-HowTo($Vendor, $FileName) {
    switch -regex ($Vendor) {
        'ASUS' { return @('1. Распакуйте архив. Файл прошивки (.CAP) скопируйте в корень флешки FAT32.', '2. Перезагрузите ПК, войдите в BIOS (Del или F2) -> Tool -> ASUS EZ Flash 3 Utility.', '3. Выберите флешку и файл .CAP, подтвердите. Дождитесь перезагрузки (до 5-10 минут, экран может гаснуть).', 'Ноутбуки ASUS: тот же EZ Flash (F2 при включении -> Advanced -> ASUS EZ Flash), зарядка подключена.') }
        'MSI' { return @('1. Распакуйте архив на флешку FAT32 (в корень).', '2. Перезагрузите ПК, войдите в BIOS (Del) -> M-FLASH -> подтвердите перезагрузку в режим прошивки.', '3. Выберите файл прошивки с флешки и дождитесь окончания (5-10 минут).') }
        'Gigabyte' { return @('1. Распакуйте архив. Файл прошивки скопируйте в корень флешки FAT32.', '2. Перезагрузите ПК, войдите в BIOS (Del) -> Q-Flash (F8) -> Update BIOS.', '3. Выберите файл с флешки и дождитесь окончания (5-10 минут).', 'ВАЖНО: у Gigabyte BIOS разный для разных ревизий платы — сверьте надпись REV в углу платы с ревизией в названии этой папки.') }
        'Colorful' { return @('1. Распакуйте архив на флешку FAT32 (в корень).', '2. Обязательно прочитайте примечание производителя к версии (ниже): часть версий Colorful ставится только вручную из UEFI Shell («UEFI DOS»), и откатываться после них на старые версии нельзя.', '3. Обычный способ: перезагрузка -> BIOS (Del) -> раздел обновления BIOS (Update BIOS / Instant Flash) -> выбрать файл с флешки.', '4. Способ «UEFI DOS»: загрузиться с этой флешки (F11 при включении -> UEFI: флешка), запустить из архива файл .nsh и дождаться окончания.', 'Официальные инструкции Colorful (PDF):') }
        'Lenovo' { return @('1. Подключите зарядку (заряд не ниже 30 %), закройте все программы.', "2. Запустите $FileName от имени администратора и следуйте мастеру (Update BIOS).", '3. Ноутбук перезагрузится и прошьётся сам (2-5 минут). Не закрывайте крышку и не отключайте питание.') }
        'Dell' { return @('1. Подключите зарядку (заряд не ниже 10 %), закройте все программы.', "2. Запустите $FileName от имени администратора -> Update.", '3. Компьютер перезагрузится и прошьётся сам (2-5 минут). Не отключайте питание.') }
        'HP' { return @('1. Возьмите флешку FAT32. Создайте на ней папку \HP\BIOS\New\ и скопируйте туда оба файла (.bin и .sig).', '2. Подключите зарядку. Перезагрузите, при включении нажимайте F10 -> Main -> Update System BIOS -> Update BIOS Using Local Media.', '3. Дождитесь окончания (2-5 минут), не отключайте питание.', 'Проще: то же обновление ставит программа HP Support Assistant.') }
    }
    return @('Следуйте инструкции производителя на странице поддержки.')
}

# Скачивание выбранной версии в папку рядом с отчётом. Возвращает @{ Folder; File; Verified; SizeMb; Err }
function Bios-Fetch($Res, $Entry, $Hw, $Dec) {
    $ret = @{ Folder = ''; File = ''; Verified = ''; SizeMb = 0; Err = '' }
    $desk = [Environment]::GetFolderPath('Desktop'); if ($env:DIAG_OUT) { $desk = $env:DIAG_OUT }
    $safeM = ("$($Res.Model)" -replace '[\\/:*?"<>|]', '' -replace '\s+', ' ').Trim(); if ($safeM.Length -gt 50) { $safeM = $safeM.Substring(0, 50).Trim() }
    $safeV = ("$($Entry.Version)" -replace '[\\/:*?"<>|\s]', '')
    $dir = Join-Path $desk ("Обновление BIOS — $safeM — версия $safeV")
    $fn = [uri]::UnescapeDataString((("$($Entry.Url)" -replace '\?.*$', '') -replace '^.*/', '')) -replace '[\\/:*?"<>|]', '_'
    if (-not $fn) { $fn = 'bios_' + $safeV + '.zip' }
    try { New-Item -ItemType Directory -Force $dir -ErrorAction Stop | Out-Null } catch { $ret.Err = 'не удалось создать папку: ' + $_.Exception.Message; return $ret }
    $dst = Join-Path $dir $fn
    $need = $true
    # уже скачивали при прошлой проверке — не качаем повторно (контрольная сумма и целостность сверяются ниже)
    if ((Test-Path -LiteralPath $dst) -and (Get-Item -LiteralPath $dst).Length -gt 300KB) { $need = $false }
    if ($need) {
        Info ('скачиваю BIOS {0} ({1})...' -f $Entry.Version, $Res.Vendor)
        if (-not (Bios-Http $Entry.Url $Res.Page $dst 900 '*/*')) {
            $ret.Err = 'файл не скачался (сайт не ответил или блокирует загрузку)'
            try { if (-not (Get-ChildItem -LiteralPath $dir -Force)) { Remove-Item -LiteralPath $dir -Force } } catch {}
            return $ret
        }
    }
    $len = (Get-Item -LiteralPath $dst).Length
    $ret.SizeMb = [math]::Round($len / 1MB, 1)
    $bad = ''
    if ($len -lt 300KB) { $bad = 'файл слишком мал для прошивки BIOS' }
    $hash = ''
    try { $hash = (Get-FileHash -LiteralPath $dst -Algorithm SHA256 -ErrorAction Stop).Hash } catch {}
    if (-not $bad -and $Entry.Sha256 -and $Entry.Sha256.Length -eq 64) {
        if ($hash -eq $Entry.Sha256) { $ret.Verified = 'контрольная сумма SHA-256 совпала с указанной производителем' } else { $bad = 'контрольная сумма не совпала с указанной производителем' }
    }
    if (-not $bad -and $fn -match '(?i)\.zip$') {
        try {
            Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
            $z = [IO.Compression.ZipFile]::OpenRead($dst); $cnt = $z.Entries.Count; $z.Dispose()
            if ($cnt -lt 1) { $bad = 'архив пуст' } elseif (-not $ret.Verified) { $ret.Verified = "архив цел, файлов: $cnt (производитель контрольную сумму не публикует)" }
        } catch { $bad = 'архив повреждён' }
    }
    if (-not $bad -and $fn -match '(?i)\.exe$') {
        try {
            $sig = Get-AuthenticodeSignature -LiteralPath $dst -ErrorAction Stop
            if ($sig.Status -eq 'Valid') { $ret.Verified = ($ret.Verified + '; цифровая подпись: ' + ($sig.SignerCertificate.Subject -replace '^CN="?([^",]+).*$', '$1')).Trim('; ') }
            elseif (-not $ret.Verified) { $bad = 'у установщика нет действительной цифровой подписи' }
        } catch {}
    }
    if ($bad) {
        Remove-Item -LiteralPath $dst -Force -ErrorAction SilentlyContinue
        try { if (-not (Get-ChildItem -LiteralPath $dir -Force)) { Remove-Item -LiteralPath $dir -Force } } catch {}
        $ret.Err = $bad + ' — файл удалён'; return $ret
    }
    foreach ($x in (AsArr $Entry.Extra)) {
        $xn = ("$x" -replace '^.*/', ''); if ($xn) { [void](Bios-Http $x $Res.Page (Join-Path $dir $xn) 120 '*/*') }
    }
    if ($fn -match '(?i)\.zip$') {
        $ex = Join-Path $dir 'Распаковано'
        try { if (-not (Test-Path -LiteralPath $ex)) { Expand-Archive -LiteralPath $dst -DestinationPath $ex -Force -ErrorAction Stop } } catch { Bios-Log "unzip: $($_.Exception.Message)" }
    }
    # В архиве может лежать готовый загрузочный комплект (EFI\BOOT\bootx64.efi + startup.nsh): тогда прошивка запускается сама при загрузке с флешки
    $kit = ''
    try {
        $nsh = Get-ChildItem -LiteralPath (Join-Path $dir 'Распаковано') -Recurse -Filter startup.nsh -ErrorAction Stop | Select-Object -First 1
        if ($nsh -and $nsh.Directory.Name -eq 'BOOT' -and $nsh.Directory.Parent.Name -eq 'EFI' -and (Test-Path -LiteralPath (Join-Path $nsh.DirectoryName 'bootx64.efi'))) { $kit = $nsh.Directory.Parent.Parent.FullName }
    } catch {}
    $ret.Kit = $kit
    # ---- инструкция
    $L = New-Object System.Collections.Generic.List[string]
    $L.Add('ОБНОВЛЕНИЕ BIOS — подготовлено программой BigTechoTest ' + (Get-Date -Format 'dd.MM.yyyy HH:mm'))
    $L.Add('=' * 70)
    $L.Add('Компьютер / плата : ' + ("$($Hw.BbMan) $($Hw.BbProd) $($Hw.BbVer)" -replace '\s+', ' ').Trim())
    $L.Add('На сайте найдена  : ' + $Res.Model)
    $L.Add('Установлен BIOS   : ' + $Hw.BiosVer + $(if ($Hw.BiosDate -is [datetime]) { ' от ' + (DT $Hw.BiosDate) } else { '' }) + $(if ($Dec.Current) { ' (у производителя это версия ' + $Dec.Current.Version + ')' } else { '' }))
    $L.Add('Новая версия      : ' + $Entry.Version + ' от ' + (DT $Entry.Date))
    $L.Add('Файл              : ' + $fn + ' (' + $ret.SizeMb + ' МБ)')
    $L.Add('Проверка файла    : ' + $(if ($ret.Verified) { $ret.Verified } else { 'не проводилась' }))
    $L.Add('SHA-256           : ' + $hash)
    $L.Add('Источник          : ' + $Entry.Url)
    $L.Add('Страница модели   : ' + $Res.Page)
    $L.Add('')
    $L.Add('ПЕРЕД ПРОШИВКОЙ — ОБЯЗАТЕЛЬНО')
    $L.Add('- Сверьте модель (и ревизию) на самой плате / наклейке ноутбука с моделью выше. Чужой BIOS превращает плату в «кирпич».')
    $L.Add('- Питание должно быть стабильным: ИБП или хотя бы не в грозу; ноутбук — на зарядке. Отключение во время прошивки = ремонт на программаторе.')
    $L.Add('- Ручной разгон сбросьте. После прошивки настройки BIOS сбросятся: заново включите XMP/EXPO, порядок загрузки, режим вентиляторов.')
    if ($Hw.BitLocker) { $L.Add('- НА ЭТОМ КОМПЬЮТЕРЕ ВКЛЮЧЕНО ШИФРОВАНИЕ BitLocker: перед прошивкой приостановите его (Панель управления -> Шифрование диска BitLocker -> Приостановить защиту) и убедитесь, что ключ восстановления сохранён. Иначе после прошивки Windows потребует ключ.') }
    else { $L.Add('- Если включено шифрование диска (BitLocker) — приостановите его перед прошивкой и сохраните ключ восстановления.') }
    $L.Add('- Не обновляйте BIOS «просто так» на ПК, который работает идеально: обновление нужно при сбоях, новом процессоре/памяти, проблемах совместимости и уязвимостях.')
    $L.Add('')
    $L.Add('КАК ОБНОВИТЬ')
    if ($kit) {
        $L.Add('В архиве производителя — ГОТОВЫЙ ЗАГРУЗОЧНЫЙ КОМПЛЕКТ (проверено программой: есть EFI\BOOT\bootx64.efi и startup.nsh).')
        $L.Add('1. Возьмите флешку, отформатируйте в FAT32.')
        $L.Add('2. Скопируйте в КОРЕНЬ флешки всё содержимое папки:')
        $L.Add('     ' + $kit)
        $L.Add('   (в корне флешки должна оказаться папка EFI).')
        $L.Add('3. Перезагрузите компьютер и загрузитесь с этой флешки (меню загрузки: F11 / F12 / F8 при включении -> «UEFI: название флешки»).')
        $L.Add('   Если флешка не загружается — временно выключите Secure Boot в BIOS (после прошивки включите обратно).')
        $L.Add('4. ПРОШИВКА НАЧНЁТСЯ САМА сразу после загрузки с флешки. Ничего не нажимайте и не выключайте питание до сообщения об окончании (3-10 минут).')
        $L.Add('5. После окончания выньте флешку (иначе при следующей загрузке с неё прошивка запустится снова) и перезагрузите компьютер.')
        $L.Add('')
        $L.Add('Другие способы (если комплект не подошёл):')
    }
    foreach ($ln in (Bios-HowTo $Res.Vendor $fn)) { $L.Add($ln) }
    foreach ($gd in (AsArr $Res.Guides)) { $L.Add('  ' + $gd.Title + ': ' + $gd.Url) }
    $L.Add('')
    $L.Add('ЧТО ИЗМЕНИЛОСЬ (по данным производителя)')
    $hist = @($Dec.Newer); if (-not $hist.Count) { $hist = @($Entry) }
    foreach ($h in ($hist | Sort-Object Date -Descending | Select-Object -First 15)) {
        $L.Add(('--- {0} от {1}' -f $h.Version, (DT $h.Date)))
        if ($h.Notes) { foreach ($ln in ((Bios-NoteRu $h.Notes) -split "`n")) { $L.Add('    ' + $ln) } } else { $L.Add('    (описания нет)') }
    }
    $L.Add('')
    $L.Add('Программа BigTechoTest сама BIOS не прошивает — решение и прошивка остаются за мастером / владельцем.')
    try { [IO.File]::WriteAllLines((Join-Path $dir 'КАК ОБНОВИТЬ BIOS.txt'), $L.ToArray(), (New-Object Text.UTF8Encoding $true)) } catch { Bios-Log "readme: $($_.Exception.Message)" }
    $ret.Folder = $dir; $ret.File = $dst
    return $ret
}
