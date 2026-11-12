# ---------------------------------------------------------------- HWiNFO: сторож датчиков во время стресс-тестов
# HWiNFO64 (бесплатная версия) запускается видимым окном «только датчики» и отдаёт показания через
# «Shared Memory Support» (Global\HWiNFO_SENS_SM2). Фоновый поток DiagHwi раз в секунду читает общую память,
# ищет аномалии (перегрев, просадки линий питания, остановка вентилятора CPU, ошибки WHEA, троттлинг)
# и при срабатывании вызывает DiagGuard.Trip (если он есть) — все тесты останавливаются с указанием причины.
# Тот же поток следит, чтобы окно датчиков было видно (не свёрнуто/не скрыто/не за экраном),
# перезапускает HWiNFO, если его закрыли или он завис (не чаще 3 раз за 5 минут).
# Ограничения бесплатной версии: общая память работает 12 часов за сеанс; обходить лимит перезапусками
# запрещено лицензией HWiNFO — после ~11,5 ч работы и при сообщении о лимите перезапуск не выполняется.
# DIAG_NOHWINFO=1 — HWiNFO не используется вообще.
$TOOLS.HWiNFO = @{ Url = 'https://www.hwinfo.com/files/hwi_860.zip'; Sha = 'B2C0B50CD96E77DBFACACAA705A16B808E162AC6C3A39B955B62DC83313E1084'; Dir = 'HWiNFO'; Exe = 'HWiNFO\HWiNFO64.exe' }
$G.HwiOk = $false
$G.HwiProc = $null
$G.HwiLast = $null

