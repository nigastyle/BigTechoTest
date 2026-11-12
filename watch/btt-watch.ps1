# BTT-Watch: фоновый наблюдатель за окнами ошибок и диалогами (UI Automation), пишет в %LOCALAPPDATA%\BTT\dialogs.log
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$dir = Join-Path $env:LOCALAPPDATA 'BTT'; New-Item -ItemType Directory -Force $dir | Out-Null
$log = Join-Path $dir 'dialogs.log'
$seen = @{}
$root = [System.Windows.Automation.AutomationElement]::RootElement
$cond = [System.Windows.Automation.Condition]::TrueCondition
while ($true) {
    try {
        $now = @{}
        foreach ($w in $root.FindAll([System.Windows.Automation.TreeScope]::Children, $cond)) {
            try {
                $c = $w.Current
                if ($c.IsOffscreen) { continue }
                $cls = "$($c.ClassName)"; $title = "$($c.Name)"
                $r = $c.BoundingRectangle
                # только окна-сообщения: небольшой диалог (#32770 или любой класс) размером с MessageBox
                if (-not ($r.Width -gt 0 -and $r.Width -lt 760 -and $r.Height -lt 480)) { continue }
                if ($cls -ne '#32770' -and $title -notmatch '(?i)ошибк|error|внимание|warning|предупрежд|не удалось|failed|exception|сбой|crash') { continue }
                $texts = @()
                foreach ($e in $w.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)) {
                    $n = "$($e.Current.Name)"; if ($n -and $n.Length -lt 600 -and $texts -notcontains $n) { $texts += $n }
                    if ($texts.Count -ge 25) { break }
                }
                $pn = ''; try { $pn = (Get-Process -Id $c.ProcessId -ErrorAction Stop).ProcessName } catch {}
                $btn = @($texts | Where-Object { $_ -match '^(OK|ОК|Да|Нет|Yes|No|Отмена|Cancel|Прервать|Повтор|Пропустить|Abort|Retry|Ignore|Закрыть|Close|Продолжить)$' }).Count
                # текст окон программ с правами администратора может не читаться — тогда пишем хотя бы заголовок
                if ($btn -eq 0 -and $texts.Count -gt 3 -and $title -notmatch '(?i)ошибк|error|внимание|warning|сбой|awe|module') { continue }
                $key = "$($c.NativeWindowHandle)|$title"
                $now[$key] = 1
                if (-not $seen.ContainsKey($key)) {
                    $line = '{0:yyyy-MM-dd HH:mm:ss} | {1} | {2} | {3} | {4}' -f (Get-Date), $pn, $cls, $title, ($texts -join ' / ')
                    Add-Content -Path $log -Value $line -Encoding UTF8
                }
            } catch {}
        }
        $seen = $now
        if ((Get-Item $log -ErrorAction SilentlyContinue).Length -gt 2MB) { Move-Item $log "$log.1" -Force }
    } catch {}
    Start-Sleep -Seconds 2
}
