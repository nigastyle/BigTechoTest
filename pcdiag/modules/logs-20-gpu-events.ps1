# История сбоев видеодрайвера: TDR (4101), события nvlddmkm/AMD/Intel, LiveKernelEvent (зависания GPU без синего экрана)
$STEPKEYS['Видеокарта: сбои драйвера за 30 дней'] = 'logs'
Step 'Видеокарта: сбои драйвера за 30 дней' {
    $s = New-Section 'Видеокарта: сбои драйвера за 30 дней'
    $since = (Get-Date).AddDays(-30)
    $known = @{}; try { Get-WinEvent -ListProvider 'nvlddmkm', 'amdkmdag', 'amdwddmg', 'igfx', 'igfxn' -ErrorAction SilentlyContinue | ForEach-Object { $known[$_.Name] = 1 } } catch {}
    $ev = New-Object System.Collections.Generic.List[object]
    foreach ($prov in @('Display') + @($known.Keys)) {
        try { Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = $prov; StartTime = $since; Level = 1, 2, 3 } -ErrorAction Stop | ForEach-Object { $ev.Add($_) } } catch {}
    }
    $tdr = @($ev | Where-Object { $_.ProviderName -eq 'Display' -and $_.Id -eq 4101 })
    $drv = @($ev | Where-Object { $_.ProviderName -ne 'Display' })
    $xid = @{}
    foreach ($e in $drv) {
        $txt = "$($e.Message) " + (($e.Properties | ForEach-Object { "$($_.Value)" }) -join ' ')
        foreach ($m in [regex]::Matches($txt, 'Xid \(PCI:[0-9A-Fa-f:.]+\):\s*(\d+)')) { $xid[[int]$m.Groups[1].Value]++ }
    }
    $lke = @()
    try {
        $lke = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'Windows Error Reporting'; Id = 1001; StartTime = $since } -ErrorAction Stop |
                Where-Object { $_.Message -match 'LiveKernelEvent' } | ForEach-Object { if ($_.Message -match 'P1:\s*([0-9a-fA-F]+)') { [pscustomobject]@{ T = $_.TimeCreated; Code = $matches[1].ToLower() } } })
    } catch {}
    # 141/117 — реальные зависания видеоядра (TDR); 193/1a8/1a1 — диагностические снимки Windows, обычно не неисправность
    $lkeGpu = @($lke | Where-Object { $_.Code -in '141', '117' })
    $lkeDiag = @($lke | Where-Object { $_.Code -in '193', '1a8', '1a1', '1b8' })
    Add-Row $s 'Сбросы драйвера (TDR, «видеодрайвер перестал отвечать»)' $tdr.Count $(if ($tdr.Count -ge 3) { 'crit' } elseif ($tdr.Count) { 'warn' } else { 'ok' })
    Add-Row $s 'Зависания видеоядра (LiveKernelEvent 141/117)' $lkeGpu.Count $(if ($lkeGpu.Count -ge 3) { 'crit' } elseif ($lkeGpu.Count) { 'warn' } else { 'ok' })
    if ($lkeDiag.Count) { Add-Row $s 'Диагностические снимки видеоядра (LiveKernelEvent 193 и др.)' ('{0} — служебные записи Windows, сами по себе не неисправность' -f $lkeDiag.Count) }
    Add-Row $s 'Ошибки видеодрайвера в журнале' $drv.Count $(if ($drv.Count -ge 10) { 'warn' } else { '' })
    $hwX = @(48, 62, 63, 64, 74, 79, 92, 94, 95)
    if ($xid.Count) {
        $names = @{ 13 = 'исключение графического ядра'; 31 = 'ошибка страницы видеопамяти'; 32 = 'повреждён буфер команд (PCIe/драйвер)'; 43 = 'GPU перестал обрабатывать задачу'; 45 = 'очистка после сбоя'; 48 = 'двухбитная ошибка памяти'; 61 = 'сбой микроконтроллера GPU'; 62 = 'остановка микроконтроллера GPU (железо/перегрев)'; 63 = 'отключение страниц памяти'; 64 = 'сбой отключения страниц памяти'; 79 = 'GPU «отвалился» от шины (питание/PCIe/перегрев/неисправность)'; 92 = 'много ошибок памяти'; 94 = 'ошибка памяти'; 95 = 'неисправимая ошибка памяти'; 119 = 'таймаут GSP'; 120 = 'ошибка GSP' }
        Add-Table $s 'Коды ошибок NVIDIA (Xid)' @($xid.Keys | Sort-Object | ForEach-Object { [pscustomobject]@{ 'Xid' = $_; 'Сколько раз' = $xid[$_]; 'Что означает' = $(if ($names[$_]) { $names[$_] } else { '—' }) } })
    }
    $hwHits = @($xid.Keys | Where-Object { $_ -in $hwX })
    $n = [math]::Max($tdr.Count, $lkeGpu.Count)   # один сбой пишет и 4101, и LiveKernelEvent
    if ($hwHits.Count) {
        Add-Issue 'crit' 'Видеокарта' ('драйвер NVIDIA фиксировал аппаратные ошибки GPU (Xid {0})' -f ($hwHits -join ', ')) 'Признак неисправности видеокарты, её питания или слота PCIe: проверьте кабели питания GPU (до щелчка), блок питания, слот; при повторении — ремонт/замена видеокарты.'
    } elseif ($n -ge 3) {
        Add-Issue 'crit' 'Видеокарта' ('видеодрайвер падал {0} раз за 30 дней' -f $n) 'Переустановите драйвер начисто (DDU), уберите разгон GPU/памяти; если сбои под нагрузкой — проверьте питание (БП, кабели) и температуру. Повторяющиеся сбои при свежем драйвере — признак неисправной видеокарты.'
    } elseif ($n -gt 0) {
        Add-Issue 'warn' 'Видеокарта' ('видеодрайвер падал {0} раз за 30 дней' -f $n) 'Обновите видеодрайвер начисто; если повторяется в играх — проверьте температуру и питание видеокарты.'
    }
    $last = @(@($tdr | ForEach-Object { [pscustomobject]@{ T = $_.TimeCreated; W = 'сброс драйвера (TDR)' } }) + @($lkeGpu | ForEach-Object { [pscustomobject]@{ T = $_.T; W = "зависание GPU (LiveKernelEvent $($_.Code))" } }) | Sort-Object T -Descending | Select-Object -First 10)
    if ($last.Count) { Add-Table $s 'Последние сбои' @($last | ForEach-Object { [pscustomobject]@{ 'Время' = $_.T.ToString('dd.MM.yyyy HH:mm'); 'Что' = $_.W } }) -Collapsed }
    $G.Num.gpu_tdr30 = $n
}
