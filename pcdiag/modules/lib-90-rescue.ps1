# Спасение данных: быстрая оценка «умирающего» диска и копирование важных папок (robocopy) на другой носитель.
# Шаг — early-20-rescue.ps1. Диск, на котором мы проверяем, только ЧИТАЕТСЯ; пишем только на выбранный пользователем носитель.
$G.RescueDanger = $false
$G.RescueInfo = $null

function Get-DiskDanger {
    # Быстрая оценка (несколько секунд): возвращает список @{ Number; Name; Letters; Level('crit'|'warn'); Reasons[] } только для дисков с признаками отказа
    $res = New-Object System.Collections.Generic.List[object]
    $pds = @(); try { $pds = @(Get-PhysicalDisk -ErrorAction Stop) } catch {}
    $wmiPred = @(); try { $wmiPred = @(Get-CimInstance -Namespace 'root\wmi' -ClassName MSStorageDriver_FailurePredictStatus -ErrorAction Stop) } catch {}
    $wmiSmart = @(); try { $wmiSmart = @(Get-CimInstance -Namespace 'root\wmi' -ClassName MSStorageDriver_ATAPISmartData -ErrorAction Stop) } catch {}
    $dd = @(CIM Win32_DiskDrive)
    $ev = @(); try { $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'disk'; Id = 7, 52, 153; StartTime = (Get-Date).AddDays(-30) } -MaxEvents 50 -ErrorAction Stop) } catch {}
    foreach ($pd in $pds) {
        $reasons = New-Object System.Collections.Generic.List[string]
        $level = ''
        $num = $null; try { $num = [int]$pd.DeviceId } catch {}
        $hs = "$($pd.HealthStatus)"
        if ($hs -match 'Unhealthy') { $reasons.Add('Windows: состояние диска «Неисправен»'); $level = 'crit' }
        elseif ($hs -match 'Warning') { $reasons.Add('Windows: состояние диска «Предупреждение» (SMART Caution)'); if (-not $level) { $level = 'warn' } }
        if ("$($pd.OperationalStatus)" -match 'Predictive|Lost|Failed|Error|Stale') { $reasons.Add('статус: ' + ("$($pd.OperationalStatus)" -replace '[{}]', '')); $level = 'crit' }
        $rc = $null; try { $rc = $pd | Get-StorageReliabilityCounter -ErrorAction Stop } catch {}
        if ($rc) {
            $unc = [int64]0; try { $unc = [int64]$rc.ReadErrorsUncorrected + [int64]$rc.WriteErrorsUncorrected } catch {}
            if ($unc -gt 0) { $reasons.Add("неисправленные ошибки чтения/записи: $unc"); $level = 'crit' }
            if ($null -ne $rc.Wear -and [int]$rc.Wear -ge 95) { $reasons.Add("износ SSD $($rc.Wear) %"); if (-not $level) { $level = 'warn' } }
        }
        # SMART через WMI (без загрузки smartctl): PredictFailure и атрибуты 5/197/198
        $drv = $dd | Where-Object { $null -ne $num -and [int]$_.Index -eq $num } | Select-Object -First 1
        if ($drv) {
            $pnp = "$($drv.PNPDeviceID)"
            foreach ($pr in $wmiPred) { if ("$($pr.InstanceName)" -like ($pnp + '*') -and $pr.PredictFailure) { $reasons.Add('SMART: диск сам предсказывает отказ'); $level = 'crit' } }
            foreach ($sm in $wmiSmart) {
                if ("$($sm.InstanceName)" -notlike ($pnp + '*')) { continue }
                $b = $sm.VendorSpecific
                if (-not $b -or $b.Length -lt 14) { continue }
                for ($i = 2; $i + 11 -lt $b.Length -and $i -lt 362; $i += 12) {
                    $id = [int]$b[$i]; if ($id -eq 0) { continue }
                    $raw = [int64]0; for ($j = 5; $j -ge 0; $j--) { $raw = $raw * 256 + [int64]$b[$i + 5 + $j] }
                    if ($id -eq 197 -and $raw -gt 0) { $reasons.Add("SMART: нестабильных (ожидающих) секторов — $raw"); $level = 'crit' }
                    elseif ($id -eq 198 -and $raw -gt 0) { $reasons.Add("SMART: неисправимых секторов — $raw"); $level = 'crit' }
                    elseif ($id -eq 5 -and $raw -ge 50) { $reasons.Add("SMART: переназначенных секторов — $raw"); if (-not $level) { $level = 'warn' } }
                }
            }
        }
        # журнал Windows: события драйвера диска (7 — плохой блок, 52 — SMART-предсказание отказа, 153 — повтор ввода-вывода)
        $e7 = @($ev | Where-Object { $_.Id -in 7, 52 })
        if ($e7.Count -and ($pds.Count -eq 1 -or "$($e7[0].Message)" -match ('DR' + $num + '\b|PhysicalDrive' + $num + '\b'))) { $reasons.Add("журнал Windows: события «плохой блок/предсказание отказа» за 30 дней — $($e7.Count)"); $level = 'crit' }
        if ($reasons.Count -eq 0) { continue }
        $letters = @(); if ($null -ne $num) { try { $letters = @(Get-Partition -DiskNumber $num -ErrorAction Stop | Where-Object { $_.DriveLetter } | ForEach-Object { "$($_.DriveLetter):" }) } catch {} }
        $res.Add([pscustomobject]@{ Number = $num; Name = "$($pd.FriendlyName)"; Letters = $letters; Level = $level; Reasons = @($reasons); SizeGB = [math]::Round([double]$pd.Size / 1GB) })
    }
    return @($res)
}