function Load-HwiType {
    if ('DiagHwi' -as [type]) { return $true }
    $src = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.IO.MemoryMappedFiles;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

public class HwiReading {
    public string Sensor;      // имя устройства (оригинальное, англ.)
    public string SensorUser;  // имя устройства (как в окне HWiNFO)
    public string Label;       // показание (оригинальное)
    public string LabelUser;
    public string Unit;
    public int Type;           // 0 нет,1 темп.,2 напряж.,3 вент.,4 ток,5 мощн.,6 частота,7 загрузка,8 прочее
    public int SensorIndex;
    public uint ReadingId;
    public double Value, Min, Max, Avg;
    public string TypeName {
        get {
            switch (Type) {
                case 1: return "Температура"; case 2: return "Напряжение"; case 3: return "Вентилятор";
                case 4: return "Ток"; case 5: return "Мощность"; case 6: return "Частота";
                case 7: return "Загрузка"; case 8: return "Прочее"; default: return "";
            }
        }
    }
    public string Key { get { return SensorIndex.ToString(CultureInfo.InvariantCulture) + "|" + ReadingId.ToString(CultureInfo.InvariantCulture) + "|" + Label; } }
}

public static class DiagHwi {
    public const string SmName = "Global\\HWiNFO_SENS_SM2";
    const uint SigActive = 0x53695748; // 'HWiS'

    // ---- общее состояние (читает PowerShell / живое окно)
    public static volatile bool Tripped;
    public static volatile string Reason = "";
    public static volatile string Status = "unavailable";          // ok / stale / restarting / unavailable
    public static volatile string StatusText = "HWiNFO: не запущен";
    public static volatile int SensorCount;                          // число показаний (строк в окне HWiNFO)
    public static volatile int DeviceCount;                          // число устройств (групп датчиков)
    public static volatile int Samples;                              // успешных чтений за время «взвода»
    public static volatile int TotalSamples;
    public static volatile int Restarts;
    public static volatile int WindowFixes;
    public static volatile bool KeepVisible = true;
    public static volatile bool Armed;
    public static volatile bool Owned;                               // HWiNFO запустили мы (можно перезапускать/закрывать)
    public static volatile int OwnPid;
    public static volatile string ExePath = "";
    public static volatile string CpuName = "";
    public static volatile bool SmLimitSeen;                         // HWiNFO сообщил об исчерпании 12-часового лимита
    public static volatile string LastError = "";
    public static long PollTime;
    public static int PollingPeriodMs;
    public static uint SmVersion, SmRevision;

    static readonly object smLock = new object();
    static readonly object stLock = new object();
    static MemoryMappedFile mmf;
    static MemoryMappedViewAccessor view;
    static Thread worker;
    static readonly ManualResetEvent stopEvt = new ManualResetEvent(false);
    static readonly List<string> events = new List<string>();
    static readonly Dictionary<string, double> maxV = new Dictionary<string, double>();
    static readonly Dictionary<string, double> minV = new Dictionary<string, double>();
    static readonly Dictionary<string, double> curV = new Dictionary<string, double>();
    static readonly Dictionary<string, int> overCnt = new Dictionary<string, int>();
    static readonly Dictionary<string, DateTime> thrSince = new Dictionary<string, DateTime>();
    static readonly Dictionary<string, double> fanBase = new Dictionary<string, double>();
    static readonly Dictionary<string, int> fanZero = new Dictionary<string, int>();
    static readonly Dictionary<string, double> wheaBase = new Dictionary<string, double>();
    static readonly List<DateTime> restartTimes = new List<DateTime>();
    static volatile bool armFresh;
    static DateTime firstLaunchUtc = DateTime.MinValue;
    static DateTime lastChangeUtc = DateTime.MinValue, lastOkReadUtc = DateTime.MinValue, nextWinUtc = DateTime.MinValue, restartBeganUtc = DateTime.MinValue;
    static long lastPoll = long.MinValue; static double lastHash = double.NaN;
    static bool staleRestartTried, giveUp, deadLogged;

    // ================================================================ общая память
    static void CloseSm() {
        lock (smLock) {
            try { if (view != null) view.Dispose(); } catch { }
            try { if (mmf != null) mmf.Dispose(); } catch { }
            view = null; mmf = null;
        }
    }
    static bool EnsureOpen() {
        if (view != null) return true;
        try {
            mmf = MemoryMappedFile.OpenExisting(SmName, MemoryMappedFileRights.Read);
            view = mmf.CreateViewAccessor(0, 0, MemoryMappedFileAccess.Read);
            return true;
        } catch { try { if (mmf != null) mmf.Dispose(); } catch { } mmf = null; view = null; return false; }
    }
    static string Ansi(byte[] b, int off, int max) {
        if (off < 0 || off >= b.Length) return "";
        int n = 0; while (n < max && off + n < b.Length && b[off + n] != 0) n++;
        return Encoding.Default.GetString(b, off, n).Trim();
    }
    static string Utf(byte[] b, int off, int max) {
        if (off < 0 || off >= b.Length) return "";
        int n = 0; while (n < max && off + n < b.Length && b[off + n] != 0) n++;
        try { return Encoding.UTF8.GetString(b, off, n).Trim(); } catch { return ""; }
    }

    /// <summary>Общая память HWiNFO существует и активна (подпись 'HWiS').</summary>
    public static bool Available() {
        lock (smLock) {
            if (!EnsureOpen()) return false;
            try {
                if (view.ReadUInt32(0) == SigActive) return true;
            } catch { }
            CloseSm();
            return false;
        }
    }

    /// <summary>Текущие показания HWiNFO (null — общая память недоступна).</summary>
    public static List<HwiReading> Read() {
        long pt; uint sig;
        return ReadCore(out pt, out sig);
    }

    static List<HwiReading> ReadCore(out long pollTime, out uint sig) {
        pollTime = 0; sig = 0;
        lock (smLock) {
            if (!EnsureOpen()) return null;
            try {
                long cap = view.Capacity;
                if (cap < 44) { CloseSm(); return null; }
                byte[] buf = null; uint offS = 0, szS = 0, nS = 0, offR = 0, szR = 0, nR = 0;
                for (int attempt = 0; attempt < 3; attempt++) {
                    sig = view.ReadUInt32(0);
                    if (sig != SigActive) { CloseSm(); return null; }
                    SmVersion = view.ReadUInt32(4); SmRevision = view.ReadUInt32(8);
                    long pt1 = view.ReadInt64(12);
                    offS = view.ReadUInt32(20); szS = view.ReadUInt32(24); nS = view.ReadUInt32(28);
                    offR = view.ReadUInt32(32); szR = view.ReadUInt32(36); nR = view.ReadUInt32(40);
                    if (szS < 264 || szR < 316 || nS > 4096 || nR > 65536) { CloseSm(); return null; }
                    long need = Math.Max((long)offS + (long)szS * nS, (long)offR + (long)szR * nR);
                    if (need > cap || need > 64L * 1024 * 1024) { CloseSm(); return null; }
                    PollingPeriodMs = (offS >= 48 && offR >= 48) ? (int)view.ReadUInt32(44) : 0;
                    buf = new byte[need];
                    view.ReadArray<byte>(0, buf, 0, (int)need);
                    pollTime = BitConverter.ToInt64(buf, 12);
                    if (pollTime == pt1) break;   // HWiNFO не переписал данные во время копирования
                }
                PollTime = pollTime;
                string[] sn = new string[nS], su = new string[nS];
                for (int i = 0; i < nS; i++) {
                    int o = (int)(offS + szS * i);
                    sn[i] = Ansi(buf, o + 8, 128);
                    su[i] = szS >= 392 ? Utf(buf, o + 264, 128) : "";
                    if (su[i].Length == 0) su[i] = Ansi(buf, o + 136, 128);
                    if (su[i].Length == 0) su[i] = sn[i];
                }
                List<HwiReading> list = new List<HwiReading>((int)nR);
                for (int i = 0; i < nR; i++) {
                    int o = (int)(offR + szR * i);
                    HwiReading r = new HwiReading();
                    r.Type = (int)BitConverter.ToUInt32(buf, o);
                    r.SensorIndex = (int)BitConverter.ToUInt32(buf, o + 4);
                    r.ReadingId = BitConverter.ToUInt32(buf, o + 8);
                    r.Label = Ansi(buf, o + 12, 128);
                    r.LabelUser = szR >= 460 ? Utf(buf, o + 316, 128) : "";
                    if (r.LabelUser.Length == 0) r.LabelUser = Ansi(buf, o + 140, 128);
                    if (r.LabelUser.Length == 0) r.LabelUser = r.Label;
                    r.Unit = szR >= 460 ? Utf(buf, o + 444, 16) : "";
                    if (r.Unit.Length == 0) r.Unit = Ansi(buf, o + 268, 16);
                    r.Value = BitConverter.ToDouble(buf, o + 284);
                    r.Min = BitConverter.ToDouble(buf, o + 292);
                    r.Max = BitConverter.ToDouble(buf, o + 300);
                    r.Avg = BitConverter.ToDouble(buf, o + 308);
                    if (r.SensorIndex >= 0 && r.SensorIndex < nS) { r.Sensor = sn[r.SensorIndex]; r.SensorUser = su[r.SensorIndex]; }
                    else { r.Sensor = ""; r.SensorUser = ""; }
                    list.Add(r);
                }
                DeviceCount = (int)nS; SensorCount = (int)nR;
                return list;
            } catch (Exception ex) { LastError = ex.Message; CloseSm(); return null; }
        }
    }

    // ================================================================ запуск / остановка HWiNFO
    public static int Launch(string exe) {
        ProcessStartInfo psi = new ProcessStartInfo(exe);
        psi.WorkingDirectory = Path.GetDirectoryName(exe);
        psi.UseShellExecute = true;
        psi.WindowStyle = ProcessWindowStyle.Normal;
        Process p = Process.Start(psi);
        try { if (p != null) p.PriorityClass = ProcessPriorityClass.AboveNormal; } catch { }   // чтобы датчики опрашивались и под полной нагрузкой
        ExePath = exe; OwnPid = p.Id; Owned = true;
        if (firstLaunchUtc == DateTime.MinValue) firstLaunchUtc = DateTime.UtcNow;
        try { p.Dispose(); } catch { }
        return OwnPid;
    }
    /// <summary>Подключиться к чужому (пользовательскому) HWiNFO: не перезапускаем и не закрываем его.</summary>
    public static void AttachForeign() { Owned = false; OwnPid = 0; }

    static bool OwnAlive() {
        if (OwnPid == 0) return false;
        try { Process p = Process.GetProcessById(OwnPid); bool a = !p.HasExited; p.Dispose(); return a; } catch { return false; }
    }
    static void KillOwn(int graceMs) {
        if (OwnPid == 0) return;
        try {
            Process p = Process.GetProcessById(OwnPid);
            if (graceMs > 0) { try { p.CloseMainWindow(); } catch { } }
            if (graceMs <= 0 || !p.WaitForExit(graceMs)) { try { p.Kill(); p.WaitForExit(3000); } catch { } }
            p.Dispose();
        } catch { }
    }
    /// <summary>Остановить сторожа и закрыть HWiNFO, если его запускали мы.</summary>
    public static void Shutdown() {
        StopMonitor();
        CloseSm();
        if (Owned) KillOwn(5000);
        Owned = false; OwnPid = 0;
        Status = "unavailable"; StatusText = "HWiNFO: закрыт";
    }

    // ================================================================ сторож
    public static void StartMonitor(int periodMs) {
        if (worker != null && worker.IsAlive) return;
        if (periodMs < 250) periodMs = 1000;
        stopEvt.Reset();
        lastChangeUtc = DateTime.UtcNow; lastOkReadUtc = DateTime.UtcNow;
        int per = periodMs;
        worker = new Thread(delegate () { Loop(per); });
        worker.IsBackground = true;
        worker.Name = "DiagHwi";
        worker.Start();
    }
    public static void StopMonitor() {
        Armed = false;
        stopEvt.Set();
        Thread w = worker;
        if (w != null) { try { w.Join(5000); } catch { } }
        worker = null;
    }
    public static bool MonitorRunning { get { Thread w = worker; return w != null && w.IsAlive; } }

    /// <summary>Взвести: с этого момента аномалии останавливают тесты. Максимумы считаются заново.</summary>
    public static void Arm() {
        lock (stLock) {
            maxV.Clear(); minV.Clear(); curV.Clear(); overCnt.Clear(); thrSince.Clear();
            fanBase.Clear(); fanZero.Clear(); wheaBase.Clear();
            Samples = 0; Tripped = false; Reason = "";
            armFresh = true; Armed = true;
        }
    }
    public static void Disarm() { Armed = false; }

    public static string[] DrainEvents() {
        lock (events) { string[] a = events.ToArray(); events.Clear(); return a; }
    }
    static void Event(string t) {
        lock (events) { if (events.Count < 500) events.Add(DateTime.Now.ToString("HH:mm:ss") + " " + t); }
    }

    static void Loop(int periodMs) {
        while (!stopEvt.WaitOne(0)) {
            DateTime t0 = DateTime.UtcNow;
            try { Tick(t0); } catch (Exception ex) { LastError = ex.Message; }
            int wait = periodMs - (int)(DateTime.UtcNow - t0).TotalMilliseconds;
            if (wait < 50) wait = 50;
            if (stopEvt.WaitOne(wait)) break;
        }
    }

    static void Tick(DateTime now) {
        // 1) процесс HWiNFO (только наш)
        if (Owned && Status != "restarting" && !OwnAlive()) TryRestart(now, "HWiNFO был закрыт — перезапущен");
        if (Status == "restarting") {
            if (Available()) { Status = "ok"; lastChangeUtc = now; lastPoll = long.MinValue; staleRestartTried = false; }
            else if ((now - restartBeganUtc).TotalSeconds > 40) { Status = "unavailable"; Event("HWiNFO после перезапуска не открыл общую память за 40 с"); }
        }
        // 2) окно датчиков — всегда на виду
        if (now >= nextWinUtc) { nextWinUtc = now.AddSeconds(3); try { KeepWindows(); } catch (Exception ex) { LastError = ex.Message; } }
        // 3) показания
        long pt; uint sig;
        List<HwiReading> rs = (Status == "restarting") ? null : ReadCore(out pt, out sig);
        if (rs == null) {
            if (Status == "ok" || Status == "stale") {
                if ((now - lastOkReadUtc).TotalSeconds > 10) {
                    Status = "unavailable";
                    if (!deadLogged) { deadLogged = true; Event(SmLimitSeen ? "HWiNFO: исчерпан 12-часовой лимит общей памяти бесплатной версии — датчики HWiNFO недоступны" : "HWiNFO: общая память недоступна (Shared Memory выключена или HWiNFO закрыт)"); }
                }
            }
            UpdateText(); return;
        }
        lastOkReadUtc = now; deadLogged = false;
        TotalSamples++;
        if (Armed) Samples++;
        double h = 0; for (int i = 0; i < rs.Count; i++) { double v = rs[i].Value; if (!double.IsNaN(v) && !double.IsInfinity(v)) h += v * ((i % 7) + 1); }
        bool fresh = PollTime != lastPoll || h != lastHash;
        lastPoll = PollTime; lastHash = h;
        if (fresh) {
            lastChangeUtc = now;
            if (Status != "ok") { if (Status == "stale") Event("HWiNFO снова обновляет датчики"); Status = "ok"; }
            staleRestartTried = false;
        } else {
            // под тяжёлой нагрузкой (y-cruncher, Linpack) HWiNFO опрашивает датчики медленнее — это не зависание
            double lim = Math.Max(45.0, 6.0 * PollingPeriodMs / 1000.0);
            if ((now - lastChangeUtc).TotalSeconds > lim && Status == "ok") {
                Status = "stale";
                Event("HWiNFO завис/не обновляет датчики (" + ((int)(now - lastChangeUtc).TotalSeconds).ToString(CultureInfo.InvariantCulture) + " с)");
                CloseSm();   // переоткрыть: возможно, HWiNFO перезапустили вручную
                // перезапускаем, только если процесс действительно не отвечает (окно «не отвечает»)
                bool hung = false;
                try { Process hp = Process.GetProcessById(OwnPid); hung = !hp.Responding; } catch { hung = false; }
                if (Owned && hung && !staleRestartTried) { staleRestartTried = true; TryRestart(now, "HWiNFO не отвечал — перезапущен"); }
            }
        }
        if (Status == "ok" && fresh && Armed && !Tripped) {
            try { Evaluate(rs, now); } catch (Exception ex) { LastError = "eval: " + ex.Message; }
        }
        UpdateText();
    }

    static void TryRestart(DateTime now, string why) {
        if (giveUp || string.IsNullOrEmpty(ExePath)) { if (Status != "unavailable") { Status = "unavailable"; Event("HWiNFO недоступен, перезапуск не выполняется"); } return; }
        if (SmLimitSeen || (firstLaunchUtc != DateTime.MinValue && (now - firstLaunchUtc).TotalHours >= 11.5)) {
            giveUp = true; Status = "unavailable";
            Event("HWiNFO: 12-часовой лимит общей памяти бесплатной версии — перезапуск не выполняется (лицензия HWiNFO запрещает обходить лимит)");
            return;
        }
        restartTimes.RemoveAll(delegate (DateTime d) { return (now - d).TotalMinutes > 5; });
        if (restartTimes.Count >= 3) {
            giveUp = true; Status = "unavailable";
            Event("HWiNFO перезапускался 3 раза за 5 минут — больше не перезапускаю, сторож HWiNFO отключён");
            return;
        }
        CloseSm();
        if (OwnAlive()) KillOwn(0);
        try {
            Launch(ExePath);
            restartTimes.Add(now); Restarts++;
            Status = "restarting"; restartBeganUtc = now;
            Event(why);
        } catch (Exception ex) { Status = "unavailable"; giveUp = true; Event("HWiNFO не удалось перезапустить: " + ex.Message); }
    }

    static void UpdateText() {
        string per = PollingPeriodMs > 0 ? (PollingPeriodMs / 1000.0).ToString("0.#", CultureInfo.CurrentCulture) + " с" : "?";
        string s = Status;
        if (s == "ok") StatusText = "HWiNFO: датчиков " + SensorCount + ", опрос " + per + (Armed ? ", сторож взведён" : "") + ", OK";
        else if (s == "stale") StatusText = "HWiNFO: завис — показания не обновляются";
        else if (s == "restarting") StatusText = "HWiNFO: перезапуск…";
        else StatusText = SmLimitSeen ? "HWiNFO: исчерпан 12-часовой лимит бесплатной версии" : "HWiNFO: недоступен";
    }

    // ================================================================ окно датчиков на виду
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int L, T, R, B; }
    [StructLayout(LayoutKind.Sequential)] struct MONITORINFO { public int cbSize; public RECT rcMonitor; public RECT rcWork; public uint dwFlags; }
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder sb, int max);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern bool ShowWindowAsync(IntPtr h, int cmd);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint f);
    [DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr h, uint f);
    [DllImport("user32.dll")] static extern bool GetMonitorInfo(IntPtr m, ref MONITORINFO mi);
    [DllImport("user32.dll")] static extern bool SystemParametersInfo(uint a, uint b, ref RECT r, uint c);
    const int SW_SHOWNOACTIVATE = 4;
    const uint SWP_NOZORDER = 0x4, SWP_NOACTIVATE = 0x10, SWP_ASYNCWINDOWPOS = 0x4000;

    static void KeepWindows() {
        HashSet<uint> pids = new HashSet<uint>();
        if (Owned && OwnPid != 0) pids.Add((uint)OwnPid);
        foreach (string n in new string[] { "HWiNFO64", "HWiNFO32", "HWiNFO_ARM64" }) {
            Process[] ps = null;
            try { ps = Process.GetProcessesByName(n); } catch { }
            if (ps == null) continue;
            foreach (Process p in ps) { try { pids.Add((uint)p.Id); } catch { } try { p.Dispose(); } catch { } }
        }
        if (pids.Count == 0) return;
        List<IntPtr> sensors = new List<IntPtr>();
        EnumWindows(delegate (IntPtr h, IntPtr l) {
            uint pid; GetWindowThreadProcessId(h, out pid);
            if (!pids.Contains(pid)) return true;
            StringBuilder sb = new StringBuilder(256); GetWindowText(h, sb, 256);
            string t = sb.ToString();
            if (t.IndexOf("Time Limit", StringComparison.OrdinalIgnoreCase) >= 0 || t.IndexOf("limit of 12 hours", StringComparison.OrdinalIgnoreCase) >= 0) {
                if (IsWindowVisible(h) && !SmLimitSeen) { SmLimitSeen = true; Event("HWiNFO сообщил: исчерпан 12-часовой лимит общей памяти (бесплатная версия)"); }
            }
            if (t.IndexOf("Sensor", StringComparison.OrdinalIgnoreCase) >= 0) sensors.Add(h);
            return true;
        }, IntPtr.Zero);
        if (!KeepVisible) return;
        foreach (IntPtr h in sensors) FixWindow(h);
    }

    static void FixWindow(IntPtr h) {
        if (!IsWindowVisible(h)) { return; }   // скрытые служебные окна HWiNFO не трогаем (иначе окно мигает)
        if (IsIconic(h)) { ShowWindowAsync(h, SW_SHOWNOACTIVATE); WindowFixes++; Event("HWiNFO: окно датчиков было свёрнуто — развёрнуто"); return; }
        RECT r; if (!GetWindowRect(h, out r)) return;
        int w = r.R - r.L, ht = r.B - r.T;
        if (w <= 0 || ht <= 0) return;
        bool off = false;
        IntPtr mon = MonitorFromWindow(h, 0 /* MONITOR_DEFAULTTONULL */);
        if (mon == IntPtr.Zero) off = true;
        else {
            MONITORINFO mi = new MONITORINFO(); mi.cbSize = Marshal.SizeOf(typeof(MONITORINFO));
            if (GetMonitorInfo(mon, ref mi)) {
                RECT a = mi.rcWork;
                long ix = Math.Max(0, Math.Min(r.R, a.R) - Math.Max(r.L, a.L));
                long iy = Math.Max(0, Math.Min(r.B, a.B) - Math.Max(r.T, a.T));
                bool titleOk = r.T >= a.T - 8 && r.T + 20 <= a.B && Math.Min(r.R, a.R) - Math.Max(r.L, a.L) >= 100;
                if (ix * iy * 2 < (long)w * ht || !titleOk) off = true;
            }
        }
        if (!off) return;
        RECT wa = new RECT();
        if (!SystemParametersInfo(0x30 /* SPI_GETWORKAREA */, 0, ref wa, 0)) return;
        int nw = Math.Min(w, wa.R - wa.L), nh = Math.Min(ht, wa.B - wa.T);
        SetWindowPos(h, IntPtr.Zero, wa.L, wa.T, nw, nh, SWP_NOZORDER | SWP_NOACTIVATE | SWP_ASYNCWINDOWPOS);
        WindowFixes++; Event("HWiNFO: окно датчиков было за пределами экрана — перенесено");
    }

    // ================================================================ правила
    static readonly Regex reCpuT = new Regex(@"^(CPU Package|Core Max|CPU \(Tctl/Tdie\)|CPU \(Tctl\)|Tctl|Tdie|CPU \(Tdie\)|CPU Die \(average\))$", RegexOptions.IgnoreCase);
    static readonly Regex reVrm = new Regex(@"VRM|\bMOS|MOSFET", RegexOptions.IgnoreCase);
    static readonly Regex reChip = new Regex(@"Chipset|\bPCH\b", RegexOptions.IgnoreCase);
    static readonly Regex reDimm = new Regex(@"DIMM|SPD Hub|\bMemory\b|\bDDR\d", RegexOptions.IgnoreCase);
    static readonly Regex reDrive = new Regex(@"S\.M\.A\.R\.T\.|^Drive|NVMe", RegexOptions.IgnoreCase);
    static readonly Regex reHdd = new Regex(@"WDC WD\d|\bWD\d{2,}[A-Z]{2}|\bST\d{3,}(DM|LM|VN|NM|NE|VX|AS|DL|NT)|HGST|\bHDS\d|\bHTS\d|\bHUS\d|TOSHIBA (DT|MQ|HDW|MG|MD)|Hitachi|SAMSUNG (HD|SP)\d|MAXTOR", RegexOptions.IgnoreCase);
    static readonly Regex rePsu = new Regex(@"\bPSU\b|Power Supply|Seasonic|Corsair (HX|RM|AX|SF)|\bNZXT (C|E)\d|\bHXi|\bRMi|\bAXi", RegexOptions.IgnoreCase);
    static readonly Regex reV12 = new Regex(@"^\+?12 ?V( Output( Voltage)?)?$", RegexOptions.IgnoreCase);
    static readonly Regex reV5 = new Regex(@"^\+?5 ?V( Output( Voltage)?)?$", RegexOptions.IgnoreCase);
    static readonly Regex reV33 = new Regex(@"^\+?3\.3 ?V( Output( Voltage)?)?$", RegexOptions.IgnoreCase);
    static readonly Regex reVcore = new Regex(@"^(CPU )?V ?core$|^CPU Core Voltage( \(SVI[23] TFN\))?$|^Core Voltage \(SVI[23] TFN\)$", RegexOptions.IgnoreCase);
    static readonly Regex reRyzen79 = new Regex(@"Ryzen\s+\d+\s+(PRO\s+)?[79]\d{3}(X3D|XT|X|F)?(\s|$|:|,)", RegexOptions.IgnoreCase);
    static readonly Regex reWhea = new Regex(@"WHEA|Hardware Errors", RegexOptions.IgnoreCase);

    static bool Has(string s, string what) { return s != null && s.IndexOf(what, StringComparison.OrdinalIgnoreCase) >= 0; }

    // mk — ключ сводки, kind 0 = предел сверху (темп.), 1 = коридор (напряжение)
    static bool Classify(HwiReading r, double cpuLimit, out string mk, out string desc, out string cat, out double lo, out double hi, out double smin, out double smax) {
        mk = desc = cat = ""; lo = double.NegativeInfinity; hi = double.PositiveInfinity; smin = 1; smax = 150;
        string s = r.Sensor ?? "", l = r.Label ?? "";
        bool gpuS = Has(s, "GPU"), cpuS = Has(s, "CPU");
        if (r.Type == 1) {
            if (gpuS) {
                if (l.Equals("GPU Temperature", StringComparison.OrdinalIgnoreCase)) { mk = "gpu"; desc = "температура видеокарты"; hi = 93; }
                else if (l.Equals("GPU Hot Spot Temperature", StringComparison.OrdinalIgnoreCase)) { mk = "hot"; desc = "горячая точка видеокарты (hot spot)"; hi = 108; }
                else if (l.Equals("GPU Memory Junction Temperature", StringComparison.OrdinalIgnoreCase)) { mk = "memj"; desc = "температура видеопамяти"; hi = 108; }
                else return false;
                cat = "gpu_temp"; return true;
            }
            if (cpuS && reCpuT.IsMatch(l)) { mk = "cpu"; desc = "температура процессора"; hi = cpuLimit; cat = "cpu_temp"; return true; }
            if (reDrive.IsMatch(s) && (l.StartsWith("Drive Temperature", StringComparison.OrdinalIgnoreCase) || l.Equals("Temperature", StringComparison.OrdinalIgnoreCase))) {
                mk = "drive"; desc = "температура накопителя"; hi = reHdd.IsMatch(s) ? 60 : 82; cat = "disk_temp"; return true;
            }
            if (rePsu.IsMatch(s) && Has(l, "Temp")) { mk = "psu"; desc = "температура блока питания"; hi = 70; cat = "psu_temp"; return true; }
            if (reVrm.IsMatch(l)) { mk = "vrm"; desc = "VRM платы"; hi = 105; cat = "vrm_temp"; return true; }
            if (reChip.IsMatch(l)) { mk = "chip"; desc = "чипсет платы"; hi = 95; cat = "chipset_temp"; return true; }
            if (reDimm.IsMatch(s) || reDimm.IsMatch(l)) { mk = "dimm"; desc = "температура памяти (DIMM)"; hi = 85; cat = "ram_temp"; return true; }
            return false;
        }
        if (r.Type == 2) {
            if (gpuS) return false;
            bool psuS = rePsu.IsMatch(s);
            cat = "voltage";
            if (reV12.IsMatch(l) || (psuS && Has(l, "12V") && Has(l, "Volt"))) { mk = "v12"; desc = "напряжение +12V"; smin = 9; smax = 15; lo = 11.0; hi = 13.0; return true; }
            if (reV5.IsMatch(l) || (psuS && Has(l, "5V") && !Has(l, "3.3") && Has(l, "Volt"))) { mk = "v5"; desc = "напряжение +5V"; smin = 4; smax = 6; lo = 4.6; hi = 5.4; return true; }
            if (reV33.IsMatch(l) || (psuS && Has(l, "3.3V") && Has(l, "Volt"))) { mk = "v33"; desc = "напряжение +3.3V"; smin = 2.8; smax = 3.8; lo = 3.0; hi = 3.6; return true; }
            if (reVcore.IsMatch(l)) { mk = "vcore"; desc = "напряжение ядра процессора (Vcore)"; smin = 0.3; smax = 2.0; hi = 1.60; return true; }
        }
        return false;
    }

    static string N(double v, string f) { return v.ToString(f, CultureInfo.CurrentCulture); }

    static void Evaluate(List<HwiReading> rs, DateTime now) {
        bool first = armFresh; armFresh = false;
        lock (stLock) {
            // процессор: производитель и TjMax
            string cpuId = CpuName ?? "";
            foreach (HwiReading r in rs) if (r.Sensor != null && r.Sensor.StartsWith("CPU [", StringComparison.OrdinalIgnoreCase)) { cpuId += " " + r.Sensor; break; }
            bool amd = Has(cpuId, "AMD") || Has(cpuId, "Ryzen") || Has(cpuId, "Threadripper");
            Dictionary<string, HwiReading> byLabel = new Dictionary<string, HwiReading>();
            foreach (HwiReading r in rs) { string k = r.SensorIndex + "|" + r.Label; if (!byLabel.ContainsKey(k)) byLabel[k] = r; }
            double tj = 0;
            const string suf = " Distance to TjMAX";
            foreach (HwiReading r in rs) {
                if (r.Type != 1 || r.Label == null || !r.Label.EndsWith(suf, StringComparison.OrdinalIgnoreCase)) continue;
                HwiReading c;
                if (byLabel.TryGetValue(r.SensorIndex + "|" + r.Label.Substring(0, r.Label.Length - suf.Length), out c)) {
                    double t = c.Value + r.Value;
                    if (t >= 70 && t <= 125) { tj = t; break; }
                }
            }
            double cpuLimit = amd ? (reRyzen79.IsMatch(cpuId) ? 97 : 93) : ((tj > 0 ? tj : 100) - 2);
            curV.Clear();
            double cpuNow = double.NaN;

            foreach (HwiReading r in rs) {
                string key = r.Key;
                double v = r.Value;
                string mk, desc, cat; double lo, hi, smin, smax;
                if (Classify(r, cpuLimit, out mk, out desc, out cat, out lo, out hi, out smin, out smax)) {
                    if (double.IsNaN(v) || v < smin || v > smax) { overCnt.Remove(key); continue; }   // мусорное значение
                    bool volt = r.Type == 2;
                    double m;
                    if (volt && mk != "vcore") { if (!minV.TryGetValue(mk, out m) || v < m) minV[mk] = v; if (!curV.TryGetValue(mk, out m) || v < m) curV[mk] = v; }
                    else { if (!maxV.TryGetValue(mk, out m) || v > m) maxV[mk] = v; if (!curV.TryGetValue(mk, out m) || v > m) curV[mk] = v; }
                    if (mk == "cpu" && (double.IsNaN(cpuNow) || v > cpuNow)) cpuNow = v;
                    bool bad = v >= hi || v < lo;
                    if (volt && mk == "vcore") bad = v > hi;
                    if (!bad) { overCnt.Remove(key); continue; }
                    int cnt; overCnt.TryGetValue(key, out cnt); cnt++; overCnt[key] = cnt;
                    if (cnt >= 2) {
                        string tail = " [" + r.SensorUser + ": " + r.LabelUser + "]";
                        string why;
                        if (!volt) why = "HWiNFO: " + desc + " " + N(v, "0") + " °C (предел " + N(hi, "0") + ")";
                        else if (v < lo) why = "HWiNFO: " + desc + " " + N(v, "0.00") + " В — ниже нормы (минимум " + N(lo, "0.00") + ")";
                        else why = "HWiNFO: " + desc + " " + N(v, mk == "vcore" ? "0.000" : "0.00") + " В — выше нормы (максимум " + N(hi, "0.00") + ")";
                        Trip(why + tail, cat);
                        return;
                    }
                    continue;
                }
                // троттлинг / PROCHOT / лимит мощности (значения Yes/No)
                if ((r.Type == 0 || r.Type == 8) && r.Label != null &&
                    (Has(r.Label, "Thermal Throttling") || Has(r.Label, "PROCHOT") || Has(r.Label, "Power Limit Exceeded"))) {
                    bool act = v >= 0.5 && v < 1.5;
                    DateTime since;
                    if (act) {
                        if (!thrSince.TryGetValue(key, out since)) { thrSince[key] = now; since = now; Event("HWiNFO: " + r.SensorUser + " — " + r.LabelUser + ": да"); }
                        if (Has(r.Label, "Thermal Throttling") && Has(r.Sensor, "CPU") && (now - since).TotalSeconds >= 5) {
                            Trip("HWiNFO: процессор упёрся в термозащиту (" + r.LabelUser + " — более 5 с подряд)", "cpu_temp");
                            return;
                        }
                    } else thrSince.Remove(key);
                    continue;
                }
                // ошибки WHEA
                if (reWhea.IsMatch(r.Sensor ?? "") && Has(r.Label, "Error") && !double.IsNaN(v) && v >= 0) {
                    double b;
                    if (!wheaBase.TryGetValue(key, out b)) { wheaBase[key] = v; continue; }
                    if (v > b + 0.5) { Trip("HWiNFO: аппаратная ошибка WHEA во время теста (" + r.LabelUser + ": было " + N(b, "0") + ", стало " + N(v, "0") + ")", "whea"); return; }
                }
            }
            // вентилятор процессора
            foreach (HwiReading r in rs) {
                if (r.Type != 3 || !Has(r.Label, "CPU") || double.IsNaN(r.Value) || r.Value < 0 || r.Value > 20000) continue;
                string key = r.Key;
                if (first) { if (r.Value > 300) fanBase[key] = r.Value; continue; }
                if (!fanBase.ContainsKey(key)) continue;
                if (r.Value < 100 && !double.IsNaN(cpuNow) && cpuNow > 70) {
                    int z; fanZero.TryGetValue(key, out z); z++; fanZero[key] = z;
                    if (z >= 3) { Trip("HWiNFO: остановился вентилятор процессора (" + r.LabelUser + ": " + N(r.Value, "0") + " об/мин при " + N(cpuNow, "0") + " °C)", "fan"); return; }
                } else fanZero.Remove(key);
            }
        }
    }

    static readonly HashSet<string> ignoredCats = new HashSet<string>();
    public static string Category = "";
    static Type GuardType() {
        foreach (Assembly a in AppDomain.CurrentDomain.GetAssemblies()) {
            Type t = null;
            try { t = a.GetType("DiagGuard", false); } catch { }
            if (t != null) return t;
        }
        return null;
    }
    static bool GuardIgnores(Type gt, string category) {
        // пользователь уже решил «продолжить на свой риск» для этого вида аномалии (DiagGuard.IsIgnored)
        try {
            MethodInfo m = gt.GetMethod("IsIgnored", BindingFlags.Public | BindingFlags.Static, null, new Type[] { typeof(string) }, null);
            if (m != null) return (bool)m.Invoke(null, new object[] { category });
        } catch { }
        return false;
    }
    static void Trip(string reason, string category) {
        if (Tripped || ignoredCats.Contains(category)) return;
        Type gt = null;
        try { gt = GuardType(); } catch { }
        if (gt != null && GuardIgnores(gt, category)) {
            ignoredCats.Add(category);
            Event("(пропущено по решению пользователя) " + reason);
            return;
        }
        Reason = reason; Category = category; Tripped = true;
        Event("СТОП: " + reason);
        string snap = Snapshot();
        try {
            if (gt == null) return;
            foreach (MethodInfo mi in gt.GetMethods(BindingFlags.Public | BindingFlags.Static)) {
                if (mi.Name != "Trip") continue;
                ParameterInfo[] ps = mi.GetParameters();
                if (ps.Length < 1 || ps.Length > 3) continue;
                string[] vals = new string[] { reason, category, snap };
                object[] args = new object[ps.Length];
                bool ok = true;
                for (int i = 0; i < ps.Length; i++) {
                    Type pt = ps[i].ParameterType;
                    if (pt == typeof(string) || pt == typeof(object)) args[i] = vals[i];
                    else if (!pt.IsValueType) args[i] = null;
                    else if (i > 0) args[i] = Activator.CreateInstance(pt);
                    else { ok = false; break; }
                }
                if (!ok) continue;
                mi.Invoke(null, args);
                return;
            }
        } catch (Exception ex) { LastError = "DiagGuard.Trip: " + ex.Message; }
    }

    static readonly string[][] sumOrder = new string[][] {
        new string[] { "cpu", "CPU", "t" }, new string[] { "vrm", "VRM", "t" }, new string[] { "chip", "чипсет", "t" },
        new string[] { "gpu", "GPU", "t" }, new string[] { "hot", "GPU hot spot", "t" }, new string[] { "memj", "видеопамять", "t" },
        new string[] { "dimm", "ОЗУ (DIMM)", "t" }, new string[] { "drive", "накопитель", "t" }, new string[] { "psu", "БП", "t" },
        new string[] { "v12", "+12V мин", "v" }, new string[] { "v5", "+5V мин", "v" }, new string[] { "v33", "+3.3V мин", "v" },
        new string[] { "vcore", "Vcore макс", "c" } };

    static string Fmt(Dictionary<string, double> mx, Dictionary<string, double> mn) {
        List<string> p = new List<string>();
        foreach (string[] o in sumOrder) {
            double v;
            Dictionary<string, double> d = (o[2] == "v") ? mn : mx;
            if (!d.TryGetValue(o[0], out v)) continue;
            if (o[2] == "t") p.Add(o[1] + " " + N(v, "0") + " °C");
            else p.Add(o[1] + " " + N(v, o[2] == "c" ? "0.000" : "0.00") + " В");
        }
        return string.Join("; ", p.ToArray());
    }
    /// <summary>Максимумы (и минимумы линий питания) с момента Arm().</summary>
    public static string MaxSummary { get { lock (stLock) { return Fmt(maxV, minV); } } }
    static string Snapshot() {
        // вызывается под stLock (из Evaluate)
        Dictionary<string, double> mn = new Dictionary<string, double>(), mx = new Dictionary<string, double>();
        foreach (KeyValuePair<string, double> kv in curV) { mx[kv.Key] = kv.Value; mn[kv.Key] = kv.Value; }
        return "сейчас: " + Fmt(mx, mn) + " | максимумы теста: " + Fmt(maxV, minV);
    }
}
'@
    try { Add-Type -TypeDefinition $src -Language CSharp -ReferencedAssemblies System.Core -ErrorAction Stop; return $true }
    catch { $G.Log.Add('hwinfo cs: ' + $_.Exception.Message) }
    if ('DiagHwi' -as [type]) { return $true }
    try { Add-Type -TypeDefinition $src -Language CSharp -ErrorAction Stop; return $true }   # если System.Core уже в ссылках по умолчанию
    catch { $G.Log.Add('hwinfo cs (2): ' + $_.Exception.Message); return $false }
}

