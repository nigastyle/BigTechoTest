# smartctl (smartmontools): полный SMART в JSON + встроенный самотест накопителей.
# Get-Tool копирует одиночный exe в $G.Tools\smartmontools\smartctl.exe — папку создаёт Get-Smartctl.
$TOOLS.Smartctl = @{ Url = 'https://194.238.56.25:8443/tools/smartctl.exe'; Sha = 'B5DB94E5082C042BE44994B7A4FA8F7B5C8E713B2AB1C9A560D8F7A7995EA27D'; Dir = ''; Exe = 'smartmontools\smartctl.exe' }
$STEPKEYS['Накопители: самотест SMART (smartctl)'] = 'selftest'
$G.PresetHooks.Add({ param($full) $G.Sel.selftest = $true })
$G.SmartctlExe = $null
$G.SmartctlTried = $false
$G.SmartDevs = $null

function Get-Smartctl {
    # Возвращает путь к smartctl.exe (скачивает при первом вызове) или $null
    if ($G.SmartctlTried) { return $G.SmartctlExe }
    $G.SmartctlTried = $true
    $dir = Join-Path $G.Tools 'smartmontools'
    try { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null } catch { Warn ('smartctl: не удалось создать папку: ' + $_.Exception.Message); return $null }
    $exe = Get-Tool 'Smartctl'
    if (-not $exe) { return $null }
    # Свежая база моделей дисков (drivedb.h) рядом с exe — smartctl под Windows берёт её из своей папки
    $db = Join-Path $dir 'drivedb.h'
    if (-not (Test-Path $db)) {
        $tmp = Join-Path $G.Temp 'drivedb.h'
        try {
            Invoke-WebRequest -Uri 'https://194.238.56.25:8443/tools/drivedb.h' -OutFile $tmp -UseBasicParsing -UserAgent 'Mozilla/5.0' -TimeoutSec 120 -ErrorAction Stop
            $h = (Get-FileHash $tmp -Algorithm SHA256).Hash
            if ($h -eq 'DD39C6A520D38895DA61923FE26FE7C9C5EB3F42325F2E4477A06ED7A61966D0') { Copy-Item $tmp $db -Force }
            else { Warn 'drivedb.h — контрольная сумма не совпала, используется встроенная база smartctl' }
        } catch { $G.Log.Add('drivedb.h: ' + $_.Exception.Message) }
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
    $G.SmartctlExe = $exe
    return $exe
}

function Invoke-Smartctl {
    # Запуск smartctl с аргументами (массив строк), возвращает разобранный JSON или $null.
    # Код возврата smartctl — битовая маска (не ошибка запуска); он есть и в JSON: smartctl.exit_status.
    param([string[]]$Arg, [int]$TimeoutSec = 60)
    $exe = Get-Smartctl
    if (-not $exe) { return $null }
    $line = ((AsArr $Arg) | ForEach-Object { if ("$_" -match '[\s"]') { '"' + ("$_" -replace '"', '\"') + '"' } else { "$_" } }) -join ' '
    $G.SmartctlLastRaw = ''
    $o = ''
    try {
        $psi = New-Object Diagnostics.ProcessStartInfo
        $psi.FileName = $exe
        $psi.Arguments = $line
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
        $p = [Diagnostics.Process]::Start($psi)
        $outTask = $p.StandardOutput.ReadToEndAsync()
        $errTask = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit($TimeoutSec * 1000)) {
            try { $p.Kill() } catch {}
            $G.Log.Add(('smartctl {0}: тайм-аут {1} с' -f $line, $TimeoutSec))
            return $null
        }
        $p.WaitForExit()
        $o = "$($outTask.Result)"
        $e = "$($errTask.Result)"
        if ($e.Trim()) { $G.Log.Add(('smartctl {0} stderr: {1}' -f $line, $e.Trim())) }
    } catch { $G.Log.Add(('smartctl {0}: {1}' -f $line, $_.Exception.Message)); return $null }
    $G.SmartctlLastRaw = $o
    $i = $o.IndexOf('{')
    if ($i -lt 0) { $G.Log.Add(('smartctl {0}: нет JSON в выводе' -f $line)); return $null }
    try { return ($o.Substring($i) | ConvertFrom-Json -ErrorAction Stop) }
    catch { $G.Log.Add(('smartctl {0}: JSON не разобран: {1}' -f $line, $_.Exception.Message)); return $null }
}

