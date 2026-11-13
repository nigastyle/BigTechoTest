# Типовые неисправности этой модели (#20): сервер собирает отчёты всех проверенных компьютеров.
# Для такой же модели (ноутбук — по модели, ПК — по материнской плате) показываем частые проблемы,
# а для такого же процессора/видеокарты/диска — обычные температуры и результаты тестов, и сравниваем с этим ПК.
# Идёт после final-10-history (там заполняются $G.Num.cpu_tmax / gpu_tmax / gpu_hot_delta).
Step 'Типовые неисправности этой модели' {
    if ($env:DIAG_NOSEND -and -not $env:DIAG_HISTORY) { Info 'пропущено: обмен данными с сервером отключён (DIAG_NOSEND)'; return }
    $pcid = ''
    try { $u = (CIM Win32_ComputerSystemProduct | Select-Object -First 1).UUID; if ($u) { $pcid = -join ([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes("pcdiag:$u")) | Select-Object -First 8 | ForEach-Object { $_.ToString('x2') }) } } catch {}
    $req = @{ pc_id = $pcid; machine = $G.Summary['Компьютер']; board = $G.Summary['Материнская плата']; kind = $(if ($G.IsLaptop) { 'laptop' } else { 'desktop' })
        cpu = $G.Summary['Процессор']; gpu = $G.Summary['Видеокарта']; disk = $G.Summary['Накопители'] }
    $r = $null
    try {
        $base = $UPLOAD.Url -replace '/upload$', ''
        $wc = New-Object Net.WebClient; $wc.Encoding = [Text.Encoding]::UTF8
        $wc.Headers.Add('X-Diag-Token', $UPLOAD.Token); $wc.Headers.Add('Content-Type', 'application/json')
        $r = $wc.UploadString("$base/models", ($req | ConvertTo-Json -Compress)) | ConvertFrom-Json
    } catch { $G.Log.Add('models: ' + $_.Exception.Message) }
    if (-not $r -or -not $r.ok) { Warn 'нет связи с сервером — сравнение с такими же компьютерами пропущено'; return }

    $sec = New-Section 'Типовые неисправности этой модели'
    $md = $r.model
    $nPc = [int]$md.n_pcs
    Add-Row $sec 'Модель' $(if ($md.name) { $md.name } else { 'не определена' })
    Add-Row $sec 'Таких же компьютеров в базе' $(if ($nPc) { '{0} (отчётов: {1})' -f $nPc, [int]$md.n_reports } else { 'пока нет — это первый такой компьютер' })

    # ---- «У таких же ПК часто: …»
    $mine = @{}
    foreach ($it in (AsArr $G.Issues)) { if ($it) { $mine[(('{0}: {1}' -f $it.Area, $it.Text) -replace '\d+([.,]\d+)?', 'N')] = $true } }
    $often = New-Object System.Collections.Generic.List[object]
    foreach ($it in (AsArr $md.issues)) {
        if (-not $it) { continue }
        $key = ('{0}: {1}' -f $it.area, $it.text)
        $often.Add([pscustomobject]@{
                'Проблема'           = ($key -replace '\bN\b', '…')
                'Как часто'          = ('{0} % ({1} из {2} ПК)' -f [int]$it.pct, [int]$it.pcs, $nPc)
                'Уровень'            = $(if ($it.level -eq 'crit') { 'критично' } else { 'внимание' })
                'Есть у этого ПК'    = $(if ($mine.ContainsKey($key)) { 'ДА' } else { 'нет' })
            })
    }
    if ($often.Count) {
        Add-Table $sec 'У таких же ПК часто:' @($often | Select-Object -First 10)
        $top = @($often | Where-Object { $_.'Есть у этого ПК' -eq 'нет' } | Select-Object -First 3 | ForEach-Object { $_.'Проблема' })
        if ($nPc -ge 3 -and $top.Count) { Add-Row $sec 'На что обратить внимание' ('у этой модели часто: ' + ($top -join '; ')) 'warn' }
        Info ('у таких же ПК часто: ' + (@($often | Select-Object -First 3 | ForEach-Object { $_.'Проблема' + ' (' + $_.'Как часто' + ')' }) -join '; '))
    } elseif ($nPc) { Add-Row $sec 'У таких же ПК часто' 'аппаратных проблем у такой модели в базе не встречалось' 'ok' }

    # ---- сравнение температур и тестов с медианой такой же модели процессора / видеокарты / диска
    # [метрика, группа, название, ед., 'hi' (больше = хуже, порог в единицах) | 'lo' (меньше = хуже, порог в %), порог, область для проблемы]
    $defs = @(
        @('cpu_tmax', 'cpu', 'Процессор: макс. температура под нагрузкой', '°C', 'hi', 10, 'Охлаждение'),
        @('gpu_tmax', 'gpu', 'Видеокарта: макс. температура под нагрузкой', '°C', 'hi', 10, 'Охлаждение'),
        @('gpu_hot_delta', 'gpu', 'Видеокарта: разница ядро / hot spot', '°C', 'hi', 8, 'Видеокарта'),
        @('cpu_mips', 'cpu', 'Процессор: 7-Zip, все потоки', 'MIPS', 'lo', 15, 'Процессор'),
        @('cpu_1t', 'cpu', 'Процессор: 7-Zip, 1 поток', 'MIPS', 'lo', 15, 'Процессор'),
        @('linpack_gflops', 'cpu', 'Процессор: Linpack', 'GFLOPS', 'lo', 15, 'Процессор'),
        @('gpu_score', 'gpu', 'Видеокарта: FurMark 1080p', 'баллов', 'lo', 15, 'Видеокарта'),
        @('disk_seq_r', 'disk', 'Диск: последовательное чтение', 'МБ/с', 'lo', 25, 'Накопитель'),
        @('disk_rnd_iops', 'disk', 'Диск: случайное чтение 4К', 'IOPS', 'lo', 25, 'Накопитель')
    )
    $cmpT = New-Object System.Collections.Generic.List[object]
    $worse = 0
    foreach ($df in $defs) {
        $nowV = $G.Num[$df[0]]
        if ($null -eq $nowV -or "$nowV" -eq '') { continue }
        $grp = $r.($df[1])
        if (-not $grp -or -not $grp.metrics) { continue }
        $mst = $grp.metrics.($df[0])
        if (-not $mst) { continue }
        $med = [double]$mst.median; $n = [int]$mst.n; $nowD = [double]$nowV
        if ($med -le 0) { continue }
        if ($df[4] -eq 'hi') {
            $diff = $nowD - $med
            $dTxt = '{0:+0;-0;0} {1}' -f $diff, $df[3]
            $bad = $diff -ge [double]$df[5]
            $good = $diff -le 3
        } else {
            $diff = ($nowD / $med - 1) * 100
            $dTxt = '{0:+0;-0;0} %' -f $diff
            $bad = $diff -le -[double]$df[5]
            $good = $diff -ge -5
        }
        $verd = if ($n -lt 3) { 'мало данных для вывода' } elseif ($bad) { 'ХУЖЕ обычного' } elseif ($good) { 'как обычно или лучше' } else { 'немного хуже обычного' }
        $cmpT.Add([pscustomobject]@{
                'Показатель'                  = $df[2]
                'У этого ПК'                  = ('{0:N0} {1}' -f $nowD, $df[3])
                'Обычно у такой же модели'    = ('{0:N0} {1} (ПК: {2})' -f $med, $df[3], $n)
                'Разница'                     = $dTxt
                'Вывод'                       = $verd
            })
        if ($bad -and $n -ge 3) {
            $worse++
            # падение 7-Zip/FurMark ниже медианы модели уже отмечается при общем сравнении с базой (Get-Compare) — здесь не дублируем
            if ($df[4] -eq 'hi') {
                if ($df[0] -eq 'gpu_hot_delta') { $fix = 'Большой разрыв ядро/hot spot у этой видеокарты нетипичен: высохла термопаста или неравномерный прижим радиатора — переобслужите охлаждение видеокарты.' }
                else { $fix = 'Такие же компьютеры под нагрузкой заметно холоднее: вероятны пыль в радиаторе, высохшая термопаста или слабый обдув — почистите охлаждение и замените термопасту.' }
                Add-Issue 'info' $df[6] ('{0}: {1:N0} {2} — на {3:N0} {2} выше, чем обычно у такой же модели ({4:N0} {2}, ПК: {5})' -f $df[2], $nowD, $df[3], $diff, $med, $n) $fix
            } elseif ($df[1] -eq 'disk' -or $df[0] -eq 'linpack_gflops') {
                Add-Issue 'info' $df[6] ('{0}: на {1:N0} % ниже, чем обычно у такой же модели ({2:N0} {3}, ПК: {4})' -f $df[2], -$diff, $med, $df[3], $n) $(if ($df[1] -eq 'disk') { 'Проверьте заполненность и износ диска, режим подключения (PCIe/SATA-порт), драйвер контроллера и перегрев накопителя.' } else { 'Проверьте режим питания Windows, лимиты мощности в BIOS и температуры под нагрузкой.' })
            }
        }
    }
    if ($cmpT.Count) {
        Add-Table $sec 'Этот ПК против такого же железа в базе (медиана)' $cmpT
        Add-Row $sec 'Итог сравнения с такими же' $(if ($worse) { 'заметно хуже обычного: {0} показ.' -f $worse } else { 'отклонений от типичных значений нет' }) $(if ($worse) { 'warn' } else { 'ok' })
    } else { Add-Row $sec 'Сравнение с таким же железом' 'в базе пока нет замеров такого же процессора/видеокарты/диска' }
}
