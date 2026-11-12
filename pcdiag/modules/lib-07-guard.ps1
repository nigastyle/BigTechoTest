# ---------------------------------------------------------------- сторож датчиков (DiagGuard)
# Во время стресс-тестов отдельный поток раз в секунду опрашивает LibreHardwareMonitor и при любой аномалии
# (перегрев CPU/GPU/VRM/ОЗУ/накопителя, напряжения вне допуска, остановка вентилятора CPU, аномальная мощность)
# СРАЗУ останавливает все тесты: убивает зарегистрированные процессы + стресс-программы по имени + DiagCore.
# Потом PowerShell показывает причину (Guard-Report) и спрашивает, продолжать ли на свой риск (Guard-Ask).
# Выключить: $env:DIAG_NOGUARD=1. Без LHM сторож не работает, Step ведёт себя как раньше.
# Компиляция ленивая (при первом Guard-Arm): на момент lib-модулей датчики ещё не запущены.
$G.GuardOk = $false; $G.GuardTried = $false
$G.GuardStopped = $false; $G.GuardStopReason = ''; $G.GuardBlind = $false; $G.GuardPreChecked = $false
$G.GuardReportedTrip = 0; $G.GuardSection = $null
$G.GuardOverride = New-Object System.Collections.Generic.List[string]
$G.GuardSkipped = New-Object System.Collections.Generic.List[string]
# ключи шагов, которые охраняет сторож (и пропускает после остановки)
$G.GuardStress = @('_cpu', 'ycr', 'ram', 'gpu', 'psu', 'vram', 'surface', 'cpu', 'disk', 'linpack', 'tm5')
# шаги с теми же ключами, которые только разбирают данные (их не пропускаем и не охраняем)
$G.GuardNoStress = @('Видеокарта: питание, троттлинг, шина PCIe')
$G.GuardSrc = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using LibreHardwareMonitor.Hardware;

public static class DiagGuard {
    // Общий замок для Update() датчиков LHM (библиотека не потокобезопасна): PowerShell берёт его в Get-AllSensors.
    public static readonly object SensorLock = new object();

    public static volatile bool Tripped;
    public static volatile bool Armed;
    public static string Reason = "";
    public static string Category = "";
    public static string Snapshot = "";
    public static string Advice = "";
    public static string LastTest = "";
    public static string LastError = "";
    public static DateTime TripTime = DateTime.MinValue;
    public static int TripCount;
    public static int Samples;
    public static int Missed;

    static readonly object stateLock = new object();
    static readonly object tripLock = new object();
    static readonly object pidLock = new object();
    static readonly List<int> pids = new List<int>();
    static readonly HashSet<string> ignored = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
    static readonly List<string> notes = new List<string>();
    static readonly HashSet<string> noteKeys = new HashSet<string>();
    static int notesTaken;

    static Thread thread;
    static ManualResetEvent stopEvt;
    static IComputer comp;
    static volatile string lastSnap = "";
    static int postKill;

    // состояние за период охраны
    static Dictionary<string, int> streak = new Dictionary<string, int>();
    static Dictionary<string, double> firstVal = new Dictionary<string, double>();
    static HashSet<string> bogus = new HashSet<string>();
    static List<string> mxOrder = new List<string>();
    static Dictionary<string, double> mxVal = new Dictionary<string, double>();
    static Dictionary<string, string> mxFmt = new Dictionary<string, string>();
    static Dictionary<string, bool> mxIsMin = new Dictionary<string, bool>();
    static List<string> curList = new List<string>();
    static string cpuName;
    static double cpuTrip, cpuLimitShown;
    static string cpuLimitText = "";
    static bool cpuTjFound;
    static double tjParam;
    static bool cpuSeen;
    static int cpuMissing;
    static Dictionary<string, double> fanBase;
    static string pendReason, pendCat, pendAdvice;

    static CultureInfo ru;
    static readonly Regex CpuPrimRe = new Regex(@"^(CPU Package|Core \(Tctl/Tdie\)|Core \(Tdie\)|Core \(Tctl\)|Core Max|CPU Core Max|Tctl|Tdie|Package)$");
    static readonly Regex VcoreCpuRe = new Regex(@"^(CPU Core|Core \(SVI2 TFN\)|Core \(SVI3 TFN\))$");
    static readonly Regex VcoreMbRe = new Regex(@"(?i)^(CPU )?V ?core$");
    static readonly Regex R12 = new Regex(@"(^|\+)12 ?V");
    static readonly Regex R5 = new Regex(@"(^|\+)5 ?V");
    static readonly Regex R33 = new Regex(@"(^|\+)3\.3 ?V|^3VCC$|^VCC3V$|^AVCC$");
    static readonly Regex StbyRe = new Regex(@"(?i)standby|sb|stby");
    static readonly Regex StbyDualRe = new Regex(@"(?i)standby|sb|stby|dual");
    static readonly Regex VrmRe = new Regex(@"(?i)VRM|MOS");
    static readonly Regex ChipRe = new Regex(@"(?i)chipset|PCH|^System|motherboard|^MB$");
    static readonly Regex GenTempRe = new Regex(@"^Temperature #\d+$");
    static readonly Regex DiskTempRe = new Regex(@"^(Composite )?Temperature$");
    static readonly Regex HddRe = new Regex(@"(?i)^(WDC ?WD\d|WD\d{2,}[A-Z]{2}|ST\d{3,}|TOSHIBA (DT|MQ|MG|MD|HDW)|HGST|Hitachi|HDS\d|HTS\d|HUS\d|HDW|SAMSUNG (HD|SP|HM)\d|Maxtor|MQ0\d|DT01)");
    static readonly Regex GpuPwrRe = new Regex(@"^(GPU Package|GPU Power|GPU Board Power|GPU Board)$");
    static readonly Regex CpuPwrRe = new Regex(@"^(CPU Package|Package)$");
    static readonly Regex StressNameRe = new Regex(@"(?i)^(prime95|furmark|y-cruncher.*|\d{2}-[A-Za-z0-9_]+ ~ .*|memtest_vulkan.*|linpack.*|cinebench.*|testmem5|tm5|diskspd)$");
    static readonly Regex AmdMobileRe = new Regex(@"(?i)\b\d{4}(U|H|HS|HX|HX3D)\b|Ryzen AI|Mobile|\bZ\d\b");
    static readonly Regex AmdZen4Re = new Regex(@"(?i)Ryzen \d+ (PRO )?([79]\d{3}|8\d{3}G)");
    static readonly Regex AmdOldRe = new Regex(@"(?i)Ryzen \d+ (PRO )?[1-5]\d{3}|Threadripper");

    class Rd {
        public string Top, Sub, Hw, Id, Type, Name;
        public double V;
    }