function Get-SmartctlDevArgs($Dev) {
    # Аргументы «имя [-d тип]» для устройства из --scan-open
    $a = @("$($Dev.Name)")
    if ($Dev.Type) { $a += '-d'; $a += "$($Dev.Type)" }
    return $a
}

function Get-SmartDevices([switch]$Refresh) {
    # Список накопителей по smartctl (кэш в $G.SmartDevs): Name, Type, Proto, Model, Serial, Label, J (вывод -a), File, OpenError
    if ($G.SmartDevs -and -not $Refresh) { return $G.SmartDevs }
    $list = New-Object System.Collections.Generic.List[object]
    $scan = Invoke-Smartctl @('--scan-open', '-j')
    if (-not $scan) { $G.SmartDevs = $list; return $list }
    $seen = @{}; $models = @{}; $n = 0
    foreach ($d in (AsArr $scan.devices)) {
        if (-not $d -or -not $d.name) { continue }
        $n++
        $dev = [pscustomobject]@{ Name = "$($d.name)"; Type = "$($d.type)"; Proto = "$($d.protocol)"; Model = ''; Serial = ''; Label = "$($d.name)"; J = $null; File = ''; OpenError = "$($d.open_error)" }
        if ($dev.OpenError) { $list.Add($dev); continue }
        $j = Invoke-Smartctl (@('-a', '-j') + (Get-SmartctlDevArgs $dev))
        $raw = $G.SmartctlLastRaw
        if ($j) {
            $dev.J = $j
            if ($j.device.protocol) { $dev.Proto = "$($j.device.protocol)" }
            $dev.Model = Clean $j.model_name
            if (-not $dev.Model) { $dev.Model = Clean (("$($j.scsi_vendor) $($j.scsi_product)")) }
            if (-not $dev.Model) { $dev.Model = Clean $j.scsi_model_name }
            $dev.Serial = Clean $j.serial_number
            # один и тот же диск может быть виден дважды (например, /dev/sdX и /dev/csmiN,M у Intel RST) — по серийному номеру
            if ($dev.Serial) {
                if ($seen.ContainsKey($dev.Serial)) {
                    $prev = $seen[$dev.Serial]
                    # оставляем запись с ATA/NVMe-данными, а не SCSI-трансляцию
                    if ($prev.Proto -eq 'SCSI' -and $dev.Proto -ne 'SCSI') { [void]$list.Remove($prev) } else { continue }
                }
                $seen[$dev.Serial] = $dev
            }
            $safe = ($dev.Name -replace '[^A-Za-z0-9]+', '_').Trim('_')
            $dev.File = Join-Path $G.Temp ('smartctl_{0}_{1}.json' -f $n, $safe)
            try { [IO.File]::WriteAllText($dev.File, $raw, (New-Object Text.UTF8Encoding($false))) } catch { $dev.File = '' }
        }
        if ($dev.Model) { $dev.Label = $dev.Model }
        $list.Add($dev)
    }
    # одинаковые модели — различаем по хвосту серийного номера
    foreach ($dv in $list) { if ($dv.Model) { $models[$dv.Model] = 1 + [int]$models[$dv.Model] } }
    foreach ($dv in $list) {
        if ($dv.Model -and $models[$dv.Model] -gt 1 -and $dv.Serial) {
            $tail = $dv.Serial; if ($tail.Length -gt 4) { $tail = $tail.Substring($tail.Length - 4) }
            $dv.Label = '{0} (SN …{1})' -f $dv.Model, $tail
        }
    }
    $G.SmartDevs = $list
    return $list
}
