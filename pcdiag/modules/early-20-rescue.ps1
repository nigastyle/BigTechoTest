# Спасение данных: если накопитель показывает признаки скорого отказа — предложить сначала скопировать важные данные
# и отключить нагрузочные тесты диска (поверхность, DiskSpd), чтобы не добить умирающий диск. Шаг без ключа — выполняется всегда, при здоровых дисках ничего не меняет.
Step 'Спасение данных: проверка риска потери' {
    $danger = @(Get-DiskDanger)
    if (-not $danger.Count) { Ok 'признаков скорого отказа накопителей не найдено'; return }
    $G.RescueDanger = $true
    $G.Num.rescue_danger = $danger.Count
    $s = New-Section 'Спасение данных'
    $anyCrit = @($danger | Where-Object { $_.Level -eq 'crit' }).Count -gt 0
    foreach ($dk in $danger) {
        $lt = ''; if ($dk.Letters.Count) { $lt = ' [' + ($dk.Letters -join ' ') + ']' }
        Add-Row $s ('Диск: {0}{1}, {2} ГБ' -f $dk.Name, $lt, $dk.SizeGB) ($dk.Reasons -join '; ') $(if ($dk.Level -eq 'crit') { 'crit' } else { 'warn' })
        $G.Log.Add(('rescue: disk {0} level={1}: {2}' -f $dk.Name, $dk.Level, ($dk.Reasons -join '; ')))
    }
    Add-Issue $(if ($anyCrit) { 'crit' } else { 'warn' }) 'Накопитель' ('диск показывает признаки скорого отказа: ' + (($danger | ForEach-Object { $_.Name }) -join ', ')) 'Срочно скопируйте важные данные на другой диск/флешку/в облако, затем замените накопитель. Не запускайте на нём тяжёлые тесты.'
    $dLetters = @($danger | ForEach-Object { $_.Letters } | ForEach-Object { "$_".ToUpper() })

    $keepTests = $false
    $done = $false
    if ($G.Interactive) {
        $items = @(Get-RescueItems)
        $onBad = @($items | Where-Object { $_.Src.Length -ge 2 -and ($dLetters -contains $_.Src.Substring(0, 2).ToUpper()) })
        if ($onBad.Count) { $items = $onBad }
        Info 'оцениваю размер папок (чтение каталогов)...'
        foreach ($it in $items) { if ($it.Kind -eq 'dir') { $it.Bytes = Get-DirBytes $it.Src } }
        $ans = Show-RescueDialog $danger $items $dLetters
        if ($ans -and $ans.Action -eq 'copy' -and @($ans.Items).Count) {
            $keepTests = [bool]$ans.KeepDiskTests
            $need = [int64]0; foreach ($it in $ans.Items) { if ($null -ne $it.Bytes) { $need += [int64]$it.Bytes } }
            $free = $null; try { $free = [int64](Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='" + ([IO.Path]::GetPathRoot($ans.Dest)).TrimEnd('\') + "'") -ErrorAction Stop).FreeSpace } catch {}
            if ($null -ne $free -and $need -gt $free) {
                Add-Row $s 'Копирование' ('не выполнено: на выбранном носителе {0:N1} ГБ свободно, а нужно ~{1:N1} ГБ' -f ($free / 1GB), ($need / 1GB)) 'warn'
                Warn 'недостаточно места на носителе — копирование не выполнено'
            } else {
                $rr = $null
                try { $rr = Invoke-RescueCopy $ans.Dest $ans.Items } catch { Add-Row $s 'Копирование' ('ошибка: ' + $_.Exception.Message) 'crit' }
                if ($rr) {
                    $done = $true
                    $G.RescueInfo = $rr
                    $st = 'ok'; if ($rr.Failed -gt 0 -or $rr.Stopped) { $st = 'warn' }
                    Add-Row $s 'Копирование данных' ('{0}: файлов {1}, {2:N2} ГБ{3}{4}' -f $rr.Root, $rr.Files, ($rr.Bytes / 1GB), $(if ($rr.Failed) { ', НЕ скопировано: ' + $rr.Failed } else { '' }), $(if ($rr.Stopped) { ' (остановлено пользователем)' } else { '' })) $st
                    Add-Row $s 'Журналы копирования' ('robocopy_*.log в ' + $rr.Root)
                    if ($rr.Failed -gt 0) { Add-Issue 'warn' 'Накопитель' ("при копировании данных не прочитано файлов: $($rr.Failed) (сбойные сектора)") 'Эти файлы читаются с ошибками — попробуйте скопировать их вручную или обратитесь в сервис восстановления данных, не включая диск лишний раз.' }
                    else { Add-Issue 'info' 'Накопитель' ('важные данные скопированы: ' + $rr.Root) 'Проверьте копию (откройте несколько файлов) и замените проблемный диск.' }
                }
            }
        } else { Add-Row $s 'Копирование данных' 'пользователь отказался (или окно не удалось показать)' 'warn'; if ($ans) { $keepTests = [bool]$ans.KeepDiskTests } }
    } else {
        Add-Row $s 'Копирование данных' 'автоматический режим — не выполнялось (запустите диагностику с участием пользователя, чтобы скопировать данные)' 'warn'
        Warn 'диск может скоро отказать — скопируйте важные данные!'
    }

    if ($keepTests) {
        Add-Row $s 'Нагрузочные тесты диска' 'оставлены по требованию пользователя (риск потери данных)' 'warn'
    } else {
        $off = @()
        if ($G.Sel.surface) { $G.Sel.surface = $false; $off += 'проверка поверхности' }
        if ($G.Sel.disk) { $G.Sel.disk = $false; $off += 'тест скорости DiskSpd' }
        Add-Row $s 'Нагрузочные тесты диска' $(if ($off.Count) { 'отключены, чтобы не добить диск: ' + ($off -join ', ') } else { 'не выбирались' }) 'ok'
        if ($off.Count) { $G.Log.Add('rescue: disabled ' + ($off -join ', ')) }
    }
}