    static DiagGuard() {
        try { ru = CultureInfo.GetCultureInfo("ru-RU"); } catch { ru = CultureInfo.InvariantCulture; }
    }

    // ------------------------------------------------------------ управление
    public static bool Arm(object computer, string testName) {
        IComputer c = computer as IComputer;
        if (c == null) return false;
        Disarm();
        lock (stateLock) {
            streak = new Dictionary<string, int>();
            firstVal = new Dictionary<string, double>();
            bogus = new HashSet<string>();
            mxOrder = new List<string>();
            mxVal = new Dictionary<string, double>();
            mxFmt = new Dictionary<string, string>();
            mxIsMin = new Dictionary<string, bool>();
            curList = new List<string>();
            cpuName = null; cpuTrip = 0; cpuLimitShown = 0; cpuLimitText = ""; cpuTjFound = false; tjParam = 0;
            cpuSeen = false; cpuMissing = 0; fanBase = null;
            Samples = 0; Missed = 0; postKill = 0;
        }
        lock (pidLock) { pids.Clear(); }
        comp = c;
        LastTest = testName == null ? "" : testName;
        lastSnap = "";
        stopEvt = new ManualResetEvent(false);
        Thread t = new Thread(Loop);
        t.IsBackground = true;
        t.Name = "DiagGuard";
        t.Priority = ThreadPriority.AboveNormal;
        thread = t;
        Armed = true;
        t.Start();
        return true;
    }

    public static void Disarm() {
        Armed = false;
        ManualResetEvent e = stopEvt;
        if (e != null) { try { e.Set(); } catch { } }
        Thread t = thread;
        if (t != null && t != Thread.CurrentThread) { try { t.Join(5000); } catch { } }
        thread = null;
    }

    public static void Reset() {
        lock (tripLock) {
            Tripped = false;
            Reason = ""; Category = ""; Snapshot = ""; Advice = "";
        }
        lock (stateLock) { streak = new Dictionary<string, int>(); postKill = 0; }
    }

    public static void IgnoreCategory(string category) {
        if (string.IsNullOrEmpty(category)) return;
        lock (ignored) { ignored.Add(category); }
    }
    public static void ClearIgnored() { lock (ignored) { ignored.Clear(); } }
    public static bool IsIgnored(string category) {
        if (string.IsNullOrEmpty(category)) return false;
        lock (ignored) { return ignored.Contains(category); }
    }
    public static string Ignored { get { lock (ignored) { return string.Join(",", new List<string>(ignored).ToArray()); } } }

    public static void RegisterProcess(int pid) {
        if (pid <= 0) return;
        lock (pidLock) { if (!pids.Contains(pid)) pids.Add(pid); }
        if (Tripped) KillTree(pid);   // тест запустили уже после остановки — гасим сразу
    }
    public static void UnregisterProcess(int pid) { lock (pidLock) { pids.Remove(pid); } }

    // Внешняя остановка (например, модуль HWiNFO). Потокобезопасно, срабатывает только первая.
    public static void Trip(string reason, string category, string snapshot) {
        if (IsIgnored(category)) { AddNote("ext:" + category + ":" + reason, "(пропущено по решению пользователя) " + reason); return; }
        if (DoTrip(reason, category, snapshot, null)) KillAll();
    }

    public static string Notes { get { lock (notes) { return string.Join("; ", notes.ToArray()); } } }
    public static string[] TakeNotes() {
        lock (notes) {
            List<string> r = new List<string>();
            for (int i = notesTaken; i < notes.Count; i++) r.Add(notes[i]);
            notesTaken = notes.Count;
            return r.ToArray();
        }
    }

    public static string MaxSummary {
        get {
            lock (stateLock) {
                List<string> p = new List<string>();
                foreach (string k in mxOrder) {
                    bool isMin = mxIsMin[k];
                    p.Add(k + (isMin ? " мин. " : " макс. ") + string.Format(ru, mxFmt[k], mxVal[k]));
                }
                return string.Join("; ", p.ToArray());
            }
        }
    }

    // ------------------------------------------------------------ поток
    static void Loop() {
        try {
            ManualResetEvent ev = stopEvt;
            IComputer c = comp;
            while (true) {
                int t0 = Environment.TickCount;
                try { Sample(c); } catch (Exception ex) { LastError = ex.Message; }
                int w = 1000 - (Environment.TickCount - t0);
                if (w < 50) w = 50;
                if (ev.WaitOne(w)) break;
            }
        } catch (Exception ex) { LastError = ex.Message; }
    }

    static void Sample(IComputer c) {
        List<Rd> rd = new List<Rd>(256);
        if (!Monitor.TryEnter(SensorLock, 3000)) { Interlocked.Increment(ref Missed); return; }
        try {
            List<IHardware> hws = new List<IHardware>();
            try { foreach (IHardware h in c.Hardware) hws.Add(h); } catch { }
            foreach (IHardware h in hws) {
                if (h == null) continue;
                try { h.Update(); } catch { }
                IHardware[] subs = null;
                try { subs = h.SubHardware; } catch { }
                if (subs != null) foreach (IHardware sh in subs) { if (sh != null) { try { sh.Update(); } catch { } } }
                Collect(h, h, rd);
                if (subs != null) foreach (IHardware sh in subs) { if (sh != null) Collect(h, sh, rd); }
            }
        } finally { Monitor.Exit(SensorLock); }
        Interlocked.Increment(ref Samples);

        bool trip = false;
        lock (stateLock) {
            pendReason = null;
            Evaluate(rd);
            if (pendReason != null) trip = DoTrip(pendReason, pendCat, null, pendAdvice);
        }
        if (trip) { KillAll(); return; }
        if (Tripped && postKill < 5) { postKill++; KillByName(); }   // добиваем перезапуски
    }

    static void Collect(IHardware top, IHardware hw, List<Rd> rd) {
        string topT = "", subT = "", id = "", name = "";
        try { topT = top.HardwareType.ToString(); subT = hw.HardwareType.ToString(); name = hw.Name; } catch { }
        try { id = hw.Identifier.ToString(); } catch { }
        ISensor[] ss = null;
        try { ss = hw.Sensors; } catch { }
        if (ss == null) return;
        foreach (ISensor s in ss) {
            if (s == null) continue;
            // пороги и уставки датчиков (DDR5 «Thermal Sensor Critical High Limit», «Warning Temperature» NVMe) — не показания
            string sn0 = s.Name == null ? "" : s.Name;
            if (Regex.IsMatch(sn0, @"(?i)\blimit\b|threshold|resolution|warning temperature|critical temperature|distance to tjmax")) { if (!sn0.Contains("Distance")) continue; }
            float? v = null;
            try { v = s.Value; } catch { }
            if (!v.HasValue) continue;
            double d = v.Value;
            if (double.IsNaN(d) || double.IsInfinity(d)) continue;
            Rd r = new Rd();
            r.Top = topT; r.Sub = subT; r.Hw = name; r.Id = id;
            r.Type = s.SensorType.ToString(); r.Name = s.Name == null ? "" : s.Name; r.V = d;
            if (tjParam == 0 && topT == "Cpu" && r.Type == "Temperature") {
                try {
                    foreach (IParameter p in s.Parameters) {
                        if (p != null && p.Name != null && p.Name.IndexOf("TjMax", StringComparison.OrdinalIgnoreCase) >= 0 && p.Value > 60 && p.Value < 130) { tjParam = Math.Round(p.Value); break; }
                    }
                } catch { }
            }
            rd.Add(r);
        }
    }

