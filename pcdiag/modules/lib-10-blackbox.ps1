# ---------------------------------------------------------------- «чёрный ящик»
# Во время стресс-тестов каждые несколько секунд пишем показания датчиков в файл со сбросом на диск
# (FileOptions.WriteThrough). Если компьютер внезапно выключится, файл останется без строки END,
# и следующий запуск программы покажет, что происходило перед отключением.
$G.BB = $null
$G.BBStress = @('_cpu', 'ycr', 'ram', 'gpu', 'psu', 'vram', 'linpack', 'tm5', 'surface')   # шаги, во время которых пишем
function Get-BBDir {
    foreach ($d in (Join-Path $G.Root 'reports\blackbox'), (Join-Path $env:LOCALAPPDATA 'PCDiag\blackbox')) {
        try { New-Item -ItemType Directory -Force $d -ErrorAction Stop | Out-Null; $t = Join-Path $d '.w'; [IO.File]::WriteAllText($t, '1'); Remove-Item $t -Force; return $d } catch {}
    }
    return $null
}
function Get-Rails($l) {
    # Напряжения линий питания. Доверяем только явно названным линиям и только в правдоподобном диапазоне:
    # у неизвестных плат LHM отдаёт «Voltage #N» без делителей — такие значения не используем.
    $r = [ordered]@{ V12 = $null; V5 = $null; V33 = $null; Vcore = $null; VcoreMb = $null }
    foreach ($x in $l) {
        if ($x.Type -ne 'Voltage' -or $null -eq $x.Value -or $x.HwType -notmatch 'SuperIO|Motherboard|EmbeddedController') { continue }
        $v = [double]$x.Value; $n = "$($x.Name)"
        if ($n -match '(^|\+)12 ?V' -and $n -notmatch '(?i)standby|sb|stby' -and $v -gt 9 -and $v -lt 15) { if ($null -eq $r.V12) { $r.V12 = $v } }
        elseif ($n -match '(^|\+)5 ?V' -and $n -notmatch '(?i)standby|sb|stby' -and $v -gt 4 -and $v -lt 6) { if ($null -eq $r.V5) { $r.V5 = $v } }
        elseif ($n -match '(^|\+)3\.3 ?V|^3VCC$|^VCC3V$|^AVCC$' -and $n -notmatch '(?i)standby|sb|stby|dual' -and $v -gt 2.8 -and $v -lt 3.8) { if ($null -eq $r.V33) { $r.V33 = $v } }
        elseif ($n -match '(?i)^(CPU )?V ?core$' -and $v -gt 0.3 -and $v -lt 2) { if ($null -eq $r.VcoreMb) { $r.VcoreMb = $v } }
    }
    # Vcore надёжнее брать с датчика самого процессора (Intel «CPU Core», AMD «Core (SVI2 TFN)»)
    foreach ($x in $l) {
        if ($x.HwType -eq 'Cpu' -and $x.Type -eq 'Voltage' -and $null -ne $x.Value -and "$($x.Name)" -match '^(CPU Core|Core \(SVI2 TFN\)|Core \(SVI3 TFN\))$' -and $x.Value -gt 0.3 -and $x.Value -lt 2) { $r.Vcore = [double]$x.Value; break }
    }
    if ($null -eq $r.Vcore) { $r.Vcore = $r.VcoreMb }
    return $r
}
function BB-Start($Test) {
    BB-Stop
    $d = Get-BBDir; if (-not $d) { return }
    $path = Join-Path $d ('bb_{0:yyyyMMdd_HHmmss}.csv' -f (Get-Date))
    try {
        $fs = New-Object IO.FileStream($path, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::Read, 4096, [IO.FileOptions]::WriteThrough)
        $w = New-Object IO.StreamWriter($fs, (New-Object Text.UTF8Encoding $false)); $w.AutoFlush = $true
        $w.WriteLine(('#test={0};start={1};ver={2}' -f $Test, (Get-Date).ToString('o'), $VER))
        $w.WriteLine('t;sec;cpuT;cpuP;cpuClk;gpuT;gpuHot;gpuP;gpuClk;gpuLoad;v12;v5;v33;vcore;fanMin')
        $G.BB = @{ Path = $path; W = $w; FS = $fs; Test = $Test; T0 = Get-Date; Last = [datetime]::MinValue }
    } catch { $G.BB = $null }
}
function BB-Sample($k) {
    $b = $G.BB; if (-not $b) { return }
    if (((Get-Date) - $b.Last).TotalSeconds -lt 2) { return }
    $b.Last = Get-Date
    $f = { param($v, $d = 0) if ($null -eq $v) { '' } else { ([double]$v).ToString("F$d", $IC) } }
    try {
        $b.W.WriteLine((@((Get-Date).ToString('HH:mm:ss'), (& $f ((Get-Date) - $b.T0).TotalSeconds), (& $f $k.CpuTemp), (& $f $k.CpuPower), (& $f $k.CpuClock), (& $f $k.GpuTemp), (& $f $k.GpuHot), (& $f $k.GpuPower), (& $f $k.GpuClock), (& $f $k.GpuLoad), (& $f $k.V12 2), (& $f $k.V5 2), (& $f $k.V33 2), (& $f $k.Vcore 3), (& $f $k.FanMin)) -join ';'))
        $b.FS.Flush($true)
    } catch {}
}
function BB-Stop {
    $b = $G.BB; if (-not $b) { return }
    $G.BB = $null
    try { $b.W.WriteLine('END'); $b.W.Close() } catch {}
    Remove-Item $b.Path -Force -ErrorAction SilentlyContinue   # тест завершился штатно — запись не нужна
}
function Read-BBFile($path) {
    # Разбор незакрытой записи: последние показания и максимумы
    $lines = @(Get-Content $path -Encoding UTF8 -ErrorAction SilentlyContinue)
    if ($lines.Count -lt 2 -or $lines[-1] -eq 'END') { return $null }
    $meta = @{}; foreach ($kv in ($lines[0].TrimStart('#') -split ';')) { $p = $kv -split '=', 2; if ($p.Count -eq 2) { $meta[$p[0]] = $p[1] } }
    $cols = $lines[1] -split ';'
    $rows = @($lines | Select-Object -Skip 2 | Where-Object { $_ -match ';' } | ForEach-Object {
            $v = $_ -split ';'; $o = @{}; for ($i = 0; $i -lt $cols.Count -and $i -lt $v.Count; $i++) { $o[$cols[$i]] = $v[$i] }; $o })
    $num = { param($rs, $c, [switch]$Min) $a = @($rs | ForEach-Object { $_[$c] } | Where-Object { $_ -ne '' -and $null -ne $_ } | ForEach-Object { [double]::Parse(($_ -replace ',', '.'), [Globalization.NumberStyles]::Float, $IC) }); if (-not $a.Count) { $null } elseif ($Min) { ($a | Measure-Object -Minimum).Minimum } else { ($a | Measure-Object -Maximum).Maximum } }
    $last = if ($rows.Count) { $rows[-1] } else { @{} }
    $start = $null; try { $start = [datetime]::Parse($meta['start'], $IC, [Globalization.DateTimeStyles]::RoundtripKind) } catch {}
    $lastSec = if ($last['sec']) { [double]::Parse(($last['sec'] -replace ',', '.'), [Globalization.NumberStyles]::Float, $IC) } else { 0 }
    return [pscustomobject]@{
        Path = $path; Test = $meta['test']; Start = $start; Ver = $meta['ver']; Samples = $rows.Count; LastSec = $lastSec
        End = $(if ($start) { $start.AddSeconds($lastSec) } else { (Get-Item $path).LastWriteTime })
        Last = $last; Rows = $rows
        CpuTmax = (& $num $rows 'cpuT'); GpuTmax = (& $num $rows 'gpuT'); GpuHotMax = (& $num $rows 'gpuHot')
        CpuPmax = (& $num $rows 'cpuP'); GpuPmax = (& $num $rows 'gpuP')
        V12min = (& $num $rows 'v12' -Min); V5min = (& $num $rows 'v5' -Min); V33min = (& $num $rows 'v33' -Min); FanMin = (& $num $rows 'fanMin' -Min)
    }
}
