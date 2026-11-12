# ---------------------------------------------------------------- «Режим по жалобе»
# Клиент выбирает жалобу (сам выключается, синий экран, артефакты, тормозит, шумит, греется, зависает, ...) -
# программа включает нужные тесты с увеличенной длительностью, а в конце (final-05-diagnosis) ранжирует вероятные причины.
# Подключение (body.ps1): после Set-Preset / разбора выбора:
#   if ($env:DIAG_COMPLAINT) { Set-ComplaintPreset ($env:DIAG_COMPLAINT -split '[,; ]+') }
#   и когда окно выбора вернуло 'complaint=shutdown,bsod' -> Set-ComplaintPreset ('shutdown,bsod' -split ',')
# $G.Complaints - упорядоченный список: Key, Title, Hint (что советовать, если причина не найдена), Tests, Rules.
$G.ComplaintKeys = @()
$G.ComplaintCauses = $null

# ---- помощники для правил (работают с $G.Issues / $G.Num / $G.Shutdowns; всё null-безопасно)
function Cx-Num($Name) {
    if ($null -eq $G.Num) { return $null }
    $v = $G.Num[$Name]
    if ($null -eq $v) { return $null }
    $d = 0.0
    if ([double]::TryParse(([string]$v), [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$d)) { return $d }
    return $null
}
function Cx-Shut($Kind) {
    if ($null -eq $G.Shutdowns) { return 0 }
    $v = $G.Shutdowns[$Kind]
    if ($null -eq $v) { return 0 }
    return [int]$v
}
# найденные проблемы (crit/warn) по области и/или тексту
function Cx-Iss($AreaRe, $TextRe = '', [switch]$AnySev) {
    $res = @()
    foreach ($it in @($G.Issues)) {
        if (-not $it) { continue }
        if (-not $AnySev -and $it.Sev -notin 'crit', 'warn') { continue }
        if ($AreaRe -and ([string]$it.Area) -notmatch $AreaRe) { continue }
        if ($TextRe -and ([string]$it.Text) -notmatch $TextRe) { continue }
        $res += $it
    }
    return , $res
}
function Cx-Short($Text, [int]$Max = 160) {
    $t = [string]$Text
    if ($t.Length -gt $Max) { return $t.Substring(0, $Max - 1) + '…' }
    return $t
}
# добавить/усилить причину: одноимённые причины из разных правил складываются
function Cx-Add($Cause, [double]$Weight, $Why, $Fix) {
    if ($null -eq $G.ComplaintCauses) { $G.ComplaintCauses = [ordered]@{} }
    $e = $G.ComplaintCauses[$Cause]
    if ($null -eq $e) {
        $e = [pscustomobject]@{ Cause = $Cause; W = 0.0; Why = (New-Object System.Collections.Generic.List[string]); Fix = (New-Object System.Collections.Generic.List[string]) }
        $G.ComplaintCauses[$Cause] = $e
    }
    $e.W += $Weight
    if ($Why -and -not $e.Why.Contains([string]$Why)) { $e.Why.Add([string]$Why) }
    if ($Fix -and -not $e.Fix.Contains([string]$Fix)) { $e.Fix.Add([string]$Fix) }
}

# названия причин (общие для правил разных жалоб, чтобы веса складывались)
$G.CxPsu = 'Блок питания / электропитание'
$G.CxCpuHot = 'Перегрев процессора / плохое охлаждение'
$G.CxGpuHot = 'Перегрев видеокарты'
$G.CxGpu = 'Неисправность видеокарты или её драйвера'
$G.CxVram = 'Неисправна видеопамять'
$G.CxRam = 'Нестабильная или неисправная оперативная память'
$G.CxCpu = 'Нестабильный процессор (разгон, напряжение, питание CPU)'
$G.CxDisk = 'Изнашивается или неисправен накопитель'
$G.CxDrv = 'Драйверы / ошибки Windows'
$G.CxSoft = 'Программный мусор, автозапуск, вирусы'
$G.CxDust = 'Пыль, износ вентиляторов, высохшая термопаста'
$G.CxNet = 'Проблемы сети / Wi-Fi'
$G.CxBat = 'Износ аккумулятора'
$G.CxAudio = 'Драйвер звука / задержки DPC'

# ---- общие блоки правил
$cxRuleStability = {
    # ошибки вычислений / памяти из тестов
    foreach ($it in (Cx-Iss 'Память' 'ошибк|нестабильн')) { Cx-Add $G.CxRam 50 (Cx-Short $it.Text) $it.Fix }
    foreach ($it in (Cx-Iss 'Процессор' 'ошибк|Prime95|y-cruncher')) {
        Cx-Add $G.CxCpu 30 (Cx-Short $it.Text) $it.Fix
        if ($it.Text -match 'y-cruncher') { Cx-Add $G.CxRam 20 (Cx-Short $it.Text) '' }
    }
}
$cxRuleHeat = {
    $ct = $G.CpuTmax
    if ($null -ne $ct) {
        if ($ct -ge 95) { Cx-Add $G.CxCpuHot 40 ('процессор под нагрузкой нагрелся до {0:N0} °C' -f $ct) 'Почистите от пыли, проверьте кулер и замените термопасту.' }
        elseif ($ct -ge 90) { Cx-Add $G.CxCpuHot 25 ('процессор под нагрузкой нагрелся до {0:N0} °C' -f $ct) 'Почистите от пыли, проверьте кулер и термопасту.' }
        elseif ($ct -ge 85) { Cx-Add $G.CxCpuHot 10 ('процессор под нагрузкой {0:N0} °C (на грани)' -f $ct) 'Проверьте охлаждение.' }
    }
    $gt = Cx-Num 'gpu_tmax'
    if ($null -ne $gt) {
        if ($gt -ge 90) { Cx-Add $G.CxGpuHot 35 ('видеокарта под нагрузкой {0:N0} °C' -f $gt) 'Почистите видеокарту, проверьте вентиляторы и термопрокладки/термопасту.' }
        elseif ($gt -ge 84) { Cx-Add $G.CxGpuHot 18 ('видеокарта под нагрузкой {0:N0} °C' -f $gt) 'Проверьте обдув корпуса и кулер видеокарты.' }
    }
    $hd = Cx-Num 'gpu_hot_delta'
    if ($null -ne $hd -and $hd -ge 20) { Cx-Add $G.CxGpuHot 15 ('горячая точка GPU на {0:N0} °C выше основной температуры' -f $hd) 'Возможно, высохли термопрокладки/термопаста видеокарты.' }
    foreach ($it in (Cx-Iss 'Охлаждение')) { Cx-Add $G.CxDust 20 (Cx-Short $it.Text) $it.Fix }
    if ($G.GuardStopped -and $G.GuardStopReason -match '(?i)перегрев|температур|°|VRM') {
        Cx-Add $G.CxCpuHot 30 ('сторож остановил тест: ' + (Cx-Short $G.GuardStopReason)) 'Устраните перегрев до дальнейших нагрузок.'
    }
}
$cxRuleDisk = {
    foreach ($it in (Cx-Iss 'Накопитель|Диск')) { Cx-Add $G.CxDisk 35 (Cx-Short $it.Text) $it.Fix }
    $sf = Cx-Num 'smart_fail'; if ($null -ne $sf -and $sf -gt 0) { Cx-Add $G.CxDisk 30 ('SMART сообщает о неисправности дисков: {0:N0}' -f $sf) 'Срочно сделайте резервную копию и замените накопитель.' }
    $se = Cx-Num 'surface_err'; if ($null -ne $se -and $se -gt 0) { Cx-Add $G.CxDisk 35 ('нечитаемых участков поверхности: {0:N0}' -f $se) 'Скопируйте данные и замените диск.' }
    $st = Cx-Num 'selftest_fail'; if ($null -ne $st -and $st -gt 0) { Cx-Add $G.CxDisk 30 'самотест диска завершился с ошибкой' 'Замените накопитель.' }
    $dh = Cx-Num 'disk_ev_hard30'; if ($null -ne $dh -and $dh -gt 0) { Cx-Add $G.CxDisk 25 ('в журнале ошибок дисков за 30 дней: {0:N0}' -f $dh) 'Проверьте кабель/питание диска, SMART, при необходимости замените.' }
    $dr = Cx-Num 'disk_ev_reset30'; if ($null -ne $dr -and $dr -gt 0) { Cx-Add $G.CxDisk 15 ('контроллер сбрасывал зависший диск: {0:N0} раз' -f $dr) 'Проверьте кабель SATA/питание и состояние диска.' }
    $sp = Cx-Num 'smart_min_spare'; if ($null -ne $sp -and $sp -le 20) { Cx-Add $G.CxDisk 15 ('у SSD остаётся {0:N0} % резерва' -f $sp) 'Планируйте замену SSD.' }
}
$cxRuleSoft = {
    $bm = Cx-Num 'boot_main_s'
    if ($null -ne $bm -and $bm -ge 60) { Cx-Add $G.CxSoft 25 ('загрузка Windows занимает {0:N0} с' -f $bm) 'Уберите лишнее из автозагрузки, удалите ненужные программы.' }
    elseif ($null -ne $bm -and $bm -ge 40) { Cx-Add $G.CxSoft 10 ('загрузка Windows занимает {0:N0} с' -f $bm) 'Проверьте автозагрузку.' }
    foreach ($it in (Cx-Iss 'Безопасность|Программы|Windows' 'угроз|вирус|вредонос|автозапуск|медленн|загрузк|мало места|свободн')) { Cx-Add $G.CxSoft 20 (Cx-Short $it.Text) $it.Fix }
    if ($G.AvThreats) { Cx-Add $G.CxSoft 40 'антивирус нашёл угрозы' 'Удалите угрозы, смените пароли, проверьте автозагрузку.' }
}

# ---- каталог жалоб
$G.Complaints = New-Object System.Collections.Generic.List[object]
function Cx-Def($Key, $Title, $Hint, $Tests, $Rules) {
    $G.Complaints.Add([pscustomobject]@{ Key = $Key; Title = $Title; Hint = $Hint; Tests = $Tests; Rules = @($Rules) })
}

Cx-Def 'shutdown' 'Сам выключается / перезагружается' 'Проверьте розетку/удлинитель/ИБП, почистите от пыли, обновите BIOS и драйверы чипсета, проверьте план электропитания; если сбои редкие и без закономерности - повторите диагностику после нескольких дней работы.' @{
    info = $true; cpu = $true; cpusec = 300; prime = $true; primemin = 10; ycr = $true; ycrmin = 10; gpu = $true; gpusec = 300; psu = $true; psumin = 10; ram = $true; logs = $true; sys = $true; selftest = $true
} @(
    {
        # блок питания / питание
        foreach ($it in (Cx-Iss 'Питание' 'проседа|одновременной нагрузкой|выключил|пропал|питан')) { Cx-Add $G.CxPsu 45 (Cx-Short $it.Text) $it.Fix }
        $bb = Cx-Num 'blackbox_crash'
        if ($null -ne $bb -and $bb -gt 0) { Cx-Add $G.CxPsu 15 'во время прошлого теста ПК внезапно выключился (чёрный ящик)' 'Проверьте блок питания и питание от сети.' }
        $pw = Cx-Shut 'power'
        if ($pw -gt 0) { Cx-Add $G.CxPsu ([math]::Min(40, 12 + 6 * $pw)) ('в журнале резких пропаданий питания без синего экрана: {0}' -f $pw) 'Проверьте розетку, удлинитель, ИБП, кабели питания и блок питания.' }
        $us = Cx-Num 'unsafe_sys'
        if ($null -ne $us -and $us -ge 50) { Cx-Add $G.CxPsu 8 ('системный SSD пережил {0:N0} аварийных отключений питания' -f $us) '' }
        if ($G.GuardStopped -and $G.GuardStopReason -match '(?i)напряж|мощност|питани|\bВ\b') { Cx-Add $G.CxPsu 30 ('сторож остановил тест: ' + (Cx-Short $G.GuardStopReason)) 'Проверьте блок питания.' }
    },
    $cxRuleHeat,
    $cxRuleStability,
    {
        $sl = Cx-Shut 'sleep'
        if ($sl -gt 0) { Cx-Add $G.CxDrv 20 ('сбоев при уходе в сон / выходе из сна: {0}' -f $sl) 'Обновите драйверы чипсета/графики и BIOS, отключите быстрый запуск и гибернацию для проверки.' }
        $bs = Cx-Shut 'bsod'
        if ($bs -gt 0) { Cx-Add $G.CxDrv 15 ('выключений из-за синего экрана: {0}' -f $bs) 'См. разбор синих экранов.' }
        $bt = Cx-Shut 'button'
        if ($bt -gt 0) { Cx-Add $G.CxDrv 8 ('зависаний с выключением кнопкой: {0}' -f $bt) 'Проверьте драйверы и память.' }
        foreach ($it in (Cx-Iss 'Стабильность' 'синих экран')) { Cx-Add $G.CxDrv 20 (Cx-Short $it.Text) $it.Fix }
    }
)

Cx-Def 'bsod' 'Синий экран' 'Обновите драйверы начисто, проверьте систему (sfc /scannow), снимите разгон/XMP для проверки; сохраните файлы дампов для разбора.' @{
    info = $true; logs = $true; ram = $true; ramfull = $true; tm5 = $true; tm5min = 20; cpu = $true; prime = $true; primemin = 5; selftest = $true; sys = $true; drivers = $true
} @(
    {
        $n = Cx-Num 'bsod90'
        foreach ($it in (Cx-Iss 'Стабильность' 'синих экран')) {
            $tx = [string]$it.Text
            $why = Cx-Short $tx 200
            if ($tx -match '(?i)чаще всего виноват') {
                if ($tx -match '(?i)nvlddmkm|amdkmdag|igdkmd|видео|NVIDIA|AMD Radeon') { Cx-Add $G.CxGpu 35 $why $it.Fix }
                else { Cx-Add $G.CxDrv 35 $why $it.Fix }
            }
            if ($tx -match '(?i)WHEA|0x124|0x9C|0x101') { Cx-Add $G.CxCpu 30 $why $it.Fix }
            if ($tx -match '(?i)MEMORY_MANAGEMENT|0x1A|0x4E|0x12B|0x50|PAGE_FAULT|оператив|памят') { Cx-Add $G.CxRam 30 $why $it.Fix }
            if ($tx -match '(?i)0x7A|0xF4|0x77|NTFS|диск|накопител') { Cx-Add $G.CxDisk 25 $why $it.Fix }
            if ($tx -match 'причина в дампах не определена') { Cx-Add $G.CxDrv 10 $why $it.Fix }
        }
        if ($null -ne $n -and $n -gt 0) { Cx-Add $G.CxDrv (5 + [math]::Min(10, 2 * $n)) ('синих экранов за 90 дней: {0:N0}' -f $n) 'Обновите драйверы, проверьте целостность Windows.' }
    },
    $cxRuleStability,
    $cxRuleDisk,
    $cxRuleHeat,
    {
        foreach ($it in (Cx-Iss 'Видеокарта' 'драйвер|Xid|сбо')) { Cx-Add $G.CxGpu 20 (Cx-Short $it.Text) $it.Fix }
        $tdr = Cx-Num 'gpu_tdr30'; if ($null -ne $tdr -and $tdr -gt 0) { Cx-Add $G.CxGpu 15 ('видеодрайвер падал {0:N0} раз за 30 дней' -f $tdr) 'Переустановите видеодрайвер начисто (DDU).' }
        $pw = Cx-Shut 'power'; if ($pw -gt 0) { Cx-Add $G.CxPsu 15 ('резких пропаданий питания: {0}' -f $pw) 'Проверьте блок питания.' }
    }
)

Cx-Def 'artifacts' 'Артефакты / полосы / мерцание на экране' 'Проверьте кабель и порт монитора, другой монитор/кабель, переустановите видеодрайвер начисто; если артефакты и на BIOS-экране - виновата видеокарта.' @{
    info = $true; gpu = $true; gpusec = 900; vram = $true; logs = $true; cpu = $false; drivers = $true
} @(
    {
        foreach ($it in (Cx-Iss 'Видеокарта' 'видеопамят')) { Cx-Add $G.CxVram 55 (Cx-Short $it.Text) $it.Fix }
        foreach ($it in (Cx-Iss 'Видеокарта' 'Xid|аппаратн')) { Cx-Add $G.CxGpu 40 (Cx-Short $it.Text) $it.Fix }
        foreach ($it in (Cx-Iss 'Видеокарта' 'шин|PCIe|питани|троттлинг')) { Cx-Add $G.CxGpu 15 (Cx-Short $it.Text) $it.Fix }
        $tdr = Cx-Num 'gpu_tdr30'
        if ($null -ne $tdr -and $tdr -gt 0) { Cx-Add $G.CxGpu 20 ('видеодрайвер падал {0:N0} раз за 30 дней' -f $tdr) 'Переустановите видеодрайвер начисто (DDU), снимите разгон.' }
        foreach ($it in (Cx-Iss 'Видеокарта' 'падал')) { Cx-Add $G.CxDrv 10 (Cx-Short $it.Text) '' }
        $pc = Cx-Num 'gpu_pcie'; if ($null -ne $pc -and $pc -gt 0 -and $pc -lt 3) { Cx-Add $G.CxGpu 5 'видеокарта работает на сниженной шине PCIe' 'Переставьте видеокарту, проверьте слот и допитку.' }
    },
    $cxRuleHeat,
    {
        if ($G.GuardStopped -and $G.GuardStopReason -match '(?i)GPU|видео') { Cx-Add $G.CxGpu 20 ('сторож остановил тест видеокарты: ' + (Cx-Short $G.GuardStopReason)) 'Проверьте охлаждение и питание видеокарты.' }
        $bb = Cx-Num 'blackbox_crash'; if ($null -ne $bb -and $bb -gt 0) { Cx-Add $G.CxGpu 10 'ПК выключился во время нагрузки на видеокарту' 'Проверьте питание видеокарты и блок питания.' }
    }
)

Cx-Def 'slow' 'Тормозит / долго грузится' 'Проверьте автозагрузку, свободное место на системном диске, наличие SSD, объём ОЗУ и вредоносные программы; переустановка Windows - крайняя мера.' @{
    info = $true; disk = $true; surface = $true; surfacemin = 5; cpu = $true; cpusec = 90; av = $true; programs = $true; logs = $true; selftest = $true; sys = $true
} @(
    $cxRuleDisk,
    $cxRuleSoft,
    {
        $rd = Cx-Num 'disk_rnd_iops'; $sr = Cx-Num 'disk_seq_r'
        if ($null -ne $sr -and $sr -gt 0 -and $sr -lt 150 -and $G.SysDiskType -notmatch '(?i)HDD|Rotational|жёстк') { Cx-Add $G.CxDisk 10 ('низкая скорость чтения системного диска: {0:N0} МБ/с' -f $sr) 'Проверьте режим SATA/NVMe, состояние диска.' }
        if ($G.SysDiskType -match '(?i)HDD|Rotational|жёстк') { Cx-Add $G.CxDisk 25 'Windows стоит на обычном жёстком диске (HDD)' 'Перенесите систему на SSD - самый заметный прирост скорости.' }
        $dp = Cx-Num 'dpc_avg_pct'; if ($null -ne $dp -and $dp -ge 3) { Cx-Add $G.CxDrv 15 ('высокие задержки DPC: {0:N1} %' -f $dp) 'Найдите драйвер-виновник (LatencyMon), обновите драйверы.' }
        foreach ($it in (Cx-Iss 'Память' 'мало оперативной')) { Cx-Add $G.CxRam 30 (Cx-Short $it.Text) 'Добавьте оперативной памяти.' }
        $ct = $G.CpuTmax; if ($null -ne $ct -and $ct -ge 92) { Cx-Add $G.CxCpuHot 20 ('троттлинг от перегрева: процессор до {0:N0} °C' -f $ct) 'Почистите охлаждение.' }
        foreach ($it in (Cx-Iss 'Процессор' 'троттлинг|ниже базовой')) { Cx-Add $G.CxCpuHot 15 (Cx-Short $it.Text) $it.Fix }
    },
    $cxRuleStability
)

Cx-Def 'noise' 'Шумит / гудит / трещит' 'Почистите от пыли, смажьте/замените шумящий вентилятор, проверьте кривую вентиляторов в BIOS; трещание диска - срочно копируйте данные.' @{
    info = $true; cpu = $true; cpusec = 180; gpu = $true; gpusec = 180; selftest = $true; logs = $true
} @(
    {
        foreach ($it in (Cx-Iss 'Охлаждение' '' -AnySev)) { Cx-Add $G.CxDust 25 (Cx-Short $it.Text) $it.Fix }
        $fr = Cx-Num 'fan_react'; if ($null -ne $fr -and $fr -lt 1) { Cx-Add $G.CxDust 10 'обороты вентиляторов не реагируют на нагрузку' 'Проверьте профиль вентиляторов в BIOS.' }
        $fc = Cx-Num 'fan_cpu_rpm'; if ($null -ne $fc -and $fc -ge 2800) { Cx-Add $G.CxCpuHot 20 ('кулер процессора раскручивается до {0:N0} об/мин' -f $fc) 'Почистите кулер, замените термопасту.' }
    },
    $cxRuleHeat,
    $cxRuleDisk
)

Cx-Def 'overheat' 'Греется / вентиляторы воют' 'Почистите от пыли, замените термопасту, проверьте направление воздушного потока и профили вентиляторов; для ноутбука - подставка и чистка системы охлаждения.' @{
    info = $true; cpu = $true; cpusec = 300; prime = $true; primemin = 10; gpu = $true; gpusec = 300; psu = $true; psumin = 5; logs = $true
} @(
    $cxRuleHeat,
    {
        $ct = $G.CpuTmax; $gt = Cx-Num 'gpu_tmax'
        if ($G.IsLaptop -and (($null -ne $ct -and $ct -ge 85) -or ($null -ne $gt -and $gt -ge 80))) { Cx-Add $G.CxDust 15 'ноутбук греется под нагрузкой - типично забита пылью система охлаждения' 'Чистка системы охлаждения и замена термопасты.' }
        foreach ($it in (Cx-Iss 'Процессор' 'высокое напряжение')) { Cx-Add $G.CxCpu 15 (Cx-Short $it.Text) $it.Fix }
        foreach ($it in (Cx-Iss 'Процессор' 'троттлинг|ниже базовой')) { Cx-Add $G.CxCpuHot 20 (Cx-Short $it.Text) $it.Fix }
    }
)

Cx-Def 'freeze' 'Зависает / подвисает' 'Проверьте драйверы, диск (SMART), память и температуры; посмотрите, что запущено в момент зависания.' @{
    info = $true; logs = $true; disk = $true; surface = $true; surfacemin = 5; selftest = $true; ram = $true; ramfull = $true; tm5 = $true; tm5min = 10; cpu = $true; prime = $true; primemin = 5; programs = $true; av = $true
} @(
    $cxRuleDisk,
    $cxRuleStability,
    $cxRuleHeat,
    $cxRuleSoft,
    {
        $bt = Cx-Shut 'button'
        if ($bt -gt 0) { Cx-Add $G.CxDrv 15 ('зависаний с принудительным выключением: {0}' -f $bt) 'Обновите драйверы; проверьте диск и память.' }
        $dp = Cx-Num 'dpc_avg_pct'; if ($null -ne $dp -and $dp -ge 3) { Cx-Add $G.CxDrv 20 ('высокие задержки DPC: {0:N1} %' -f $dp) 'Найдите драйвер-виновник (LatencyMon).' }
        $is = Cx-Num 'isr_avg_pct'; if ($null -ne $is -and $is -ge 2) { Cx-Add $G.CxDrv 10 ('много времени на аппаратные прерывания: {0:N1} %' -f $is) 'Проверьте драйверы устройств.' }
        foreach ($it in (Cx-Iss 'Видеокарта' 'падал')) { Cx-Add $G.CxGpu 20 (Cx-Short $it.Text) $it.Fix }
        $ss = Cx-Num 'surface_slow'; if ($null -ne $ss -and $ss -gt 0) { Cx-Add $G.CxDisk 15 ('медленных участков поверхности диска: {0:N0}' -f $ss) 'Диск подвисает на чтении - проверьте SMART.' }
    }
)

Cx-Def 'nodisk' 'Не видит диск / ошибки диска' 'Проверьте кабели SATA/питание, порт, режим AHCI/NVMe в BIOS; скопируйте данные до любых экспериментов.' @{
    info = $true; logs = $true; disk = $true; surface = $true; surfacemin = 10; selftest = $true; drivers = $false
} @(
    $cxRuleDisk,
    {
        foreach ($it in (Cx-Iss 'Устройства|BIOS' 'диск|накопител|NVMe|SATA|контроллер')) { Cx-Add $G.CxDrv 15 (Cx-Short $it.Text) $it.Fix }
        $dr = Cx-Num 'disk_ev_reset30'; if ($null -ne $dr -and $dr -gt 0) { Cx-Add $G.CxPsu 8 'сбросы контроллера диска бывают из-за плохого кабеля или питания' 'Замените кабель SATA и подключите диск к другому разъёму питания.' }
    }
)

Cx-Def 'nosound' 'Нет звука / хрипит' 'Проверьте выбранное устройство вывода, разъём и колонки, переустановите звуковой драйвер, отключите улучшения звука.' @{
    info = $true; logs = $true; sound = $true; mic = $true; drivers = $true
} @(
    {
        foreach ($it in (Cx-Iss 'Устройства' 'звук|аудио|audio|Realtek|динамик|микрофон' -AnySev)) { Cx-Add $G.CxAudio 35 (Cx-Short $it.Text) $it.Fix }
        $dp = Cx-Num 'dpc_avg_pct'; if ($null -ne $dp -and $dp -ge 2) { Cx-Add $G.CxAudio 30 ('задержки DPC {0:N1} % дают хрипы и щелчки звука' -f $dp) 'Найдите драйвер-виновник (LatencyMon), обновите драйверы.' }
        foreach ($it in (Cx-Iss 'Устройства' 'DPC|прерывани')) { Cx-Add $G.CxAudio 15 (Cx-Short $it.Text) $it.Fix }
    }
)

Cx-Def 'wifi' 'Плохой интернет / Wi-Fi' 'Проверьте роутер (перезагрузка, канал, расстояние), кабель, драйвер Wi-Fi адаптера и тариф провайдера.' @{
    info = $true; net = $true; logs = $true; drivers = $true
} @(
    {
        $loss = Cx-Num 'net_loss_pct'
        if ($null -ne $loss -and $loss -ge 1) { Cx-Add $G.CxNet ([math]::Min(45, 15 + 5 * $loss)) ('потери пакетов {0:N1} %' -f $loss) 'Проверьте роутер, кабель и сигнал Wi-Fi; позвоните провайдеру.' }
        $jit = Cx-Num 'net_jitter_ms'; if ($null -ne $jit -and $jit -ge 30) { Cx-Add $G.CxNet 20 ('джиттер {0:N0} мс' -f $jit) 'Пинг скачет: Wi-Fi помехи или перегруженный канал.' }
        $png = Cx-Num 'net_ping_ms'; if ($null -ne $png -and $png -ge 80) { Cx-Add $G.CxNet 15 ('высокий пинг {0:N0} мс' -f $png) 'Подключитесь кабелем для проверки.' }
        $dn = Cx-Num 'net_down_mbps'; if ($null -ne $dn -and $dn -gt 0 -and $dn -lt 20) { Cx-Add $G.CxNet 20 ('скорость загрузки только {0:N0} Мбит/с' -f $dn) 'Сравните по кабелю и с тарифом.' }
        foreach ($it in (Cx-Iss 'Сеть')) { Cx-Add $G.CxNet 15 (Cx-Short $it.Text) $it.Fix }
        foreach ($it in (Cx-Iss 'Устройства' 'Wi-?Fi|Wireless|сетев|Ethernet|Bluetooth' -AnySev)) { Cx-Add $G.CxDrv 15 (Cx-Short $it.Text) $it.Fix }
    },
    $cxRuleSoft
)

Cx-Def 'battery' 'Быстро садится батарея' 'Проверьте износ батареи, профиль электропитания и фоновые программы; при износе более 40 % - замена аккумулятора.' @{
    info = $true; programs = $true; logs = $true; cpu = $false
} @(
    {
        $bh = Cx-Num 'bat_health'
        if ($null -ne $bh -and $bh -gt 0) {
            if ($bh -lt 50) { Cx-Add $G.CxBat 60 ('остаточная ёмкость батареи всего {0:N0} %' -f $bh) 'Замените аккумулятор.' }
            elseif ($bh -lt 70) { Cx-Add $G.CxBat 40 ('остаточная ёмкость батареи {0:N0} %' -f $bh) 'Планируйте замену аккумулятора.' }
            elseif ($bh -lt 85) { Cx-Add $G.CxBat 15 ('остаточная ёмкость батареи {0:N0} %' -f $bh) 'Лёгкий износ.' }
        }
        $cy = Cx-Num 'bat_cycles'; if ($null -ne $cy -and $cy -ge 500) { Cx-Add $G.CxBat 15 ('циклов зарядки: {0:N0}' -f $cy) '' }
        foreach ($it in (Cx-Iss 'Аккумулятор')) { Cx-Add $G.CxBat 30 (Cx-Short $it.Text) $it.Fix }
    },
    $cxRuleSoft,
    {
        $ct = $G.CpuTmax; if ($null -ne $ct -and $ct -ge 90) { Cx-Add $G.CxDust 10 'высокие температуры повышают расход заряда' 'Почистите систему охлаждения.' }
    }
)

Cx-Def 'usb' 'Не работают USB / устройства отваливаются' 'Проверьте другие порты (на задней панели), кабели и концентраторы, отключите экономию питания USB, обновите драйверы чипсета.' @{
    info = $true; logs = $true; drivers = $true; psu = $true; psumin = 2
} @(
    {
        foreach ($it in (Cx-Iss 'Устройства' 'USB|контроллер|драйвер|ошибк' -AnySev)) { Cx-Add $G.CxDrv 25 (Cx-Short $it.Text) $it.Fix }
        foreach ($it in (Cx-Iss 'Питание' 'проседа')) { Cx-Add $G.CxPsu 25 (Cx-Short $it.Text) $it.Fix }
        $v5 = Cx-Iss 'Питание' '5 ?В|\+5'
        foreach ($it in $v5) { Cx-Add $G.CxPsu 15 (Cx-Short $it.Text) $it.Fix }
    }
)

# ---- применение пресета жалоб поверх обычного выбора
function Set-ComplaintPreset($Keys) {
    $want = @()
    foreach ($ck in @($Keys)) { $t = ([string]$ck).Trim().ToLower(); if ($t) { $want += $t } }
    $known = @($G.Complaints | ForEach-Object { $_.Key })
    $sel = @($want | Where-Object { $known -contains $_ } | Select-Object -Unique)
    $G.ComplaintKeys = $sel
    $G.ComplaintCauses = $null
    if (-not $sel.Count) { return }
    foreach ($cmp in @($G.Complaints | Where-Object { $sel -contains $_.Key })) {
        foreach ($tk in @($cmp.Tests.Keys)) {
            $tv = $cmp.Tests[$tk]
            if ($tv -is [bool]) {
                # «включить» только добавляет; явное false в каталоге не отключает тесты других жалоб
                if ($tv) { $G.Sel[$tk] = $true }
            } else {
                $cur = 0; if ($null -ne $G.Sel[$tk] -and $G.Sel[$tk] -isnot [bool]) { $cur = [int]$G.Sel[$tk] }
                $G.Sel[$tk] = [int][math]::Max($cur, [int]$tv)
            }
        }
    }
    # «sound/mic» интерактивны: в авто-режиме выключаются самим body.ps1 (после этого вызова)
    $G.Log.Add('Режим по жалобе: ' + ($sel -join ', '))
}
