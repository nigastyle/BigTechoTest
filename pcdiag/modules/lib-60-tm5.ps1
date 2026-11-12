# TestMem5 (TM5) + конфиги anta777 — лучший тест стабильности ОЗУ из-под Windows (ловит нестабильный XMP/разгон).
# Архив .7z: Get-Tool распаковывает только .zip, поэтому своя функция Get-TM5 (распаковка 7zr.exe из $TOOLS.SevenZ).
$TOOLS.TM5 = @{ Url = 'https://194.238.56.25:8443/tools/TestMem5.7z'; Url2 = 'https://github.com/CoolCmd/TestMem5/releases/download/v0.13.1/TestMem5.7z'; Sha = '05FFB5BBAA0C2243BF25664049C7AA3615A77BD5036497EF845FC8ED50128C12'; Dir = 'TM5'; Exe = 'TM5\TM5.exe' }
$STEPKEYS['Оперативная память: TestMem5 (anta777)'] = 'tm5'
$G.PresetHooks.Add({ param($full) $G.Sel.tm5 = [bool]$full; $G.Sel.tm5min = 20 })
function Get-TM5 {
    $t = $TOOLS.TM5
    $dir = Join-Path $G.Tools $t.Dir
    $f = Get-ChildItem -LiteralPath $dir -Filter 'TM5.exe' -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($f) { return $f.FullName }
    $z = Get-Tool 'SevenZ'
    if (-not $z) { Warn 'TestMem5: нет распаковщика 7zr.exe'; return $null }
    $dl = Join-Path $G.Temp 'TestMem5.7z'
    $ok = $false
    foreach ($u in @($t.Url, $t.Url2)) {
        Info "скачиваю TestMem5..."
        try {
            Remove-Item $dl -Force -ErrorAction SilentlyContinue
            Invoke-WebRequest -Uri $u -OutFile $dl -UseBasicParsing -UserAgent 'Mozilla/5.0' -TimeoutSec 300 -ErrorAction Stop
            if ((Get-FileHash $dl -Algorithm SHA256).Hash -eq $t.Sha) { $ok = $true; break }
            Warn 'TestMem5 — контрольная сумма не совпала, пробую другой источник'
        } catch { $G.Log.Add(('TM5 download {0}: {1}' -f $u, $_.Exception.Message)) }
    }
    if (-not $ok) { Remove-Item $dl -Force -ErrorAction SilentlyContinue; Warn 'не удалось скачать TestMem5'; return $null }
    try {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $p = Start-Process $z -ArgumentList ('x -y "-o{0}" "{1}"' -f $dir, $dl) -PassThru -Wait -WindowStyle Hidden
        $G.Log.Add("TM5 7zr exit: $($p.ExitCode)")
    } catch { Warn ('TestMem5: ошибка распаковки: ' + $_.Exception.Message); return $null }
    Remove-Item $dl -Force -ErrorAction SilentlyContinue
    $f = Get-ChildItem -LiteralPath $dir -Filter 'TM5.exe' -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($f) { return $f.FullName }
    Warn 'TestMem5: TM5.exe не найден после распаковки (возможно, удалён антивирусом)'
    return $null
}
