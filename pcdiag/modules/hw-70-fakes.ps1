# Поиск подделок (дешёвые проверки, без нагрузки): видеокарта (код чипа PCI vs название и объём памяти),
# оперативная память (SPD: партномер vs производитель, клоны серийных номеров), накопители (объём vs номинал в названии).
# Тест поддельного объёма флешки (запись/чтение) - отдельный шаг stress-70-fakeflash (ключ fakeflash).
# Таблица кодов - выборочная (популярные модели); чего в таблице нет - не оценивается. Ноутбучные (Laptop/Max-Q) видеокарты пропускаются.
Step 'Поиск подделок: видеокарта, память, накопители' {
    $s = New-Section 'Поиск подделок'
    $rows = New-Object System.Collections.Generic.List[object]
    $script:fkCrit = 0; $script:fkWarn = 0
    function FkRow($what, $found, $risk) {
        $txt = switch ($risk) { 'crit' { 'ВЫСОКИЙ' } 'warn' { 'средний' } default { 'низкий' } }
        $rows.Add([pscustomobject]@{ 'Что проверено' = $what; 'Находка' = $found; 'Риск' = $txt })
        if ($risk -eq 'crit') { $script:fkCrit++ } elseif ($risk -eq 'warn') { $script:fkWarn++ }
    }

    # ================================================================ (a) ВИДЕОКАРТА
    # «код PCI|модели через запятую (заглавными)|допустимый объём памяти, ГБ»
    $gpuTable = @'
10DE:2B85|RTX 5090|32
10DE:2C02|RTX 5080|16
10DE:2C05|RTX 5070 TI|16
10DE:2F04|RTX 5070|12
10DE:2D04|RTX 5060 TI|8,16
10DE:2D05|RTX 5060|8
10DE:2684|RTX 4090|24
10DE:2704|RTX 4080|16
10DE:2702|RTX 4080 SUPER|16
10DE:2705|RTX 4070 TI SUPER|16
10DE:2782|RTX 4070 TI|12
10DE:2783|RTX 4070 SUPER|12
10DE:2786|RTX 4070|12
10DE:2860|RTX 4070|12
10DE:2803|RTX 4060 TI|8
10DE:2805|RTX 4060 TI|16
10DE:2882|RTX 4060|8
10DE:2204|RTX 3090|24
10DE:2203|RTX 3090 TI|24
10DE:2206|RTX 3080|10,12
10DE:220A|RTX 3080|12
10DE:2216|RTX 3080|10
10DE:2208|RTX 3080 TI|12
10DE:2484|RTX 3070|8
10DE:2488|RTX 3070|8
10DE:2482|RTX 3070 TI|8
10DE:2486|RTX 3060 TI|8
10DE:2489|RTX 3060 TI|8
10DE:2414|RTX 3060 TI|8
10DE:2503|RTX 3060|12
10DE:2504|RTX 3060|12
10DE:2487|RTX 3060|8,12
10DE:2507|RTX 3050|6,8
10DE:2582|RTX 3050|8
10DE:2584|RTX 3050|6
10DE:1E04|RTX 2080 TI|11
10DE:1E07|RTX 2080 TI|11
10DE:1E87|RTX 2080|8
10DE:1E82|RTX 2080|8
10DE:1E81|RTX 2080 SUPER|8
10DE:1E84|RTX 2070 SUPER|8
10DE:1F02|RTX 2070|8
10DE:1F07|RTX 2070|8
10DE:1F06|RTX 2060 SUPER|8
10DE:1F42|RTX 2060 SUPER|8
10DE:1F47|RTX 2060 SUPER|8
10DE:1F08|RTX 2060|6
10DE:1F15|RTX 2060|6
10DE:1F11|RTX 2060|12
10DE:2184|GTX 1660|6
10DE:21C4|GTX 1660 SUPER|6
10DE:2182|GTX 1660 TI|6
10DE:2187|GTX 1650 SUPER|4
10DE:1F82|GTX 1650|4
10DE:2188|GTX 1650|4
10DE:1B06|GTX 1080 TI|11
10DE:1B80|GTX 1080|8
10DE:1B82|GTX 1070 TI|8
10DE:1B81|GTX 1070|8
10DE:1C03|GTX 1060|6
10DE:1C02|GTX 1060|3,6
10DE:1C82|GTX 1050 TI|4
10DE:1C81|GTX 1050|2
10DE:1D01|GT 1030|2
10DE:17C8|GTX 980 TI|6
10DE:13C0|GTX 980|4
10DE:13C2|GTX 970|4
10DE:1401|GTX 960|2,4
10DE:1380|GTX 750 TI|2,4
10DE:1381|GTX 750|1,2
10DE:1287|GT 730|1,2,4
10DE:0F02|GT 730|1,2
10DE:128B|GT 710|1,2
10DE:1280|GT 710|1,2
1002:744C|RX 7900 XTX,RX 7900 XT,RX 7900 GRE|20,24
1002:747E|RX 7800 XT,RX 7700 XT|12,16
1002:7480|RX 7600,RX 7600 XT|8,16
1002:73BF|RX 6950 XT,RX 6900 XT,RX 6800 XT,RX 6800|16
1002:73A5|RX 6950 XT|16
1002:73DF|RX 6700 XT,RX 6700,RX 6750 XT|10,12
1002:73FF|RX 6600 XT,RX 6600|8
1002:743F|RX 6500 XT,RX 6400|4
1002:7340|RX 5500 XT|4,8
1002:731F|RX 5700 XT,RX 5700,RX 5600 XT|6,8
1002:67DF|RX 590,RX 580,RX 570,RX 480,RX 470|4,8
1002:67FF|RX 560,RX 550|2,4
1002:699F|RX 550,RX 540|2,4
1002:7550|RX 9070 XT,RX 9070|16
8086:56A0|ARC A770|8,16
8086:56A1|ARC A750|8
8086:56A2|ARC A580|8
8086:56A5|ARC A380|6
8086:E20B|ARC B580|12
8086:E20C|ARC B570|10
'@
    $gtab = @{}
    foreach ($ln in ($gpuTable -split "`r?`n")) {
        $p = $ln.Trim() -split '\|'
        if ($p.Count -lt 3) { continue }
        $e = [pscustomobject]@{ Keys = @($p[1] -split ','); Vram = @($p[2] -split ',' | ForEach-Object { [int]$_ }) }
        if ($gtab.ContainsKey($p[0])) { $o = $gtab[$p[0]]; $gtab[$p[0]] = [pscustomobject]@{ Keys = @($o.Keys + $e.Keys | Select-Object -Unique); Vram = @($o.Vram + $e.Vram | Select-Object -Unique) } }
        else { $gtab[$p[0]] = $e }
    }
    # «RTX 3080 Ti» -> 'RTX 3080 TI'; «RX 7900 XTX» -> 'RX 7900 XTX'; «Arc A770» -> 'ARC A770'; иначе ''
    function Fk-Key($name) {
        $n = "$name"
        if ($n -match '(?i)\b(RTX|GTX|GT)\s*-?\s*(\d{3,4})(?:\s*(Ti)\b)?(?:\s*(SUPER)\b)?') {
            $k = ('{0} {1}' -f $Matches[1].ToUpper(), $Matches[2])
            if ($Matches[3]) { $k += ' TI' }
            if ($Matches[4]) { $k += ' SUPER' }
            return $k
        }
        if ($n -match '(?i)\bRX\s*(\d{3,4})\s*(XTX|XT|GRE)?\b') {
            $k = 'RX ' + $Matches[1]
            if ($Matches[2]) { $k += ' ' + $Matches[2].ToUpper() }
            return $k
        }
        if ($n -match '(?i)\bArc\s*(?:Pro\s*)?([AB]\d{3})\b') { return 'ARC ' + $Matches[1].ToUpper() }
        return ''
    }
    function Fk-Base($key) { return ($key -replace ' (TI SUPER|TI|SUPER|XTX|XT|GRE)$', '') }

    $smiRows = @()
    $smi = $null; if (Get-Command Get-SmiExe -ErrorAction SilentlyContinue) { $smi = Get-SmiExe }
    if ($smi) {
        try {
            $r = Run-Exe $smi '--query-gpu=name,pci.device_id,memory.total --format=csv,noheader,nounits' 20
            foreach ($ln in ($r.Out -split "`r?`n")) {
                $p = $ln -split ',\s*'
                if ($p.Count -ge 3 -and $p[1] -match '(?i)^0x([0-9A-F]{4})10DE$') { $smiRows += [pscustomobject]@{ Name = $p[0].Trim(); Dev = $Matches[1].ToUpper(); MiB = $p[2].Trim() } }
            }
        } catch { $G.Log.Add('fakes smi: ' + $_.Exception.Message) }
    }
    $gpuN = 0
    foreach ($v in @(CIM Win32_VideoController)) {
        $pnp = "$($v.PNPDeviceID)"
        if ($pnp -notmatch 'VEN_([0-9A-F]{4})&DEV_([0-9A-F]{4})') { continue }
        $ven = $Matches[1].ToUpper(); $dev = $Matches[2].ToUpper()
        $nm = Clean $v.Name
        if ($ven -notin '10DE', '1002', '8086') { continue }
        $gpuN++
        $lbl = 'Видеокарта «' + $nm + '» (' + $ven + ':' + $dev + ')'
        if ($nm -match '(?i)laptop|mobile|max-q|notebook') { FkRow $lbl 'ноутбучная версия - таблица кодов не применяется' ''; continue }
        $key = Fk-Key $nm
        $ent = $gtab[($ven + ':' + $dev)]
        # объём памяти: реестр драйвера (qword), иначе nvidia-smi
        $memGB = $null
        try {
            $dk = (Get-PnpDeviceProperty -InstanceId $pnp -KeyName 'DEVPKEY_Device_Driver' -ErrorAction Stop).Data
            if ($dk) {
                $reg = Get-ItemProperty ('HKLM:\SYSTEM\CurrentControlSet\Control\Class\' + $dk) -ErrorAction Stop
                $mq = $reg.'HardwareInformation.qwMemorySize'
                if ($mq) { $memGB = [math]::Round([double]$mq / 1GB) }
            }
        } catch {}
        $sm = $null
        if ($ven -eq '10DE') { $sm = @($smiRows | Where-Object { $_.Dev -eq $dev })[0] }
        $smGB = $null
        if ($sm) { $d1 = 0.0; if ([double]::TryParse($sm.MiB, [Globalization.NumberStyles]::Float, $IC, [ref]$d1) -and $d1 -gt 0) { $smGB = [math]::Round($d1 / 1024) } }
        if ($null -eq $memGB -and $null -ne $smGB) { $memGB = $smGB }
        if (-not $ent) {
            FkRow $lbl 'код чипа нет в таблице - сверка названия не выполнена' ''
        } elseif (-not $key) {
            FkRow $lbl ('название без номера модели; код чипа соответствует: ' + ($ent.Keys -join ' / ')) ''
        } elseif ($ent.Keys -contains $key) {
            FkRow $lbl ('название и код чипа согласованы (' + $key + ')') ''
        } elseif (@($ent.Keys | Where-Object { (Fk-Base $_) -eq (Fk-Base $key) }).Count) {
            FkRow $lbl ('в названии «{0}», по коду чипа ожидается: {1} (вариант того же чипа - возможна неполнота таблицы)' -f $key, ($ent.Keys -join ' / ')) 'warn'
        } else {
            FkRow $lbl ('в названии «{0}», а код чипа принадлежит {1}' -f $key, ($ent.Keys -join ' / ')) 'crit'
            Add-Issue 'crit' 'Видеокарта' ('{0}: название не совпадает с чипом - код PCI {1}:{2} принадлежит {3}' -f $nm, $ven, $dev, ($ent.Keys -join ' / ')) 'Видеокарта может быть перешита (поддельная/«перепрошитая» старая карта под более новую модель). Не покупайте/не платите как за заявленную модель; сверьте чип визуально (маркировка на кристалле), сделайте бенчмарк и сравните с эталоном этой модели.'
        }
        # объём видеопамяти по таблице
        if ($ent -and $null -ne $memGB -and $memGB -gt 0) {
            $okMem = @($ent.Vram | Where-Object { [math]::Abs($_ - $memGB) -le 1 }).Count -gt 0
            $mx = ($ent.Vram | Measure-Object -Maximum).Maximum
            if ($okMem) { FkRow ('Видеопамять ' + $nm) ('{0:N0} ГБ - допустимо для чипа ({1} ГБ)' -f $memGB, ($ent.Vram -join '/')) '' }
            elseif ($memGB -gt $mx * 1.5) {
                FkRow ('Видеопамять ' + $nm) ('драйвер сообщает {0:N0} ГБ, а чип выпускался только с {1} ГБ' -f $memGB, ($ent.Vram -join '/')) 'crit'
                Add-Issue 'crit' 'Видеокарта' ('{0}: заявлено {1:N0} ГБ видеопамяти, у этого чипа бывает только {2} ГБ' -f $nm, $memGB, ($ent.Vram -join '/')) 'Признак подделки/перепрошивки (завышенный объём в прошивке). Запустите тест видеопамяти (VRAM) - он покажет реальный объём.'
            } else { FkRow ('Видеопамять ' + $nm) ('{0:N0} ГБ; обычно у этого чипа {1} ГБ (возможен редкий вариант)' -f $memGB, ($ent.Vram -join '/')) 'warn' }
        }
        if ($null -ne $memGB -and $null -ne $smGB -and [math]::Abs($memGB - $smGB) -ge 2) {
            FkRow ('Видеопамять ' + $nm) ('Windows: {0:N0} ГБ, nvidia-smi: {1:N0} ГБ - расхождение' -f $memGB, $smGB) 'warn'
        }
        # имя драйвера Windows vs имя в nvidia-smi
        if ($sm -and $key) {
            $k2 = Fk-Key $sm.Name
            if ($k2 -and $k2 -ne $key) { FkRow ('Название ' + $nm) ('nvidia-smi называет карту «{0}», Windows - «{1}»' -f $sm.Name, $nm) 'warn' }
        }
    }
    if (-not $gpuN) { FkRow 'Видеокарта' 'дискретная NVIDIA/AMD/Intel Arc не обнаружена - пропущено' '' }

    # ================================================================ (b) ОПЕРАТИВНАЯ ПАМЯТЬ
    $mk = @{ '80CE' = 'Samsung'; 'CE80' = 'Samsung'; '80AD' = 'SK hynix'; 'AD80' = 'SK hynix'; '802C' = 'Micron'; '2C80' = 'Micron'; '859B' = 'Crucial'; '9B85' = 'Crucial'; '9801' = 'Kingston'; '0198' = 'Kingston'; '04CD' = 'G.Skill'; 'CD04' = 'G.Skill'; '029E' = 'Corsair'; '9E02' = 'Corsair' }
    function Fk-Maker($raw) {
        $t = (Clean $raw) -replace '^(?i)0x', ''
        if (-not $t -or $t -match '(?i)^(undefined|unknown|manufacturer\d*|not specified|0+|ffff|n/a)$') { return '' }
        if ($t -match '^[0-9A-Fa-f]{4}$') { $x = $mk[$t.ToUpper()]; if ($x) { return $x }; return '?' }
        if ($t -match '(?i)samsung') { return 'Samsung' }
        if ($t -match '(?i)hynix') { return 'SK hynix' }
        if ($t -match '(?i)micron') { return 'Micron' }
        if ($t -match '(?i)crucial') { return 'Crucial' }
        if ($t -match '(?i)kingston') { return 'Kingston' }
        if ($t -match '(?i)g\.?\s*skill') { return 'G.Skill' }
        if ($t -match '(?i)corsair') { return 'Corsair' }
        return $t
    }
    # партномер -> (семейство-производитель, является ли «сырым» номером чипмейкера)
    function Fk-PartMaker($pn) {
        $t = (Clean $pn).ToUpper()
        if ($t -match '^(M378|M471|M474|M391|M393|M386|M323|M425|M321|M470|M312)') { return @('Samsung', $true) }
        if ($t -match '^(HMA|HMT|HMAA|HMCG|HMAB|HMP|HMD|HMG)') { return @('SK hynix', $true) }
        if ($t -match '^MT[AC]?\d') { return @('Micron', $true) }
        if ($t -match '^(KVR|KHX|KF[345]|KCP|KSM|HX\d|HYPERX)') { return @('Kingston', $false) }
        if ($t -match '^(CT\d|BL[SEMT]?\d|CP\d)') { return @('Crucial', $false) }
        if ($t -match '^(CM[KVXWHTRD]\d)') { return @('Corsair', $false) }
        if ($t -match '^F[345]-\d') { return @('G.Skill', $false) }
        return @('', $false)
    }
    $dims = @(CIM Win32_PhysicalMemory)
    $big3 = 'Samsung', 'SK hynix', 'Micron'
    $serials = @{}
    foreach ($d in $dims) {
        $sn = Clean $d.SerialNumber
        if ($sn -and $sn -notmatch '^(0+|FFFFFFFF|None|Unknown|Not Specified|SerNum\d)$') { if ($serials.ContainsKey($sn)) { $serials[$sn]++ } else { $serials[$sn] = 1 } }
    }
    $ri = 0
    foreach ($d in $dims) {
        $ri++
        $pn = Clean $d.PartNumber
        $loc = (Clean $d.DeviceLocator); if (-not $loc) { $loc = 'модуль ' + $ri }
        $lbl = 'Память ' + $loc + $(if ($pn) { ' (' + $pn + ')' } else { '' })
        $ff = [int]$d.FormFactor
        $removable = ($ff -in 8, 12, 13)
        $maker = Fk-Maker $d.Manufacturer
        $pm = Fk-PartMaker $pn
        $bad = $false
        if (-not $removable) { FkRow $lbl 'распаянная память - проверка SPD не применяется' ''; continue }
        if (-not $pn -or $pn -match '(?i)^(unknown|undefined|not specified|0+|array\d*|none|-+|n/?a)$') {
            FkRow $lbl 'партномер не указан или фиктивный - безымянный модуль' 'warn'; $bad = $true
        }
        if ($pm[0]) {
            if ($maker -and $maker -ne '?' -and $maker -ne $pm[0]) {
                if ($pm[1] -and ($big3 -contains $maker)) {
                    FkRow $lbl ('партномер чипмейкера {0}, а производитель модуля в SPD - {1}: перемаркировка/подделка' -f $pm[0], $maker) 'crit'
                    Add-Issue 'crit' 'Память' ('{0}: партномер {1} принадлежит {2}, но в SPD указан производитель {3}' -f $loc, $pn, $pm[0], $maker) 'Признак перемаркированного/поддельного модуля памяти. Сверьте наклейку с данными SPD (CPU-Z), при покупке откажитесь или требуйте замену.'
                    $bad = $true
                } else {
                    FkRow $lbl ('партномер соответствует {0}, а производитель в SPD - {1}' -f $pm[0], $maker) 'warn'; $bad = $true
                }
            } elseif ($pm[1] -and (-not $maker -or $maker -eq '?')) {
                FkRow $lbl ('партномер {0} (сырой номер чипмейкера), а производитель модуля в SPD не определён' -f $pm[0]) 'warn'; $bad = $true
            }
        }
        $sn = Clean $d.SerialNumber
        if ($sn -and $serials.ContainsKey($sn) -and $serials[$sn] -gt 1 -and $dims.Count -gt 1) {
            FkRow $lbl ('серийный номер {0} совпадает у {1} модулей - SPD клонирован' -f $sn, $serials[$sn]) 'warn'; $bad = $true
        }
        $capGB = [math]::Round([double]$d.Capacity / 1GB, 1)
        if ($capGB -notin 1, 2, 3, 4, 6, 8, 12, 16, 24, 32, 48, 64, 96, 128, 192, 256) { FkRow $lbl ('нестандартный объём модуля {0:N1} ГБ' -f $capGB) 'warn'; $bad = $true }
        if (-not $bad) { FkRow $lbl ('SPD правдоподобен ({0} ГБ, производитель: {1})' -f $capGB, $(if ($maker -and $maker -ne '?') { $maker } else { 'код не расшифрован' })) '' }
    }
    if (-not $dims.Count) { FkRow 'Оперативная память' 'модули не обнаружены' 'warn' }

    # ================================================================ (c) НАКОПИТЕЛИ: объём vs номинал в названии
    $smDevs = @(); if ($G.SmartDevs) { $smDevs = @($G.SmartDevs | Where-Object { $_ -and $_.J }) }
    foreach ($dk in @(CIM Win32_DiskDrive)) {
        $model = Clean $dk.Model
        $size = [double]$dk.Size
        if (-not $model -or $size -le 0) { continue }
        $lbl = 'Накопитель «' + $model + '»'
        $nom = $null; $nomTxt = ''
        if ($model -match '(?<![A-Za-z0-9.])(\d{1,4}(?:\.\d)?)\s?(TB|GB|T|G)(?![A-Za-z0-9])') { $nomTxt = $Matches[1] + $Matches[2]; $val = [double]::Parse($Matches[1], $IC); if ($Matches[2] -like 'T*') { $nom = $val * 1e12 } else { $nom = $val * 1e9 } }
        elseif ($model -match 'S37/?(\d{2,4})(G|T)\b') { $nomTxt = $Matches[1] + $Matches[2]; $val = [double]::Parse($Matches[1], $IC); if ($Matches[2] -eq 'T') { $nom = $val * 1e12 } else { $nom = $val * 1e9 } }
        $found = ''; $risk = ''
        if ($nom) {
            $ratio = $size / $nom
            if ($ratio -lt 0.6) { $risk = 'crit'; $found = ('в названии {0}, а реальный объём {1:N0} ГБ ({2:P0} от заявленного)' -f $nomTxt, ($size / 1e9), $ratio) }
            elseif ($ratio -lt 0.88) { $risk = 'warn'; $found = ('в названии {0}, объём {1:N0} ГБ - заметно меньше заявленного' -f $nomTxt, ($size / 1e9)) }
            elseif ($ratio -gt 1.15) { $risk = 'warn'; $found = ('в названии {0}, объём {1:N0} ГБ - больше заявленного (проверьте модель)' -f $nomTxt, ($size / 1e9)) }
            else { $found = ('объём {0:N0} ГБ соответствует названию ({1})' -f ($size / 1e9), $nomTxt) }
        } else { $found = ('объём {0:N0} ГБ; номинал в названии не указан' -f ($size / 1e9)) }
        # объём по SMART (smartctl) vs Windows: расхождение у USB-адаптеров - норма, у обычных дисков - странно
        $sd = $smDevs | Where-Object { $_.Model -and ($_.Model -eq $model -or $model -like ('*' + $_.Model + '*')) } | Select-Object -First 1
        if ($sd -and $sd.J.user_capacity -and $sd.J.user_capacity.bytes) {
            $cb = [double]$sd.J.user_capacity.bytes
            if ($cb -gt 0 -and [math]::Abs($cb - $size) / $cb -gt 0.05) { $found += ('; smartctl видит {0:N0} ГБ' -f ($cb / 1e9)); if (-not $risk) { $risk = 'warn' } }
        }
        $isUsb = ("$($dk.InterfaceType)" -eq 'USB') -or ("$($dk.PNPDeviceID)" -like 'USB*')
        if ($isUsb -and $size -ge 250e9 -and $model -match '(?i)flash|usb disk|generic|mass storage|storage device|u disk|udisk') {
            $found += '; безымянная USB-флешка такого объёма - частая подделка, запустите тест «поддельный объём» (ключ fakeflash)'
            if (-not $risk) { $risk = 'warn' }
        }
        if ($risk -eq 'crit') { Add-Issue 'crit' 'Накопитель' ('{0}: {1}' -f $model, $found) 'Диск/флешка занижает или подменяет объём - вероятная подделка. Не используйте для важных данных; верните продавцу.' }
        FkRow $lbl $found $risk
    }

    # ---- итог
    Add-Table $s 'Проверка на подделки: что проверено / находка / риск' (AsArr $rows)
    if ($script:fkCrit) { Add-Row $s 'Итог' ('признаки подделки: {0}, подозрений: {1}' -f $script:fkCrit, $script:fkWarn) 'crit' }
    elseif ($script:fkWarn) { Add-Row $s 'Итог' ('явных подделок нет, подозрений: {0}' -f $script:fkWarn) 'warn' }
    else { Add-Row $s 'Итог' 'признаков подделки по дешёвым проверкам не найдено' 'ok' }
    Add-Row $s 'Примечание' 'Проверка по данным Windows/SPD; для карт с полностью подменённым ID её недостаточно - используйте тест видеопамяти и бенчмарк.'
    $G.Num.fake_crit = [int]$script:fkCrit
    $G.Num.fake_warn = [int]$script:fkWarn
}
