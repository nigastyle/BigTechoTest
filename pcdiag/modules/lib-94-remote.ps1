# Удалённая диагностика вживую (#19).
# Включается переменной окружения DIAG_REMOTE=1 или выбором $G.Sel.remote (галочку в ui.cs добавляет сопровождающий).
# Remote-Start создаёт номер сессии (16 hex) и показывает ссылку https://<сервер>:8443/panel/live/<sid>.
# Фоновый runspace каждые 3 с отправляет на POST /live/<sid> небольшой JSON: текущий этап, состояния этапов,
# последние 20 строк журнала, последний замер датчиков, число проблем по уровням, состояние ТемпературногоНюхача.
# Сервер недоступен -> пакет молча выбрасывается (2 попытки, затем пауза), основная программа никогда не ждёт сеть.
# $G в runspace не виден, поэтому основной поток пишет в синхронизированную таблицу $G.RemoteState через тонкие обёртки:
#   Remote-Step / Remote-StepEnd / Remote-Log / Remote-Issue / Remote-Sensors / Remote-Finish (все дешёвые и не бросают исключений).

function Remote-Enabled { return [bool](($env:DIAG_REMOTE -eq '1') -or ($G.Sel -and $G.Sel.remote)) }

function Remote-Start {
    if ($G.RemoteOn -or $G.RemoteTried) { return }
    if (-not (Remote-Enabled)) { return }
    $G.RemoteTried = $true
    try {
        $rnd = New-Object byte[] 8
        [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($rnd)
        $sid = -join ($rnd | ForEach-Object { $_.ToString('x2') })
        $base = $UPLOAD.Url -replace '/upload$', ''
        $rst = [hashtable]::Synchronized(@{})
        $rst.Lock = New-Object object
        $rst.Sid = $sid
        $rst.Url = "$base/live/$sid"
        $rst.Token = $UPLOAD.Token
        $rst.Stop = $false
        $rst.Done = $false
        $rst.Summary = ''
        $rst.Score = $null
        $rst.V = [string]$VER
        $rst.Mode = [string]$G.Mode
        $rst.Machine = ''
        if ($G.Summary -and $G.Summary['Компьютер']) { $rst.Machine = [string]$G.Summary['Компьютер'] }
        $rst.Step = ''
        $rst.Started = (Get-Date).ToString('s')
        $rst.Steps = New-Object System.Collections.Generic.List[object]   # элементы: string[] @(имя, состояние)
        $rst.StepIdx = @{}
        $rst.Log = New-Object 'System.Collections.Generic.Queue[string]'
        $rst.Issues = New-Object 'System.Collections.Generic.Queue[object]'
        $rst.Iss = @{ crit = 0; warn = 0; info = 0 }
        $rst.Sample = $null
        $rst.SampleN = 0
        $rst.GuardType = $null
        $rst.Sent = 0
        $rst.Failed = 0
        # список этапов — та же логика, что и в онлайн-окне (Live-Start)
        if ($G.AllSteps) {
            foreach ($stepName in $G.AllSteps) {
                $on = $true
                if ($G.Sel -and $STEPKEYS.ContainsKey($stepName)) {
                    $key = $STEPKEYS[$stepName]
                    if ($key -eq '_inter') { $on = [bool]$G.Interactive }
                    elseif ($key -eq '_cpu') { $on = [bool]($G.Sel.cpu -or $G.Sel.prime) }
                    else { $on = [bool]$G.Sel[$key] }
                }
                if (-not $rst.StepIdx.ContainsKey([string]$stepName)) {
                    $rst.StepIdx[[string]$stepName] = $rst.Steps.Count
                    $rst.Steps.Add([string[]]@([string]$stepName, $(if ($on) { 'wait' } else { 'off' })))
                }
            }
        }
        foreach ($it in (AsArr $G.Issues)) { if ($it -and $rst.Iss.ContainsKey([string]$it.Sev)) { $rst.Iss[[string]$it.Sev]++ } }

        $worker = @'
param($R)
$enc = New-Object System.Text.UTF8Encoding $false
$fails = 0
$next = [DateTime]::UtcNow
$lastPost = [DateTime]::MinValue
function Cut($t, $n) { $t = [string]$t; if ($t.Length -gt $n) { return $t.Substring(0, $n) + '…' }; return $t }
while ($true) {
    $final = [bool]$R.Stop
    if (-not $final -and [DateTime]::UtcNow -lt $next) { Start-Sleep -Milliseconds 200; continue }
    $period = 3; if ($fails -ge 5) { $period = 15 }   # сервер долго недоступен — реже стучимся
    $next = [DateTime]::UtcNow.AddSeconds($period)
    try {
        $steps = New-Object System.Collections.Generic.List[object]
        $logA = @(); $issA = @(); $smp = $null
        [System.Threading.Monitor]::Enter($R.Lock)
        try {
            foreach ($x in $R.Steps) { $steps.Add([string[]]@((Cut $x[0] 100), [string]$x[1])) }
            $logA = @($R.Log.ToArray() | ForEach-Object { Cut $_ 220 })
            $issA = @($R.Issues.ToArray())
            if ($R.Sample) { $smp = @{} + $R.Sample }
            $iss = @{ crit = [int]$R.Iss.crit; warn = [int]$R.Iss.warn; info = [int]$R.Iss.info }
            $step = [string]$R.Step; $machine = [string]$R.Machine; $done = [bool]$R.Done; $summary = [string]$R.Summary; $sc = $R.Score
        } finally { [System.Threading.Monitor]::Exit($R.Lock) }
        $guard = 'не запущен'
        $gt = $R.GuardType
        if ($gt) {
            try {
                if ($gt::Tripped) { $guard = 'сработал: ' + (Cut $gt::Reason 120) }
                elseif ($gt::Armed) { $guard = 'следит' + $(if ($gt::LastTest) { ' (' + (Cut $gt::LastTest 60) + ')' } else { '' }) }
                else { $guard = 'включён, ждёт теста' }
            } catch {}
        }
        $issL = New-Object System.Collections.Generic.List[object]
        foreach ($x in $issA) { $issL.Add([string[]]@([string]$x[0], (Cut $x[1] 160))) }
        $body = [ordered]@{ v = $R.V; sid = $R.Sid; machine = $machine; mode = $R.Mode; started = $R.Started; step = $step; steps = $steps
            log = $logA; sample = $smp; iss = $iss; issues = $issL; guard = $guard; done = $done; summary = $summary; score = $sc; ts = [DateTime]::UtcNow.ToString('s') }
        $json = ConvertTo-Json -InputObject $body -Depth 5 -Compress
        $bytes = $enc.GetBytes($json)
        if ($bytes.Length -gt 30000) {   # лимит сервера 32 КБ: сначала режем тексты проблем, потом журнал
            $cutI = New-Object System.Collections.Generic.List[object]
            for ($i = [math]::Max(0, $issL.Count - 5); $i -lt $issL.Count; $i++) { $cutI.Add($issL[$i]) }
            $body.issues = $cutI; $body.log = [string[]]@($logA | Select-Object -Last 8)
            $bytes = $enc.GetBytes((ConvertTo-Json -InputObject $body -Depth 5 -Compress))
        }
        $gap = ([DateTime]::UtcNow - $lastPost).TotalMilliseconds   # сервер принимает не чаще 1 раза в секунду на сессию
        if ($gap -lt 1100) { Start-Sleep -Milliseconds ([int](1100 - $gap)) }
        $lastPost = [DateTime]::UtcNow
        $ok = $false
        for ($a = 0; $a -lt 2 -and -not $ok; $a++) {
            try {
                $rq = [System.Net.HttpWebRequest]::Create($R.Url)
                $rq.Method = 'POST'; $rq.Timeout = 5000; $rq.ReadWriteTimeout = 5000; $rq.KeepAlive = $true
                $rq.ContentType = 'application/json; charset=utf-8'; $rq.Headers.Add('X-Diag-Token', $R.Token)
                $rq.ContentLength = $bytes.Length
                $rqs = $rq.GetRequestStream(); $rqs.Write($bytes, 0, $bytes.Length); $rqs.Close()
                $rs = $rq.GetResponse(); $rs.Close()
                $ok = $true
            } catch [System.Net.WebException] {
                $resp = $_.Exception.Response
                if ($resp) { $code = [int]$resp.StatusCode; $resp.Close(); if ($code -in 400, 403, 404, 413, 429) { $ok = $true; break } }   # сервер ответил: повтор не поможет
                if ($a -eq 0) { Start-Sleep -Milliseconds 1200 }
            } catch { if ($a -eq 0) { Start-Sleep -Milliseconds 1200 } }
        }
        if ($ok) { $fails = 0; $R.Sent = [int]$R.Sent + 1 } else { $fails++; $R.Failed = [int]$R.Failed + 1 }
    } catch { $fails++ }
    if ($final) { break }
}
'@
        $rsp = [runspacefactory]::CreateRunspace()
        $rsp.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
        $rsp.Open()
        $psh = [powershell]::Create()
        $psh.Runspace = $rsp
        [void]$psh.AddScript($worker).AddArgument($rst)
        $G.RemoteState = $rst
        $G.RemotePS = $psh
        $G.RemoteRS = $rsp
        $G.RemoteHandle = $psh.BeginInvoke()
        $G.RemoteSid = $sid
        $G.RemoteLink = "$base/panel/live/$sid"
        $G.RemoteOn = $true
        Say ''
        Say ('УДАЛЁННАЯ ДИАГНОСТИКА: номер сессии {0}' -f $sid) 'Magenta'
        Say ('  мастер видит ход проверки вживую: {0}' -f $G.RemoteLink) 'Magenta'
        Say ''
        if ($G.LiveOk) { Live-Activity ('Удалённая диагностика: сессия ' + $sid) }
    } catch {
        $G.RemoteOn = $false
        $G.Log.Add('remote: не запустилась: ' + $_.Exception.Message)
    }
}

# ---- тонкие обёртки: вызываются рядом с Live-* (ничего не ждут, исключений не бросают)
function Remote-Lock([scriptblock]$Body) {
    $rst = $G.RemoteState
    if (-not $rst) { return }
    [System.Threading.Monitor]::Enter($rst.Lock)
    try { & $Body $rst } catch {} finally { [System.Threading.Monitor]::Exit($rst.Lock) }
}
function Remote-Step($Name) {
    if (-not $G.RemoteOn) { return }
    $nm = [string]$Name
    if (-not $G.RemoteState.GuardType -and $G.GuardOk) { try { $G.RemoteState.GuardType = [type]'DiagGuard' } catch {} }
    if (-not $G.RemoteState.Machine -and $G.Summary -and $G.Summary['Компьютер']) { $G.RemoteState.Machine = [string]$G.Summary['Компьютер'] }
    Remote-Lock {
        param($R)
        $R.Step = $nm
        if ($R.StepIdx.ContainsKey($nm)) { $R.Steps[$R.StepIdx[$nm]][1] = 'run' }
        else { $R.StepIdx[$nm] = $R.Steps.Count; $R.Steps.Add([string[]]@($nm, 'run')) }
    }
}
function Remote-StepEnd($Name, $State = 'ok') {
    if (-not $G.RemoteOn) { return }
    $nm = [string]$Name; $sv = [string]$State
    Remote-Lock {
        param($R)
        if ($R.StepIdx.ContainsKey($nm)) { $R.Steps[$R.StepIdx[$nm]][1] = $sv }
        else { $R.StepIdx[$nm] = $R.Steps.Count; $R.Steps.Add([string[]]@($nm, $sv)) }
        if ($R.Step -eq $nm) { $R.Step = '' }
    }
}
function Remote-Log($Text) {
    if (-not $G.RemoteOn) { return }
    $line = ([string]$Text).Trim()
    if (-not $line) { return }
    $line = '{0:HH:mm:ss} {1}' -f (Get-Date), $line
    Remote-Lock { param($R) $R.Log.Enqueue($line); while ($R.Log.Count -gt 20) { [void]$R.Log.Dequeue() } }
}
function Remote-Issue($Sev, $Text) {
    if (-not $G.RemoteOn) { return }
    $lv = [string]$Sev; if ($lv -notin 'crit', 'warn') { $lv = 'info' }
    $tx = [string]$Text
    Remote-Lock { param($R) $R.Iss[$lv] = [int]$R.Iss[$lv] + 1; $R.Issues.Enqueue([string[]]@($lv, $tx)); while ($R.Issues.Count -gt 15) { [void]$R.Issues.Dequeue() } }
}
function Remote-Sensors($k) {
    if (-not $G.RemoteOn -or $null -eq $k) { return }
    $smp = @{}
    foreach ($nm in 'CpuTemp', 'CpuPower', 'GpuTemp', 'GpuPower', 'V12', 'Vcore', 'FanMin') {
        $v = $null
        try { if ($null -ne $k.$nm) { $d = [double]$k.$nm; if (-not [double]::IsNaN($d) -and -not [double]::IsInfinity($d)) { $v = [math]::Round($d, 3) } } } catch {}
        $smp[$nm] = $v
    }
    Remote-Lock { param($R) $R.SampleN = [int]$R.SampleN + 1; $smp.t = $R.SampleN; $R.Sample = $smp }
}
# Итог: отмечает сессию завершённой, ждёт последнюю отправку (не дольше ~7 с) и закрывает runspace
function Remote-Finish($Summary = '', $Points = $null) {
    if (-not $G.RemoteOn) { return }
    $sm = [string]$Summary
    Remote-Lock { param($R) $R.Done = $true; $R.Summary = $sm; $R.Score = $Points; $R.Step = '' }
    Remote-Stop
}
function Remote-Stop {
    if (-not $G.RemoteOn) { return }
    $G.RemoteOn = $false
    try {
        $G.RemoteState.Stop = $true
        if ($G.RemoteHandle) { [void]$G.RemoteHandle.AsyncWaitHandle.WaitOne(7000) }
        if ($G.RemoteHandle -and $G.RemoteHandle.IsCompleted) { [void]$G.RemotePS.EndInvoke($G.RemoteHandle) } else { $G.RemotePS.BeginStop($null, $null) | Out-Null }
        $G.Log.Add(('remote: сессия {0}, отправлено {1}, не дошло {2}' -f $G.RemoteSid, $G.RemoteState.Sent, $G.RemoteState.Failed))
        if ($G.RemoteHandle.IsCompleted) { $G.RemotePS.Dispose(); $G.RemoteRS.Dispose() }
    } catch {}
}
