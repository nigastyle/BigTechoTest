# Результат проверки памяти Windows (mdsched / memtest.efi), запланированной прошлым запуском программы.
# Шаг 'Планирование проверки памяти' (body.ps1) ставит {memdiag} в bootsequence загрузчика и пишет время
# в HKCU\Software\BigTechoTest\MemDiagScheduled. После перезагрузки memtest.efi проходит до Windows,
# а при входе в систему Windows пишет итог в журнал System, источник Microsoft-Windows-MemoryDiagnostics-Results:
#   1101/1201 — ошибок нет; 1102/1202 — найдены аппаратные ошибки; 1103 — отменена; 1104 — не завершена.
Step 'Результат проверки памяти Windows' {
    $mdKey = 'HKCU:\Software\BigTechoTest'
    $mdVal = $null
    try { $mdVal = (Get-ItemProperty -Path $mdKey -Name MemDiagScheduled -ErrorAction Stop).MemDiagScheduled } catch {}
    if (-not $mdVal) { Info 'проверка памяти Windows не планировалась'; return }
    $mdWhen = $null
    try { $mdWhen = [datetime]::Parse("$mdVal", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) } catch {}
    if (-not $mdWhen) { Remove-ItemProperty -Path $mdKey -Name MemDiagScheduled -ErrorAction SilentlyContinue; return }
    # события чуть раньше отметки (часы/часовой пояс) тоже считаем — берём запас 2 минуты
    $mdEv = @()
    try { $mdEv = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-MemoryDiagnostics-Results'; StartTime = $mdWhen.AddMinutes(-2) } -ErrorAction Stop | Where-Object { $_.Id -in 1101, 1102, 1103, 1104, 1201, 1202 } | Sort-Object TimeCreated -Descending) } catch {}
    $s = New-Section 'Проверка памяти Windows (после перезагрузки)'
    Add-Row $s 'Запланирована' $mdWhen.ToString('dd.MM.yyyy HH:mm')
    if ($mdEv.Count) {
        $mdLast = $mdEv[0]
        $G.MemDiagReported = $true
        switch ($mdLast.Id) {
            { $_ -in 1101, 1201 } {
                Add-Row $s 'Результат' ('{0}: ошибок не обнаружено' -f $mdLast.TimeCreated.ToString('dd.MM.yyyy HH:mm')) 'ok'
                Ok 'проверка памяти Windows: ошибок не обнаружено'
                $G.Num.memdiag_ok = 1
            }
            { $_ -in 1102, 1202 } {
                Add-Row $s 'Результат' ('{0}: НАЙДЕНЫ АППАРАТНЫЕ ОШИБКИ ПАМЯТИ' -f $mdLast.TimeCreated.ToString('dd.MM.yyyy HH:mm')) 'crit'
                Warn 'проверка памяти Windows нашла ошибки оперативной памяти!'
                Add-Issue 'crit' 'Память' 'средство проверки памяти Windows нашло аппаратные ошибки оперативной памяти' 'Отключите разгон XMP/EXPO в BIOS и проверьте планки по одной (MemTest86 с флешки); сбойную планку замените.'
                $G.Num.memdiag_ok = 0
            }
            1103 {
                Add-Row $s 'Результат' 'проверка была отменена (нажата Esc или выключение во время теста)' 'warn'
                Add-Issue 'info' 'Память' 'проверка памяти Windows была отменена и не дала результата' 'Запланируйте её снова и дождитесь окончания (~20–40 мин), не выключая компьютер.'
            }
            default {
                Add-Row $s 'Результат' 'проверка не завершилась' 'warn'
                Add-Issue 'warn' 'Память' 'проверка памяти Windows не смогла завершиться' 'Возможна нестабильность памяти: проверьте ОЗУ MemTest86 с флешки, отключите разгон XMP/EXPO.'
            }
        }
        $mdMsg = Clean $mdLast.Message
        if ($mdMsg) { Add-Row $s 'Сообщение Windows' $mdMsg }
        Remove-ItemProperty -Path $mdKey -Name MemDiagScheduled -ErrorAction SilentlyContinue
        return
    }
    # результата нет: либо ещё не перезагружались, либо тест не запустился/был прерван
    $mdPending = ((bcdedit /enum '{bootmgr}' 2>$null) -join "`n") -match '(?im)^bootsequence\s+.*\{memdiag\}'
    if ($mdPending) {
        Add-Row $s 'Результат' 'ещё не выполнялась — компьютер не перезагружали' 'warn'
        Add-Issue 'info' 'Память' 'проверка памяти Windows запланирована, но компьютер ещё не перезагружали' 'Пуск → Выключение → «Перезагрузка» (именно перезагрузка: «Завершение работы» при быстром запуске Windows проверку может пропустить). Проверка пройдёт до загрузки Windows (~20–40 мин), результат покажет следующий запуск программы.'
        return   # отметку оставляем — результат прочитаем в следующий раз
    }
    Add-Row $s 'Результат' 'нет: проверка не запустилась или была прервана (в журнале нет записи)' 'warn'
    Add-Issue 'info' 'Память' 'запланированная проверка памяти Windows не дала результата' 'Запустите mdsched.exe → «Выполнить перезагрузку и проверку» или проверьте память MemTest86 с флешки.'
    Remove-ItemProperty -Path $mdKey -Name MemDiagScheduled -ErrorAction SilentlyContinue
}
