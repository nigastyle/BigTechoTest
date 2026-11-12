# Intel oneMKL Linpack: решает большую систему линейных уравнений (AVX/FMA на всех ядрах) и проверяет ответ.
# Самая «горячая» нагрузка на процессор + проверка стабильности: ошибка в ответе = нестабильный CPU/память/питание.
# Окно Linpack видно пользователю: обёртка PowerShell запускает linpack_xeon64.exe прогон за прогоном и дублирует вывод в файл.
Step 'Процессор: Linpack (Intel MKL)' {
    $s = New-Section 'Процессор: Linpack (Intel MKL)'
    $min = [int]$G.Sel.linpackmin; if ($min -lt 1) { $min = 3 }
    $exe = Get-Tool 'Linpack'
    if (-not $exe) { Add-Row $s 'Linpack' 'не удалось скачать' 'warn'; return }
    $isAmd = "$($G.CpuName)" -match '(?i)AMD|Ryzen|EPYC|Threadripper|Athlon'
    # Размер задачи: матрица N×N занимает ~8·N² байт; берём ~50 % свободной памяти, не больше 16 ГБ
    $freeB = [double](CIM Win32_OperatingSystem | Select-Object -First 1).FreePhysicalMemory * 1024
    $useB = [math]::Min($freeB * 0.5, 16GB)
    $nMem = [int]([math]::Floor([math]::Sqrt($useB / 8) / 1000) * 1000)
    $nMem = [math]::Max(5000, [math]::Min(40000, $nMem))
    $runSec = [int][math]::Max(20, [math]::Min(60, $min * 60 / 4))   # длительность одного прогона
    $out = Join-Path $G.Temp 'linpack_out.txt'
    $wr = Join-Path $G.Temp 'linpack_run.ps1'
    Remove-Item $out -Force -ErrorAction SilentlyContinue
    # Обёртка: калибровка (N=5000) → подбор N под ~$runSec с → прогоны до истечения времени.
    # Формат lininput: 2 строки заголовка, затем число тестов, размеры, LDA, повторы, выравнивание (КБ).
    @'
param([string]$Exe, [string]$Out, [int]$NMem, [int]$RunSec, [long]$Until)
$host.UI.RawUI.WindowTitle = 'Linpack (Intel MKL) — PC-Diagnostika: не закрывайте окно'
$wd = Split-Path $Exe
$inp = Join-Path (Split-Path $Out) 'lininput_diag.txt'
function W($t) { Write-Host $t; try { Add-Content -LiteralPath $Out -Value $t -Encoding UTF8 } catch {} }
function Run1($n) {
    @('Intel(R) Optimized LINPACK Benchmark data file (PC-Diagnostika)', 'Intel(R) Optimized LINPACK Benchmark data', '1 # number of tests', "$n # problem sizes", ('{0} # leading dimensions' -f ($n + 8)), '1 # times to run a test', '4 # alignment values (in KBytes)') | Set-Content -LiteralPath $inp -Encoding ascii
    $rows = New-Object System.Collections.Generic.List[string]
    Push-Location $wd
    try { $null | & $Exe $inp 2>&1 | ForEach-Object { $l = "$_"; W $l; if ($l -match '^\s*\d+\s+\d+\s+\d+\s+[\d.]+\s+[\d.]+\s+\S+\s+\S+\s+(pass|fail)') { $rows.Add($l) } } }
    catch { W ('#ERROR ' + $_.Exception.Message) }
    Pop-Location
    return $rows
}
W '#PHASE cal'
$gf = $null
$r = @(Run1 5000)
if ($r.Count) { $p = $r[0].Trim() -split '\s+'; try { $gf = [double]::Parse($p[4], [Globalization.CultureInfo]::InvariantCulture) } catch {} }
$n = [math]::Min($NMem, 10000)
if ($gf) { $n = [math]::Min($NMem, [int]([math]::Floor([math]::Pow(1.5 * $RunSec * $gf * 1e9, 1.0 / 3) / 1000) * 1000)) }
$n = [math]::Max(5000, $n)
W ('#PHASE main N={0}' -f $n)
$last = 0
while ([datetime]::UtcNow.Ticks -lt $Until) {
    $left = ($Until - [datetime]::UtcNow.Ticks) / 1e7
    if ($last -gt 0 -and $left -lt $last * 0.7) { break }
    $t = [datetime]::UtcNow
    $r = @(Run1 $n)
    $last = ([datetime]::UtcNow - $t).TotalSeconds
    if (-not $r.Count) { W '#NOROWS'; break }
}
W '#DONE'
'@ | Set-Content -LiteralPath $wr -Encoding UTF8
    $t0 = Get-Date
    $until = [datetime]::UtcNow.AddMinutes($min).Ticks
    Info ("Linpack (Intel MKL): {0} мин, матрица до {1}×{1} (~{2:N1} ГБ). Окно Linpack не закрывайте — оно закроется само." -f $min, $nMem, (8.0 * $nMem * $nMem / 1GB))
    $wa = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Exe "{1}" -Out "{2}" -NMem {3} -RunSec {4} -Until {5}' -f $wr, $exe, $out, $nMem, $runSec, $until
    # linpack_xeon64.exe требует OpenMP-библиотеку libiomp5md.dll из той же поставки (windows\compiler\bin)
    $omp = Join-Path (Split-Path $exe) '..\..\..\..\compiler\bin'
    if (Test-Path (Join-Path $omp 'libiomp5md.dll')) { $env:PATH = (Resolve-Path $omp).Path + ';' + $env:PATH }
    else { $G.Log.Add('linpack: libiomp5md.dll не найден рядом с ' + $exe) }
    try { $pw = Start-Process 'powershell.exe' -ArgumentList $wa -WorkingDirectory (Split-Path $exe) -PassThru -WindowStyle Normal }
    catch { Add-Row $s 'Linpack' ('не запустился: ' + $_.Exception.Message) 'warn'; return }
    $hasGuard = [bool](Get-Command Guard-Register -ErrorAction SilentlyContinue)
    $hasTrip = [bool](Get-Command Guard-Tripped -ErrorAction SilentlyContinue)
    if ($hasGuard) { Guard-Register $pw }
    $seen = @{}
    $L = New-Object System.Collections.Generic.List[object]; $stop = $null
    $parse = {
        $txt = @(Get-Content -LiteralPath $out -Encoding UTF8 -ErrorAction SilentlyContinue)
        $ph = ''; $n = $null; $rows = New-Object System.Collections.Generic.List[object]
        foreach ($l in $txt) {
            if ($l -match '^#PHASE cal') { $ph = 'cal'; continue }
            if ($l -match '^#PHASE main N=(\d+)') { $ph = 'main'; $n = [int]$Matches[1]; continue }
            $m = [regex]::Match($l, '^\s*(\d+)\s+(\d+)\s+(\d+)\s+([\d.]+)\s+([\d.]+)\s+(\S+)\s+(\S+)\s+(pass|fail)')
            if ($m.Success) { $rows.Add([pscustomobject]@{ Ph = $ph; N = [int]$m.Groups[1].Value; Time = [double]::Parse($m.Groups[4].Value, $IC); GF = [double]::Parse($m.Groups[5].Value, $IC); Check = $m.Groups[8].Value }) }
        }
        [pscustomobject]@{ Lines = $txt; N = $n; Rows = $rows }
    }
    try {
        while (-not $pw.HasExited) {
            Start-Sleep -Seconds 3
            foreach ($c in @(Get-Process -Name 'linpack_xeon64' -ErrorAction SilentlyContinue)) {
                if (-not $seen.ContainsKey($c.Id)) { $seen[$c.Id] = $true; if ($hasGuard) { try { Guard-Register $c } catch {} } }
            }
            $k = Read-Key; $L.Add($k)
            $el = ((Get-Date) - $t0).TotalSeconds
            $pr = & $parse; $mr = @($pr.Rows | Where-Object { $_.Ph -eq 'main' })
            $lastGf = if ($mr.Count) { '{0:N1} GFlops' -f $mr[-1].GF } elseif ($pr.N) { 'идёт прогон' } else { 'калибровка' }
            Write-Host -NoNewline ("`r    {0,4:N0} с | N={1} | прогонов {2} | {3} | CPU {4} °C | {5} Вт   " -f $el, $(if ($pr.N) { $pr.N } else { '…' }), $mr.Count, $lastGf, $(if ($null -ne $k.CpuTemp) { '{0:N0}' -f $k.CpuTemp } else { '—' }), $(if ($k.CpuPower) { '{0:N0}' -f $k.CpuPower } else { '—' }))
            if ($G.LiveOk) { Live-Activity ('Linpack: N={0}, прогонов {1}, {2}' -f $(if ($pr.N) { $pr.N } else { '…' }), $mr.Count, $lastGf) }
            if (@($pr.Rows | Where-Object { $_.Check -eq 'fail' }).Count) { $stop = 'ошибка вычислений — тест остановлен'; break }
            if ($null -ne $k.CpuTemp -and $k.CpuTemp -ge 100) { $stop = 'температура процессора 100 °C — тест остановлен для защиты'; break }
            if ($hasTrip) { if (Guard-Tripped) { $stop = 'сработала защита (сторож безопасности)'; break } }
            if ($el -gt $min * 60 + 180) { $stop = 'превышено время — прогон прерван'; break }
        }
    } finally {
        foreach ($c in @(Get-Process -Name 'linpack_xeon64' -ErrorAction SilentlyContinue)) { try { $c.Kill() } catch {} }
        try { if (-not $pw.HasExited) { $pw.Kill() } } catch {}
    }
    Write-Host ''
    Start-Sleep -Seconds 1
    $pr = & $parse
    $all = @($pr.Lines) -join "`n"
    $rows = @($pr.Rows | Where-Object { $_.Ph -eq 'main' })
    $fails = @($pr.Rows | Where-Object { $_.Check -eq 'fail' }).Count + @([regex]::Matches($all, '(?i)Residual checks FAILED')).Count
    $dur = ((Get-Date) - $t0).TotalSeconds
    Add-Row $s 'Длительность' ('{0:N0} с из {1} мин' -f $dur, $min) $(if ($stop) { 'warn' } else { 'ok' })
    if ($stop) { Add-Row $s 'Остановлен досрочно' $stop 'warn' }
    if ($pr.N) { Add-Row $s 'Размер задачи' ('N = {0} ({1:N1} ГБ памяти)' -f $pr.N, (8.0 * $pr.N * $pr.N / 1GB)) }
    $tv = @($L | ForEach-Object { $_.CpuTemp } | Where-Object { $null -ne $_ })
    $pv = @($L | ForEach-Object { $_.CpuPower } | Where-Object { $null -ne $_ })
    $tmax = if ($tv.Count) { ($tv | Measure-Object -Maximum).Maximum } else { $null }
    $pmax = if ($pv.Count) { ($pv | Measure-Object -Maximum).Maximum } else { $null }
    if ($rows.Count) {
        $gm = $rows | Measure-Object -Property GF -Average -Maximum -Minimum
        Add-Row $s 'Прогонов выполнено' $rows.Count
        Add-Row $s 'Производительность (сред. / макс. / мин.)' ('{0:N1} / {1:N1} / {2:N1} GFlops' -f $gm.Average, $gm.Maximum, $gm.Minimum)
        $G.Bench['Linpack (Intel MKL), GFlops'] = '{0:N1} (N={1})' -f $gm.Maximum, $pr.N
        $G.Num.linpack_gflops = [math]::Round($gm.Maximum, 1)
        if ($rows.Count -ge 3 -and $gm.Maximum -gt 0) {
            $var = 100.0 * ($gm.Maximum - $gm.Minimum) / $gm.Maximum
            $hot = $null -ne $tmax -and $tmax -ge 95
            $st = if ($var -gt 5) { 'warn' } else { 'ok' }
            Add-Row $s 'Разброс между прогонами' ('{0:N1} %{1}' -f $var, $(if ($var -gt 5 -and $hot) { ' — вероятно, из-за перегрева (троттлинг)' } elseif ($var -gt 5) { ' — нестабильная производительность' } else { '' })) $st
            if ($var -gt 5 -and -not $hot) { Add-Issue 'warn' 'Процессор' ('Linpack: нестабильная производительность — разброс {0:N0} % между прогонами при нормальной температуре' -f $var) 'Частота «скачет» по ограничению питания (VRM платы, лимиты PL1/PL2, плохой БП) или мешают фоновые программы. Проверьте настройки питания в BIOS и нагрев VRM.' }
        }
    } elseif ($all -match '(?i)msvcp|vcruntime|\.dll|not supported|unsupported') {
        Add-Row $s 'Linpack' 'не запустился на этом процессоре/системе (нужна библиотека или процессор не поддерживается)' 'warn'
    } else {
        Add-Row $s 'Linpack' 'результат не получен (прогон не успел завершиться)' 'warn'
    }
    if ($isAmd) { Add-Row $s 'Примечание' 'процессор AMD: Intel MKL работает, но может выбирать не самый быстрый код — GFlops ниже, чем у аналогичного Intel; стабильность проверяется полноценно' }
    if ($null -ne $tmax) {
        Add-Row $s 'Максимальная температура процессора' ('{0:N0} °C' -f $tmax) $(if ($tmax -ge 95) { 'crit' } elseif ($tmax -ge 90) { 'warn' } else { 'ok' })
        if ($null -eq $G.CpuTmax -or $tmax -gt $G.CpuTmax) { $G.CpuTmax = $tmax }
    }
    if ($pmax) { Add-Row $s 'Мощность процессора (макс.)' ('{0:N0} Вт' -f $pmax); if (-not $G.CpuPmax -or $pmax -gt $G.CpuPmax) { $G.CpuPmax = $pmax } }
    if ($fails) {
        Add-Row $s 'Проверка вычислений' ('ОШИБКИ: {0}' -f $fails) 'crit'
        Add-Issue 'crit' 'Стабильность' 'Linpack: ошибка вычислений — процессор/память/питание нестабильны (разгон, андервольт, XMP, VRM)' 'Сбросьте BIOS к заводским настройкам (уберите разгон, андервольт, XMP/EXPO), проверьте охлаждение процессора и VRM, затем повторите тест. Если ошибки остаются на заводских — проверьте память по одной планке и блок питания.'
    } elseif ($rows.Count) {
        Add-Row $s 'Проверка вычислений' 'ошибок нет (residual check: pass)' 'ok'
    }
    $G.Log.Add('Linpack tail: ' + ((@($pr.Lines) | Select-Object -Last 20) -join ' / '))
    Remove-Item $wr -Force -ErrorAction SilentlyContinue
}