    // ------------------------------------------------------------ оценка
    static bool IsBoard(Rd r) {
        return r.Top == "Motherboard" || r.Top == "SuperIO" || r.Top == "EmbeddedController" || r.Sub == "SuperIO" || r.Sub == "EmbeddedController";
    }
    static bool BogusCode(double v) {
        return Math.Abs(v - 127) < 0.01 || Math.Abs(v - 128) < 0.01 || Math.Abs(v - 255) < 0.01 || Math.Abs(v + 128) < 0.01;
    }
    static string F(double v, int dec) { return v.ToString("F" + dec, ru); }

    static void Cur(string label, double v, string unit, int dec, bool isMin) {
        string fmt = "{0:F" + dec + "}" + unit;
        curList.Add(label + " " + string.Format(ru, fmt, v));
        double old;
        if (!mxVal.TryGetValue(label, out old)) {
            mxOrder.Add(label); mxVal[label] = v; mxFmt[label] = fmt; mxIsMin[label] = isMin;
        } else if (isMin ? v < old : v > old) mxVal[label] = v;
    }

    static void AddNote(string key, string text) {
        lock (notes) {
            if (noteKeys.Contains(key)) return;
            noteKeys.Add(key);
            notes.Add(DateTime.Now.ToString("HH:mm:ss") + " " + text);
        }
    }

    // bad: за пределом; cata: мгновенно; hard: остановка даже если пользователь разрешил игнорировать категорию
    static void Check(string key, string cat, bool bad, bool cata, bool hard, int need, string reason, string advice) {
        int n;
        streak.TryGetValue(key, out n);
        if (!bad) { if (n != 0) streak[key] = 0; return; }
        n++; streak[key] = n;
        if (pendReason != null) return;
        if (IsIgnored(cat)) {
            if (!hard || n < 2) return;
            reason = reason + " (сверх допуска, разрешённого пользователем)";
        } else if (!cata && n < need) return;
        pendReason = reason; pendCat = cat; pendAdvice = advice;
    }

    // первый замер значения датчика: если он уже «за пределом» в начале теста — скорее всего, датчик врёт
    static bool Suspect(string key, double v, double limit, string label) {
        if (bogus.Contains(key)) return true;
        double f;
        if (!firstVal.TryGetValue(key, out f)) {
            firstVal[key] = v;
            if (v >= limit) {
                bogus.Add(key);
                AddNote("bogus:" + key, label + " показывает " + F(v, 0) + " °C уже в начале теста — вероятно, неисправный/неверно подписанный датчик, по нему тест не останавливаем");
                return true;
            }
        }
        return false;
    }

    static void InitCpuLimits(double tjDist) {
        string n = cpuName == null ? "" : cpuName;
        bool amd = Regex.IsMatch(n, @"(?i)AMD|Ryzen|Threadripper|EPYC|Athlon");
        if (!amd) {
            double tj = tjDist > 0 ? tjDist : (tjParam > 0 ? tjParam : 100);
            cpuLimitShown = tj; cpuTrip = tj - 2;
            cpuLimitText = "предел для этой модели " + F(tj, 0) + " °C";
            return;
        }
        if (AmdMobileRe.IsMatch(n)) { cpuTrip = 99; cpuLimitShown = 100; cpuLimitText = "предел для ноутбучного процессора около 100 °C"; }
        else if (AmdZen4Re.IsMatch(n)) { cpuTrip = 97; cpuLimitShown = 95; cpuLimitText = "этот процессор рассчитан работать до 95 °C"; }
        else if (AmdOldRe.IsMatch(n)) { cpuTrip = 93; cpuLimitShown = 90; cpuLimitText = "предел для этой серии 90–95 °C"; }
        else { cpuTrip = 98; cpuLimitShown = 100; cpuLimitText = "обычный предел процессоров около 100 °C"; }    }
    static void ApplyTestOverride() {
        // только для проверки самой программы: DIAG_GUARD_CPU=55 — сработать уже при 55 °C
        string ov = Environment.GetEnvironmentVariable("DIAG_GUARD_CPU");
        double v;
        if (!string.IsNullOrEmpty(ov) && double.TryParse(ov, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out v) && v > 30) { cpuTrip = v; cpuLimitShown = v; cpuLimitText = "ТЕСТОВЫЙ порог " + F(v, 0) + " °C"; }
    }

