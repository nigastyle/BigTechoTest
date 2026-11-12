# Шина PCIe: на какой скорости и ширине подключены видеокарта, NVMe, сетевые карты (грязный слот, райзер, не тот слот)
Step 'Шина PCIe: подключение устройств' {
    $links = @(Get-PcieLinks)
    if (-not $links.Count) { Info 'Windows не отдаёт данные о линиях PCIe'; return }
    $s = New-Section 'Шина PCIe: подключение устройств'
    $tbl = @()
    foreach ($l in $links) {
        $kind = switch ($l.Class) { 'Display' { 'видеокарта' } 'Net' { 'сеть' } default { 'накопитель' } }
        $wBad = $l.CurW -gt 0 -and $l.CurW -lt $l.MaxW
        $tbl += [pscustomobject]@{ 'Устройство' = $l.Name; 'Тип' = $kind; 'Сейчас' = ('PCIe {0}.0 x{1}' -f $l.CurGen, $l.CurW); 'Максимум устройства' = ('PCIe {0}.0 x{1}' -f $l.MaxGen, $l.MaxW); 'Оценка' = $(if ($wBad) { 'меньше линий, чем может' } else { 'норма' }) }
        # Ширина в простое не меняется (в отличие от скорости, которая падает для экономии энергии) — её можно проверять сразу
        if ($wBad -and $kind -eq 'видеокарта' -and $l.MaxW -ge 8 -and $l.CurW -le $l.MaxW / 2) {
            Add-Issue 'warn' 'Видеокарта' ('{0} подключена на x{1} вместо x{2}' -f $l.Name, $l.CurW, $l.MaxW) 'Проверьте: карта в основном (верхнем) слоте x16, контакты чистые, райзер исправен, в BIOS не включено деление линий (bifurcation).'
        } elseif ($wBad -and $kind -eq 'накопитель' -and $l.MaxW -ge 4 -and $l.CurW -lt $l.MaxW) {
            Add-Issue 'info' 'Накопитель' ('{0} работает на x{1} вместо x{2}' -f $l.Name, $l.CurW, $l.MaxW) 'NVMe-диск в слоте с урезанными линиями (часто нижний M.2 через чипсет) или плохой контакт — переставьте в основной слот M.2.'
        }
    }
    Add-Table $s 'Линии PCIe (скорость в простое может быть ниже — это энергосбережение)' $tbl
}