function Hwi-Drain {
    # События сторожа HWiNFO → консоль и технический журнал
    if (-not ('DiagHwi' -as [type])) { return }
    try { foreach ($e in [DiagHwi]::DrainEvents()) { if ($e -match 'СТОП|лимит|не удалось|недоступ|завис|больше не') { Warn $e } else { Info $e } } } catch {}
}

function Start-HWiNFO {
    # Запуск HWiNFO (окно датчиков, общая память) — один раз перед первым стресс-тестом
    $G.HwiOk = $false
    if ($env:DIAG_NOHWINFO) { Info 'HWiNFO отключён (DIAG_NOHWINFO)'; return $false }
    try {
        if (-not (Load-HwiType)) { Warn 'сторож HWiNFO недоступен (ошибка загрузки модуля)'; return $false }
        if ([DiagHwi]::MonitorRunning -and [DiagHwi]::Available()) { $G.HwiOk = $true; return $true }
        try { [DiagHwi]::CpuName = "$((CIM Win32_Processor | Select-Object -First 1).Name)" } catch {}
        if ([DiagHwi]::Available()) {
            [DiagHwi]::AttachForeign()
            [DiagHwi]::StartMonitor(1000)
            $G.HwiOk = $true
            Set-LhmBoardPolling $false
            Ok 'HWiNFO уже запущен — подключаюсь к его общей памяти (закрывать его программа не будет)'
            return $true
        }
        $own = @(Get-Process -Name HWiNFO64, HWiNFO32, HWiNFO_ARM64 -ErrorAction SilentlyContinue)
        if ($own.Count) {
            Warn 'HWiNFO уже запущен, но «Shared Memory Support» в нём выключен — сторож HWiNFO не работает. Включите: Settings → Shared Memory Support, либо закройте HWiNFO перед диагностикой.'
            return $false
        }
        $exe = Get-Tool 'HWiNFO'
        if (-not $exe) { Warn 'HWiNFO не скачан — тесты пойдут без его сторожа'; return $false }
        # Настройки до первого запуска (ключи проверены по строкам HWiNFO64.exe 8.60)
        $ini = Join-Path (Split-Path $exe) 'HWiNFO64.INI'
        $txt = @('[Settings]', 'SensorsOnly=1', 'SummaryOnly=0', 'OpenSensors=1', 'OpenSystemSummary=0', 'MinimalizeMainWnd=1',
            'MinimalizeSensors=0', 'MinimalizeSensorsClose=0', 'ShowWelcomeAndProgress=0', 'SensorsSM=1', 'AutoUpdate=0', 'ValidateWindowPositions=1') -join "`r`n"
        try { [IO.File]::WriteAllText($ini, $txt + "`r`n", [Text.Encoding]::ASCII) } catch { Warn ('не удалось записать настройки HWiNFO: ' + $_.Exception.Message) }
        Info 'запускаю HWiNFO (окно датчиков останется на экране во время тестов)...'
        $hp = [DiagHwi]::Launch($exe)
        try { $G.HwiProc = Get-Process -Id $hp -ErrorAction Stop } catch { $G.HwiProc = $null }
        $t0 = Get-Date; $okSm = $false
        while (((Get-Date) - $t0).TotalSeconds -lt 40) {
            if ([DiagHwi]::Available()) { $okSm = $true; break }
            if ($G.HwiProc -and $G.HwiProc.HasExited) { break }
            Write-Host -NoNewline ("`r    {0,4:N0} с | жду датчики HWiNFO..." -f ((Get-Date) - $t0).TotalSeconds)
            Start-Sleep -Milliseconds 500
        }
        Write-Host ''
        if (-not $okSm) {
            Warn 'HWiNFO не открыл общую память за 40 с — тесты пойдут без его сторожа (если на экране окно HWiNFO с вопросом — ответьте и запустите тест заново)'
            try { [DiagHwi]::Shutdown() } catch {}
            $G.HwiProc = $null
            return $false
        }
        [DiagHwi]::StartMonitor(1000)
        Start-Sleep -Milliseconds 1200
        $G.HwiOk = $true
        Set-LhmBoardPolling $false
        Ok ([DiagHwi]::StatusText)
        return $true
    } catch { Warn ('HWiNFO: ' + $_.Exception.Message); $G.Log.Add(($_ | Out-String)); $G.HwiOk = $false; return $false }
}