    static void Evaluate(List<Rd> rd) {
        curList = new List<string>();
        // ---- процессор
        double cpuT = -1, cpuTf = -1, cpuP = -1, vcore = -1, vcoreMb = -1;
        bool hasTdie = false;
        Dictionary<string, double> ctemps = new Dictionary<string, double>();
        Dictionary<string, double> dist = new Dictionary<string, double>();
        foreach (Rd r in rd) if (r.Top == "Cpu" && r.Type == "Temperature" && r.Name == "Core (Tdie)") hasTdie = true;
        foreach (Rd r in rd) {
            if (r.Top != "Cpu") continue;
            if (cpuName == null && !string.IsNullOrEmpty(r.Hw)) cpuName = r.Hw;
            if (r.Type == "Temperature") {
                if (r.Name.EndsWith(" Distance to TjMax")) { dist[r.Name.Substring(0, r.Name.Length - 18)] = r.V; continue; }
                if (r.V < 5 || r.V > 130) continue;
                if (!ctemps.ContainsKey(r.Name)) ctemps[r.Name] = r.V;
                if (CpuPrimRe.IsMatch(r.Name) && !(hasTdie && r.Name == "Core (Tctl)")) { if (r.V > cpuT) cpuT = r.V; }
                else if (r.Name.IndexOf("Core", StringComparison.OrdinalIgnoreCase) >= 0 || r.Name.StartsWith("CCD")) { if (r.V > cpuTf) cpuTf = r.V; }
            } else if (r.Type == "Power" && CpuPwrRe.IsMatch(r.Name)) { if (r.V > cpuP) cpuP = r.V; }
            else if (r.Type == "Voltage" && vcore < 0 && VcoreCpuRe.IsMatch(r.Name) && r.V > 0.3 && r.V < 2) vcore = r.V;
        }
        if (cpuT < 0) cpuT = cpuTf;
        if (!cpuTjFound) {
            double tjd = 0;
            foreach (KeyValuePair<string, double> kv in dist) {
                double t;
                if (ctemps.TryGetValue(kv.Key, out t)) { double tj = Math.Round(t + kv.Value); if (tj >= 80 && tj <= 115) { tjd = tj; break; } }
            }
            if (tjd > 0) { cpuTjFound = true; InitCpuLimits(tjd); ApplyTestOverride(); }
            else if (cpuTrip == 0 && cpuName != null) { InitCpuLimits(0); ApplyTestOverride(); }
        }
        if (cpuTrip == 0) { InitCpuLimits(0); ApplyTestOverride(); }

        // ---- плата: напряжения, вентиляторы, температуры
        double v12 = -1, v5 = -1, v33 = -1;
        List<Rd> boardT = new List<Rd>();
        List<Rd> fans = new List<Rd>();
        foreach (Rd r in rd) {
            if (!IsBoard(r)) continue;
            if (r.Type == "Voltage") {
                double v = r.V; string n = r.Name;
                if (R12.IsMatch(n) && !StbyRe.IsMatch(n) && v > 9 && v < 15) { if (v12 < 0) v12 = v; }
                else if (R5.IsMatch(n) && !StbyRe.IsMatch(n) && v > 4 && v < 6) { if (v5 < 0) v5 = v; }
                else if (R33.IsMatch(n) && !StbyDualRe.IsMatch(n) && v > 2.8 && v < 3.8) { if (v33 < 0) v33 = v; }
                else if (VcoreMbRe.IsMatch(n) && v > 0.3 && v < 2) { if (vcoreMb < 0) vcoreMb = v; }
            } else if (r.Type == "Fan") { if (r.V >= 0 && r.V < 20000) fans.Add(r); }
            else if (r.Type == "Temperature") boardT.Add(r);
        }
        if (vcore < 0) vcore = vcoreMb;

        // ---- видеокарты
        double gCore = -1, gHot = -1, gMem = -1, gPow = -1;
        bool gAmd = false;
        foreach (Rd r in rd) {
            if (!r.Top.StartsWith("Gpu")) continue;
            bool amd = r.Top == "GpuAmd";
            if (r.Type == "Temperature" && r.V > 5 && r.V < 150) {
                if (r.Name == "GPU Core") { if (r.V > gCore) gCore = r.V; }
                else if (r.Name == "GPU Hot Spot") { if (r.V > gHot) { gHot = r.V; } }
                else if (r.Name == "GPU Memory Junction" || (amd && r.Name == "GPU Memory")) { if (r.V > gMem) gMem = r.V; }
                if (amd) gAmd = true;
            } else if (r.Type == "Power" && GpuPwrRe.IsMatch(r.Name)) { if (r.V > gPow) gPow = r.V; }
            else if (r.Type == "Voltage" && r.Name == "GPU Core" && r.V > 1.15 && r.V < 3) AddNote("gpuv", "напряжение ядра видеокарты " + F(r.V, 3) + " В (выше 1,15 В — проверьте разгон)");
        }

        // ---- ОЗУ и накопители
        double ramT = -1; string ramKey = null;
        double diskWorst = -999, diskT = -1, diskLim = 0; string diskName = null;
        foreach (Rd r in rd) {
            if (r.Type != "Temperature" || r.V < 5 || r.V > 120 || BogusCode(r.V)) continue;
            if (r.Top == "Memory") {
                string k = "ram:" + r.Hw + ":" + r.Name;
                if (Suspect(k, r.V, 85, "Датчик памяти «" + r.Name + "»")) continue;
                if (r.V > ramT) { ramT = r.V; ramKey = r.Name; }
            } else if (r.Top == "Storage" && DiskTempRe.IsMatch(r.Name)) {
                bool nvme = r.Id.IndexOf("nvme", StringComparison.OrdinalIgnoreCase) >= 0 || r.Hw.IndexOf("NVMe", StringComparison.OrdinalIgnoreCase) >= 0;
                bool hdd = !nvme && HddRe.IsMatch(r.Hw) && r.Hw.IndexOf("SSD", StringComparison.OrdinalIgnoreCase) < 0;
                double lim = hdd ? 60 : 82;
                string k = "disk:" + r.Id + ":" + r.Name;
                if (Suspect(k, r.V, lim, "Накопитель «" + r.Hw + "»")) continue;
                if (r.V - lim > diskWorst) { diskWorst = r.V - lim; diskT = r.V; diskLim = lim; diskName = r.Hw; }
            }
        }

        // ---- текущие значения (снимок) и максимумы
        if (cpuT >= 0) Cur("CPU", cpuT, " °C", 0, false);
        if (cpuP >= 0) Cur("CPU мощность", cpuP, " Вт", 0, false);
        if (vcore >= 0) Cur("Vcore", vcore, " В", 3, false);
        if (gCore >= 0) Cur("GPU", gCore, " °C", 0, false);
        if (gHot >= 0) Cur("GPU горячая точка", gHot, " °C", 0, false);
        if (gMem >= 0) Cur("GPU память", gMem, " °C", 0, false);
        if (gPow >= 0) Cur("GPU мощность", gPow, " Вт", 0, false);
        if (v12 >= 0) Cur("+12V", v12, " В", 2, true);
        if (v5 >= 0) Cur("+5V", v5, " В", 2, true);
        if (v33 >= 0) Cur("+3.3V", v33, " В", 2, true);
        if (ramT >= 0) Cur("ОЗУ", ramT, " °C", 0, false);
        if (diskT >= 0) Cur("Накопитель", diskT, " °C", 0, false);

        // ---- вентиляторы: база при первом замере
        if (fanBase == null && fans.Count > 0) {
            fanBase = new Dictionary<string, double>();
            foreach (Rd f in fans) {
                bool cand = f.Name.IndexOf("CPU", StringComparison.OrdinalIgnoreCase) >= 0 || f.Name == "Fan #1" || f.Name == "Fan #2";
                if (cand && f.V > 300 && !fanBase.ContainsKey(f.Name)) fanBase[f.Name] = f.V;
            }
        }
        double fanMin = -1;
        if (fanBase != null) foreach (Rd f in fans) if (fanBase.ContainsKey(f.Name) && (fanMin < 0 || f.V < fanMin)) fanMin = f.V;
        if (fanMin >= 0) Cur("Вентилятор CPU", fanMin, " об/мин", 0, true);

        // ---- плата: VRM / чипсет
        double vrmMax = -1, chipMax = -1;
        foreach (Rd r in boardT) {
            double v = r.V;
            if (v < 5 || v > 150 || BogusCode(v)) continue;
            string k = "mb:" + r.Hw + ":" + r.Name;
            if (VrmRe.IsMatch(r.Name)) {
                if (Suspect(k, v, 105, "Датчик «" + r.Name + "»")) continue;
                if (v > vrmMax) vrmMax = v;
                Check(k, "vrm_temp", v >= 105, v >= 112, v >= 115, 2,
                    "Цепи питания процессора на плате (" + r.Name + ") нагрелись до " + F(v, 0) + " °C (предел 105 °C)",
                    "Перегрев VRM материнской платы: нужен обдув зоны питания процессора (корпусные вентиляторы, кулер с боковым потоком), снижение лимитов мощности CPU в BIOS. На простых платах не ставьте мощные процессоры без обдува.");
            } else if (ChipRe.IsMatch(r.Name)) {
                if (Suspect(k, v, 95, "Датчик «" + r.Name + "»")) continue;
                if (v > chipMax) chipMax = v;
                Check(k, "vrm_temp", v >= 95, v >= 102, v >= 105, 2,
                    "Датчик платы «" + r.Name + "» показывает " + F(v, 0) + " °C (предел 95 °C)",
                    "Перегрев чипсета/платы: проверьте вентиляцию корпуса, радиатор чипсета (и его вентилятор, если есть), пыль.");
            } else if (GenTempRe.IsMatch(r.Name) && v > 115) {
                AddNote("gen:" + k, "датчик платы «" + r.Name + "» показывает " + F(v, 0) + " °C — скорее всего, не подключён (не учитывается)");
            }
        }
        if (vrmMax >= 0) Cur("VRM", vrmMax, " °C", 0, false);
        if (chipMax >= 0) Cur("Чипсет/плата", chipMax, " °C", 0, false);

        lastSnap = string.Join("; ", curList.ToArray());
        if (Tripped) return;

        // ---- проверки
        if (cpuT >= 0) {
            cpuSeen = true; cpuMissing = 0;
            Check("cpu_t", "cpu_temp", cpuT >= cpuTrip, cpuT >= cpuTrip + 5, cpuT >= cpuTrip + 5, 2,
                "Процессор нагрелся до " + F(cpuT, 0) + " °C (" + cpuLimitText + ")",
                "Проверьте охлаждение процессора: прижим и исправность кулера/помпы СВО, термопасту, пыль в радиаторе. Проверьте в BIOS лимиты мощности и напряжение (разгон, MCE/PBO). До исправления не нагружайте компьютер.");
        } else if (cpuSeen) {
            cpuMissing++;
            if (cpuMissing >= 10) AddNote("cpuloss", "датчик температуры процессора пропал более чем на 10 с во время теста");
        }
        if (cpuP >= 0) {
            bool hedt = cpuName != null && Regex.IsMatch(cpuName, @"(?i)Threadripper|Xeon|EPYC");
            double lim = hedt ? 700 : 400;
            if (cpuP > lim * 2) AddNote("cpupg", "мощность процессора " + F(cpuP, 0) + " Вт — явный сбой датчика, не учитывается");
            else Check("cpu_p", "power", cpuP > lim, false, false, 2,
                "Мощность процессора " + F(cpuP, 0) + " Вт — выше разумного предела " + F(lim, 0) + " Вт",
                "Аномальное потребление процессора: сбой датчика или «разгон без ограничений». Проверьте в BIOS лимиты мощности (PL1/PL2, PBO); при повторении — диагностика платы.");
        }
        if (vcore >= 0) Check("vcore", "voltage", vcore > 1.60, false, vcore > 1.70, 2,
            "Напряжение ядра процессора (Vcore) " + F(vcore, 3) + " В — выше безопасных 1,60 В",
            "Опасное напряжение на процессоре (деградация, особенно Intel 13/14 поколения). Проверьте BIOS: ручное напряжение, разгон, «MultiCore Enhancement»; для Intel 13/14 — обновите BIOS до микрокода 0x12F или новее.");
        if (gCore >= 0) Check("gpu_core", "gpu_temp", gCore >= 93, gCore >= 100, gCore >= 100, 2,
            "Видеокарта нагрелась до " + F(gCore, 0) + " °C (предел 93 °C)",
            "Чистка видеокарты от пыли, замена термопасты и термопрокладок, проверка её вентиляторов и продувки корпуса.");
        double hl = gAmd ? 110 : 108;
        if (gHot >= 0) Check("gpu_hot", "gpu_temp", gHot >= hl, gHot >= hl + 7, gHot >= hl + 7, 2,
            "Горячая точка видеокарты " + F(gHot, 0) + " °C (предел " + F(hl, 0) + " °C)",
            "Большая разница между ядром и горячей точкой — высохла термопаста или плохой прижим радиатора видеокарты: замена термопасты/термопрокладок.");
        if (gMem >= 0) Check("gpu_mem", "gpu_temp", gMem >= hl, gMem >= hl + 7, gMem >= hl + 7, 2,
            "Видеопамять нагрелась до " + F(gMem, 0) + " °C (предел " + F(hl, 0) + " °C)",
            "Замените термопрокладки на памяти видеокарты, улучшите обдув.");
        if (gPow >= 0) {
            if (gPow > 1300) AddNote("gpupg", "мощность видеокарты " + F(gPow, 0) + " Вт — явный сбой датчика, не учитывается");
            else Check("gpu_p", "power", gPow > 650, false, false, 2,
                "Мощность видеокарты " + F(gPow, 0) + " Вт — выше разумного предела 650 Вт",
                "Аномальное потребление видеокарты: сбой датчика или неисправность (утечка/КЗ в цепях питания, снятые лимиты). Проверьте настройки разгона; при повторении — диагностика видеокарты.");
        }
        if (ramT >= 0) Check("ram", "ram_temp", ramT >= 85, ramT >= 92, ramT >= 95, 2,
            "Модуль памяти (" + ramKey + ") нагрелся до " + F(ramT, 0) + " °C (предел 85 °C)",
            "Обеспечьте обдув модулей памяти; проверьте XMP/EXPO и напряжение памяти в BIOS.");
        if (diskT >= 0) Check("disk", "disk_temp", diskT >= diskLim, diskT >= diskLim + 8, diskT >= diskLim + 10, 2,
            "Накопитель «" + diskName + "» нагрелся до " + F(diskT, 0) + " °C (предел " + F(diskLim, 0) + " °C)",
            "Накопитель перегревается: радиатор для NVMe, обдув, проверьте, не греет ли его видеокарта.");
        Rail("v12", "+12V", v12, 11.0, 13.0, 10.2, 13.8, "11,4–12,6");
        Rail("v5", "+5V", v5, 4.6, 5.4, 4.3, 5.7, "4,75–5,25");
        Rail("v33", "+3.3V", v33, 3.0, 3.6, 2.9, 3.75, "3,14–3,47");
        if (fanBase != null && cpuT > 70) {
            foreach (Rd f in fans) {
                if (!fanBase.ContainsKey(f.Name)) continue;
                bool isCpu = f.Name.IndexOf("CPU", StringComparison.OrdinalIgnoreCase) >= 0;
                Check("fan:" + f.Name, "fan", f.V < 50, false, false, 3,
                    (isCpu ? "Вентилятор процессора («" + f.Name + "»)" : "Вентилятор «" + f.Name + "» (вероятно, процессорный)") + " остановился при " + F(cpuT, 0) + " °C",
                    "Проверьте вентилятор процессора: разъём, кабель, не заклинило ли его, кривую оборотов в BIOS. Не нагружайте компьютер до ремонта.");
            }
        } else if (fanBase != null) {
            foreach (string k in fanBase.Keys) streak["fan:" + k] = 0;
        }
    }

