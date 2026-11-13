# Фризы и статтеры (frametime): Intel PresentMon (MIT, github.com/GameTechDev/PresentMon) — консольный захват кадров.
# Шаг — modules/stress-36-frametime.ps1. Ключ UI: frametime (в пресете включён только в «полном»).
# Режим игры: переменная окружения DIAG_GAME_EXE=имя процесса (например game.exe) — захват 120 с вместо FurMark.
$TOOLS.PresentMon = @{ Url = 'https://github.com/GameTechDev/PresentMon/releases/download/v2.6.0/PresentMon-2.6.0-x64.exe'; Sha = 'B2A706BC6AD475749E3B7E3409263AA1E6906D45BDCF993F6DBC0F660188F1AF'; Dir = ''; Exe = 'PresentMon-2.6.0-x64.exe' }
$STEPKEYS['Видеокарта: фризы и статтеры (frametime)'] = 'frametime'
$G.PresetHooks.Add({ param($full) $G.Sel.frametime = $full })
$G.GuardStress = (AsArr $G.GuardStress) + @('frametime')
function Get-FtPct($sorted, [double]$pct) {
    # перцентиль по УЖЕ отсортированному по возрастанию массиву
    if (-not $sorted.Count) { return $null }
    $i = [int][math]::Floor(($sorted.Count - 1) * $pct / 100.0)
    return [double]$sorted[$i]
}
function Read-FrameTimes($csv) {
    # CSV PresentMon → список времён кадра (мс). Колонка: MsBetweenPresents (1.x/2.x) или FrameTime (--v2_metrics).
    $res = New-Object System.Collections.Generic.List[double]
    if (-not (Test-Path $csv)) { return $res }
    $sr = $null
    try {
        $sr = New-Object System.IO.StreamReader($csv)
        $hdr = $sr.ReadLine(); if (-not $hdr) { return $res }
        $cols = $hdr.Split(',') | ForEach-Object { $_.Trim().Trim('"') }
        $ix = -1
        foreach ($nm in 'MsBetweenPresents', 'FrameTime', 'msBetweenPresents', 'MsBetweenDisplayChange') {
            for ($i = 0; $i -lt $cols.Count; $i++) { if ($cols[$i] -ieq $nm) { $ix = $i; break } }
            if ($ix -ge 0) { break }
        }
        if ($ix -lt 0) { return $res }
        while (($line = $sr.ReadLine()) -ne $null) {
            $f = $line.Split(',')
            if ($f.Count -le $ix) { continue }
            $v = 0.0
            if ([double]::TryParse($f[$ix].Trim('"'), [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$v) -and $v -gt 0) { $res.Add($v) }
        }
    } catch {} finally { if ($sr) { $sr.Dispose() } }
    return $res
}
