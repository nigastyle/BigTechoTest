# Деградация охлаждения по кривой нагрева/остывания: ключ выбора 'coolcurve' (только в полном режиме)
$STEPKEYS['Охлаждение: кривая нагрева и остывания'] = 'coolcurve'
$G.PresetHooks.Add({ param($full) $G.Sel.coolcurve = [bool]$full })
# тест нагружает процессор — сторож датчиков должен его охранять
if ($G.GuardStress -and (@($G.GuardStress) -notcontains 'coolcurve')) { $G.GuardStress = @($G.GuardStress) + 'coolcurve' }