    static void Rail(string key, string label, double v, double lo, double hi, double clo, double chi, string norm) {
        if (v < 0) return;
        bool bad = v < lo || v > hi;
        bool cata = v < clo || v > chi;
        double f;
        if (!firstVal.TryGetValue(key, out f)) {
            firstVal[key] = v;
            if (bad) { bogus.Add(key); AddNote("rail:" + key, label + " = " + F(v, 2) + " В уже в начале теста — вероятно, неверная калибровка датчика платы; останавливаем только при грубом выходе за пределы"); }
        }
        if (bogus.Contains(key)) bad = cata;
        string what = v < lo ? " просел до " : " поднялся до ";
        Check(key, "voltage", bad, cata, cata, 2,
            label + what + F(v, 2) + " В (норма " + norm + ")",
            "Напряжение блока питания вышло за допуск ATX: проверьте БП заменой на заведомо исправный или мультиметром (датчики платы имеют погрешность 2–3 %). До проверки не нагружайте компьютер.");
    }

    // ------------------------------------------------------------ остановка
    static bool DoTrip(string reason, string category, string snapshot, string advice) {
        lock (tripLock) {
            if (Tripped) return false;
            Reason = reason == null ? "" : reason;
            Category = category == null ? "" : category;
            Snapshot = string.IsNullOrEmpty(snapshot) ? lastSnap : snapshot;
            Advice = string.IsNullOrEmpty(advice) ? DefaultAdvice(Category) : advice;
            TripTime = DateTime.Now;
            TripCount++;
            Tripped = true;
        }
        return true;
    }