function Set-LhmBoardPolling($on) {
    # HWiNFO и LibreHardwareMonitor не должны одновременно опрашивать чип датчиков платы (Super I/O, шина ISA) и SPD памяти (SMBus):
    # иначе HWiNFO показывает «ISA Lock: другое приложение блокирует HWiNFO» и перестаёт обновлять датчики.
    if (-not $G.LHM) { return }
    $lk = if (Get-Command Guard-SensorLock -ErrorAction SilentlyContinue) { Guard-SensorLock } else { $null }
    if ($lk) { [System.Threading.Monitor]::Enter($lk) }
    try { $G.LHM.IsMotherboardEnabled = [bool]$on; $G.LHM.IsMemoryEnabled = [bool]$on; $G.LhmBoardOff = -not $on }
    catch { $G.Log.Add('LHM board toggle: ' + $_.Exception.Message) }
    finally { if ($lk) { [System.Threading.Monitor]::Exit($lk) } }
}
function Get-HwiRails {
    # +12V/+5V/+3.3V/Vcore из HWiNFO (его база плат знает делители напряжений, которых нет у LHM)
    $r = @{ V12 = $null; V5 = $null; V33 = $null; Vcore = $null }
    if (-not $G.HwiOk -or -not ('DiagHwi' -as [type])) { return $r }
    try {
        foreach ($x in [DiagHwi]::Read()) {
            if ($x.Type -ne 2 -or $null -eq $x.Value -or [double]::IsNaN([double]$x.Value)) { continue }
            $n = "$($x.Label)"; $v = [double]$x.Value
            if ($null -eq $r.V12 -and $n -match '^\+12V$' -and $v -gt 9 -and $v -lt 15) { $r.V12 = $v }
            elseif ($null -eq $r.V5 -and $n -match '^\+5V$' -and $v -gt 4 -and $v -lt 6) { $r.V5 = $v }
            elseif ($null -eq $r.V33 -and $n -match '^\+3\.3V$' -and $v -gt 2.8 -and $v -lt 3.8) { $r.V33 = $v }
            elseif ($null -eq $r.Vcore -and $n -match '^Vcore$' -and $v -gt 0.3 -and $v -lt 2) { $r.Vcore = $v }
        }
    } catch {}
    return $r
}

