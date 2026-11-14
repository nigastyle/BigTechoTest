# ---------------------------------------------------------------- проверка памяти Windows: результат после перезагрузки
# Проверка идёт ДО загрузки Windows, поэтому в отчёт текущего запуска попасть не может. Чтобы итог не терялся:
#   1) при планировании проверки программа запоминает путь к готовому отчёту и ставит разовую задачу «BTT-MemResult» (при входе в Windows);
#   2) после перезагрузки задача запускает программу в режиме DIAG_TOOL=memresult: она ждёт запись Windows о результате,
#      показывает окно с итогом и дописывает его в уже сохранённые отчёт и «Итог»; затем задача удаляет себя.
$MEMRES = @{ Key = 'HKCU:\Software\BigTechoTest'; Task = 'BTT-MemResult' }

function MemResult-Register($Report, $Summary) {
    try {
        if (-not (Test-Path $MEMRES.Key)) { New-Item -Path $MEMRES.Key -Force | Out-Null }
        Set-ItemProperty -Path $MEMRES.Key -Name MemDiagReport -Value "$Report"
        Set-ItemProperty -Path $MEMRES.Key -Name MemDiagSummary -Value "$Summary"
        Set-ItemProperty -Path $MEMRES.Key -Name MemDiagTries -Value 0
        $exe = "$env:DIAG_EXE"
        if ($exe -and (Test-Path -LiteralPath $exe)) { $act = New-ScheduledTaskAction -Execute $exe -Argument '--memresult' }
        elseif ($G.Self -and (Test-Path -LiteralPath $G.Self) -and $G.Self -notmatch [regex]::Escape($env:TEMP)) {
            $act = New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot 'System32\cmd.exe') -Argument ('/c set "DIAG_TOOL=memresult" && "{0}"' -f $G.Self)
        } else { $G.Log.Add('memresult: нет постоянного пути к программе — задача не создана'); return $false }
        $usr = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        $trg = New-ScheduledTaskTrigger -AtLogOn -User $usr
        $prn = New-ScheduledTaskPrincipal -UserId $usr -LogonType Interactive -RunLevel Highest
        $stg = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
        Register-ScheduledTask -TaskName $MEMRES.Task -Action $act -Trigger $trg -Principal $prn -Settings $stg -Force -ErrorAction Stop | Out-Null
        return $true
    } catch { $G.Log.Add("memresult: $($_.Exception.Message)"); return $false }
}

function MemResult-Unregister { try { Unregister-ScheduledTask -TaskName $MEMRES.Task -Confirm:$false -ErrorAction SilentlyContinue } catch {} }

# Дописать плашку с результатом в сохранённый HTML (сразу после <body>)
function MemResult-Patch($Path, $Color, $Head, $Text) {
    try {
        if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $false }
        $h = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
        if ($h -match 'id="btt-memresult"') { return $true }
        $enc = { param($t) [System.Net.WebUtility]::HtmlEncode([string]$t) }
        $ban = '<div id="btt-memresult" style="max-width:1100px;margin:14px auto;padding:14px 18px;border-radius:12px;border:2px solid {0};background:#fff;color:#1d2330;font:15px/1.5 Segoe UI,system-ui,sans-serif"><div style="font-weight:700;color:{0};font-size:17px">{1}</div><div>{2}</div></div>' -f $Color, (& $enc $Head), (& $enc $Text)
        $m = [regex]::Match($h, '<body[^>]*>')
        if (-not $m.Success) { return $false }
        $h = $h.Substring(0, $m.Index + $m.Length) + $ban + $h.Substring($m.Index + $m.Length)
        [IO.File]::WriteAllText($Path, $h, (New-Object Text.UTF8Encoding $true))
        return $true
    } catch { return $false }
}

