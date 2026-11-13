# Тест видеопамяти (memtest_vulkan): битые чипы памяти видеокарты — артефакты, вылеты игр, «полосы»
Step 'Видеокарта: тест видеопамяти' {
    $s = New-Section 'Видеокарта: тест видеопамяти'
    $exe = Get-Tool 'MemtestVulkan'
    if (-not $exe) { Add-Row $s 'memtest_vulkan' 'не удалось скачать' 'warn'; return }
    $wd = Join-Path $G.Temp 'vram'; New-Item -ItemType Directory -Force $wd | Out-Null
    $out = Join-Path $wd 'out.txt'; $err = Join-Path $wd 'err.txt'
    Info 'тест видеопамяти memtest_vulkan (~6 мин). Экран может кратко «моргнуть» — это нормально.'
    # окно теста видно пользователю; результат читаем из memtest_vulkan.log (программа пишет его в рабочую папку)
    $out = Join-Path $wd 'memtest_vulkan.log'
    $p = Start-Process $exe -ArgumentList '1' -WorkingDirectory $wd -PassThru -WindowStyle Normal
    $t0 = Get-Date; $verdict = $null; $tmax = $null
    try {
    while (-not $p.HasExited -and ((Get-Date) - $t0).TotalSeconds -lt 480) {
        Start-Sleep -Seconds 5
        $k = Read-Key; if ($null -ne $k.GpuTemp -and ($null -eq $tmax -or $k.GpuTemp -gt $tmax)) { $tmax = $k.GpuTemp }
        if (Stop-Requested) { Write-Host ''; Warn (Stop-Text); break }
        $txt = ''; try { $fs = [IO.File]::Open($out, 'Open', 'Read', 'ReadWrite'); $txt = (New-Object IO.StreamReader($fs)).ReadToEnd(); $fs.Close() } catch {}
        if ($txt -match '(?m)^Standard 5-minute test (PASSed|fail)') { $verdict = $matches[1]; break }
        if ($txt -match '(?m)^Error found\.' -and ((Get-Date) - $t0).TotalSeconds -gt 60) { $verdict = 'fail'; break }
        Write-Host -NoNewline ("`r    {0,4:N0} с | GPU {1} °C   " -f ((Get-Date) - $t0).TotalSeconds, $(if ($null -ne $k.GpuTemp) { '{0:N0}' -f $k.GpuTemp } else { '—' }))
        if ($null -ne $k.GpuTemp -and $k.GpuTemp -ge 95) { Write-Host ''; Warn 'GPU 95 °C — тест остановлен'; break }
    }
    } finally { try { if (-not $p.HasExited) { $p.Kill() } } catch {} }
    Write-Host ''
    Start-Sleep -Milliseconds 500
    $txt = ''; try { $fs = [IO.File]::Open($out, 'Open', 'Read', 'ReadWrite'); $txt = (New-Object IO.StreamReader($fs)).ReadToEnd(); $fs.Close() } catch {}
    $dev = [regex]::Match($txt, '(?m)^Standard 5-minute test of \d+:\s*(.+)$')
    if ($dev.Success) { Add-Row $s 'Видеокарта' ($dev.Groups[1].Value.Trim() -replace '\s{2,}', ' ') }
    $it = @([regex]::Matches($txt, '(?m)^\s*(\d+) iteration\. Passed\s+([\d.]+) seconds\s+written:\s*([\d.]+)GB\s*([\d.]+)GB/sec\s+checked:\s*([\d.]+)GB'))
    if ($it.Count) { $l = $it[-1]; Add-Row $s 'Проверено' ('{0} проходов, записано {1} ГБ, скорость {2} ГБ/с' -f $l.Groups[1].Value, $l.Groups[3].Value, $l.Groups[4].Value) }
    $errs = @([regex]::Matches($txt, '(?m)^Error found\. Mode \w+, total errors 0x([0-9A-F]+)'))
    $rt = [regex]::Match($txt, '(?m)^Runtime error: (.*)$')
    if ($verdict -eq 'fail' -or $errs.Count) {
        $n = if ($errs.Count) { [Convert]::ToUInt64($errs[-1].Groups[1].Value, 16) } else { 0 }
        Add-Row $s 'Результат' ('ОШИБКИ ВИДЕОПАМЯТИ: {0}' -f $n) 'crit'
        Add-Issue 'crit' 'Видеокарта' ('тест видеопамяти нашёл ошибки ({0})' -f $n) 'Неисправна видеопамять (или перегрев/разгон памяти): уберите разгон памяти GPU, замените термопрокладки и повторите. Если ошибки остаются — ремонт (замена чипа памяти) или замена видеокарты.'
    } elseif ($verdict -eq 'PASSed') {
        Add-Row $s 'Результат' 'ошибок нет' 'ok'
    } elseif ($rt.Success) {
        Add-Row $s 'Результат' ('тест прервался: ' + $rt.Groups[1].Value.Trim()) 'crit'
        Add-Issue 'warn' 'Видеокарта' ('тест видеопамяти прервался ошибкой драйвера: ' + $rt.Groups[1].Value.Trim()) 'Видеокарта или драйвер нестабильны под нагрузкой на память: переустановите драйвер, снимите разгон, проверьте питание.'
    } elseif ($txt -match 'early exit during init|no Vulkan|vkCreateInstance') {
        Add-Row $s 'Результат' 'не поддерживается (нет Vulkan у драйвера)' 'warn'
    } else {
        Add-Row $s 'Результат' $(if ($it.Count) { 'ошибок не найдено (тест остановлен до итогового вердикта)' } else { 'результат не распознан' }) $(if ($it.Count) { 'ok' } else { 'warn' })
        $G.Log.Add('memtest_vulkan: ' + ($txt.Substring([math]::Max(0, $txt.Length - 1500))))
    }
    if ($null -ne $tmax) { Add-Row $s 'Температура GPU (макс.)' ('{0:N0} °C' -f $tmax) }
}