    static string DefaultAdvice(string cat) {
        switch (cat) {
            case "cpu_temp": return "Проверьте охлаждение процессора: кулер, термопасту, пыль, лимиты мощности в BIOS.";
            case "gpu_temp": return "Чистка видеокарты, замена термопасты/термопрокладок, проверка вентиляторов.";
            case "vrm_temp": return "Улучшите обдув цепей питания платы, снизьте лимиты мощности CPU в BIOS.";
            case "ram_temp": return "Обдув модулей памяти, проверьте XMP/EXPO.";
            case "disk_temp": return "Радиатор/обдув накопителя.";
            case "voltage": return "Проверьте блок питания и настройки напряжений в BIOS.";
            case "fan": return "Проверьте вентилятор процессора и его подключение.";
            case "power": return "Проверьте лимиты мощности; при повторении — диагностика платы/видеокарты.";
        }
        return "Устраните причину перед повторной нагрузкой.";
    }

    public static void KillAll() {
        int[] list;
        lock (pidLock) { list = pids.ToArray(); }
        foreach (int pid in list) KillTree(pid);
        KillByName();
        StopDiagCore();
    }

    static void KillByName() {
        int self = Process.GetCurrentProcess().Id;
        Process[] all;
        try { all = Process.GetProcesses(); } catch { return; }
        foreach (Process p in all) {
            try { if (p.Id != self && StressName.IsMatch(p.ProcessName)) p.Kill(); } catch { }
            finally { p.Dispose(); }
        }
    }
    static Regex StressName { get { return StressNameRe; } }

    static void StopDiagCore() {
        try {
            foreach (Assembly a in AppDomain.CurrentDomain.GetAssemblies()) {
                Type t = null;
                try { t = a.GetType("DiagCore", false); } catch { }
                if (t == null) continue;
                MethodInfo m = t.GetMethod("Stop", BindingFlags.Public | BindingFlags.Static, null, Type.EmptyTypes, null);
                if (m != null) { try { m.Invoke(null, null); } catch { } }
                foreach (string fn in new string[] { "StopFlag", "StopRequested" }) {
                    FieldInfo f = t.GetField(fn, BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Static);
                    if (f != null && f.FieldType == typeof(bool)) { try { f.SetValue(null, true); } catch { } }
                }
            }
        } catch { }
    }

    // ---- дерево процессов (Toolhelp32): y-cruncher и др. запускают дочерние процессы
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct PROCESSENTRY32 {
        public uint dwSize; public uint cntUsage; public uint th32ProcessID; public IntPtr th32DefaultHeapID;
        public uint th32ModuleID; public uint cntThreads; public uint th32ParentProcessID; public int pcPriClassBase;
        public uint dwFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szExeFile;
    }
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint pid);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool Process32FirstW(IntPtr h, ref PROCESSENTRY32 e);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool Process32NextW(IntPtr h, ref PROCESSENTRY32 e);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);

    static void KillTree(int root) {
        int self = Process.GetCurrentProcess().Id;
        if (root == self) return;
        List<int> victims = new List<int>();
        victims.Add(root);
        try {
            Dictionary<int, List<int>> kids = new Dictionary<int, List<int>>();
            IntPtr h = CreateToolhelp32Snapshot(2, 0);
            if (h != IntPtr.Zero && h != new IntPtr(-1)) {
                try {
                    PROCESSENTRY32 e = new PROCESSENTRY32();
                    e.dwSize = (uint)Marshal.SizeOf(typeof(PROCESSENTRY32));
                    bool ok = Process32FirstW(h, ref e);
                    while (ok) {
                        int pp = (int)e.th32ParentProcessID, id = (int)e.th32ProcessID;
                        if (id != pp) {
                            List<int> l;
                            if (!kids.TryGetValue(pp, out l)) { l = new List<int>(); kids[pp] = l; }
                            l.Add(id);
                        }
                        ok = Process32NextW(h, ref e);
                    }
                } finally { CloseHandle(h); }
            }
            for (int i = 0; i < victims.Count && i < 256; i++) {
                List<int> l;
                if (kids.TryGetValue(victims[i], out l)) foreach (int c in l) if (c != self && !victims.Contains(c)) victims.Add(c);
            }
        } catch { }
        for (int i = victims.Count - 1; i >= 0; i--) {
            try { using (Process p = Process.GetProcessById(victims[i])) { p.Kill(); } } catch { }
        }
    }
}
'@

