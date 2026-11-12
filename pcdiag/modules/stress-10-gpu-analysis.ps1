# Разбор показаний NVIDIA, записанных во время FurMark: троттлинг, PCIe под нагрузкой, лимит мощности, память GDDR6X
$STEPKEYS['Видеокарта: питание, троттлинг, шина PCIe'] = 'gpu'
Step 'Видеокарта: питание, троттлинг, шина PCIe' {
    $rows = @($G.SmiRows | Where-Object { $_ }); $mx = $G.GpuStressMax
    if (-not $rows.Count -and -not $mx) { Info 'нет данных (стресс-тест видеокарты не выполнялся)'; return }
    $s = New-Section 'Видеокарта: питание, троттлинг, шина PCIe'
    if ($mx -and $null -ne $mx.M) {
        Add-Row $s 'Температура видеопамяти (GDDR6X junction), макс.' ('{0:N0} °C' -f $mx.M) $(if ($mx.M -ge 105) { 'crit' } elseif ($mx.M -ge 100) { 'warn' } else { 'ok' })
        if ($mx.M -ge 100) { Add-Issue $(if ($mx.M -ge 105) { 'crit' } else { 'warn' }) 'Видеокарта' ('видеопамять перегревается: {0:N0} °C' -f $mx.M) 'Замените термопрокладки на памяти видеокарты, улучшите обдув. При 110 °C память сбрасывает частоты, долгий перегрев сокращает её жизнь.' }
    }
    if (-not $rows.Count) { return }
    $num = { param($v) if ($null -eq $v -or "$v" -eq '') { $null } else { try { [double]::Parse("$v", $IC) } catch { $null } } }
    $load = @($rows | Where-Object { (& $num $_.'utilization.gpu') -ge 80 })
    if (-not $load.Count) { $load = $rows }
    Add-Row $s 'Записано показаний драйвера NVIDIA' ('{0} (под нагрузкой: {1})' -f $rows.Count, $load.Count)
    # Причины снижения частот (битовая маска clocks_throttle_reasons.active)
    $bits = @{ 0x4 = 0; 0x8 = 0; 0x20 = 0; 0x40 = 0; 0x80 = 0 }
    foreach ($r in $load) {
        $m = "$($r.'clocks_throttle_reasons.active')"; if (-not $m) { continue }
        try { $v = [Convert]::ToUInt64(($m -replace '^0x', ''), 16) } catch { continue }
        foreach ($b in @($bits.Keys)) { if ($v -band $b) { $bits[$b]++ } }
    }
    $hasMask = @($load | Where-Object { "$($_.'clocks_throttle_reasons.active')" }).Count -gt 0
    $minHits = [math]::Max(3, [math]::Ceiling($load.Count * 0.02))
    foreach ($b in 0x8, 0x20, 0x40, 0x80) { if ($bits[$b] -lt $minHits) { $bits[$b] = 0 } }   # единичные отсчёты — шум
    $pct = { param($n) [math]::Round(100.0 * $n / [math]::Max(1, $load.Count)) }
    $thr = @()
    if ($bits[0x4]) { $thr += ('упор в лимит мощности {0} % времени (это нормально)' -f (& $pct $bits[0x4])) }
    if ($bits[0x20]) { $thr += ('программный термозащитный сброс {0} %' -f (& $pct $bits[0x20])) }
    if ($bits[0x40]) { $thr += ('АППАРАТНЫЙ перегрев {0} %' -f (& $pct $bits[0x40])) }
    if ($bits[0x8]) { $thr += ('АППАРАТНОЕ замедление {0} %' -f (& $pct $bits[0x8])) }
    if ($bits[0x80]) { $thr += ('СИГНАЛ ТОРМОЖЕНИЯ ПО ПИТАНИЮ {0} %' -f (& $pct $bits[0x80])) }
    Add-Row $s 'Почему снижались частоты' $(if (-not $hasMask) { 'нет данных (драйвер не отдаёт причины)' } elseif ($thr.Count) { $thr -join '; ' } else { 'не снижались' }) $(if ($bits[0x80] -or $bits[0x8] -or $bits[0x40]) { 'crit' } elseif ($bits[0x20]) { 'warn' } else { 'ok' })
    if ($bits[0x80]) { Add-Issue 'crit' 'Питание' 'видеокарта получала сигнал аварийного торможения по питанию (power brake)' 'Блок питания или кабели питания видеокарты не справляются: проверьте, что все разъёмы питания GPU вставлены до щелчка, не используйте разветвители/переходники, проверьте БП (мощность, возраст).' }
    elseif ($bits[0x8]) { Add-Issue 'crit' 'Видеокарта' 'видеокарта аппаратно сбрасывала частоты (HW slowdown)' 'Признак проблем с питанием или перегрева VRM видеокарты: проверьте кабели питания, БП, температуру, термопрокладки.' }
    elseif ($bits[0x40]) { Add-Issue 'crit' 'Видеокарта' 'видеокарта сбрасывала частоты из-за аппаратного перегрева' 'Почистите видеокарту, замените термопасту и термопрокладки, проверьте вентиляторы.' }
    # PCIe под нагрузкой
    $gen = @($load | ForEach-Object { & $num $_.'pcie.link.gen.current' } | Where-Object { $_ }); $wid = @($load | ForEach-Object { & $num $_.'pcie.link.width.current' } | Where-Object { $_ })
    $gmax = & $num $rows[0].'pcie.link.gen.max'; $wmax = & $num $rows[0].'pcie.link.width.max'
    if ($gen.Count -and $wid.Count) {
        $g1 = ($gen | Measure-Object -Maximum).Maximum; $w1 = ($wid | Measure-Object -Maximum).Maximum
        $bad = ($wmax -and $w1 -lt $wmax) -or ($gmax -and $g1 -lt $gmax)
        Add-Row $s 'Шина PCIe под нагрузкой' ('PCIe {0}.0 x{1} (максимум для карты: {2}.0 x{3})' -f $g1, $w1, $gmax, $wmax) $(if ($bad) { 'warn' } else { 'ok' })
        if ($wmax -and $w1 -lt $wmax) { Add-Issue 'warn' 'Видеокарта' ('видеокарта работает на x{0} вместо x{1}' -f $w1, $wmax) 'Проверьте: видеокарта в верхнем (основном) слоте, контакты чистые, райзер (если есть) исправен; в BIOS не включено деление линий. Потеря скорости 5–15 %, а иногда это признак плохого контакта.' }
        elseif ($gmax -and $g1 -lt $gmax) { Add-Issue 'info' 'Видеокарта' ('шина видеокарты работает как PCIe {0}.0 при поддержке {1}.0' -f $g1, $gmax) 'Обычно ограничение платы/процессора или райзера; проверьте настройку PCIe в BIOS (Auto).' }
    }
    # Лимит мощности: сильно ниже заводского — кабель питания вставлен не полностью / слабый переходник / ручное ограничение
    $pl = & $num $rows[0].'enforced.power.limit'; $pd = & $num $rows[0].'power.default_limit'
    $pw = @($load | ForEach-Object { & $num $_.'power.draw' } | Where-Object { $_ })
    if ($pw.Count) { Add-Row $s 'Потребление по данным драйвера (макс.)' ('{0:N0} Вт из лимита {1:N0} Вт' -f ($pw | Measure-Object -Maximum).Maximum, $pl) }
    if ($pl -and $pd -and $pl -lt $pd * 0.8) {
        Add-Row $s 'Лимит мощности' ('{0:N0} Вт при заводском {1:N0} Вт' -f $pl, $pd) 'warn'
        Add-Issue 'warn' 'Видеокарта' ('лимит мощности видеокарты снижен до {0:N0} Вт (заводской {1:N0} Вт)' -f $pl, $pd) 'Если лимит не снижали вручную (MSI Afterburner и т. п.) — видеокарта «видит» слабый кабель питания: проверьте, что разъём 12VHPWR/12V-2x6 вставлен до конца, без изгиба у разъёма, переходник исправен.'
    }
    $G.Num.gpu_pcie = $(if ($gen.Count) { '{0}x{1}' -f ($gen | Measure-Object -Maximum).Maximum, ($wid | Measure-Object -Maximum).Maximum } else { $null })
}
