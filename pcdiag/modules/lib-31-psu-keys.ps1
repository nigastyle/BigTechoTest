# Совместный тест БП: ключ выбора и значения по умолчанию (должны быть известны до применения пресета)
$STEPKEYS['Блок питания: совместная нагрузка CPU + GPU'] = 'psu'
$G.PresetHooks.Add({ param($full) $G.Sel.psu = $true; $G.Sel.psumin = $(if ($full) { 10 } else { 2 }) })