function Get-RescueItems {
    # Кандидаты на копирование: [pscustomobject]@{ Label; Src; Kind('dir'|'files'); Files[]; Default; Bytes }
    $items = New-Object System.Collections.Generic.List[object]
    $profiles = @()
    try { $profiles = @(Get-ChildItem -LiteralPath (Join-Path $env:SystemDrive 'Users') -Directory -ErrorAction Stop | Where-Object { $_.Name -notmatch '^(Public|Default|Default User|All Users|WDAGUtilityAccount)$' -and (Test-Path (Join-Path $_.FullName 'Desktop')) }) } catch {}
    foreach ($pf in $profiles) {
        $isMe = ($pf.FullName -eq $env:USERPROFILE)
        foreach ($f in @(
                @('Рабочий стол', 'Desktop', 'Desktop', $true), @('Документы', 'Documents', 'MyDocuments', $true), @('Изображения', 'Pictures', 'MyPictures', $true),
                @('Загрузки', 'Downloads', $null, $false), @('Видео', 'Videos', 'MyVideos', $false), @('Музыка', 'Music', 'MyMusic', $false))) {
            $dir = Join-Path $pf.FullName $f[1]
            if ($isMe -and $f[2]) { try { $d2 = [Environment]::GetFolderPath($f[2]); if ($d2) { $dir = $d2 } } catch {} }
            if (-not (Test-Path -LiteralPath $dir)) { continue }
            $items.Add([pscustomobject]@{ Label = ('{0}: {1}' -f $pf.Name, $f[0]); Src = $dir; Kind = 'dir'; Files = @(); Default = [bool]$f[3]; Bytes = $null; Key = ($pf.Name + '\' + $f[1]) })
        }
        # закладки браузеров (только файлы закладок — пароли и куки не копируем)
        $bm = @(
            @('Chrome', "$($pf.FullName)\AppData\Local\Google\Chrome\User Data"), @('Edge', "$($pf.FullName)\AppData\Local\Microsoft\Edge\User Data"),
            @('Brave', "$($pf.FullName)\AppData\Local\BraveSoftware\Brave-Browser\User Data"), @('Yandex', "$($pf.FullName)\AppData\Local\Yandex\YandexBrowser\User Data"),
            @('Opera', "$($pf.FullName)\AppData\Roaming\Opera Software\Opera Stable"))
        foreach ($b in $bm) {
            if (-not (Test-Path -LiteralPath $b[1])) { continue }
            $files = @()
            if ($b[0] -eq 'Opera') { $files = @(Get-ChildItem -LiteralPath $b[1] -Filter 'Bookmarks*' -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }) }
            else { $files = @(Get-ChildItem -LiteralPath $b[1] -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(Default|Profile \d+)$' } | ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Filter 'Bookmarks*' -File -ErrorAction SilentlyContinue } | ForEach-Object { $_.FullName }) }
            if ($files.Count) { $items.Add([pscustomobject]@{ Label = ('{0}: закладки {1}' -f $pf.Name, $b[0]); Src = $b[1]; Kind = 'files'; Files = $files; Default = $true; Bytes = $null; Key = ($pf.Name + '\Browser\' + $b[0]) }) }
        }
        $ff = Join-Path $pf.FullName 'AppData\Roaming\Mozilla\Firefox\Profiles'
        if (Test-Path -LiteralPath $ff) {
            $files = @(Get-ChildItem -LiteralPath $ff -Recurse -File -Include 'places.sqlite', 'places.sqlite-wal' -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
            if ($files.Count) { $items.Add([pscustomobject]@{ Label = ('{0}: закладки Firefox' -f $pf.Name); Src = $ff; Kind = 'files'; Files = $files; Default = $true; Bytes = $null; Key = ($pf.Name + '\Browser\Firefox') }) }
        }
    }
    return @($items)
}

function Get-DirBytes {
    # размер папки без копирования (robocopy /L, быстро и безопасно); при неудаче $null
    param([string]$Path)
    $log = Join-Path $G.Temp ('rc_size_' + [guid]::NewGuid().ToString('N') + '.log')
    try {
        $pi2 = New-Object Diagnostics.ProcessStartInfo
        $pi2.FileName = Join-Path $env:SystemRoot 'System32\robocopy.exe'
        $pi2.Arguments = '"' + $Path.TrimEnd('\') + '" "' + (Join-Path $G.Temp 'rc_nul') + '" /L /E /XJ /R:0 /W:0 /NFL /NDL /NJH /NP /BYTES /UNILOG:"' + $log + '"'
        $pi2.UseShellExecute = $false; $pi2.CreateNoWindow = $true
        $pr2 = [Diagnostics.Process]::Start($pi2)
        if (-not $pr2.WaitForExit(120000)) { try { $pr2.Kill() } catch {}; return $null }
        $txt = [IO.File]::ReadAllText($log, [Text.Encoding]::Unicode)
        $rows = @()
        foreach ($l in ($txt -split "`r?`n")) { if ($l -match '^\s*\S+\s*:\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s*$') { $rows += [int64]$Matches[1] } }
        if ($rows.Count -ge 3) { return $rows[2] }   # строки итога: папки, файлы, байты
    } catch {} finally { Remove-Item $log -Force -ErrorAction SilentlyContinue }
    return $null
}

function Show-RescueDialog {
    # Диалог. Возвращает @{ Action='copy'|'skip'; Dest; Items[]; KeepDiskTests } или $null (окно не удалось показать)
    param($Danger, $Items, [string[]]$DangerLetters)
    try { Add-Type -AssemblyName System.Windows.Forms, System.Drawing -ErrorAction Stop } catch { return $null }
    $F = New-Object System.Windows.Forms.Form
    $F.Text = 'PC-Диагностика: сохранение данных'
    $F.StartPosition = 'CenterScreen'; $F.TopMost = $true; $F.FormBorderStyle = 'FixedDialog'; $F.MaximizeBox = $false; $F.MinimizeBox = $false
    $F.ClientSize = New-Object System.Drawing.Size(640, 520)
    $F.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
    $lb = New-Object System.Windows.Forms.Label
    $lb.Location = New-Object System.Drawing.Point(14, 10); $lb.Size = New-Object System.Drawing.Size(612, 88)
    $why = (@($Danger | ForEach-Object { '• ' + $_.Name + ' (' + (($_.Letters) -join ' ') + '): ' + (($_.Reasons | Select-Object -First 2) -join '; ') }) -join "`r`n")
    $lb.Text = "Диск может скоро отказать. Сначала скопировать важные данные?`r`n`r`n" + $why
    $lb.Font = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Bold)
    $F.Controls.Add($lb)
    $cl = New-Object System.Windows.Forms.CheckedListBox
    $cl.Location = New-Object System.Drawing.Point(14, 104); $cl.Size = New-Object System.Drawing.Size(612, 220); $cl.CheckOnClick = $true
    $cl.HorizontalScrollbar = $true
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($it in $Items) { $list.Add($it); $sz = ''; if ($null -ne $it.Bytes) { $sz = '  — {0:N1} ГБ' -f ($it.Bytes / 1GB) }; [void]$cl.Items.Add(($it.Label + $sz), $it.Default) }
    $F.Controls.Add($cl)
    $bAdd = New-Object System.Windows.Forms.Button
    $bAdd.Text = 'Добавить папку…'; $bAdd.Location = New-Object System.Drawing.Point(14, 330); $bAdd.Size = New-Object System.Drawing.Size(150, 28)
    $bAdd.Add_Click({
            try {
                $fb = New-Object System.Windows.Forms.FolderBrowserDialog
                $fb.Description = 'Папка, которую нужно сохранить'
                if ($fb.ShowDialog($F) -eq 'OK') {
                    $by = Get-DirBytes $fb.SelectedPath
                    $it2 = [pscustomobject]@{ Label = $fb.SelectedPath; Src = $fb.SelectedPath; Kind = 'dir'; Files = @(); Default = $true; Bytes = $by; Key = ('Custom\' + ($fb.SelectedPath -replace '[:\\/]+', '_')) }
                    $list.Add($it2)
                    $sz2 = ''; if ($null -ne $by) { $sz2 = '  — {0:N1} ГБ' -f ($by / 1GB) }
                    [void]$cl.Items.Add(($it2.Label + $sz2), $true)
                }
            } catch {}
        }.GetNewClosure())
    $F.Controls.Add($bAdd)
    $l2 = New-Object System.Windows.Forms.Label
    $l2.Text = 'Куда копировать (другой диск или флешка, НЕ проблемный диск):'; $l2.Location = New-Object System.Drawing.Point(14, 366); $l2.Size = New-Object System.Drawing.Size(612, 22)
    $F.Controls.Add($l2)
    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Location = New-Object System.Drawing.Point(14, 390); $tb.Size = New-Object System.Drawing.Size(500, 26)
    # предложение по умолчанию: внешний/другой диск с наибольшим свободным местом, не из списка проблемных
    try {
        $best = Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=2 or DriveType=3' -ErrorAction Stop | Where-Object { $DangerLetters -notcontains $_.DeviceID -and $_.FreeSpace } | Sort-Object { [int64]$_.FreeSpace } -Descending | Select-Object -First 1
        if ($best) { $tb.Text = $best.DeviceID + '\' }
    } catch {}
    $F.Controls.Add($tb)
    $bBr = New-Object System.Windows.Forms.Button
    $bBr.Text = 'Обзор…'; $bBr.Location = New-Object System.Drawing.Point(522, 388); $bBr.Size = New-Object System.Drawing.Size(104, 28)
    $bBr.Add_Click({ try { $fb2 = New-Object System.Windows.Forms.FolderBrowserDialog; $fb2.Description = 'Куда сохранить копию'; if ($fb2.ShowDialog($F) -eq 'OK') { $tb.Text = $fb2.SelectedPath } } catch {} }.GetNewClosure())
    $F.Controls.Add($bBr)
    $ck = New-Object System.Windows.Forms.CheckBox
    $ck.Text = 'Всё равно выполнять нагрузочные тесты диска (риск потери данных!)'; $ck.Location = New-Object System.Drawing.Point(14, 426); $ck.Size = New-Object System.Drawing.Size(612, 24); $ck.Checked = $false
    $F.Controls.Add($ck)
    $bOk = New-Object System.Windows.Forms.Button
    $bOk.Text = 'Скопировать данные'; $bOk.Location = New-Object System.Drawing.Point(14, 466); $bOk.Size = New-Object System.Drawing.Size(200, 36)
    $bOk.Add_Click({
            if (-not $tb.Text -or -not (Test-Path -LiteralPath $tb.Text)) { [void][System.Windows.Forms.MessageBox]::Show($F, 'Укажите существующую папку или диск для копии.', 'Сохранение данных'); return }
            $dl = ([IO.Path]::GetPathRoot($tb.Text)).TrimEnd('\').ToUpper()
            if ($DangerLetters -contains $dl) { [void][System.Windows.Forms.MessageBox]::Show($F, 'Это тот же диск, что и проблемный. Выберите другой диск или флешку.', 'Сохранение данных'); return }
            if ($cl.CheckedIndices.Count -eq 0) { [void][System.Windows.Forms.MessageBox]::Show($F, 'Отметьте хотя бы одну папку.', 'Сохранение данных'); return }
            $F.DialogResult = [System.Windows.Forms.DialogResult]::OK; $F.Close()
        }.GetNewClosure())
    $F.Controls.Add($bOk)
    $bNo = New-Object System.Windows.Forms.Button
    $bNo.Text = 'Не копировать'; $bNo.Location = New-Object System.Drawing.Point(226, 466); $bNo.Size = New-Object System.Drawing.Size(150, 36)
    $bNo.Add_Click({ $F.DialogResult = [System.Windows.Forms.DialogResult]::Cancel; $F.Close() }.GetNewClosure())
    $F.Controls.Add($bNo)
    # на случай, если за компьютером никого нет: через 15 минут — «не копировать»
    $tm = New-Object System.Windows.Forms.Timer
    $tm.Interval = 15 * 60 * 1000
    $tm.Add_Tick({ $tm.Stop(); $F.DialogResult = [System.Windows.Forms.DialogResult]::Cancel; $F.Close() }.GetNewClosure())
    $tm.Start()
    $dr = $F.ShowDialog()
    $tm.Stop()
    $chosen = @()
    if ($dr -eq [System.Windows.Forms.DialogResult]::OK) { foreach ($i in $cl.CheckedIndices) { $chosen += $list[[int]$i] } }
    $r = @{ Action = $(if ($dr -eq [System.Windows.Forms.DialogResult]::OK) { 'copy' } else { 'skip' }); Dest = $tb.Text; Items = $chosen; KeepDiskTests = [bool]$ck.Checked }
    try { $F.Dispose() } catch {}
    return $r
}

function Invoke-RescueCopy {
    # Копирование robocopy в <Dest>\Спасение данных <ПК> <дата>\<ключ>. Возвращает @{ Root; Ok; Failed; Bytes; Files; Log }
    param([string]$Dest, $Items)
    $root = Join-Path $Dest ('Спасение данных {0} {1:yyyy-MM-dd_HH-mm}' -f $env:COMPUTERNAME, (Get-Date))
    New-Item -ItemType Directory -Path $root -Force -ErrorAction Stop | Out-Null
    $rcExe = Join-Path $env:SystemRoot 'System32\robocopy.exe'
    $total = @{ Files = [int64]0; Bytes = [int64]0; Failed = [int64]0; Items = 0; Stopped = $false }
    $idx = 0
    foreach ($it in $Items) {
        $idx++
        if (User-Stopped) { $total.Stopped = $true; break }
        $dst = Join-Path $root ($it.Key)
        New-Item -ItemType Directory -Path $dst -Force -ErrorAction SilentlyContinue | Out-Null
        $log = Join-Path $root ('robocopy_{0}.log' -f $idx)
        if ($it.Kind -eq 'dir') {
            $a = '"' + $it.Src.TrimEnd('\') + '" "' + $dst + '" /E /R:1 /W:1 /MT:8 /XJ /NP /BYTES /UNILOG:"' + $log + '"'
            $runs = @($a)
        } else {
            # только файлы закладок: каждая папка отдельным вызовом, структура профилей сохраняется
            $runs = @()
            foreach ($grp in ($it.Files | Group-Object { Split-Path $_ -Parent })) {
                $sub = $grp.Name.Substring([math]::Min($grp.Name.Length, $it.Src.Length)).TrimStart('\')
                $names = ($grp.Group | ForEach-Object { '"' + (Split-Path $_ -Leaf) + '"' }) -join ' '
                $runs += ('"' + $grp.Name + '" "' + (Join-Path $dst $sub) + '" ' + $names + ' /R:1 /W:1 /NP /BYTES /UNILOG+:"' + $log + '"')
            }
        }
        Info ('копирую [{0}/{1}]: {2}' -f $idx, @($Items).Count, $it.Label)
        foreach ($argLine in $runs) {
            $psi = New-Object Diagnostics.ProcessStartInfo
            $psi.FileName = $rcExe; $psi.Arguments = $argLine; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
            $p = $null
            try { $p = [Diagnostics.Process]::Start($psi) } catch { $G.Log.Add('rescue: ' + $_.Exception.Message); continue }
            try { $p.PriorityClass = 'BelowNormal' } catch {}
            $t0 = Get-Date; $pos = [int64]0; $nfiles = 0; $lastName = ''
            while (-not $p.HasExited) {
                Start-Sleep -Milliseconds 1500
                if (User-Stopped) { try { $p.Kill() } catch {}; $total.Stopped = $true; break }
                try {
                    $fs = [IO.File]::Open($log, 'Open', 'Read', 'ReadWrite')
                    try {
                        if ($fs.Length -gt $pos) {
                            [void]$fs.Seek($pos, 'Begin')
                            $buf = New-Object byte[] ([int][math]::Min(1MB, $fs.Length - $pos))
                            $n = $fs.Read($buf, 0, $buf.Length); $pos += $n
                            foreach ($ln in ([Text.Encoding]::Unicode.GetString($buf, 0, $n) -split "`r?`n")) { if ($ln -match '^\s+(New File|Newer|Older|Новый файл|Новее|Старее|Same|Тот же)?\s*\d+\s+(.+\\)?([^\\]+)$') { $nfiles++; $lastName = $Matches[3] } }
                        }
                    } finally { $fs.Close() }
                } catch {}
                $nm = $lastName; if ($nm.Length -gt 38) { $nm = $nm.Substring(0, 37) + '…' }
                Write-Host -NoNewline ("`r    {0,5:N0} с | файлов ~{1,7} | {2,-40}" -f ((Get-Date) - $t0).TotalSeconds, $nfiles, $nm)
                if (((Get-Date) - $t0).TotalHours -gt 8) { try { $p.Kill() } catch {}; break }
            }
            Write-Host ''
            try { $p.WaitForExit() } catch {}
        }
        $total.Items++
        # итог по логу: Dirs/Files/Bytes — Total, Copied, Skipped, Mismatch, FAILED, Extras
        try {
            $txt = [IO.File]::ReadAllText($log, [Text.Encoding]::Unicode)
            $rows = @(); foreach ($ln in ($txt -split "`r?`n")) { if ($ln -match '^\s*\S+\s*:\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s*$') { $rows += , @([int64]$Matches[1], [int64]$Matches[2], [int64]$Matches[3], [int64]$Matches[4], [int64]$Matches[5]) } }
            # строки итога идут по порядку Dirs, Files, Bytes (после них строка времени, не совпадающая с шаблоном); при нескольких запусках — суммируем по тройкам
            for ($k = 0; $k + 2 -lt $rows.Count; $k += 3) { $total.Files += $rows[$k + 1][1]; $total.Bytes += $rows[$k + 2][1]; $total.Failed += $rows[$k + 1][4] }
        } catch {}
    }
    return @{ Root = $root; Files = $total.Files; Bytes = $total.Bytes; Failed = $total.Failed; Items = $total.Items; Stopped = $total.Stopped }
}
