# Скрытые майнеры и руткиты. Выполняется ДО стресс-тестов (компьютер в простое). Только отчёт: ничего не удаляется.
Step 'Скрытые майнеры и подозрительная автозагрузка' {
    $s = New-Section 'Скрытые майнеры и подозрительная автозагрузка'
    $find = New-Object System.Collections.Generic.List[object]
    function Add-Find($Kind, $Item, $Path, $Why, $Sev) {
        $find.Add([pscustomobject]@{ Sev = $Sev; 'Где' = $Kind; 'Что' = $Item; 'Путь / команда' = $Path; 'Почему подозрительно' = $Why })
    }
    function Is-SysPath($p) { return [bool]($p -match '(?i)^[a-z]:\\Windows\\(System32|SysWOW64|WinSxS)\\') }
    $selfPid = $PID

    # ---------- (а) нагрузка в простое
    Info 'замер нагрузки в простое (30 с) — не трогайте компьютер...'
    $m = Measure-IdleLoad 30
    $cpuTop = @($m.Procs | Where-Object { $_.Pid -ne $selfPid -and $_.Pid -ne 0 -and $_.Pid -ne 4 } | Sort-Object Cpu -Descending | Select-Object -First 5)
    $gpuTop = @($m.Procs | Where-Object { $_.Gpu -gt 1 } | Sort-Object Gpu -Descending | Select-Object -First 5)
    if ($null -ne $m.CpuTotal) { Add-Row $s 'Загрузка процессора в простое' ('{0:N0} %' -f $m.CpuTotal) $(if ($m.CpuTotal -gt 40) { 'warn' } else { 'ok' }) }
    if ($null -ne $m.NvUtil) {
        $pw = ''; if ($null -ne $m.NvPower) { $pw = ', мощность {0:N0} Вт' -f $m.NvPower }
        Add-Row $s 'Видеокарта NVIDIA в простое' ('загрузка {0:N0} %{1}' -f $m.NvUtil, $pw) $(if ($m.NvUtil -gt 20) { 'warn' } else { 'ok' })
    }
    $G.Num.idle_cpu = $(if ($null -ne $m.CpuTotal) { [math]::Round($m.CpuTotal) } else { $null })
    $G.Num.idle_gpu = $(if ($null -ne $m.NvUtil) { [math]::Round($m.NvUtil) } else { $null })

    $procInfo = @{}
    foreach ($pr in @(CIM Win32_Process)) { $procInfo[[int]$pr.ProcessId] = $pr }
    $busy = New-Object System.Collections.Generic.List[object]
    foreach ($x in @($m.Procs | Where-Object { ($_.Cpu -gt 25 -or $_.Gpu -gt 20) -and $_.Pid -ne $selfPid })) {
        $pi = $procInfo[[int]$x.Pid]
        $path = ''; $cmd = ''
        if ($pi) { $path = "$($pi.ExecutablePath)"; $cmd = "$($pi.CommandLine)" }
        $sigTxt = ''; $trusted = $false
        if ($path) { $si = Get-SigInfo $path; $sigTxt = $si.Status; $trusted = ($si.Status -eq 'Valid') }
        $sysp = ($path -and ($path -match '(?i)^[a-z]:\\Windows\\'))
        $isMiner = ("$($x.Name) $cmd" -match $G.MinerRe)
        $res = ''
        if ($isMiner) { $res = 'MINER' } elseif (-not $sysp -and -not $trusted) { $res = 'SUSP' } elseif ($x.Gpu -gt 20 -and -not $sysp -and (Test-UserWritablePath $path)) { $res = 'SUSP' }
        $busy.Add([pscustomobject]@{ 'Процесс' = $x.Name; 'PID' = $x.Pid; 'ЦП %' = [math]::Round($x.Cpu); 'GPU %' = [math]::Round($x.Gpu); 'Подпись' = $sigTxt; 'Путь' = $path; Res = $res })
        if ($res -eq 'MINER') { Add-Find 'Нагрузка в простое' $x.Name $path ('имя/параметры майнера, ЦП {0:N0} %, GPU {1:N0} %' -f $x.Cpu, $x.Gpu) 'crit' }
        elseif ($res -eq 'SUSP') { Add-Find 'Нагрузка в простое' $x.Name $path ('грузит в простое (ЦП {0:N0} %, GPU {1:N0} %), файл без действительной подписи ({2})' -f $x.Cpu, $x.Gpu, $(if ($sigTxt) { $sigTxt } else { 'путь неизвестен' })) 'warn' }
    }
    $topRows = @()
    $seen = @{}
    foreach ($x in ((AsArr $cpuTop) + (AsArr $gpuTop))) { if ($seen.ContainsKey($x.Pid)) { continue }; $seen[$x.Pid] = 1
        $topRows += [pscustomobject]@{ 'Процесс' = $x.Name; 'PID' = $x.Pid; 'ЦП % (в среднем)' = [math]::Round($x.Cpu, 1); 'GPU % (в среднем)' = [math]::Round($x.Gpu, 1) } }
    Add-Table $s 'Самые активные процессы в простое' $topRows -Collapsed
    if ($busy.Count -eq 0) { Add-Row $s 'Фоновая нагрузка' 'процессов, постоянно грузящих ЦП (>25 %) или видеокарту (>20 %), нет' 'ok' }
    else { Add-Row $s 'Фоновая нагрузка' ('процессов с высокой нагрузкой в простое: {0}' -f $busy.Count) 'warn' }

    # ---------- (б) процессы: маскировка и майнеры
    Info 'проверка запущенных процессов...'
    $sysNames = @{ 'svchost.exe' = 'System32'; 'csrss.exe' = 'System32'; 'lsass.exe' = 'System32'; 'dwm.exe' = 'System32'; 'winlogon.exe' = 'System32'; 'wininit.exe' = 'System32'
        'services.exe' = 'System32'; 'smss.exe' = 'System32'; 'spoolsv.exe' = 'System32'; 'taskhostw.exe' = 'System32'; 'conhost.exe' = 'System32'; 'fontdrvhost.exe' = 'System32'; 'sihost.exe' = 'System32'
        'runtimebroker.exe' = 'System32'; 'explorer.exe' = 'Windows' }
    $lookalike = '(?i)^(svch0st|scvhost|svhost|svchots|svchosts|csrs|crss|csrss[0-9a-z]|lsas|lssas|lsasss|lsass[0-9a-z]|winlog0n|expl0rer|explorer[0-9a-z]|dwm[0-9a-z]|services[0-9a-z]|smss[0-9a-z])\.exe$'
    foreach ($pr in $procInfo.Values) {
        $nm = "$($pr.Name)".ToLower(); $path = "$($pr.ExecutablePath)"; $cmd = "$($pr.CommandLine)"
        if ([int]$pr.ProcessId -eq $selfPid) { continue }
        if ($sysNames.ContainsKey($nm) -and $path) {
            $ok = $false
            if ($sysNames[$nm] -eq 'System32') { $ok = ($path -match '(?i)^[a-z]:\\Windows\\(System32|SysWOW64)\\') } else { $ok = ($path -match '(?i)^[a-z]:\\Windows\\[^\\]+$') }
            if (-not $ok) { Add-Find 'Процесс' $pr.Name $path 'имя системного процесса, но файл лежит не в папке Windows — маскировка под систему' 'crit' }
        } elseif ($nm -match $lookalike) {
            Add-Find 'Процесс' $pr.Name $path 'имя похоже на системный процесс (опечатка) — маскировка' 'crit'
        }
        $minerHit = ("$($pr.Name)" -match $G.MinerRe)
        if (-not $minerHit -and $cmd -and ($cmd -match $G.MinerRe) -and ("$($pr.Name)" -notmatch '(?i)^(powershell|pwsh|cmd|conhost|claude|node)\.exe$')) { $minerHit = $true }
        if ($minerHit -and ($cmd -notmatch 'PC-Diagnostika')) {
            $cc = ($cmd -replace '\s+', ' '); if ($cc.Length -gt 120) { $cc = $cc.Substring(0, 120) }
            Add-Find 'Процесс' $pr.Name $path ('имя или параметры майнера: ' + $cc) 'crit'
        }
    }

    # ---------- планировщик
    Info 'проверка планировщика заданий, служб и автозапуска...'
    $tasks = @(); try { $tasks = @(Get-ScheduledTask -ErrorAction Stop) } catch {}
    foreach ($t in $tasks) {
        if ("$($t.TaskPath)" -like '\Microsoft\*') { continue }
        foreach ($a in (AsArr $t.Actions)) {
            $ex = "$($a.Execute)"; if (-not $ex) { continue }
            $full = ("$ex $($a.Arguments)").Trim()
            $path = Get-ExeFromCmd $full
            $why = New-Object System.Collections.Generic.List[string]
            $sev = 'warn'
            if ($full -match $G.MinerRe) { $why.Add('параметры/имя майнера'); $sev = 'crit' }
            if (Test-UserWritablePath $path) { $why.Add('запускает файл из AppData/Temp/ProgramData') }
            if ($full -match '(?i)powershell.*(-enc|-encodedcommand|-e\s+[A-Za-z0-9+/=]{40,})|mshta|wscript.*(\\appdata|\\temp)|regsvr32.*/i:http|certutil.*-urlcache|bitsadmin.*/transfer') { $why.Add('закодированная/скачивающая команда') }
            if ((Test-RandomName $t.TaskName) -and $path -and -not (Is-SysPath $path)) { $why.Add('случайное имя задания') }
            if ($path -and -not (Is-SysPath $path) -and (Test-Path -LiteralPath $path -ErrorAction SilentlyContinue)) {
                $si = Get-SigInfo $path
                if ($si.Status -ne 'Valid' -and (Test-UserWritablePath $path)) { $why.Add('файл без действительной подписи') }
            }
            if ($why.Count -ge 1 -and ($sev -eq 'crit' -or $why.Count -ge 2 -or $why[0] -match 'закодирован')) { Add-Find 'Планировщик' ($t.TaskPath + $t.TaskName) $full ($why -join '; ') $sev }
            elseif ($why.Count -eq 1) { Add-Find 'Планировщик' ($t.TaskPath + $t.TaskName) $full ($why[0]) 'info' }
        }
    }

    # ---------- службы
    foreach ($sv in @(CIM Win32_Service)) {
        $pn = "$($sv.PathName)"; if (-not $pn) { continue }
        $path = Get-ExeFromCmd $pn
        if (-not $path -or (Is-SysPath $path)) { continue }
        $why = New-Object System.Collections.Generic.List[string]; $sev = 'warn'
        if ($pn -match $G.MinerRe) { $why.Add('параметры/имя майнера'); $sev = 'crit' }
        if (Test-UserWritablePath $path) { $why.Add('служба запускает файл из AppData/Temp/ProgramData') }
        if (Test-RandomName $sv.Name) { $why.Add('случайное имя службы') }
        if (Test-RandomName ([IO.Path]::GetFileName($path))) { $why.Add('случайное имя файла') }
        if ($path -and (Test-Path -LiteralPath $path -ErrorAction SilentlyContinue)) {
            $si = Get-SigInfo $path
            if ($si.Status -ne 'Valid' -and $why.Count) { $why.Add('нет действительной подписи') }
        } elseif ($why.Count) { $why.Add('файл не найден') }
        if ($why.Count -ge 2 -or $sev -eq 'crit') { Add-Find 'Служба' "$($sv.Name) ($($sv.DisplayName))" $pn ($why -join '; ') $sev }
    }

    # ---------- ключи Run
    $runKeys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
    foreach ($rk in $runKeys) {
        $props = $null; try { $props = Get-ItemProperty -Path $rk -ErrorAction Stop } catch { continue }
        foreach ($pp in $props.PSObject.Properties) {
            if ($pp.Name -match '^PS(Path|ParentPath|ChildName|Drive|Provider)$') { continue }
            $val = "$($pp.Value)"; if (-not $val) { continue }
            $path = Get-ExeFromCmd $val
            $why = New-Object System.Collections.Generic.List[string]; $sev = 'warn'
            if ($val -match $G.MinerRe) { $why.Add('параметры/имя майнера'); $sev = 'crit' }
            if (Test-UserWritablePath $path) { $why.Add('файл в AppData/Temp/ProgramData') }
            if ((Test-RandomName $pp.Name) -or (Test-RandomName ([IO.Path]::GetFileName($path)))) { $why.Add('случайное имя') }
            if ($val -match '(?i)powershell.*(-enc|-encodedcommand)|mshta|wscript|cscript.*\\(appdata|temp)') { $why.Add('скрипт/закодированная команда') }
            if ($path -and (Test-Path -LiteralPath $path -ErrorAction SilentlyContinue)) { $si = Get-SigInfo $path; if ($si.Status -ne 'Valid' -and $why.Count) { $why.Add('нет действительной подписи') } }
            if ($why.Count -ge 2 -or $sev -eq 'crit') { Add-Find ('Автозапуск ' + ($rk -replace '^HKLM:.*', 'HKLM' -replace '^HKCU:.*', 'HKCU')) $pp.Name $val ($why -join '; ') $sev }
        }
    }
    # папки автозагрузки: исполняемые файлы без подписи
    foreach ($sd in "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Startup", "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup") {
        foreach ($f in @(Get-ChildItem -LiteralPath $sd -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -match '(?i)^\.(exe|bat|cmd|vbs|js|ps1|scr|hta)$' })) {
            $si = Get-SigInfo $f.FullName
            if ($si.Status -ne 'Valid') { Add-Find 'Папка автозагрузки' $f.Name $f.FullName 'исполняемый файл без действительной подписи' 'warn' }
        }
    }

    # ---------- Defender: исключения
    $ex = Get-DefenderExclusions
    if ($ex.Ok) {
        $exTotal = $ex.Path.Count + $ex.Process.Count + $ex.Ext.Count
        if ($exTotal -eq 0) { Add-Row $s 'Исключения Defender' 'нет' 'ok' }
        else {
            $bad = @($ex.Path + $ex.Process | Where-Object { $_ -match '(?i)^[a-z]:\\?$|\\AppData\\|\\Temp\\|\\ProgramData\\|\\Users\\|\\Windows\\|\.exe$' -or $_ -match '(?i)^(%|\*)' })
            $lvl = 'warn'
            Add-Row $s 'Исключения Defender' ('папок/файлов: {0}, процессов: {1}, расширений: {2}' -f $ex.Path.Count, $ex.Process.Count, $ex.Ext.Count) $lvl
            foreach ($e in @($ex.Path | Select-Object -First 15)) { Add-Find 'Исключение Defender (путь)' $e '' 'антивирус не проверяет это место — любимый приём майнеров; убедитесь, что вы сами это добавляли' $(if ($e -match '(?i)^[a-z]:\\?$|\\AppData\\|\\Temp\\|\\ProgramData\\|\\Windows\\') { 'warn' } else { 'info' }) }
            foreach ($e in @($ex.Process | Select-Object -First 15)) { Add-Find 'Исключение Defender (процесс)' $e '' 'процесс исключён из проверки' 'warn' }
            foreach ($e in @($ex.Ext | Select-Object -First 10)) { Add-Find 'Исключение Defender (тип файлов)' $e '' 'тип файлов исключён из проверки' 'warn' }
        }
    } else { Add-Row $s 'Исключения Defender' 'не удалось прочитать (Defender отключён или заменён другим антивирусом)' '' }

    # ---------- hosts
    $hs = @(Get-HostsTampering)
    if ($hs.Count) { Add-Row $s 'Файл hosts' ('есть записи, блокирующие сайты антивирусов/обновлений: {0}' -f $hs.Count) 'crit'; foreach ($l in ($hs | Select-Object -First 10)) { Add-Find 'Файл hosts' $l (Join-Path $env:SystemRoot 'System32\drivers\etc\hosts') 'сайт антивируса/Microsoft перенаправлен или заблокирован — вредонос мешает обновлению защиты' 'crit' } }
    else { Add-Row $s 'Файл hosts' 'блокировок сайтов антивирусов нет' 'ok' }

    # ---------- WMI
    $wm = @(Get-WmiPersistence)
    if ($wm.Count) { Add-Row $s 'WMI-подписки (скрытый автозапуск)' ('найдено нестандартных: {0}' -f $wm.Count) 'crit'
        foreach ($w in ($wm | Select-Object -First 10)) { Add-Find 'WMI-подписка' ($w.Class + ': ' + $w.Name) $w.Detail 'постоянная подписка WMI — приём для скрытого запуска кода; у обычных домашних ПК её нет' 'crit' } }
    else { Add-Row $s 'WMI-подписки (скрытый автозапуск)' 'нестандартных нет' 'ok' }

    # ---------- итог
    $hi = @($find | Where-Object { $_.Sev -eq 'crit' })
    $warns = @($find | Where-Object { $_.Sev -eq 'warn' })
    $infos = @($find | Where-Object { $_.Sev -eq 'info' })
    if ($find.Count) {
        $rows = @($find | Sort-Object @{ Expression = { switch ($_.Sev) { 'crit' { 0 } 'warn' { 1 } default { 2 } } } } | Select-Object -First 60 | ForEach-Object {
                [pscustomobject]@{ 'Важность' = $(switch ($_.Sev) { 'crit' { 'ВЫСОКАЯ' } 'warn' { 'средняя' } default { 'низкая' } }); 'Где' = $_.'Где'; 'Что' = $_.'Что'; 'Почему подозрительно' = $_.'Почему подозрительно'; 'Путь / команда' = $_.'Путь / команда' } })
        Add-Table $s 'Подозрительные находки' $rows
    }
    Add-Row $s 'Итог проверки на майнеры/руткиты' $(if ($hi.Count) { "серьёзных признаков: $($hi.Count), подозрительных: $($warns.Count)" } elseif ($warns.Count) { "подозрительных признаков: $($warns.Count)" } else { 'явных признаков нет' }) $(if ($hi.Count) { 'crit' } elseif ($warns.Count) { 'warn' } else { 'ok' })
    $G.Num.miner_crit = $hi.Count; $G.Num.miner_warn = $warns.Count
    if ($hi.Count) {
        Add-Issue 'crit' 'Безопасность' ('признаки майнера/вредоносного ПО: ' + (($hi | Select-Object -First 4 | ForEach-Object { $_.'Что' }) -join ', ')) 'Не удаляйте вручную вслепую: сделайте полную проверку (Defender + Kaspersky Virus Removal Tool / Dr.Web CureIt), затем смените пароли с чистого устройства. При подтверждении — переустановка Windows.'
    }
    if ($warns.Count) {
        Add-Issue 'warn' 'Безопасность' ('подозрительная автозагрузка/нагрузка в простое: ' + (($warns | Select-Object -First 4 | ForEach-Object { $_.'Что' }) -join ', ')) 'Проверьте перечисленные файлы на virustotal.com; если не узнаёте программу — удалите её и проверьте компьютер антивирусом.'
    }
    $G.Log.Add(('miners: crit={0} warn={1} info={2}' -f $hi.Count, $warns.Count, $infos.Count))
}

