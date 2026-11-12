# How to write a PC-Diagnostika module (PowerShell 5.1, runs as admin, Windows 10/11)

The program is ONE PowerShell script (`body.ps1`) built into `PC-Diagnostika.cmd` by `build.sh`.
Modules are files `modules/<anchor>-NN-name.ps1`; `build.sh` inlines them (alphabetically) at the line `#%%MOD:<anchor>%%`.
Anchors (execution order):
- `lib`   — before any step; define functions, `$TOOLS.X = @{...}`, `$STEPKEYS[...]`, `$G.PresetHooks.Add({param($full) ...})`.
- `early` — before 'Система, материнская плата, BIOS' (sensors started, nothing else yet).
- `hw`    — after static hardware info steps (CPU/RAM/GPU/Storage/Battery info), before 'Устройства и драйверы'.
- `logs`  — after 'Журналы ошибок за 30 дней', before 'Сеть и интернет'.
- `stress`— after FurMark GPU stress, before Defender scan (all heavy tests live here).
- `final` — before 'Завершение' (report/score are computed after it; good place for cross-checks/prognosis).

## Rules (IMPORTANT)
- PowerShell variable names are CASE-INSENSITIVE. EVEN INSIDE a Step/function, `$g = ...` or `foreach ($g in ...)` creates a local that SHADOWS the global `$G` for the rest of that scope (=> `$G.Log` becomes null). Never name any variable g, ic, sb, cs, out, verdict, score, crit, warn, meta, VER, TOOLS, STEPKEYS, UPLOAD. build.sh rejects `$g`. NEVER create script-scope vars named `$g`, `$ic`, `$sb`, `$out`, `$cs`, `$s` etc. at top level of a module (they clobber globals `$G`, `$IC`, `$sb`...). Put code inside `Step '...' { }` (runs in a child scope via `& $Body`) or `& { ... }`.
- No `try` inside expressions (PS 5.1 can't). No ternary `?:`, no `??`.
- Must work on Windows PowerShell 5.1 (no PS7 features). Use `-ErrorAction SilentlyContinue/Stop` + try/catch.
- Russian user-facing text, short and practical (a PC repair technician + the PC owner read it).
- Never modify the user's system state (no installs, no settings changes, no writes to disks under test) except temp files in `$G.Temp`.
- Numbers to text: `'{0:N1}' -f $x`. Parse invariant: `[double]::Parse($s, $IC)`.

## API
- `Step 'Название шага' { ... }` — prints a title, times it, catches errors. If `$STEPKEYS['Название шага'] = 'key'` is set, the step runs only when `$G.Sel.key` is true (user selection). Steps without a key always run.
- `$s = New-Section 'Заголовок'` — a report section.
- `Add-Row $s 'Ключ' 'Значение' 'ok'|'warn'|'crit'|''` — a key/value row (status colors it).
- `Add-Table $s 'Заголовок' $arrayOfPSCustomObjects [-Collapsed]` — a table (property names = column headers).
- `Add-Issue 'crit'|'warn'|'info' 'Область' 'что найдено' 'что делать'` — a problem for the summary; Areas used: Процессор, Охлаждение, Память, Видеокарта, Накопитель, Питание, Стабильность, Windows, Безопасность, Программы, Сеть, Устройства, BIOS, Аккумулятор.
- `Info 'text'`, `Ok 'text'`, `Warn 'text'` — console log lines.
- `CIM 'Win32_Class' [ns] [filter]` — Get-CimInstance wrapper returning array (never throws).
- `Get-Tool 'Name'` — downloads+verifies a tool from `$TOOLS.Name = @{ Url=...; Sha='UPPERCASE SHA256'; Dir='folder' (zip→extract) or '' (single exe); Exe='relative\path.exe' }`, returns full exe path or $null.
- `Read-Key` — current sensors: `.CpuTemp .CpuPower .CpuClock .GpuTemp .GpuHot .GpuMemT .GpuPower .GpuClock .GpuLoad .GpuFan .V12 .V5 .V33 .Vcore .FanMin` (any may be $null). Calling it also feeds the black-box recorder during stress steps.
- `Get-AllSensors` — list of `[pscustomobject]@{HwType; Hw; Type; Name; Value}` from LibreHardwareMonitor (HwType: Cpu, GpuNvidia, GpuAmd, Motherboard (SuperIO sub-hw included), Storage, Memory...; Type: Temperature, Fan, Control, Voltage, Power, Clock, Load, Data...). `Pick $list $hwRe $type $nameRe [-Max|-Avg]`.
- `$G.Sel.<key>` — user selection (bools) and durations (ints). `$G.IsLaptop`, `$G.Summary['Процессор'|'Материнская плата'|'Накопители'|'Windows'...]`, `$G.Temp`, `$G.Root`, `$G.Num.<metric>` (numbers sent to the stats server), `$G.Log.Add('...')` (technical log).
- New user-selectable test: add `$STEPKEYS[...]='key'` + `$G.PresetHooks.Add({ param($full) $G.Sel.key = ... })` in a `lib-` module; UI checkbox is added separately in ui.cs by the maintainer (tell him the key).
- Console progress inside loops: `Write-Host -NoNewline ("`r    {0,4:N0} с | ..." -f ...)` then `Write-Host ''`.
- See existing modules in this folder for style (e.g. logs-20-gpu-events.ps1, stress-30-psu.ps1).
