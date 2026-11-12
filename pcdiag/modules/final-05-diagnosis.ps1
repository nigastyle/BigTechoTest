# Диагноз по жалобе: собирает улики из всех тестов и ранжирует вероятные причины (правила - в lib-70-complaint.ps1).
Step 'Диагноз по жалобе' {
    if (-not $G.ComplaintKeys -or @($G.ComplaintKeys).Count -eq 0) { return }
    $G.ComplaintCauses = $null
    $picked = @($G.Complaints | Where-Object { @($G.ComplaintKeys) -contains $_.Key })
    if (-not $picked.Count) { return }
    $sec = New-Section 'Диагноз по жалобе'
    Add-Row $sec 'Жалоба клиента' (($picked | ForEach-Object { $_.Title }) -join '; ')
    foreach ($cmp in $picked) {
        foreach ($rule in @($cmp.Rules)) {
            if (-not $rule) { continue }
            try { & $rule } catch { $G.Log.Add(('Диагноз по жалобе, правило {0}: {1}' -f $cmp.Key, $_.Exception.Message)) }
        }
    }
    $list = @()
    if ($G.ComplaintCauses) { $list = @($G.ComplaintCauses.Values | Where-Object { $_.W -gt 0 } | Sort-Object W -Descending) }
    $total = 0.0; foreach ($cz in $list) { $total += $cz.W }
    $top = $null; if ($list.Count) { $top = $list[0] }
    if ($list.Count -eq 0 -or $total -lt 20 -or $top.W -lt 15) {
        Add-Row $sec 'Итог' 'явной причины не найдено' 'ok'
        $hints = @($picked | ForEach-Object { $_.Hint } | Where-Object { $_ })
        $rows = @()
        foreach ($cz in ($list | Select-Object -First 3)) {
            $rows += [pscustomobject]@{ 'Что проверить в первую очередь' = $cz.Cause; 'Слабые признаки' = (($cz.Why | Select-Object -First 3) -join '; ') }
        }
        if ($rows.Count) { Add-Table $sec 'Слабые признаки (недостаточно для вывода)' $rows }
        $fixTxt = ($hints -join ' ')
        Add-Row $sec 'Что делать' $fixTxt
        Add-Issue 'info' 'Стабильность' ('по жалобе «{0}» явной причины тестами не найдено' -f (($picked | ForEach-Object { $_.Title }) -join ' / ')) $(if ($fixTxt) { $fixTxt } else { 'Повторите диагностику, когда проблема проявляется; проверьте внешние факторы (розетка, кабели, периферия).' })
        $G.Num.complaint_found = 0
        return
    }
    $rows = @(); $i = 0
    foreach ($cz in ($list | Select-Object -First 6)) {
        $pct = [math]::Round(100.0 * $cz.W / $total)
        if ($i -gt 0 -and $pct -lt 5) { continue }
        $i++
        $rows += [pscustomobject]@{
            'Вероятная причина'              = $cz.Cause
            'Вероятность'                    = ('{0:N0} %' -f $pct)
            'Почему так думаем (факты из тестов)' = (($cz.Why | Select-Object -First 4) -join '; ')
            'Что сделать'                    = (($cz.Fix | Select-Object -First 3) -join ' ')
        }
    }
    Add-Table $sec 'Вероятные причины жалобы (по убыванию)' $rows
    $topPct = [math]::Round(100.0 * $top.W / $total)
    $sevName = 'warn'; if ($topPct -ge 50 -and $top.W -ge 40) { $sevName = 'crit' }
    Add-Row $sec 'Итог' ('{0} ({1:N0} %)' -f $top.Cause, $topPct) $sevName
    $why = (($top.Why | Select-Object -First 2) -join '; ')
    $fix = (($top.Fix | Select-Object -First 3) -join ' ')
    if (-not $fix) { $fix = 'Устраните причину и повторите диагностику.' }
    Add-Issue $sevName 'Стабильность' ('Вероятная причина жалобы «{0}»: {1} ({2:N0} %). {3}' -f (($picked | ForEach-Object { $_.Title }) -join ' / '), $top.Cause, $topPct, $why) $fix
    $G.Num.complaint_found = 1
    $G.Num.complaint_top_pct = [int]$topPct
}