function Invoke-MemResult {
    $sched = $null; $rep = ''; $sum = ''; $tries = 0
    try { $kp = Get-ItemProperty -Path $MEMRES.Key -ErrorAction Stop; $sched = $kp.MemDiagScheduled; $rep = "$($kp.MemDiagReport)"; $sum = "$($kp.MemDiagSummary)"; $tries = [int]$kp.MemDiagTries } catch {}
    if (-not $sched) { MemResult-Unregister; return }
    $when = $null
    try { $when = [datetime]::Parse("$sched", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) } catch {}
    if (-not $when) { MemResult-Unregister; return }
    $pending = { ((bcdedit /enum '{bootmgr}' 2>$null) -join "`n") -match '(?im)^bootsequence\s+.*\{memdiag\}' }
    $ev = $null
    # Windows пишет итог в журнал через 0,5–3 минуты после входа в систему
    for ($i = 0; $i -lt 30; $i++) {
        try { $ev = Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-MemoryDiagnostics-Results'; StartTime = $when.AddMinutes(-2) } -ErrorAction Stop | Where-Object { $_.Id -in 1101, 1102, 1103, 1104, 1201, 1202 } | Select-Object -First 1 } catch { $ev = $null }
        if ($ev) { break }
        if (& $pending) { break }   # проверка ещё не запускалась (вход без настоящей перезагрузки) — ждать нечего
        Start-Sleep -Seconds 10
    }
    if (-not $ev) {
        $tries++
        try { Set-ItemProperty -Path $MEMRES.Key -Name MemDiagTries -Value $tries } catch {}
        if ((& $pending) -and $tries -lt 6) { return }   # задача остаётся: сработает после настоящей перезагрузки
        MemResult-Unregister
        if (-not (& $pending)) {
            $t = "Проверка памяти Windows была запланирована $($when.ToString('dd.MM.yyyy HH:mm')), но результата в журнале Windows нет: проверка не запустилась или была прервана.`n`nЗапустите её вручную: Win+R -> mdsched.exe -> «Выполнить перезагрузку и проверку»."
            try { [DiagDialog]::Warning('Проверка памяти — результата нет', $t) } catch { try { [void][System.Windows.Forms.MessageBox]::Show($t, 'BigTechoTest') } catch {} }
        }
        return
    }
    $tm = $ev.TimeCreated.ToString('dd.MM.yyyy HH:mm')
    $kind = 'warn'; $col = '#c98200'
    if ($ev.Id -in 1101, 1201) { $kind = 'ok'; $col = '#1f9d55'; $head = 'Проверка памяти Windows: ошибок не обнаружено'; $txt = "Проверка оперативной памяти до загрузки Windows завершена $tm. Ошибок нет." }
    elseif ($ev.Id -in 1102, 1202) { $kind = 'crit'; $col = '#d64545'; $head = 'Проверка памяти Windows: НАЙДЕНЫ АППАРАТНЫЕ ОШИБКИ'; $txt = "Проверка оперативной памяти до загрузки Windows завершена $tm и нашла ошибки. Отключите разгон XMP/EXPO в BIOS и проверьте планки по одной (MemTest86 с флешки); сбойную планку замените." }
    elseif ($ev.Id -eq 1103) { $head = 'Проверка памяти Windows: отменена'; $txt = "Проверка была прервана ($tm): нажата Esc или компьютер выключили во время теста. Результата нет — запланируйте проверку ещё раз." }
    else { $head = 'Проверка памяти Windows: не завершилась'; $txt = "Проверка не смогла завершиться ($tm). Возможна нестабильность памяти — проверьте ОЗУ тестом MemTest86 с флешки." }
    $p1 = MemResult-Patch $rep $col $head $txt
    $p2 = MemResult-Patch $sum $col $head $txt
    try { Set-ItemProperty -Path $MEMRES.Key -Name MemDiagShown -Value ((Get-Date).ToString('o')) } catch {}
    MemResult-Unregister
    # отметку MemDiagScheduled не трогаем: следующий полный запуск программы включит результат и в новый отчёт (шаг «Результат проверки памяти Windows»)
    $open = $sum; if (-not $open -or -not (Test-Path -LiteralPath $open)) { $open = $rep }
    $can = [bool]($open -and (Test-Path -LiteralPath $open))
    $msg = $txt + $(if ($p1 -or $p2) { "`n`nРезультат дописан в отчёт диагностики (плашка в начале страницы)." } else { '' })
    $go = $false
    try {
        if ($can) { $go = [DiagDialog]::Ask($head, ($msg + "`n`nОткрыть отчёт?"), 'Открыть отчёт', 'Закрыть', $true) }
        elseif ($kind -eq 'crit') { [DiagDialog]::Error($head, $msg) } else { [DiagDialog]::Info($head, $msg) }
    } catch { try { [void][System.Windows.Forms.MessageBox]::Show($msg, $head) } catch {} }
    if ($go) { try { Start-Process $open } catch {} }
}
