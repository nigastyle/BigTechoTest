# Wi-Fi: каналы и помехи. Разбор `netsh wlan show interfaces` и `netsh wlan show networks mode=bssid` (вывод локализован: RU/EN).
# Считает загруженность каналов 2,4 и 5 ГГц и подсказывает лучший канал для роутера. Без Wi-Fi адаптера шаг пропускается.
$STEPKEYS['Wi-Fi: каналы и помехи'] = 'net'
Step 'Wi-Fi: каналы и помехи' {
    $wi = @(netsh wlan show interfaces 2>$null)
    if (-not ($wi | Where-Object { $_ -match '^\s*(SSID|BSSID|State|Состояние|Name|Имя)\s*:' })) { $G.Log.Add('wifi-chan: нет Wi-Fi интерфейса'); return }
    $s = New-Section 'Wi-Fi: каналы и помехи'

    function ConvBand([string]$txt, [int]$chan) {
        if ($txt -match '^\s*6') { return '6' }
        if ($txt -match '^\s*5') { return '5' }
        if ($txt -match '^\s*2') { return '2.4' }
        if ($chan -ge 1 -and $chan -le 14) { return '2.4' }
        if ($chan -ge 36) { return '5' }
        return ''
    }
    function KV([string]$line) {
        if ($line -match '^\s*([^:]+?)\s*:\s*(.*?)\s*$') { return @($Matches[1], $Matches[2]) }
        return $null
    }
    function ToInt([string]$v) { $m = [regex]::Match("$v", '\d+'); if ($m.Success) { return [int]$m.Value } return $null }

    # ---------------- текущее подключение
    $cur = @{ Ssid = ''; Bssid = ''; Chan = $null; Band = ''; Sig = $null; Rx = $null; Tx = $null; Radio = '' }
    $connected = $false
    foreach ($ln in $wi) {
        $kv = KV $ln; if (-not $kv) { continue }
        $k = $kv[0]; $v = $kv[1]
        if ($k -match '^(SSID)$') { $cur.Ssid = $v; if ($v) { $connected = $true } }
        elseif ($k -match '^BSSID$') { $cur.Bssid = $v.ToLower() }
        elseif ($k -match '^(Канал|Channel)$') { $cur.Chan = ToInt $v }
        elseif ($k -match '^(Диапазон|Band)$') { $cur.Band = $v }
        elseif ($k -match '^(Сигнал|Signal)$') { $cur.Sig = ToInt $v }
        elseif ($k -match '^(Тип радио|Radio type)$') { $cur.Radio = $v }
        elseif ($k -match '^(Скорость\s+прие|Receive rate)') { $cur.Rx = ToInt $v }
        elseif ($k -match '^(Скорость\s+передачи|Transmit rate)') { $cur.Tx = ToInt $v }
    }
    $curBand = ConvBand $cur.Band ([int]$cur.Chan)
    $bandTxt = @{ '2.4' = '2,4 ГГц'; '5' = '5 ГГц'; '6' = '6 ГГц'; '' = '?' }
    if ($connected) {
        $rate = $(if ($cur.Rx) { "$($cur.Rx)" } else { '?' }) + $(if ($cur.Tx) { " / $($cur.Tx)" } else { '' })
        Add-Row $s 'Текущая сеть' ('«{0}», BSSID {1}' -f $cur.Ssid, $cur.Bssid) ''
        Add-Row $s 'Канал и диапазон' ('канал {0}, {1}{2}' -f $cur.Chan, $bandTxt[$curBand], $(if ($cur.Radio) { ', ' + $cur.Radio } else { '' })) ''
        $sigSt = ''; if ($null -ne $cur.Sig) { $sigSt = $(if ($cur.Sig -ge 60) { 'ok' } elseif ($cur.Sig -ge 40) { 'warn' } else { 'crit' }) }
        Add-Row $s 'Сигнал и скорость' ('сигнал {0} %, скорость приёма/передачи {1} Мбит/с' -f $cur.Sig, $rate) $sigSt
        if ($null -ne $cur.Sig) { $G.Num.wifi_signal = $cur.Sig }
        if ($null -ne $cur.Sig -and $cur.Sig -lt 40) {
            Add-Issue 'warn' 'Wi-Fi' ("слабый сигнал Wi-Fi: {0} %" -f $cur.Sig) 'Подойдите ближе к роутеру или уберите препятствия (стены, зеркала, микроволновка). Поможет усилитель или mesh-система; на 5 ГГц сигнал слабее проходит стены.'
        }
    } else {
        Add-Row $s 'Wi-Fi подключение' 'адаптер есть, но не подключён к сети' ''
    }

    # ---------------- сканирование окружения
    $nw = @(netsh wlan show networks mode=bssid 2>&1 | ForEach-Object { "$_" })
    $nets = New-Object System.Collections.Generic.List[object]
    $ssid = ''; $c = $null
    foreach ($ln in $nw) {
        $kv = KV $ln; if (-not $kv) { continue }
        $k = $kv[0]; $v = $kv[1]
        if ($k -match '^SSID\s+\d+$') { $ssid = $v }
        elseif ($k -match '^BSSID\s+\d+$') {
            if ($c) { $nets.Add($c) }
            $c = [pscustomobject]@{ Ssid = $ssid; Bssid = $v.ToLower(); Sig = 0; Chan = 0; BandRaw = ''; Radio = '' }
        }
        elseif ($c) {
            if ($k -match '^(Сигнал|Signal)$') { $c.Sig = [int](ToInt $v) }
            elseif ($k -match '^(Канал|Channel)$') { $c.Chan = [int](ToInt $v) }
            elseif ($k -match '^(Диапазон|Band)$') { $c.BandRaw = $v }
            elseif ($k -match '^(Тип радио|Radio type)$') { $c.Radio = $v }
        }
    }
    if ($c) { $nets.Add($c) }
    $all = @($nets | Where-Object { $_.Chan -gt 0 })
    if (-not $all.Count) {
        $txt = ($nw -join ' ')
        if ($txt -match '(?i)location|местоположен|геолокац|privacy-location|отслеживани') {
            Add-Row $s 'Сканирование сетей' 'нужно включить службы определения местоположения (Параметры - Конфиденциальность - Расположение), иначе Windows не показывает список сетей' 'warn'
            Add-Issue 'info' 'Wi-Fi' 'анализ каналов Wi-Fi невозможен: выключены службы определения местоположения' 'Включите: Параметры - Конфиденциальность и защита - Расположение (и разрешите классическим приложениям), затем повторите проверку.'
        } else {
            Add-Row $s 'Сканирование сетей' 'список соседних сетей не получен (сетей нет в зоне или Wi-Fi выключен)' ''
        }
        return
    }
    foreach ($n in $all) { $n | Add-Member -NotePropertyName Band -NotePropertyValue (ConvBand $n.BandRaw $n.Chan) -Force }

    # ---------------- расчёт загруженности
    # свои точки доступа: тот же SSID в том же диапазоне (роутер, mesh) исключаем из помех
    function Get-Load([object[]]$list, [string]$band, [int]$ch, [string]$mySsid) {
        $sum = 0.0; $cntN = 0
        foreach ($n in $list) {
            if ($n.Band -ne $band) { continue }
            if ($mySsid -and $n.Ssid -eq $mySsid) { continue }
            $w = 0.0
            if ($band -eq '2.4') { $dd = [math]::Abs($n.Chan - $ch); if ($dd -le 4) { $w = 1.0 - ($dd / 5.0) } }
            else {
                if ($n.Chan -eq $ch) { $w = 1.0 }
                elseif ([math]::Floor(($n.Chan - 36) / 8) -eq [math]::Floor(($ch - 36) / 8)) { $w = 0.6 }
                elseif ([math]::Floor(($n.Chan - 36) / 16) -eq [math]::Floor(($ch - 36) / 16)) { $w = 0.3 }
            }
            if ($w -gt 0 -and $n.Sig -ge 15) { $sum += $w * $n.Sig; if ($w -ge 0.6) { $cntN++ } }
        }
        return [pscustomobject]@{ Load = $sum; Count = $cntN }
    }
    $mySsid = $cur.Ssid
    $best24 = $null; $best5 = $null
    $rows24 = @(); $rows5 = @()
    $has24 = @($all | Where-Object { $_.Band -eq '2.4' }).Count -gt 0
    $has5 = @($all | Where-Object { $_.Band -eq '5' }).Count -gt 0
    if ($has24) {
        foreach ($ch in 1..13) {
            $ld = Get-Load $all '2.4' $ch ''
            $ldOthers = Get-Load $all '2.4' $ch $mySsid
            $rows24 += [pscustomobject]@{ Канал = $ch; Load = $ld.Load; Others = $ldOthers.Load; Cnt = $ld.Count }
        }
        $cand = @($rows24 | Where-Object { $_.Канал -in 1, 6, 11 } | Sort-Object Others, Канал)
        $best24 = $cand[0]
    }
    $std5 = 36, 40, 44, 48, 149, 153, 157, 161
    if ($has5) {
        $chs5 = @($std5 + @($all | Where-Object { $_.Band -eq '5' } | ForEach-Object { $_.Chan }) | Sort-Object -Unique)
        foreach ($ch in $chs5) {
            $ld = Get-Load $all '5' $ch ''
            $ldOthers = Get-Load $all '5' $ch $mySsid
            $rows5 += [pscustomobject]@{ Канал = $ch; Load = $ld.Load; Others = $ldOthers.Load; Cnt = $ld.Count }
        }
        $cand5 = @($rows5 | Where-Object { $_.Канал -in $std5 } | Sort-Object Others, Канал)
        $best5 = $cand5[0]
    }

    # таблица всех сетей
    $tbl = @($all | Sort-Object @{ Expression = { $_.Band } }, @{ Expression = { $_.Chan } }, @{ Expression = { -$_.Sig } } | ForEach-Object {
        [pscustomobject]@{ 'Сеть' = $(if ($_.Ssid) { $_.Ssid } else { '(скрытая)' }); 'BSSID' = $_.Bssid; 'Диапазон' = $bandTxt[$_.Band]; 'Канал' = $_.Chan; 'Сигнал, %' = $_.Sig; 'Стандарт' = $_.Radio; 'Это вы' = $(if ($_.Bssid -eq $cur.Bssid) { 'да' } else { '' }) } })
    Add-Row $s 'Видно точек доступа' ('{0} ({1} на 2,4 ГГц, {2} на 5 ГГц)' -f $all.Count, @($all | Where-Object { $_.Band -eq '2.4' }).Count, @($all | Where-Object { $_.Band -eq '5' }).Count) ''
    function ChanTable($rows, $title) {
        @($rows | ForEach-Object { [pscustomobject]@{ 'Канал' = $_.Канал; 'Сетей рядом' = $_.Cnt; 'Загрузка (усл.)' = ('{0:N0}' -f $_.Load) } })
    }
    if ($has24) { Add-Table $s 'Загруженность каналов 2,4 ГГц' (ChanTable $rows24 '') -Collapsed }
    if ($has5) { Add-Table $s 'Загруженность каналов 5 ГГц' (ChanTable $rows5 '') -Collapsed }
    Add-Table $s ('Все найденные Wi-Fi сети ({0})' -f $tbl.Count) $tbl -Collapsed

    # ---------------- выводы
    if ($best24) { Add-Row $s 'Лучший канал 2,4 ГГц' ('канал {0} (1, 6 и 11 не пересекаются)' -f $best24.Канал) '' }
    if ($best5) { Add-Row $s 'Лучший канал 5 ГГц' ('канал {0}' -f $best5.Канал) '' }
    if ($connected -and $cur.Chan) {
        $myRows = $(if ($curBand -eq '2.4') { $rows24 } elseif ($curBand -eq '5') { $rows5 } else { @() })
        $best = $(if ($curBand -eq '2.4') { $best24 } else { $best5 })
        $mine = @($myRows | Where-Object { $_.Канал -eq $cur.Chan })
        if ($mine.Count -and $best) {
            $m = $mine[0]
            $need = $(if ($curBand -eq '2.4') { 3 } else { 2 })
            $crowded = ($m.Cnt -ge $need) -and ($m.Others -gt 60) -and ($best.Others -le $m.Others * 0.6) -and ($best.Канал -ne $cur.Chan)
            if ($crowded) {
                Add-Row $s 'Загруженность вашего канала' ('канал {0} занят: рядом {1} сетей, лучше канал {2}' -f $cur.Chan, $m.Cnt, $best.Канал) 'warn'
                Add-Issue 'info' 'Wi-Fi' ("канал Wi-Fi {0} ({1}) перегружен соседними сетями ({2})" -f $cur.Chan, $bandTxt[$curBand], $m.Cnt) ("Смените канал роутера на {0} (в настройках роутера, раздел Wi-Fi - канал; не «авто», если авто выбирает занятый)." -f $best.Канал)
            } else {
                Add-Row $s 'Загруженность вашего канала' ('канал {0}: помехи от соседей невысокие ({1} сетей рядом)' -f $cur.Chan, $m.Cnt) 'ok'
            }
            $G.Num.wifi_neighbors = $m.Cnt
        }
        if ($curBand -eq '2.4') {
            $pre = $(if ($cur.Bssid.Length -ge 14) { $cur.Bssid.Substring(0, 14) } else { '' })
            $sib = @($all | Where-Object { $_.Band -eq '5' -and (($mySsid -and $_.Ssid -eq $mySsid) -or ($pre -and $_.Bssid.StartsWith($pre))) })
            if ($sib.Count) {
                $sb5 = $sib | Sort-Object Sig -Descending | Select-Object -First 1
                Add-Row $s 'Диапазон 5 ГГц' ('у этого же роутера есть сеть 5 ГГц («{0}», сигнал {1} %), вы подключены к 2,4 ГГц' -f $sb5.Ssid, $sb5.Sig) 'warn'
                Add-Issue 'info' 'Wi-Fi' 'подключение в диапазоне 2,4 ГГц, хотя этот же роутер раздаёт 5 ГГц' ("Подключитесь к сети 5 ГГц{0} - скорость и стабильность будут выше (если сигнал достаточный)." -f $(if ($sb5.Ssid -and $sb5.Ssid -ne $mySsid) { ' «' + $sb5.Ssid + '»' } else { '' }))
            }
        }
    }
}