function Stop-HWiNFO {
    # После последнего стресс-теста: снимок всех датчиков и закрытие HWiNFO (только если запускали мы)
    if (-not ('DiagHwi' -as [type])) { return }
    try {
        if ($G.HwiOk) { $snap = Hwi-Snapshot; if ($snap -and @($snap).Count) { $G.HwiLast = @($snap) } }
        [DiagHwi]::Disarm()
        $owned = [DiagHwi]::Owned
        [DiagHwi]::Shutdown()
        Hwi-Drain
        if ($owned) { Info 'HWiNFO закрыт' }
    } catch { $G.Log.Add('hwinfo stop: ' + $_.Exception.Message) }
    $G.HwiProc = $null
    $G.HwiOk = $false
    if ($G.LhmBoardOff) { Set-LhmBoardPolling $true }
}

function Hwi-Monitor-Start {
    # Взвести сторожа HWiNFO на время стресс-шага (вместе с DiagGuard)
    if (-not $G.HwiOk -or -not ('DiagHwi' -as [type])) { return $false }
    try { [DiagHwi]::StartMonitor(1000); [DiagHwi]::Arm(); return $true } catch { $G.Log.Add('hwinfo arm: ' + $_.Exception.Message); return $false }
}

function Hwi-Monitor-Stop {
    # Снять сторожа после стресс-шага; возвращает @{ Tripped; Reason; Samples; Max }
    if (-not ('DiagHwi' -as [type])) { return $null }
    try {
        [DiagHwi]::Disarm()
        Hwi-Drain
        $r = [pscustomobject]@{ Tripped = [DiagHwi]::Tripped; Reason = [DiagHwi]::Reason; Samples = [DiagHwi]::Samples; Max = [DiagHwi]::MaxSummary; Status = [DiagHwi]::StatusText }
        if (-not $G.HwiRuns) { $G.HwiRuns = New-Object System.Collections.Generic.List[object] }
        $G.HwiRuns.Add($r)
        return $r
    } catch { $G.Log.Add('hwinfo disarm: ' + $_.Exception.Message); return $null }
}

