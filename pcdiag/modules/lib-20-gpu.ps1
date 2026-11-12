# ---------------------------------------------------------------- видеокарта: nvidia-smi, PCIe
$TOOLS.MemtestVulkan = @{ Url = 'https://github.com/GpuZelenograd/memtest_vulkan/releases/download/v0.5.0/memtest_vulkan-v0.5.0.exe'; Sha = '09E67704210762AE8D8AD70FE6D71275EEFBE815CC2C0658CD5AFC8E231D0DF6'; Dir = ''; Exe = 'memtest_vulkan.exe' }
$STEPKEYS['Видеокарта: тест видеопамяти'] = 'vram'
$G.PresetHooks.Add({ param($full) $G.Sel.vram = $full })
$G.SmiFields = $null
function Get-SmiExe {
    foreach ($p in "$env:SystemRoot\System32\nvidia-smi.exe", "$env:ProgramFiles\NVIDIA Corporation\NVSMI\nvidia-smi.exe") { if (Test-Path $p) { return $p } }
    return $null
}
function Get-SmiFields {
    # Неизвестное поле ломает весь запрос — берём только те, что знает установленный драйвер
    if ($null -ne $G.SmiFields) { return $G.SmiFields }
    $G.SmiFields = @()
    $smi = Get-SmiExe; if (-not $smi) { return $G.SmiFields }
    $want = 'index,name,temperature.gpu,fan.speed,power.draw,power.limit,enforced.power.limit,power.default_limit,power.max_limit,clocks.gr,clocks.mem,clocks.max.gr,pcie.link.gen.current,pcie.link.gen.max,pcie.link.width.current,pcie.link.width.max,memory.total,memory.used,utilization.gpu,clocks_throttle_reasons.active,clocks_event_reasons.active' -split ','
    try { $help = (& $smi --help-query-gpu 2>$null) -join "`n" } catch { return $G.SmiFields }
    $G.SmiFields = @($want | Where-Object { $help -match ('"' + [regex]::Escape($_) + '"') })
    return $G.SmiFields
}
function Read-SmiCsv($lines) {
    $f = Get-SmiFields; $out = @()
    foreach ($line in $lines) {
        if ("$line" -notmatch ',') { continue }
        $v = "$line" -split ',\s*'; $o = [ordered]@{}
        for ($i = 0; $i -lt $f.Count -and $i -lt $v.Count; $i++) {
            $x = $v[$i].Trim(); $o[$f[$i]] = if ($x -match '^\[?(N/A|Not Supported|Unknown Error|Insufficient Permissions|GPU requires reset)\]?$') { $null } else { $x }
        }
        if (-not $o['clocks_throttle_reasons.active'] -and $o['clocks_event_reasons.active']) { $o['clocks_throttle_reasons.active'] = $o['clocks_event_reasons.active'] }   # новое имя поля (драйверы R535+)
        $out += [pscustomobject]$o
    }
    return $out
}
function Start-SmiLog {
    # Фоновая запись показаний NVIDIA раз в секунду (во время нагрузки)
    $smi = Get-SmiExe; $f = Get-SmiFields
    if (-not $smi -or -not $f.Count) { return $null }
    $file = Join-Path $G.Temp ('smi_' + (Get-Date -Format 'HHmmss') + '.csv')
    try { $p = Start-Process $smi -ArgumentList ("--query-gpu=$($f -join ',') --format=csv,noheader,nounits -lms 1000 -f `"$file`"") -PassThru -WindowStyle Hidden } catch { return $null }
    return @{ P = $p; File = $file }
}
function Stop-SmiLog($h) {
    if (-not $h) { return @() }
    try { if (-not $h.P.HasExited) { $h.P.Kill() } } catch {}
    Start-Sleep -Milliseconds 300
    if (-not (Test-Path $h.File)) { return @() }
    return @(Read-SmiCsv (Get-Content $h.File -ErrorAction SilentlyContinue))
}
function Get-PcieLinks {
    # Скорость/ширина PCIe по данным Windows (для любых устройств: видеокарты, NVMe, сетевые)
    $k = 'DEVPKEY_PciDevice_CurrentLinkSpeed', 'DEVPKEY_PciDevice_CurrentLinkWidth', 'DEVPKEY_PciDevice_MaxLinkSpeed', 'DEVPKEY_PciDevice_MaxLinkWidth'
    $out = @()
    foreach ($d in @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -like 'PCI\*' -and $_.Class -in 'Display', 'SCSIAdapter', 'HDC', 'Net' })) {
        $h = @{}
        try { Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName $k -ErrorAction Stop | ForEach-Object { $h[$_.KeyName] = $_.Data } } catch { continue }
        $cs = $h[$k[0]]; $cw = $h[$k[1]]; $ms = $h[$k[2]]; $mw = $h[$k[3]]
        if (-not $ms -or -not $mw) { continue }
        $out += [pscustomobject]@{ Name = $d.FriendlyName; Class = $d.Class; Id = $d.InstanceId; CurGen = [int]$cs; CurW = [int]$cw; MaxGen = [int]$ms; MaxW = [int]$mw }
    }
    return $out
}
