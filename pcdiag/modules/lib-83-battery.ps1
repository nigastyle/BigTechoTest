# Аккумулятор: тест разряда под нагрузкой и реальная автономность (только ноутбуки, только с участием пользователя).
# Ключ выбора, значения по умолчанию (в полном режиме и только если есть батарея). batmin - длительность, мин.
$STEPKEYS['Аккумулятор: тест разряда под нагрузкой'] = 'batdrain'
$G.PresetHooks.Add({ param($full)
    $hasBat = $false
    try { $hasBat = (@(Get-CimInstance -ClassName Win32_Battery -ErrorAction Stop)).Count -gt 0 } catch {}
    $G.Sel.batdrain = ($full -and $hasBat)
    $G.Sel.batmin = 10
})

# Удержание экрана включённым на время теста
function Set-KeepAwake([bool]$on) {
    if (-not ('DiagKeepAwake' -as [type])) {
        try { Add-Type -TypeDefinition 'using System.Runtime.InteropServices; public static class DiagKeepAwake { [DllImport("kernel32.dll")] static extern uint SetThreadExecutionState(uint f); public static void On() { SetThreadExecutionState(0x80000003u); } public static void Off() { SetThreadExecutionState(0x80000000u); } }' -ErrorAction Stop } catch { return }
    }
    if ($on) { [DiagKeepAwake]::On() } else { [DiagKeepAwake]::Off() }
}

# Одно измерение батареи (root/wmi): суммарно по всем батареям. Возвращает $null, если данных нет.
function Get-BatSample {
    $st = @(CIM 'BatteryStatus' 'root/wmi')
    if ($st.Count -eq 0) { return $null }
    $rem = 0.0; $rate = 0.0; $volt = 0.0; $nv = 0; $online = $false; $disch = $false; $chg = $false; $isCrit = $false; $chgRate = 0.0
    foreach ($b in $st) {
        if ($b.RemainingCapacity -gt 0 -and $b.RemainingCapacity -lt 4000000) { $rem += [double]$b.RemainingCapacity }
        $dr = [double]$b.DischargeRate; if ($dr -gt 0 -and $dr -lt 300000) { $rate += $dr }
        $cr = [double]$b.ChargeRate; if ($cr -gt 0 -and $cr -lt 300000) { $chgRate += $cr }
        if ($b.Voltage -gt 1000 -and $b.Voltage -lt 60000) { $volt += [double]$b.Voltage; $nv++ }
        if ($b.PowerOnline) { $online = $true }
        if ($b.Discharging) { $disch = $true }
        if ($b.Charging) { $chg = $true }
        if ($b.Critical) { $isCrit = $true }
    }
    $pct = $null; $w = @(CIM 'Win32_Battery'); if ($w.Count) { $pct = [double]$w[0].EstimatedChargeRemaining }
    return [pscustomobject]@{ T = Get-Date; Rem = $rem; Rate = $rate; ChargeRate = $chgRate; Volt = $(if ($nv) { $volt / $nv } else { 0 }); Online = $online; Discharging = $disch; Charging = $chg; Critical = $isCrit; Pct = $pct }
}