function Guard-Init {
    if ($G.GuardOk) { return $true }
    if ($env:DIAG_NOGUARD -or -not $G.LHM -or $G.GuardTried) { return $false }
    $G.GuardTried = $true
    try {
        if (-not ('DiagGuard' -as [type])) {
            $loc = $G.LHM.GetType().Assembly.Location
            Add-Type -TypeDefinition $G.GuardSrc -Language CSharp -ReferencedAssemblies $loc -ErrorAction Stop
        }
        $G.GuardOk = $true
    } catch {
        Warn ('ТемпературныйНюхач (контроль датчиков) не запустился: ' + $_.Exception.Message)
        $G.Log.Add(($_ | Out-String))
    }
    return $G.GuardOk
}
function Guard-SensorLock { if ($G.GuardOk) { return [DiagGuard]::SensorLock }; return $null }
function Guard-Arm($TestName) {
    if (-not (Guard-Init)) { return }
    try { [void][DiagGuard]::Arm($G.LHM, [string]$TestName) } catch { $G.Log.Add('Guard-Arm: ' + $_.Exception.Message) }
}
function Guard-Disarm {
    if (-not $G.GuardOk) { return }
    try {
        [DiagGuard]::Disarm()
        foreach ($n in [DiagGuard]::TakeNotes()) { $G.Log.Add('ТемпературныйНюхач: ' + $n); Info ('ТемпературныйНюхач: ' + $n) }
        if ([DiagGuard]::LastError) { $G.Log.Add('ТемпературныйНюхач, ошибка опроса: ' + [DiagGuard]::LastError) }
        $G.Log.Add(('ТемпературныйНюхач: {0} замеров, пропущено {1}; {2}' -f [DiagGuard]::Samples, [DiagGuard]::Missed, [DiagGuard]::MaxSummary))
    } catch {}
}
function Guard-Register($Proc) {
    if (-not $G.GuardOk -or $null -eq $Proc) { return }
    $id = if ($Proc -is [System.Diagnostics.Process]) { $Proc.Id } else { $Proc -as [int] }
    if ($id) { try { [DiagGuard]::RegisterProcess([int]$id) } catch {} }
}
function Guard-Tripped { if (-not $G.GuardOk) { return $false }; return [bool][DiagGuard]::Tripped }
function Guard-Area($cat) { if ($cat -in 'voltage', 'power') { return 'Питание' }; if ($cat -eq 'whea') { return 'Стабильность' }; return 'Охлаждение' }
function Guard-Report {
    if (-not (Guard-Tripped)) { return }
    $n = [DiagGuard]::TripCount
    if ($G.GuardReportedTrip -eq $n) { return }   # отчёт о каждой остановке — один раз
    $G.GuardReportedTrip = $n
    $G.GuardStopped = $true
    $reason = [DiagGuard]::Reason; $G.GuardStopReason = $reason
    Write-Host ''
    Bad ('ТЕСТЫ ОСТАНОВЛЕНЫ — ТемпературныйНюхач: ' + $reason)
    if (Get-Command Live-Issue -ErrorAction SilentlyContinue) { Live-Issue 'crit' ('ТемпературныйНюхач остановил тесты: ' + $reason) }
    $s = New-Section 'ТЕСТЫ ОСТАНОВЛЕНЫ: ТемпературныйНюхач обнаружил аномалию'
    $G.GuardSection = $s
    Add-Row $s 'Причина остановки' $reason 'crit'
    Add-Row $s 'Время' ([DiagGuard]::TripTime.ToString('dd.MM.yyyy HH:mm:ss'))
    Add-Row $s 'Тест' ([DiagGuard]::LastTest)
    Add-Row $s 'Показания в момент остановки' ([DiagGuard]::Snapshot)
    $mx = [DiagGuard]::MaxSummary; if ($mx) { Add-Row $s 'Пики за время теста' $mx }
    $nt = [DiagGuard]::Notes; if ($nt) { Add-Row $s 'Замечания: ТемпературныйНюхач' $nt }
    Add-Row $s 'Что сделано' 'стресс-программы закрыты, нагрузка снята сразу (опрос датчиков раз в секунду)'
    Add-Issue 'crit' (Guard-Area ([DiagGuard]::Category)) ('тесты остановил ТемпературныйНюхач: ' + $reason) ([DiagGuard]::Advice)
    $G.Num.guard_trip = 1
}
function Guard-Dialog($Title, $Text, $StopText, $GoText) {
    # $true — пользователь выбрал «продолжить на свой риск»
    try {
        Add-Type -AssemblyName System.Windows.Forms, System.Drawing -ErrorAction Stop
        $f = New-Object System.Windows.Forms.Form
        $f.Text = $Title; $f.TopMost = $true; $f.StartPosition = 'CenterScreen'
        $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.MinimizeBox = $false; $f.ShowInTaskbar = $true
        $f.BackColor = [System.Drawing.Color]::FromArgb(245, 246, 248); $f.Font = New-Object System.Drawing.Font('Segoe UI', 10)
        $f.AutoSize = $true; $f.AutoSizeMode = 'GrowAndShrink'; $f.Padding = New-Object System.Windows.Forms.Padding(18)
        $p = New-Object System.Windows.Forms.FlowLayoutPanel
        $p.FlowDirection = 'TopDown'; $p.AutoSize = $true; $p.WrapContents = $false
        $h = New-Object System.Windows.Forms.Label
        $h.Text = $Title; $h.AutoSize = $true; $h.ForeColor = [System.Drawing.Color]::FromArgb(200, 30, 30)
        $h.Font = New-Object System.Drawing.Font('Segoe UI', 13, [System.Drawing.FontStyle]::Bold); $h.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 10)
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $Text; $l.AutoSize = $true; $l.MaximumSize = New-Object System.Drawing.Size(620, 0); $l.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 16)
        $b = New-Object System.Windows.Forms.FlowLayoutPanel; $b.AutoSize = $true; $b.FlowDirection = 'LeftToRight'
        $bs = New-Object System.Windows.Forms.Button
        $bs.Text = $StopText; $bs.AutoSize = $true; $bs.Padding = New-Object System.Windows.Forms.Padding(10, 4, 10, 4)
        $bs.BackColor = [System.Drawing.Color]::FromArgb(42, 120, 214); $bs.ForeColor = [System.Drawing.Color]::White; $bs.FlatStyle = 'Flat'; $bs.FlatAppearance.BorderSize = 0
        $bs.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $bg = New-Object System.Windows.Forms.Button
        $bg.Text = $GoText; $bg.AutoSize = $true; $bg.Padding = New-Object System.Windows.Forms.Padding(10, 4, 10, 4); $bg.FlatStyle = 'Flat'
        $bg.DialogResult = [System.Windows.Forms.DialogResult]::Yes
        $b.Controls.Add($bs); $b.Controls.Add($bg)
        $p.Controls.Add($h); $p.Controls.Add($l); $p.Controls.Add($b)
        $f.Controls.Add($p)
        $f.AcceptButton = $bs; $f.CancelButton = $bs
        $f.Add_Shown({ $f.Activate(); $bs.Focus() })
        try { [System.Media.SystemSounds]::Hand.Play() } catch {}
        $r = $f.ShowDialog()
        $f.Dispose()
        return ($r -eq [System.Windows.Forms.DialogResult]::Yes)
    } catch {
        $G.Log.Add('Guard-Dialog: ' + $_.Exception.Message)
        return $false
    }
}
function Guard-Ask {
    # После остановки: $true — пользователь решил продолжить остальные тесты на свой риск
    if (-not (Guard-Tripped)) { return $false }
    if ($G.Auto) { return $false }
    $reason = [DiagGuard]::Reason
    $txt = $reason + "`r`n`r`nПоказания в момент остановки: " + [DiagGuard]::Snapshot + "`r`n`r`nНагрузка уже снята.`r`n`r`nМы не рекомендуем продолжать: это может повредить компьютер или скрывать неисправность. Продолжить остальные тесты на свой риск?"
    $go = Guard-Dialog 'ТемпературныйНюхач: тесты остановлены' $txt 'Остановить тесты' 'Продолжить на свой риск'
    if (-not $go) { return $false }
    $cat = [DiagGuard]::Category
    [DiagGuard]::IgnoreCategory($cat)
    [DiagGuard]::Reset()
    [void]$G.GuardOverride.Add($reason)
    $G.GuardStopped = $false; $G.GuardStopReason = ''
    Warn 'пользователь продолжил тесты на свой риск'
    if ($G.GuardSection) { Add-Row $G.GuardSection 'Решение пользователя' 'пользователь продолжил тесты на свой риск (этот вид аномалии дальше не останавливает тесты, кроме грубого выхода за пределы)' 'warn' }
    Add-Issue 'info' (Guard-Area $cat) ('пользователь продолжил тесты на свой риск после остановки: ' + $reason) 'Результаты следующих тестов получены при известной аномалии — учитывайте это при выводах.'
    return $true
}
function Guard-PreCheck {
    # Перед первым стресс-шагом: есть ли чем следить за температурой
    if ($G.GuardPreChecked) { return }
    $G.GuardPreChecked = $true
    if ($env:DIAG_NOGUARD) { return }
    $k = $null; try { $k = Read-Key } catch {}
    $noCpu = (-not $G.LHM) -or -not (Guard-Init) -or ($null -eq $k) -or ($null -eq $k.CpuTemp)
    $gpuSel = $G.Sel -and ($G.Sel.gpu -or $G.Sel.vram -or $G.Sel.psu)
    $noGpu = $gpuSel -and (($null -eq $k) -or ($null -eq $k.GpuTemp))
    if (-not $noCpu -and -not $noGpu) { return }
    $what = @(); if ($noCpu) { $what += 'процессора' }; if ($noGpu) { $what += 'видеокарты' }
    $wt = $what -join ' и '
    if ($G.Auto) {
        $G.GuardBlind = $true
        Add-Issue 'warn' 'Охлаждение' ("стресс-тесты шли без контроля температуры $wt (датчик недоступен)") 'ТемпературныйНюхач не мог остановить тест при перегреве. Для полного контроля запустите проверку с драйвером датчиков PawnIO.'
        return
    }
    $txt = "Датчик температуры $wt недоступен — ТемпературныйНюхач не сможет остановить тест при перегреве.`r`n`r`nНе рекомендуем продолжать без контроля. Продолжить?"
    $go = Guard-Dialog 'ТемпературныйНюхач: нет контроля температуры' $txt 'Не запускать стресс-тесты' 'Продолжить на свой риск'
    if ($go) {
        $G.GuardBlind = $true
        Warn "стресс-тесты без контроля температуры $wt (выбор пользователя)"
        Add-Issue 'warn' 'Охлаждение' ("стресс-тесты выполнены без контроля температуры $wt (датчик недоступен, пользователь продолжил на свой риск)") 'Для полного контроля запустите проверку с драйвером датчиков PawnIO.'
    } else {
        $G.GuardStopped = $true; $G.GuardStopReason = 'нет датчика температуры, пользователь отказался'
        Add-Issue 'warn' 'Охлаждение' ("стресс-тесты не выполнялись: нет датчика температуры $wt, пользователь отказался от тестов без контроля") 'Запустите проверку с драйвером датчиков PawnIO, чтобы тесты шли под контролем температуры.'
    }
}
function Guard-IsStress($Name) {
    return ($STEPKEYS.ContainsKey($Name) -and ($G.GuardStress -contains $STEPKEYS[$Name]) -and ($G.GuardNoStress -notcontains $Name))
}
function Guard-Before($Name) {
    # Вызывается из Step перед телом стресс-шага. $false — шаг пропустить.
    if (-not (Guard-IsStress $Name)) { return $true }
    Guard-PreCheck
    if ($G.GuardStopped) {
        Warn ('пропущено: тесты остановил ТемпературныйНюхач ({0})' -f $G.GuardStopReason)
        [void]$G.GuardSkipped.Add($Name)
        if ($G.GuardSection) { Add-Row $G.GuardSection 'Пропущен тест' $Name 'warn' }
        return $false
    }
    Guard-Arm $Name
    # HWiNFO: окно датчиков на экране + чтение его памяти каждую секунду
    if (Get-Command Start-HWiNFO -ErrorAction SilentlyContinue) {
        if (-not $G.HwiStarted) { $G.HwiStarted = $true; try { Start-HWiNFO } catch { $G.Log.Add('Start-HWiNFO: ' + $_.Exception.Message) } }
        try { Hwi-Monitor-Start } catch {}
    }
    return $true
}
function Guard-After($Name) {
    # Вызывается из Step в finally после стресс-шага.
    if ((Guard-IsStress $Name) -and (Get-Command Hwi-Monitor-Stop -ErrorAction SilentlyContinue)) { try { Hwi-Monitor-Stop } catch {} }
    if (-not $G.GuardOk -or -not (Guard-IsStress $Name)) { return }
    Guard-Disarm
    if (Guard-Tripped) {
        Guard-Report
        if (-not (Guard-Ask)) { $G.GuardStopped = $true }
    }
}