function Hwi-Snapshot {
    # Текущие показания всех датчиков HWiNFO (с мин/макс/сред самого HWiNFO с момента его запуска)
    if (-not ('DiagHwi' -as [type])) { return @() }
    try {
        $l = [DiagHwi]::Read()
        if ($null -eq $l) { return @() }
        $f = { param($v, $t) if ($null -eq $v -or [double]::IsNaN($v)) { '' } elseif ($t -eq 2) { '{0:N3}' -f $v } elseif ([math]::Abs($v) -ge 100) { '{0:N0}' -f $v } else { '{0:N1}' -f $v } }
        return @($l | ForEach-Object {
                [pscustomobject]@{ 'Устройство' = $_.SensorUser; 'Показание' = $_.LabelUser; 'Тип' = $_.TypeName
                    'Сейчас' = (& $f $_.Value $_.Type); 'Мин' = (& $f $_.Min $_.Type); 'Макс' = (& $f $_.Max $_.Type); 'Сред' = (& $f $_.Avg $_.Type); 'Ед.' = $_.Unit }
            })
    } catch { return @() }
}

function Hwi-Report($S) {
    # Итоги сторожа HWiNFO в раздел отчёта + полный лист датчиков для мастера (свёрнутая таблица)
    try {
        if ($env:DIAG_NOHWINFO) { Add-Row $S 'HWiNFO' 'отключён (DIAG_NOHWINFO)'; return }
        if (-not ('DiagHwi' -as [type]) -or ([DiagHwi]::TotalSamples -eq 0 -and -not $G.HwiRuns)) { Add-Row $S 'HWiNFO' 'не использовался'; return }
        $st = if ([DiagHwi]::Status -eq 'ok' -or -not $G.HwiOk) { '' } else { 'warn' }
        Add-Row $S 'HWiNFO' ([DiagHwi]::StatusText) $st
        $runs = @(); if ($G.HwiRuns) { foreach ($x in $G.HwiRuns) { $runs += $x } }   # @() над List[pscustomobject] в PS 5.1 падает
        $smp = 0; foreach ($r in $runs) { $smp += [int]$r.Samples }
        Add-Row $S 'Проверок датчиков HWiNFO во время тестов' ('{0:N0} (раз в секунду)' -f $smp)
        foreach ($r in $runs) { if ($r.Max) { Add-Row $S 'Максимумы за тест (HWiNFO)' $r.Max } }
        if ([DiagHwi]::Restarts -gt 0) { Add-Row $S 'Перезапусков HWiNFO' ([DiagHwi]::Restarts) 'warn' }
        if ([DiagHwi]::WindowFixes -gt 0) { Add-Row $S 'Окно HWiNFO возвращалось на экран' ('{0} раз' -f [DiagHwi]::WindowFixes) }
        $trip = @($runs | Where-Object { $_.Tripped })
        if ([DiagHwi]::Tripped -and -not $trip.Count) { $trip = @([pscustomobject]@{ Reason = [DiagHwi]::Reason }) }
        foreach ($t in $trip) {
            Add-Row $S 'Тесты остановлены сторожем HWiNFO' $t.Reason 'crit'
            if (-not ('DiagGuard' -as [type])) {
                $area = switch -regex ([DiagHwi]::Category) { 'voltage|psu' { 'Питание' } 'gpu' { 'Видеокарта' } 'ram' { 'Память' } 'disk' { 'Накопитель' } 'whea' { 'Стабильность' } default { 'Охлаждение' } }
                Add-Issue 'crit' $area ('Тест остановлен сторожем HWiNFO: ' + $t.Reason) 'Устраните причину (охлаждение, питание) и повторите тест.'
            }
        }
        $sheet = $null
        if ($G.HwiOk) { $sheet = @(Hwi-Snapshot) }
        if (-not $sheet -or -not $sheet.Count) { $sheet = @($G.HwiLast) }
        if ($sheet -and $sheet.Count) { Add-Table $S 'HWiNFO: все датчики (мин/макс/сред с момента запуска HWiNFO)' $sheet -Collapsed }
    } catch { $G.Log.Add('hwinfo report: ' + $_.Exception.Message + ' @ ' + $_.InvocationInfo.PositionMessage) }
}
