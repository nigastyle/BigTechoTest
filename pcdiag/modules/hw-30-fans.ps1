# Вентиляторы: обороты (RPM) и управление (%) по данным LibreHardwareMonitor.
# 0 RPM на пустых разъёмах платы — норма, поэтому показываем только вращающиеся и «процессорные» вентиляторы.
Step 'Вентиляторы' {
    $s = New-Section 'Вентиляторы'
    $G.FanIdle = @{}
    $l = @(Get-AllSensors)
    if (-not $l.Count) { Add-Row $s 'Датчики' 'недоступны (LibreHardwareMonitor не загрузился)'; return }
    $fans = @($l | Where-Object { $_.Type -eq 'Fan' -and $null -ne $_.Value -and -not [double]::IsNaN([double]$_.Value) -and [double]$_.Value -ge 0 -and [double]$_.Value -lt 20000 })
    $ctrl = @($l | Where-Object { $_.Type -eq 'Control' -and $null -ne $_.Value -and -not [double]::IsNaN([double]$_.Value) })
    if (-not $fans.Count) {
        Add-Row $s 'Датчики оборотов' $(if ($G.IsLaptop) { 'нет (на ноутбуках обороты обычно недоступны — это нормально)' } else { 'нет данных (нужен драйвер датчиков PawnIO или плата не поддерживается)' })
        return
    }
    foreach ($f in $fans) { $G.FanIdle["$($f.Hw)|$($f.Name)"] = [double]$f.Value }
    $isCpuName = { param($n) "$n" -match '(?i)\bCPU\b|^CPU|Processor' }
    $rows = @()
    foreach ($f in $fans) {
        $v = [double]$f.Value
        $named = ($f.HwType -eq 'Motherboard') -and (& $isCpuName $f.Name)
        if ($v -le 0 -and -not $named) { continue }   # пустой разъём
        # Управление: 'Fan Control #1' ↔ 'Fan #1', 'CPU Fan' ↔ 'CPU Fan', 'GPU Fan' ↔ 'GPU Fan'
        $base = ("$($f.Name)" -replace '(?i)\s*Control', '').Trim()
        $c = $ctrl | Where-Object { $_.Hw -eq $f.Hw -and (("$($_.Name)" -replace '(?i)\s*Control', '').Trim() -eq $base) } | Select-Object -First 1
        $src = switch -regex ($f.HwType) { '^Gpu' { 'видеокарта' } 'Motherboard' { 'мат. плата' } 'Cpu' { 'процессор' } 'Controller' { 'контроллер' } default { "$($f.HwType)" } }
        $rows += [pscustomobject]@{
            'Вентилятор' = $f.Name
            'Где'        = $src
            'Обороты'    = $(if ($v -gt 0) { '{0:N0} об/мин' -f $v } else { 'стоит (0)' })
            'Управление' = $(if ($c) { '{0:N0} %' -f [double]$c.Value } else { '—' })
        }
    }
    if ($rows.Count) { Add-Table $s 'Вентиляторы' $rows } else { Add-Row $s 'Вентиляторы' 'все датчики оборотов показывают 0' }
    $spin = @($fans | Where-Object { [double]$_.Value -gt 0 })
    Add-Row $s 'Вращаются' ('{0} из {1} датчиков' -f $spin.Count, $fans.Count)

    # Вентилятор процессора
    $mb = @($fans | Where-Object { $_.HwType -eq 'Motherboard' })
    $cpuNamed = @($mb | Where-Object { & $isCpuName $_.Name })
    $cpuMain = @($cpuNamed | Where-Object { "$($_.Name)" -notmatch '(?i)opt|optional|pump|aio|#2' })
    if (-not $cpuMain.Count) { $cpuMain = $cpuNamed }
    if ($cpuMain.Count) {
        $cpuRpm = ($cpuMain | ForEach-Object { [double]$_.Value } | Measure-Object -Maximum).Maximum
        $anyCpu = ($cpuNamed | ForEach-Object { [double]$_.Value } | Measure-Object -Maximum).Maximum
        $G.Num.fan_cpu_rpm = [int]$anyCpu
        if ($anyCpu -le 0) {
            if ($G.IsLaptop) { Add-Row $s 'Вентилятор процессора' 'сейчас не вращается (у ноутбуков в простое это бывает нормой)' }
            else {
                Add-Row $s 'Вентилятор процессора' '0 об/мин' 'warn'
                Add-Issue 'warn' 'Охлаждение' 'вентилятор процессора не вращается или не подключён к CPU_FAN' 'Проверьте, что кулер процессора крутится и подключён к разъёму CPU_FAN (у СЖО — помпа/вентиляторы к CPU_FAN или AIO_PUMP). Если стоит режим остановки вентилятора в простое — это не неисправность. Без работающего кулера процессор перегреется.'
            }
        } elseif ($cpuRpm -le 0) {
            Add-Row $s 'Вентилятор процессора' ('на CPU_FAN 0 об/мин, на дополнительном разъёме {0:N0} об/мин' -f $anyCpu)
            Add-Issue 'info' 'Охлаждение' 'кулер процессора подключён не к основному разъёму CPU_FAN' 'Если плата выдаёт ошибку «CPU Fan Error» при включении — переключите кулер в CPU_FAN.'
        } else {
            Add-Row $s 'Вентилятор процессора' ('{0:N0} об/мин' -f $cpuRpm) 'ok'
        }
    } elseif ($mb.Count -and -not $G.IsLaptop) {
        # Названия общие ('Fan #N'): какой из них CPU_FAN — зависит от платы, поэтому не ругаемся, а только подсказываем
        if (-not @($mb | Where-Object { [double]$_.Value -gt 0 }).Count) {
            Add-Row $s 'Вентиляторы на мат. плате' 'все показывают 0 об/мин'
            Add-Issue 'info' 'Охлаждение' 'плата не видит оборотов ни одного вентилятора' 'Вентиляторы могут быть подключены к хабу/контроллеру подсветки или к блоку питания (тогда это нормально). Убедитесь, что кулер процессора вращается.'
        }
    }
    foreach ($f in $spin) {
        if ([double]$f.Value -lt 300) { Add-Issue 'info' 'Охлаждение' ('{0}: очень низкие обороты — {1:N0} об/мин' -f $f.Name, [double]$f.Value) 'Возможен износ подшипника или вентилятор подтормаживает (пыль). Проверьте, что он вращается свободно.' }
    }
    $G.Log.Add('fans idle: ' + (($G.FanIdle.Keys | ForEach-Object { '{0}={1:N0}' -f $_, $G.FanIdle[$_] }) -join '; '))
}
