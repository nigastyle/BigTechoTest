# Долгий тест стабильности GPU (Vulkan): FurMark 2 (furmark-vk) на родном разрешении N минут.
# Ловит то, что не видно за 60 секунд: сбои драйвера (TDR/Xid), просадки частоты, дребезг лимита мощности, медленный прогрев.
# Сам шаг — modules/stress-35-gpustab.ps1. Ключи UI: gpustab (галочка), gpustabmin (минуты, по умолчанию 20).
$STEPKEYS['Видеокарта: стабильность (Vulkan, долгий)'] = 'gpustab'
$G.PresetHooks.Add({ param($full) $G.Sel.gpustab = $full; $G.Sel.gpustabmin = 20 })
# сторож датчиков охраняет этот шаг так же, как остальные стресс-тесты
$G.GuardStress = (AsArr $G.GuardStress) + @('gpustab')
function Get-GsPct($arr, [double]$pct) {
    # перцентиль (0..100) по массиву чисел; $null для пустого
    $v = @($arr | Where-Object { $null -ne $_ } | Sort-Object)
    if (-not $v.Count) { return $null }
    $i = [int][math]::Floor(($v.Count - 1) * $pct / 100.0)
    return [double]$v[$i]
}
function ConvertFrom-SmiMask($txt) {
    # '0x0000000000000004' -> число; $null если не разобрать
    if (-not $txt) { return $null }
    try { return [int64][Convert]::ToInt64(("$txt" -replace '^0x', ''), 16) } catch { return $null }
}