# =====================================================================
Step 'Глубокая проверка: Kaspersky Virus Removal Tool' {
    $s = New-Section 'Глубокая проверка: Kaspersky Virus Removal Tool'
    $dir = Join-Path $G.Tools 'kvrt'
    $exe = Join-Path $dir 'KVRT.exe'
    try { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null } catch { Add-Row $s 'KVRT' 'не удалось создать папку' 'warn'; return }
    if (-not (Test-Path $exe)) {
        Info 'скачиваю Kaspersky Virus Removal Tool (100+ МБ)...'
        $dl = Join-Path $G.Temp 'KVRT.exe'
        try {
            try { Invoke-WebRequest -Uri $G.KvrtUrl -OutFile $dl -UseBasicParsing -UserAgent 'Mozilla/5.0' -TimeoutSec 1200 -ErrorAction Stop }
            catch {
                $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
                if (-not (Test-Path $curl)) { throw }
                Remove-Item $dl -Force -ErrorAction SilentlyContinue
                & $curl -fsSL --max-time 1200 -A 'Mozilla/5.0' -o $dl $G.KvrtUrl 2>$null
                if (-not (Test-Path $dl)) { throw }
            }
        } catch { Add-Row $s 'Загрузка KVRT' ('не удалась: ' + $_.Exception.Message) 'warn'; return }
        # у KVRT нет фиксированного хеша (файл обновляется ежедневно) — доверяем только действительной подписи «Kaspersky»
        $si = Get-SigInfo $dl
        if ($si.Status -ne 'Valid' -or $si.Signer -notmatch '(?i)kaspersky') {
            Add-Row $s 'Загрузка KVRT' ("файл отклонён: подпись '{0}' / {1}" -f $si.Signer, $si.Status) 'warn'
            Remove-Item $dl -Force -ErrorAction SilentlyContinue; return
        }
        Copy-Item $dl $exe -Force; Remove-Item $dl -Force -ErrorAction SilentlyContinue
    }
    $rep = Join-Path $dir ('report_' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
    New-Item -ItemType Directory -Path $rep -Force -ErrorAction SilentlyContinue | Out-Null
    # Ключи KVRT (по документации Kaspersky; перепроверить при смене версии): -accepteula, -silent (без окна), -adinsilent (без рекламы/запросов),
    # -processlevel 2 (проверять процессы, у которых уровень доверия ниже «доверенный»), -dontcryptsupportinfo (отчёт в открытом виде), -d <папка> (отчёты/карантин).
    # ВНИМАНИЕ: в тихом режиме KVRT применяет действия по умолчанию (лечение/карантин) — это его поведение, программа сама ничего не удаляет.
    $argLine = '-accepteula -silent -adinsilent -processlevel 2 -dontcryptsupportinfo -d "' + $rep + '"'
    Info 'KVRT: проверка (может занять 20–60 минут)...'
    $t0 = Get-Date
    $p = $null
    try { $p = Start-Process -FilePath $exe -ArgumentList $argLine -PassThru -WindowStyle Hidden -ErrorAction Stop } catch { Add-Row $s 'KVRT' ('не удалось запустить: ' + $_.Exception.Message) 'warn'; return }
    try { $p.PriorityClass = 'BelowNormal' } catch {}
    $limit = 90
    while (-not $p.HasExited) {
        Start-Sleep -Seconds 5
        $el = ((Get-Date) - $t0).TotalMinutes
        Write-Host -NoNewline ("`r    KVRT: идёт {0:N0} мин...   " -f $el)
        if ($el -gt $limit -or (User-Stopped)) { try { $p.Kill() } catch {}; break }
    }
    Write-Host ''
    $timeout = (((Get-Date) - $t0).TotalMinutes -gt $limit)
    $code = $null; try { $code = $p.ExitCode } catch {}
    $hits = @(Find-KvrtReportHits $rep | Where-Object { $_ -notmatch '(?i)(detected|обнаружено|infected|заражено|угроз\w*)\s*[:=]?\s*0\s*$' })
    Add-Row $s 'Время проверки' ('{0:N0} мин (код возврата {1})' -f ((Get-Date) - $t0).TotalMinutes, $code)
    Add-Row $s 'Папка отчёта KVRT' $rep
    if ($timeout) { Add-Row $s 'Результат' 'проверка не завершилась за 90 мин и была остановлена' 'warn' }
    elseif ($hits.Count) {
        Add-Row $s 'Результат' ('в отчёте есть строки об угрозах: {0} — см. таблицу и папку отчёта' -f $hits.Count) 'crit'
        Add-Table $s 'Строки отчёта KVRT' @($hits | Select-Object -First 40 | ForEach-Object { [pscustomobject]@{ 'Запись' = $_ } })
        Add-Issue 'crit' 'Безопасность' 'Kaspersky Virus Removal Tool сообщил об угрозах' ('Откройте отчёт: ' + $rep + '. Проверьте, что именно найдено и обезврежено; смените пароли; при сомнениях — переустановка Windows.')
    } else { Add-Row $s 'Результат' $(if ($code -eq 0 -or $null -eq $code) { 'угроз в отчёте не найдено' } else { 'угроз не найдено, но код возврата ненулевой — проверьте отчёт вручную' }) $(if ($code -eq 0 -or $null -eq $code) { 'ok' } else { 'warn' }) }
}
