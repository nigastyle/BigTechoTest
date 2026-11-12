# TestMem5 (TM5) с конфигом anta777: жёсткий тест стабильности оперативной памяти из-под Windows.
# Ловит то, что пропускают простые тесты: нестабильный XMP/EXPO, разгон, слабый контроллер памяти, плохой контакт в слоте.
# NB: формат Log.txt TM5 и точный разбор командной строки не проверены на живой системе — разбор сделан «с запасом».
Step 'Оперативная память: TestMem5 (anta777)' {
    $s = New-Section 'Оперативная память: TestMem5 (anta777)'
    $min = [int]$G.Sel.tm5min; if ($min -lt 1) { $min = 20 }
    $tm = Get-TM5
    if (-not $tm) { Add-Row $s 'TestMem5' 'не удалось скачать/распаковать (или файл удалён антивирусом)' 'warn'; return }
    $td = Split-Path $tm
    # Выбор конфига anta777: DDR5 + Intel → специальный (если есть), иначе Extreme, иначе Absolut, иначе любой anta777
    $cfgs = @(Get-ChildItem -LiteralPath $td -Filter '*.cfg' -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch '^BTT ' })
    $ddr5 = "$($G.Summary['Оперативная память'])" -match 'DDR5'
    $intel = "$($G.CpuName)" -match '(?i)Intel'
    $pref = @()
    if ($ddr5 -and $intel) { $pref += '(?i)DDR5.*Intel.*anta777|anta777.*DDR5.*Intel|Intel.*DDR5.*anta777' }
    $pref += '(?i)^Extreme.*@\s*anta777', '(?i)^Absolut.*@\s*anta777', '(?i)anta777'
    $cfg = $null
    foreach ($re in $pref) { $cfg = $cfgs | Where-Object { $_.Name -match $re } | Select-Object -First 1; if ($cfg) { break } }
    if (-not $cfg) { Add-Row $s 'TestMem5' ('конфиг anta777 не найден (есть: {0})' -f (($cfgs | ForEach-Object { $_.Name }) -join ', ')) 'warn'; return }
    $G.Log.Add('TM5 configs: ' + (($cfgs | ForEach-Object { $_.Name }) -join ' | '))
    # Командная строка из справки TM5: TM5.exe Config File="CoolCmd @ CoolCmd.cfg" Minutes=180
    # TM5, видимо, разбирает сырую строку сам; если не стартует — пробуем второй вариант кавычек.
    # TM5.ini, секция [Settings]: «Use AWE» = Never (2) — иначе TM5 показывает системное окно «Для включения поддержки AWE…»
    try { @('[Settings]', 'Use AWE=2', 'AWE=2', 'Enable Sound=0', 'Enable Notifications=0') | Set-Content (Join-Path $td 'TM5.ini') -Encoding ascii } catch {}
    # AWE требует привилегии «Блокировка страниц в памяти» (её нет даже у администратора без настройки и перезахода) —
    # иначе TM5 показывает окно «Для включения поддержки AWE…» и ждёт нажатия. Делаем копию конфига с Use AWE=0.
    try {
        $lines = [IO.File]::ReadAllLines($cfg.FullName, [Text.Encoding]::Default)
        $out2 = New-Object System.Collections.Generic.List[string]
        foreach ($ln in $lines) { if ($ln -notmatch '^\s*Use AWE\s*=') { $out2.Add($ln) }; if ($ln -match '^\s*\[Global Memory Setup\]') { $out2.Add('Use AWE=0') } }
        if (-not ($out2 -contains 'Use AWE=0')) { $out2.Add('[Global Memory Setup]'); $out2.Add('Use AWE=0') }
        $bttCfg = Join-Path $cfg.DirectoryName ('BTT ' + $cfg.Name)
        [IO.File]::WriteAllLines($bttCfg, $out2.ToArray(), [Text.Encoding]::Default)
        $cfg = Get-Item -LiteralPath $bttCfg
    } catch { $G.Log.Add('TM5 cfg copy: ' + $_.Exception.Message) }
    $argSets = @(('Config File="{0}" Minutes={1}' -f $cfg.Name, $min), ('"Config File={0}" Minutes={1}' -f $cfg.Name, $min))
    $hasGuard = [bool](Get-Command Guard-Register -ErrorAction SilentlyContinue)
    $hasTrip = [bool](Get-Command Guard-Tripped -ErrorAction SilentlyContinue)
    Info ("TestMem5, конфиг «{0}»: {1} мин. Окно TM5 не закрывайте — оно закроется само." -f $cfg.Name, $min)
    $p = $null; $t0 = $null; $used = $null
    foreach ($a in $argSets) {
        $t0 = Get-Date
        try { $p = Start-Process $tm -ArgumentList $a -WorkingDirectory $td -PassThru -WindowStyle Normal }
        catch { Add-Row $s 'TestMem5' ('не запустился (вероятно, заблокирован антивирусом): ' + $_.Exception.Message) 'warn'; Add-Issue 'info' 'Память' 'TestMem5 не запустился' 'Часто антивирус ошибочно блокирует TM5 (низкоуровневый доступ к памяти). Тест памяти можно провести MemTest86 с флешки.'; return }
        if ($hasGuard) { Guard-Register $p }
        $used = $a
        Start-Sleep -Seconds 8
        if (-not $p.HasExited) { break }
        $G.Log.Add("TM5 exited early with args [$a], code $($p.ExitCode)")
    }
    $logOf = {
        # Log.txt рядом с TM5.exe (или любой свежий .txt/.log в папке TM5)
        $c = @(Get-ChildItem -LiteralPath $td -Recurse -File -Include '*.txt', '*.log' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $t0.AddSeconds(-5) } | Sort-Object @{ Expression = { $_.Name -eq 'Log.txt' }; Descending = $true }, @{ Expression = 'LastWriteTime'; Descending = $true })
        if ($c.Count) { $c[0].FullName } else { $null }
    }
    $errRe = '(?i)\berror|ошибк|\bfail'
    $okRe = '(?i)\b0\s*errors?\b|errors?\s*[:=]\s*0\b|ошиб\w*\s*[:=]?\s*0\b|без ошибок|no errors|^\s*[\w ]+\s*='
    $doneRe = '(?i)testing (is )?(completed|finished)|all tests (completed|passed)|тестирование заверш'   # не «Cycle N completed»
    $L = New-Object System.Collections.Generic.List[object]; $stop = $null; $done = $false; $lines = @(); $lf = $null
    try {
        while (-not $p.HasExited) {
            Start-Sleep -Seconds 3
            $k = Read-Key; $L.Add($k)
            # TM5 показывает окно «Для включения поддержки AWE…» (нет привилегии блокировки страниц) — закрываем его: тест идёт без AWE
            # окно системное (его рисует csrss, а не TM5) — ищем по заголовку и закрываем как нажатие «ОК»
            if (-not ('BttWin' -as [type])) { Add-Type 'using System;using System.Runtime.InteropServices;public class BttWin{[DllImport("user32.dll",CharSet=CharSet.Unicode)]public static extern IntPtr FindWindow(string c,string t);[DllImport("user32.dll")]public static extern bool PostMessage(IntPtr h,uint m,IntPtr w,IntPtr l);}' }
            $hw = [BttWin]::FindWindow('#32770', 'TestMem5, AWE module')
            if ($hw -ne [IntPtr]::Zero) {
                [void][BttWin]::PostMessage($hw, 0x0111, [IntPtr]1, [IntPtr]::Zero)   # WM_COMMAND IDOK
                [void][BttWin]::PostMessage($hw, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)   # WM_CLOSE
                if (-not $G.Tm5AweClosed) { $G.Tm5AweClosed = $true; Info 'TestMem5: AWE недоступен (нет привилегии «Блокировка страниц в памяти») — окно закрыто, тест идёт без AWE' }
            }
            $el = ((Get-Date) - $t0).TotalSeconds
            if (-not $lf) { $lf = & $logOf }
            if ($lf) { $lines = @(Get-Content -LiteralPath $lf -Encoding UTF8 -ErrorAction SilentlyContinue) }
            $errs = @($lines | Where-Object { $_ -match $errRe -and $_ -notmatch $okRe })
            Write-Host -NoNewline ("`r    {0,4:N0} с из {1} | ошибок: {2} | CPU {3} °C   " -f $el, ($min * 60), $errs.Count, $(if ($null -ne $k.CpuTemp) { '{0:N0}' -f $k.CpuTemp } else { '—' }))
            if ($G.LiveOk) { Live-Activity ('TestMem5 ({0}): {1:N0} из {2} мин, ошибок {3}' -f $cfg.BaseName, ($el / 60), $min, $errs.Count) }
            if ($hasTrip) { if (Guard-Tripped) { $stop = 'сработала защита (сторож безопасности)'; break } }
            if ($null -ne $k.CpuTemp -and $k.CpuTemp -ge 100) { $stop = 'температура процессора 100 °C — тест остановлен'; break }
            if (@($lines | Where-Object { $_ -match $doneRe }).Count) { $done = $true; Start-Sleep -Seconds 2; break }
            if ($el -gt $min * 60 + 120) { break }
        }
    } finally { try { if ($p -and -not $p.HasExited) { $p.Kill() } } catch {} }
    Write-Host ''
    Start-Sleep -Seconds 1
    if (-not $lf) { $lf = & $logOf }
    if ($lf) { $lines = @(Get-Content -LiteralPath $lf -Encoding UTF8 -ErrorAction SilentlyContinue) }
    $errs = @($lines | Where-Object { $_ -match $errRe -and $_ -notmatch $okRe } | ForEach-Object { $_.Trim() })
    $dur = ((Get-Date) - $t0).TotalSeconds
    Add-Row $s 'Конфиг' $cfg.Name
    Add-Row $s 'Длительность' ('{0:N0} мин из {1}' -f ($dur / 60), $min) $(if ($stop) { 'warn' } else { 'ok' })
    if ($stop) { Add-Row $s 'Остановлен досрочно' $stop 'warn' }
    $early = -not $stop -and -not $done -and $dur -lt $min * 60 * 0.8
    $tv = @($L | ForEach-Object { $_.CpuTemp } | Where-Object { $null -ne $_ })
    if ($tv.Count) { Add-Row $s 'Макс. температура процессора' ('{0:N0} °C' -f ($tv | Measure-Object -Maximum).Maximum) }
    if ($errs.Count) {
        Add-Row $s 'Ошибки памяти' ('{0}: {1}' -f $errs.Count, (($errs | Select-Object -First 3) -join ' | ')) 'crit'
        Add-Issue 'crit' 'Память' 'TestMem5 нашёл ошибки памяти — нестабильная ОЗУ (XMP/разгон, планка, контроллер памяти)' 'Отключите XMP/EXPO (или снизьте частоту на шаг) и повторите тест. Если ошибки остались — проверяйте планки по одной и в разных слотах (сбойная планка или слот); проверьте, что модули одного комплекта. На разгоне — поднимите напряжение памяти/контроллера (VDDQ/VSOC/SA) или ослабьте тайминги.'
    } elseif ($early) {
        Add-Row $s 'Результат' ('TestMem5 закрылся раньше времени через {0:N0} с (закрыт вручную, заблокирован антивирусом или не принял параметры) — результат недостоверен' -f $dur) 'warn'
        Add-Issue 'info' 'Память' 'TestMem5 не отработал до конца' 'Повторите тест; если антивирус блокирует TM5 — добавьте папку программы в исключения на время проверки или проверьте память MemTest86 с флешки.'
    } elseif (-not $lf) {
        Add-Row $s 'Результат' 'журнал TestMem5 не найден — ошибки не распознаны (смотрите окно TM5 во время теста)' 'warn'
    } else {
        Add-Row $s 'Результат' $(if ($done) { 'тест завершён, ошибок нет' } else { 'ошибок нет за время теста' }) 'ok'
    }
    if (-not $done -and -not $early -and -not $errs.Count -and $lf) { Add-Row $s 'Примечание' 'отметка о завершении в журнале не найдена — тест остановлен по времени' }
    $G.Log.Add("TM5 args: $used; log: $lf")
    $G.Log.Add('TM5 log tail: ' + ((@($lines) | Select-Object -Last 40) -join ' / '))
}
