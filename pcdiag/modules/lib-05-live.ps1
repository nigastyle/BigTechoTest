# ---------------------------------------------------------------- онлайн-окно диагностики (DiagLive)
# Окно живёт в отдельном STA-потоке со своим циклом сообщений; PowerShell только кладёт данные (Live-* функции).
# Выключить: $env:DIAG_NOLIVE=1. Если компиляция не удалась — программа работает без окна ($G.LiveOk = $false).
$G.LiveOk = $false
$G.LiveReady = $false
$G.LiveLastTick = $null
$G.LiveInTick = $false
if (-not $env:DIAG_NOLIVE) {
    & {
        try {
            if (-not ('DiagLive' -as [type])) {
                $liveSrc = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;

internal class LiveStep {
    public string Name;
    public bool En;
    public int St;      // 0 ожидает, 1 идёт, 2 ok, 3 warn, 4 crit, 5 skip, 6 error
    public double T0 = -1;
    public double T1 = -1;
    public double Est = 20;   // ожидаемая длительность, с (для оценки «осталось»)
}

internal class LiveSample {
    public double T;
    public double[] V = new double[10];
}

internal class LiveIssue {
    public string Level;
    public string Text;
}

internal class LiveSnap {
    public string Title = "";
    public string Activity = "";
    public string Summary = "";
    public string Cur = "";
    public bool Finished;
    public int Score = -1;
    public double Now;
    public double Eta = -1;
    public int Pct;
    public int Done;
    public int Total;
    public int NCrit;
    public int NWarn;
    public int NInfo;
    public List<LiveStep> Steps = new List<LiveStep>();
    public List<LiveSample> Samples = new List<LiveSample>();
    public List<LiveIssue> Issues = new List<LiveIssue>();
}

public static class DiagLive {
    internal static readonly object L = new object();
    static bool started;
    static bool finished;
    static string title = "";
    static string activity = "";
    static string summary = "";
    static string curStep = "";
    static int score = -1;
    static int progDone = -1;
    static int progTotal = -1;
    static int nCrit, nWarn, nInfo;
    static double lastSampleT = -100;
    static readonly List<LiveStep> steps = new List<LiveStep>();
    static readonly List<string> log = new List<string>();
    static long logDropped;
    static readonly List<LiveSample> samples = new List<LiveSample>();
    static readonly List<LiveIssue> issues = new List<LiveIssue>();
    static readonly Stopwatch clock = new Stopwatch();
    static LiveForm form;
    static ManualResetEvent ready;
    static ManualResetEvent closed;
    static volatile IntPtr hwnd = IntPtr.Zero;
    static string repFull = "", repSum = "", repDir = "";

    // «Остановить тесты»: PowerShell читает [DiagLive]::StopRequested (Stop-Requested / Step в body.ps1)
    public static volatile bool StopRequested;
    // Окно — главное окно программы (запуск из BigTechoTest.exe): активируется при показе, итог и «Закрыть» в нём
    public static bool GuiMode;
    // Для DiagDialog (ui.cs): владелец диалогов
    public static IntPtr FormHandle { get { return hwnd; } }
    public static bool IsOpen { get { return hwnd != IntPtr.Zero; } }

    static readonly string[] StressProcs = { "prime95", "furmark", "y-cruncher", "linpack_xeon64", "memtest_vulkan", "tm5", "diskspd" };

    // Останавливает наши нагрузочные программы и внутренние тесты (DiagCore / DiagSurface, если есть)
    public static void StopAll() {
        StopRequested = true;
        try {
            foreach (Process pr in Process.GetProcesses()) {
                try {
                    string n = (pr.ProcessName ?? "").ToLowerInvariant();
                    bool hit = false;
                    foreach (string sn in StressProcs) if (n == sn || n.StartsWith(sn)) { hit = true; break; }
                    if (!hit) {
                        try { string mp = pr.MainModule.FileName; if (mp != null && mp.IndexOf("YCruncher", StringComparison.OrdinalIgnoreCase) >= 0) hit = true; } catch (Exception) { }
                    }
                    if (hit) pr.Kill();
                } catch (Exception) { }
                finally { try { pr.Dispose(); } catch (Exception) { } }
            }
        } catch (Exception) { }
        try {
            foreach (System.Reflection.Assembly asm in AppDomain.CurrentDomain.GetAssemblies()) {
                Type t = null;
                try { t = asm.GetType("DiagCore", false); } catch (Exception) { }
                if (t != null) {
                    try { System.Reflection.MethodInfo m = t.GetMethod("Stop", System.Reflection.BindingFlags.Public | System.Reflection.BindingFlags.Static, null, Type.EmptyTypes, null); if (m != null) m.Invoke(null, null); } catch (Exception) { }
                }
                Type t2 = null;
                try { t2 = asm.GetType("DiagSurface", false); } catch (Exception) { }
                if (t2 != null) {
                    try {
                        System.Reflection.FieldInfo fi = t2.GetField("Cancel", System.Reflection.BindingFlags.Public | System.Reflection.BindingFlags.Static);
                        if (fi != null && fi.FieldType == typeof(bool)) fi.SetValue(null, true);
                        else {
                            System.Reflection.PropertyInfo pi = t2.GetProperty("Cancel", System.Reflection.BindingFlags.Public | System.Reflection.BindingFlags.Static);
                            if (pi != null && pi.CanWrite && pi.PropertyType == typeof(bool)) pi.SetValue(null, true, null);
                        }
                    } catch (Exception) { }
                }
            }
        } catch (Exception) { }
    }

    internal static bool IsFinished {
        get { lock (L) { return finished; } }
    }

    static double Now() { return clock.Elapsed.TotalSeconds; }

    static LiveStep Find(string name, bool create) {
        for (int i = 0; i < steps.Count; i++) {
            if (string.Equals(steps[i].Name, name, StringComparison.Ordinal)) return steps[i];
        }
        if (!create) return null;
        LiveStep s = new LiveStep();
        s.Name = name;
        s.En = true;
        steps.Add(s);
        return s;
    }

    public static void Start(string windowTitle, string[] stepNames, bool[] stepEnabled) {
        Start(windowTitle, stepNames, stepEnabled, null);
    }

    public static void Start(string windowTitle, string[] stepNames, bool[] stepEnabled, double[] stepSeconds) {
        lock (L) {
            if (started) return;
            started = true;
            title = windowTitle ?? "";
            steps.Clear();
            if (stepNames != null) {
                for (int i = 0; i < stepNames.Length; i++) {
                    LiveStep s = new LiveStep();
                    s.Name = stepNames[i] ?? "";
                    s.En = (stepEnabled == null || i >= stepEnabled.Length) ? true : stepEnabled[i];
                    if (stepSeconds != null && i < stepSeconds.Length && stepSeconds[i] > 0) s.Est = stepSeconds[i];
                    steps.Add(s);
                }
            }
            clock.Reset();
            clock.Start();
        }
        ready = new ManualResetEvent(false);
        closed = new ManualResetEvent(false);
        Thread t = new Thread(new ThreadStart(Run));
        t.SetApartmentState(ApartmentState.STA);
        t.IsBackground = true;
        t.Name = "DiagLive";
        t.Start();
        ready.WaitOne(5000);
    }

    static void Run() {
        try {
            LiveForm f = new LiveForm(title);
            form = f;
            f.HandleCreated += delegate { try { hwnd = f.Handle; ready.Set(); } catch (Exception) { } };
            Application.AddMessageFilter(f);
            Application.Run(f);
        } catch (Exception) {
        } finally {
            form = null;
            hwnd = IntPtr.Zero;
            try { ready.Set(); } catch (Exception) { }
            try { closed.Set(); } catch (Exception) { }
        }
    }

    // Ждать, пока пользователь закроет окно (режим GUI: итоговая панель с кнопками отчётов)
    public static void WaitClosed() {
        ManualResetEvent ev = closed;
        if (ev == null) return;
        ev.WaitOne();
    }

    public static void StepStart(string name) {
        lock (L) {
            if (!started) return;
            LiveStep s = Find(name ?? "", true);
            s.En = true;
            s.St = 1;
            s.T0 = Now();
            s.T1 = -1;
            curStep = s.Name;
            activity = "";
            AddLog("► " + s.Name);
        }
    }

    public static void StepEnd(string name, string state) {
        lock (L) {
            if (!started) return;
            LiveStep s = Find(name ?? "", true);
            string st = (state ?? "ok").ToLowerInvariant();
            int code = 2;
            if (st == "warn") code = 3;
            else if (st == "crit") code = 4;
            else if (st == "skip") code = 5;
            else if (st == "error") code = 6;
            s.St = code;
            s.T1 = Now();
            if (string.Equals(curStep, s.Name, StringComparison.Ordinal)) activity = "";
        }
    }

    public static void SetActivity(string text) {
        lock (L) { activity = Clean(text, 400); }
    }

    static string Clean(string t, int max) {
        if (t == null) return "";
        t = t.Replace("\r", " ").Replace("\n", " ").Replace("\t", " ");
        if (t.Length > max) t = t.Substring(0, max);
        return t.Trim();
    }

    static void AddLog(string line) {
        log.Add(line);
        if (log.Count > 20000) { int n = log.Count - 15000; log.RemoveRange(0, n); logDropped += n; }
    }

    public static void Log(string line) {
        lock (L) {
            if (!started) return;
            string c = Clean(line, 4000);
            if (c.Length == 0) return;
            AddLog(c);
        }
    }

    // новые строки журнала с номера seq (окно забирает порциями)
    internal static List<string> LogSince(ref long seq) {
        List<string> r = new List<string>();
        lock (L) {
            if (seq < logDropped) seq = logDropped;
            for (int i = (int)(seq - logDropped); i < log.Count; i++) r.Add(log[i]);
            seq = logDropped + log.Count;
        }
        return r;
    }

    internal static string AllLog() {
        lock (L) { return string.Join("\r\n", log.ToArray()); }
    }

    public static void Sensor(double cpuT, double cpuP, double cpuClk, double gpuT, double gpuP, double gpuLoad, double gpuClk, double v12, double vcore, double fan) {
        lock (L) {
            if (!started || finished) return;
            double t = Now();
            if (t - lastSampleT < 0.4) return;
            lastSampleT = t;
            LiveSample s = new LiveSample();
            s.T = t;
            s.V[0] = cpuT; s.V[1] = cpuP; s.V[2] = cpuClk; s.V[3] = gpuT; s.V[4] = gpuP;
            s.V[5] = gpuLoad; s.V[6] = gpuClk; s.V[7] = v12; s.V[8] = vcore; s.V[9] = fan;
            samples.Add(s);
            if (samples.Count > 300) samples.RemoveRange(0, samples.Count - 300);
        }
    }

    public static void Issue(string level, string text) {
        lock (L) {
            if (!started) return;
            LiveIssue i = new LiveIssue();
            string lv = (level ?? "info").ToLowerInvariant();
            if (lv != "crit" && lv != "warn") lv = "info";
            i.Level = lv;
            i.Text = Clean(text, 600);
            issues.Add(i);
            if (lv == "crit") nCrit++; else if (lv == "warn") nWarn++; else nInfo++;
            if (issues.Count > 300) issues.RemoveRange(0, issues.Count - 300);
        }
    }

    public static void Progress(int done, int total) {
        lock (L) { progDone = done; progTotal = total; }
    }

    public static void SetReports(string full, string summaryFile, string folder) {
        lock (L) { repFull = full ?? ""; repSum = summaryFile ?? ""; repDir = folder ?? ""; }
    }
    internal static string[] Reports() { lock (L) { return new string[] { repFull, repSum, repDir }; } }

    public static void Finish(string text, int finalScore) {
        lock (L) {
            if (!started || finished) return;
            finished = true;
            summary = Clean(text, 400);
            score = finalScore;
            activity = "";
            curStep = "";
            for (int i = 0; i < steps.Count; i++) if (steps[i].St == 1) { steps[i].St = 2; steps[i].T1 = Now(); }
            AddLog("► Диагностика завершена. " + summary);
            clock.Stop();
        }
        LiveForm f = form;
        if (f != null) {
            try {
                if (f.IsHandleCreated) f.BeginInvoke(new MethodInvoker(delegate {
                    try {
                        f.OnFinished();
                        if (f.WindowState == FormWindowState.Minimized) f.WindowState = FormWindowState.Normal;
                        f.Activate();
                    } catch (Exception) { }
                }));
            } catch (Exception) { }
        }
    }

    public static void Close() {
        LiveForm f = form;
        if (f == null) return;
        try {
            if (f.IsHandleCreated) f.BeginInvoke(new MethodInvoker(delegate {
                try { f.ForceClose = true; f.Close(); } catch (Exception) { }
            }));
        } catch (Exception) { }
    }

    internal static LiveSnap TakeSnap() {
        LiveSnap s = new LiveSnap();
        lock (L) {
            s.Title = title;
            s.Activity = activity;
            s.Summary = summary;
            s.Cur = curStep;
            s.Finished = finished;
            s.Score = score;
            double now = Now();
            s.Now = now;
            s.NCrit = nCrit; s.NWarn = nWarn; s.NInfo = nInfo;
            double sumEst = 0, sumAct = 0;
            for (int i = 0; i < steps.Count; i++) {
                LiveStep a = steps[i];
                LiveStep c = new LiveStep();
                c.Name = a.Name; c.En = a.En; c.St = a.St; c.T0 = a.T0; c.T1 = a.T1; c.Est = a.Est;
                s.Steps.Add(c);
                if (a.En) { s.Total++; if (a.St >= 2) s.Done++; }
                if (a.St >= 2 && a.St != 5 && a.T0 >= 0 && a.T1 >= a.T0) { sumEst += a.Est; sumAct += a.T1 - a.T0; }
            }
            // оценка «осталось»: ожидаемые длительности, поправленные на реальную скорость уже пройденных этапов
            double factor = 1;
            if (sumEst > 60 && sumAct > 0) factor = Math.Max(0.4, Math.Min(2.5, sumAct / sumEst));
            double rem = 0;
            bool any = false;
            for (int i = 0; i < steps.Count; i++) {
                LiveStep a = steps[i];
                if (!a.En) continue;
                if (a.St == 0) { rem += a.Est * factor; any = true; }
                else if (a.St == 1) { rem += Math.Max(a.Est * factor - (now - a.T0), 5); any = true; }
            }
            if (finished) { s.Eta = 0; s.Pct = 100; }
            else if (any) { s.Eta = rem; s.Pct = (int)Math.Max(0, Math.Min(99, now * 100 / Math.Max(1, now + rem))); }
            else s.Pct = s.Total > 0 ? (int)Math.Min(99, (long)s.Done * 100 / s.Total) : 0;
            if (progDone >= 0 && progTotal > 0) { s.Done = progDone; s.Total = progTotal; }
            if (finished) s.Done = s.Total;
            s.Samples.AddRange(samples);
            int isx = Math.Max(0, issues.Count - 200);
            s.Issues.AddRange(issues.GetRange(isx, issues.Count - isx));
        }
        return s;
    }
}

// фирменная палитра «Биг Техно Клаб» — те же значения, что DiagTheme в ui.cs
internal static class LT {
    public static readonly Color Bg = Color.FromArgb(0x0e, 0x0e, 0x10);
    public static readonly Color Pn = Color.FromArgb(0x17, 0x17, 0x1a);
    public static readonly Color PlateHi = Color.FromArgb(0x23, 0x23, 0x27);
    public static readonly Color Soft = Color.FromArgb(0x21, 0x21, 0x25);
    public static readonly Color Line = Color.FromArgb(0x29, 0x29, 0x2e);
    public static readonly Color Bd = Color.FromArgb(0x3a, 0x3a, 0x40);
    public static readonly Color Ac = Color.FromArgb(0xdd, 0x0a, 0x0a);
    public static readonly Color AcHi = Color.FromArgb(0xff, 0x3a, 0x28);
    public static readonly Color AcLo = Color.FromArgb(0xc4, 0x08, 0x08);
    public static readonly Color AcText = Color.FromArgb(0xff, 0x7a, 0x68);
    public static readonly Color AcSoft = Color.FromArgb(0x3a, 0x16, 0x14);
    public static readonly Color Ok = Color.FromArgb(0x45, 0xd1, 0x7a);
    public static readonly Color Wn = Color.FromArgb(0xf0, 0xb2, 0x3c);
    public static readonly Color Cr = Color.FromArgb(0xff, 0x4d, 0x4f);
    public static readonly Color Tx = Color.FromArgb(0xf4, 0xf4, 0xf5);
    public static readonly Color Tx2 = Color.FromArgb(0xc2, 0xc2, 0xc6);
    public static readonly Color Dim = Color.FromArgb(0x8e, 0x8e, 0x94);
    public static readonly Color Faint = Color.FromArgb(0x6e, 0x6e, 0x74);
    public static readonly Color CCpu = Color.FromArgb(0x38, 0xbd, 0xf8);
    public static readonly Color CGpu = Color.FromArgb(0xc0, 0x84, 0xfc);

    public static GraphicsPath RR(RectangleF r, float rad) {
        GraphicsPath p = new GraphicsPath();
        float d = Math.Min(rad * 2f, Math.Min(r.Width, r.Height));
        if (d < 1.5f) { p.AddRectangle(r); return p; }
        p.AddArc(r.X, r.Y, d, d, 180, 90);
        p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        p.CloseFigure();
        return p;
    }
    public static void Fill(Graphics g, RectangleF r, float rad, Color c) { using (GraphicsPath p = RR(r, rad)) using (SolidBrush b = new SolidBrush(c)) g.FillPath(b, p); }
    public static void Stroke(Graphics g, RectangleF r, float rad, Color c, float w) { using (GraphicsPath p = RR(r, rad)) using (Pen pen = new Pen(c, w)) g.DrawPath(pen, p); }
    public static void Accent(Graphics g, RectangleF r, float rad, bool hover) {
        using (GraphicsPath p = RR(r, rad))
        using (LinearGradientBrush b = new LinearGradientBrush(new RectangleF(r.X, r.Y - 1, r.Width, r.Height + 2),
                   hover ? Color.FromArgb(0xff, 0x55, 0x45) : AcHi, hover ? Color.FromArgb(0xd8, 0x10, 0x10) : AcLo, 90f)) g.FillPath(b, p);
    }
    const TextFormatFlags Base = TextFormatFlags.NoPrefix | TextFormatFlags.NoPadding | TextFormatFlags.PreserveGraphicsClipping | TextFormatFlags.PreserveGraphicsTranslateTransform;
    public static void T(Graphics g, string s, Font f, Rectangle r, Color c) {
        if (string.IsNullOrEmpty(s) || r.Width <= 0) return;
        TextRenderer.DrawText(g, s, f, r, c, Base | TextFormatFlags.SingleLine | TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis);
    }
    public static void TR(Graphics g, string s, Font f, Rectangle r, Color c) {
        if (string.IsNullOrEmpty(s) || r.Width <= 0) return;
        TextRenderer.DrawText(g, s, f, r, c, Base | TextFormatFlags.SingleLine | TextFormatFlags.VerticalCenter | TextFormatFlags.Right | TextFormatFlags.EndEllipsis);
    }
    public static void TC(Graphics g, string s, Font f, Rectangle r, Color c) {
        if (string.IsNullOrEmpty(s) || r.Width <= 0) return;
        TextRenderer.DrawText(g, s, f, r, c, Base | TextFormatFlags.SingleLine | TextFormatFlags.VerticalCenter | TextFormatFlags.HorizontalCenter);
    }
    public static void W(Graphics g, string s, Font f, Rectangle r, Color c) {
        if (string.IsNullOrEmpty(s) || r.Width <= 0) return;
        TextRenderer.DrawText(g, s, f, r, c, Base | TextFormatFlags.WordBreak | TextFormatFlags.TextBoxControl | TextFormatFlags.EndEllipsis);
    }
    public static int TW(Graphics g, string s, Font f) { return TextRenderer.MeasureText(g, s ?? "", f, new Size(100000, 1000), Base | TextFormatFlags.SingleLine).Width; }
    public static Font MakeFont(string family, float size, FontStyle style, string fallback) {
        Font f = null;
        try { f = new Font(family, size, style); } catch (Exception) { f = null; }
        if (f == null || !string.Equals(f.Name, family, StringComparison.OrdinalIgnoreCase)) {
            if (f != null) f.Dispose();
            f = new Font(fallback, size, style);
        }
        return f;
    }

    // логотип BTT (как DiagGlyph.Logo в ui.cs)
    public static void Logo(Graphics g, RectangleF r) {
        SmoothingMode old = g.SmoothingMode; TextRenderingHint oth = g.TextRenderingHint;
        g.SmoothingMode = SmoothingMode.AntiAlias; g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
        Accent(g, r, r.Width * 0.22f, false);
        float s = r.Width;
        using (Font f = new Font("Segoe UI Black", Math.Max(6f, s * 0.30f), FontStyle.Bold, GraphicsUnit.Pixel))
        using (StringFormat sf = new StringFormat()) {
            sf.Alignment = StringAlignment.Center; sf.LineAlignment = StringAlignment.Center;
            g.DrawString("BTT", f, Brushes.White, new RectangleF(r.X, r.Y + s * 0.04f, s, s * 0.56f), sf);
        }
        using (Pen p = new Pen(Color.FromArgb(240, 255, 255, 255), Math.Max(1.4f, s * 0.055f))) {
            p.StartCap = LineCap.Round; p.EndCap = LineCap.Round; p.LineJoin = LineJoin.Round;
            float y = r.Y + s * 0.74f;
            g.DrawLines(p, new PointF[] { new PointF(r.X + s * 0.2f, y), new PointF(r.X + s * 0.4f, y), new PointF(r.X + s * 0.47f, y - s * 0.11f),
                new PointF(r.X + s * 0.55f, y + s * 0.09f), new PointF(r.X + s * 0.61f, y), new PointF(r.X + s * 0.8f, y) });
        }
        g.SmoothingMode = old; g.TextRenderingHint = oth;
    }

    // значки панели инструментов
    public static void Glyph(Graphics g, int kind, RectangleF r, Color c, float w) {
        float x = r.X, y = r.Y, s = Math.Min(r.Width, r.Height);
        using (Pen p = new Pen(c, w)) {
            p.StartCap = LineCap.Round; p.EndCap = LineCap.Round; p.LineJoin = LineJoin.Round;
            switch (kind) {
                case 0: // этапы: список
                    for (int i = 0; i < 3; i++) {
                        float yy = y + s * (0.22f + 0.28f * i);
                        using (SolidBrush b = new SolidBrush(c)) g.FillEllipse(b, x + s * 0.06f, yy - s * 0.07f, s * 0.14f, s * 0.14f);
                        g.DrawLine(p, x + s * 0.34f, yy, x + s * 0.94f, yy);
                    }
                    break;
                case 1: // графики
                    g.DrawLines(p, new PointF[] { new PointF(x + s * 0.06f, y + s * 0.72f), new PointF(x + s * 0.32f, y + s * 0.42f), new PointF(x + s * 0.54f, y + s * 0.6f), new PointF(x + s * 0.94f, y + s * 0.2f) });
                    g.DrawLine(p, x + s * 0.06f, y + s * 0.92f, x + s * 0.94f, y + s * 0.92f);
                    break;
                case 2: // находки: треугольник
                    g.DrawPolygon(p, new PointF[] { new PointF(x + s * 0.5f, y + s * 0.08f), new PointF(x + s * 0.94f, y + s * 0.88f), new PointF(x + s * 0.06f, y + s * 0.88f) });
                    g.DrawLine(p, x + s * 0.5f, y + s * 0.38f, x + s * 0.5f, y + s * 0.6f);
                    using (SolidBrush b = new SolidBrush(c)) g.FillEllipse(b, x + s * 0.45f, y + s * 0.7f, s * 0.1f, s * 0.1f);
                    break;
                case 3: // журнал: терминал
                    using (GraphicsPath gp = RR(new RectangleF(x + s * 0.06f, y + s * 0.12f, s * 0.88f, s * 0.76f), s * 0.1f)) g.DrawPath(p, gp);
                    g.DrawLines(p, new PointF[] { new PointF(x + s * 0.24f, y + s * 0.36f), new PointF(x + s * 0.4f, y + s * 0.5f), new PointF(x + s * 0.24f, y + s * 0.64f) });
                    g.DrawLine(p, x + s * 0.5f, y + s * 0.66f, x + s * 0.74f, y + s * 0.66f);
                    break;
                case 4: // компактно
                    using (GraphicsPath gp = RR(new RectangleF(x + s * 0.06f, y + s * 0.12f, s * 0.88f, s * 0.76f), s * 0.1f)) g.DrawPath(p, gp);
                    g.DrawLine(p, x + s * 0.06f, y + s * 0.5f, x + s * 0.94f, y + s * 0.5f);
                    using (SolidBrush b = new SolidBrush(Color.FromArgb(110, c))) g.FillRectangle(b, x + s * 0.06f, y + s * 0.12f, s * 0.88f, s * 0.38f);
                    break;
                case 5: // булавка
                    g.DrawLine(p, x + s * 0.36f, y + s * 0.1f, x + s * 0.64f, y + s * 0.1f);
                    g.DrawLines(p, new PointF[] { new PointF(x + s * 0.42f, y + s * 0.1f), new PointF(x + s * 0.4f, y + s * 0.42f), new PointF(x + s * 0.24f, y + s * 0.6f),
                        new PointF(x + s * 0.76f, y + s * 0.6f), new PointF(x + s * 0.6f, y + s * 0.42f), new PointF(x + s * 0.58f, y + s * 0.1f) });
                    g.DrawLine(p, x + s * 0.5f, y + s * 0.6f, x + s * 0.5f, y + s * 0.94f);
                    break;
                case 6: // мельче
                    g.DrawLine(p, x + s * 0.24f, y + s * 0.5f, x + s * 0.76f, y + s * 0.5f);
                    break;
                case 7: // крупнее
                    g.DrawLine(p, x + s * 0.24f, y + s * 0.5f, x + s * 0.76f, y + s * 0.5f);
                    g.DrawLine(p, x + s * 0.5f, y + s * 0.24f, x + s * 0.5f, y + s * 0.76f);
                    break;
                case 8: // справка
                    g.DrawEllipse(p, x + s * 0.08f, y + s * 0.08f, s * 0.84f, s * 0.84f);
                    g.DrawArc(p, x + s * 0.38f, y + s * 0.24f, s * 0.24f, s * 0.22f, 180, 250);
                    g.DrawLine(p, x + s * 0.52f, y + s * 0.47f, x + s * 0.5f, y + s * 0.56f);
                    using (SolidBrush b = new SolidBrush(c)) g.FillEllipse(b, x + s * 0.45f, y + s * 0.66f, s * 0.1f, s * 0.1f);
                    break;
            }
        }
    }
}

// Сохранение окна: HKCU\Software\BigTechoTest\Windows (как DiagWinCfg в ui.cs)
internal static class LiveCfg {
    const string Key = "Software\\BigTechoTest\\Windows";
    public static string Get(string name, string def) {
        try {
            using (Microsoft.Win32.RegistryKey rk = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(Key)) {
                if (rk == null) return def;
                object v = rk.GetValue(name);
                return v == null ? def : Convert.ToString(v, CultureInfo.InvariantCulture);
            }
        } catch (Exception) { return def; }
    }
    public static void Set(string name, string val) {
        try { using (Microsoft.Win32.RegistryKey rk = Microsoft.Win32.Registry.CurrentUser.CreateSubKey(Key)) { if (rk != null) rk.SetValue(name, val ?? ""); } } catch (Exception) { }
    }
    public static bool GetRect(string name, Size min, out Rectangle r) {
        r = Rectangle.Empty;
        string[] p = Get(name, "").Split(',');
        if (p.Length != 4) return false;
        int x, y, w, h;
        if (!int.TryParse(p[0], out x) || !int.TryParse(p[1], out y) || !int.TryParse(p[2], out w) || !int.TryParse(p[3], out h)) return false;
        if (w < min.Width || h < min.Height || w > 20000 || h > 20000) return false;
        r = new Rectangle(x, y, w, h);
        foreach (Screen s in Screen.AllScreens) {
            Rectangle i = Rectangle.Intersect(s.WorkingArea, new Rectangle(x, y, w, 60));
            if (i.Width >= 160 && i.Height >= 30) {
                if (r.Width > s.WorkingArea.Width) r.Width = s.WorkingArea.Width;
                if (r.Height > s.WorkingArea.Height) r.Height = s.WorkingArea.Height;
                return true;
            }
        }
        return false;
    }
}

// Кнопка панели инструментов в шапке: значок (+ подпись), состояние «включено», наведение, нажатие
internal class LiveIconButton : Button {
    public int Glyph;
    public bool Checked;
    public bool ShowLabel;
    bool hov, down;
    public LiveIconButton(int glyph, string text, string tip) {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        FlatStyle = FlatStyle.Flat; FlatAppearance.BorderSize = 0; UseVisualStyleBackColor = false;
        Glyph = glyph; Text = text; AccessibleName = text; AccessibleDescription = tip;
        AccessibleRole = AccessibleRole.PushButton;
        Cursor = Cursors.Hand; TabStop = true;
    }
    protected override void OnMouseEnter(EventArgs e) { hov = true; Invalidate(); base.OnMouseEnter(e); }
    protected override void OnMouseLeave(EventArgs e) { hov = false; down = false; Invalidate(); base.OnMouseLeave(e); }
    protected override void OnMouseDown(MouseEventArgs e) { if (e.Button == MouseButtons.Left) { down = true; Invalidate(); } base.OnMouseDown(e); }
    protected override void OnMouseUp(MouseEventArgs e) { down = false; Invalidate(); base.OnMouseUp(e); }
    protected override void OnGotFocus(EventArgs e) { Invalidate(); base.OnGotFocus(e); }
    protected override void OnLostFocus(EventArgs e) { Invalidate(); base.OnLostFocus(e); }
    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = e.Graphics;
        g.Clear(LT.Pn);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        float k = Height / 34f;
        RectangleF r = new RectangleF(0.5f, 0.5f, Width - 1.5f, Height - 1.5f);
        float rad = 9 * k;
        if (Checked) LT.Fill(g, r, rad, down ? Color.FromArgb(0x52, 0x1c, 0x1a) : (hov ? Color.FromArgb(0x48, 0x1a, 0x18) : LT.AcSoft));
        else if (down) LT.Fill(g, r, rad, LT.Bd);
        else if (hov) LT.Fill(g, r, rad, LT.PlateHi);
        if (Focused && ShowFocusCues) LT.Stroke(g, new RectangleF(r.X + 1.5f, r.Y + 1.5f, r.Width - 3, r.Height - 3), rad - 1, LT.AcText, 1.2f);
        Color c = !Enabled ? LT.Faint : (Checked ? LT.AcText : (hov ? LT.Tx : LT.Dim));
        float gs = 16 * k;
        float gx = ShowLabel ? 10 * k : (Width - gs) / 2f;
        LT.Glyph(g, Glyph, new RectangleF(gx, (Height - gs) / 2f, gs, gs), c, Math.Max(1.3f, 1.6f * k));
        if (ShowLabel) LT.T(g, Text, Font, new Rectangle((int)(gx + gs + 7 * k), 0, Width - (int)(gx + gs + 7 * k) - (int)(8 * k), Height), Checked ? LT.Tx : (hov ? LT.Tx : LT.Tx2));
    }
}

// Кнопки итоговой панели (главная — красная) и «Остановить тесты»
internal class LiveActionButton : Button {
    public int Kind;   // 0 главная, 1 обычная, 2 стоп
    public Color Back = LT.Pn;
    bool hov, down;
    public LiveActionButton(int kind, string text, string tip) {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        FlatStyle = FlatStyle.Flat; FlatAppearance.BorderSize = 0; UseVisualStyleBackColor = false;
        Kind = kind; Text = text; AccessibleName = text; AccessibleDescription = tip;
        AccessibleRole = AccessibleRole.PushButton;
        Cursor = Cursors.Hand; TabStop = true;
    }
    protected override void OnTextChanged(EventArgs e) { base.OnTextChanged(e); AccessibleName = Text; Invalidate(); }
    protected override void OnMouseEnter(EventArgs e) { hov = true; Invalidate(); base.OnMouseEnter(e); }
    protected override void OnMouseLeave(EventArgs e) { hov = false; down = false; Invalidate(); base.OnMouseLeave(e); }
    protected override void OnMouseDown(MouseEventArgs e) { if (e.Button == MouseButtons.Left) { down = true; Invalidate(); } base.OnMouseDown(e); }
    protected override void OnMouseUp(MouseEventArgs e) { down = false; Invalidate(); base.OnMouseUp(e); }
    protected override void OnEnabledChanged(EventArgs e) { Invalidate(); base.OnEnabledChanged(e); }
    protected override void OnGotFocus(EventArgs e) { Invalidate(); base.OnGotFocus(e); }
    protected override void OnLostFocus(EventArgs e) { Invalidate(); base.OnLostFocus(e); }
    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = e.Graphics;
        g.Clear(Back);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        RectangleF r = new RectangleF(0.5f, 0.5f, Width - 1.5f, Height - 1.5f);
        float rad = Math.Min(r.Height / 2f, Height * 0.3f);
        Color tc;
        if (!Enabled) {
            LT.Fill(g, r, rad, Kind == 2 ? Color.FromArgb(0x4a, 0x1c, 0x1a) : LT.Soft);
            tc = Kind == 2 ? Color.FromArgb(0xc2, 0xa0, 0x9c) : LT.Faint;
        } else if (Kind == 0 || Kind == 2) {
            if (down) LT.Fill(g, r, rad, LT.AcLo); else LT.Accent(g, r, rad, hov);
            tc = Color.White;
        } else {
            LT.Fill(g, r, rad, down ? LT.Bd : (hov ? LT.PlateHi : LT.Soft));
            LT.Stroke(g, r, rad, hov ? LT.Faint : LT.Bd, 1f);
            tc = hov ? LT.Tx : LT.Tx2;
        }
        if (Focused && ShowFocusCues && Enabled) LT.Stroke(g, new RectangleF(r.X + 2.5f, r.Y + 2.5f, r.Width - 5, r.Height - 5), Math.Max(2, rad - 2.5f), Kind == 1 ? LT.AcText : Color.FromArgb(210, 255, 255, 255), 1.3f);
        int ix = 0;
        if (Kind == 2) {
            // значок «стоп»
            float sq = Height * 0.26f;
            int tw = TextRenderer.MeasureText(g, Text, Font).Width;
            float x0 = (Width - (sq + Height * 0.2f + tw)) / 2f;
            using (GraphicsPath p = LT.RR(new RectangleF(x0, (Height - sq) / 2f, sq, sq), sq * 0.2f)) using (SolidBrush b = new SolidBrush(tc)) g.FillPath(b, p);
            ix = (int)(sq + Height * 0.2f);
            TextRenderer.DrawText(g, Text, Font, new Rectangle((int)(x0 + ix), 0, tw + 4, Height), tc, TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine | TextFormatFlags.NoPrefix | TextFormatFlags.NoPadding);
            return;
        }
        TextRenderer.DrawText(g, Text, Font, new Rectangle(0, 0, Width, Height), tc,
            TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix);
    }
}

// Совместимость: прежнее имя кнопки остановки (UI Automation ищет по имени «Остановить тесты»)
internal class LiveStopButton : LiveActionButton {
    public LiveStopButton() : base(2, "Остановить тесты", "Остановить все нагрузочные тесты. Уже собранные данные войдут в отчёт.") { }
}

// Шапка: логотип, название, панель инструментов
internal class LiveHeader : Control {
    readonly LiveForm F;
    public LiveHeader(LiveForm f) {
        F = f;
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        BackColor = LT.Pn;
    }
    internal int TitleRight;
    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = e.Graphics;
        g.Clear(LT.Pn);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        using (Pen p = new Pen(LT.Line)) g.DrawLine(p, 0, Height - 1, Width, Height - 1);
        int ls = F.S(F.compact ? 26 : 32);
        int lx = F.S(14);
        LT.Logo(g, new RectangleF(lx, (Height - ls) / 2f, ls, ls));
        int tx = lx + ls + F.S(12);
        int room = Math.Max(10, TitleRight - tx - F.S(10));
        if (F.compact) {
            LT.T(g, F.AppTitle, F.fBold, new Rectangle(tx, 0, room, Height), LT.Tx);
            return;
        }
        LT.T(g, F.AppTitle, F.fTitle, new Rectangle(tx, F.S(7), room, F.S(24)), LT.Tx);
        LT.T(g, F.SubTitle, F.fSmall, new Rectangle(tx, F.S(30), room, F.S(18)), LT.Faint);
    }
}

internal class LiveForm : Form, IMessageFilter {
    internal LiveHeader header;
    internal LivePanel panel;
    internal LiveActionButton stopBtn, bReport, bSum, bFolder, bClose;
    internal RichTextBox logBox;
    internal ToolTip tips;
    internal LiveIconButton tSteps, tCharts, tIssues, tLog, tCompact, tPin, tSmaller, tBigger, tHelp;
    internal bool showSteps = true, showCharts = true, showIssues = true, showLog = true;
    internal bool compact, pinned, logPaused;
    internal float uiScale = 1f, dpiK = 1f;
    internal string AppTitle = "BigTechoTest — диагностика ПК";
    internal string SubTitle = "Онлайн-ход проверки: этапы, датчики, находки и журнал";
    internal Font fTitle, fBig, fBold, fNorm, fSmall, fMono, fMonoB, fScore, fBtn, fCap, fLog;
    Rectangle normalBounds = Rectangle.Empty;
    bool finalShown, savedMax;
    long logSeq;
    int logLines;
    System.Windows.Forms.Timer timer;
    public bool ForceClose;

    [DllImport("dwmapi.dll")]
    static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int val, int size);
    [DllImport("user32.dll")]
    static extern IntPtr SendMessage(IntPtr h, int msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll")]
    static extern bool GetScrollInfo(IntPtr h, int bar, ref ScrollInf si);
    [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)]
    static extern int SetWindowTheme(IntPtr h, string app, string idList);
    [StructLayout(LayoutKind.Sequential)]
    struct ScrollInf { public int cbSize, fMask, nMin, nMax, nPage, nPos, nTrackPos; }

    internal int S(double v) { return (int)Math.Round(v * dpiK * uiScale); }

    public LiveForm(string title) {
        if (!string.IsNullOrEmpty(title)) AppTitle = title;
        Text = AppTitle;
        try {
            // значок BTT встроен в программу (body.ps1 кладёт его во временный файл DIAG_ICON); запасной вариант — значок из .exe
            string ic = Environment.GetEnvironmentVariable("DIAG_ICON");
            if (!string.IsNullOrEmpty(ic) && System.IO.File.Exists(ic)) { Icon = new System.Drawing.Icon(ic); ShowIcon = true; }
            else { string ex = System.IO.Path.Combine(Environment.GetEnvironmentVariable("DIAG_ROOT") ?? "", "BigTechoTest.exe"); if (System.IO.File.Exists(ex)) { Icon = System.Drawing.Icon.ExtractAssociatedIcon(ex); ShowIcon = true; } }
        } catch { }
        AutoScaleMode = AutoScaleMode.None;
        BackColor = LT.Bg;
        ForeColor = LT.Tx;
        ShowInTaskbar = true;
        KeyPreview = true;
        FormBorderStyle = FormBorderStyle.Sizable;
        StartPosition = FormStartPosition.Manual;
        AccessibleName = AppTitle;
        try { using (Graphics g = CreateGraphics()) dpiK = Math.Max(1f, g.DpiX / 96f); } catch (Exception) { }
        float sc;
        if (float.TryParse(LiveCfg.Get("Live.Scale", "1"), NumberStyles.Float, CultureInfo.InvariantCulture, out sc)) uiScale = Math.Max(0.8f, Math.Min(1.6f, sc));
        string pv = LiveCfg.Get("Live.Panels", "1111");
        if (pv.Length == 4) { showSteps = pv[0] == '1'; showCharts = pv[1] == '1'; showIssues = pv[2] == '1'; showLog = pv[3] == '1'; }
        pinned = LiveCfg.Get("Live.Pin", "0") == "1";
        TopMost = pinned;
        MakeFonts();

        Rectangle wa = Screen.PrimaryScreen.WorkingArea;
        MinimumSize = new Size(Math.Min((int)(760 * dpiK), wa.Width), Math.Min((int)(520 * dpiK), wa.Height));
        int w = Math.Min((int)(1100 * dpiK), wa.Width), h = Math.Min((int)(760 * dpiK), wa.Height);
        Bounds = new Rectangle(wa.X + (wa.Width - w) / 2, wa.Y + (wa.Height - h) / 2, w, h);
        Rectangle saved;
        if (LiveCfg.GetRect("Live.Bounds", MinimumSize, out saved)) Bounds = saved;
        savedMax = LiveCfg.Get("Live.Max", "0") == "1";

        tips = new ToolTip(); tips.InitialDelay = 350; tips.ReshowDelay = 80; tips.AutoPopDelay = 8000;

        panel = new LivePanel(this);
        panel.Dock = DockStyle.Fill;
        header = new LiveHeader(this);
        header.Dock = DockStyle.Top;
        Controls.Add(panel);
        Controls.Add(header);

        tSteps = Tool(0, "Этапы", "Показать или скрыть список этапов (Ctrl+1)", true);
        tCharts = Tool(1, "Графики", "Показать или свернуть графики датчиков (Ctrl+2)", true);
        tIssues = Tool(2, "Находки", "Показать или свернуть найденные проблемы (Ctrl+3)", true);
        tLog = Tool(3, "Журнал", "Показать или свернуть подробный журнал (Ctrl+4)", true);
        tCompact = Tool(4, "Компактно", "Компактный режим: только текущий этап, прогресс и «Стоп» (Ctrl+M)", false);
        tPin = Tool(5, "Поверх всех окон", "Поверх всех окон (Ctrl+T)", false);
        tSmaller = Tool(6, "Мельче", "Мельче (Ctrl −, Ctrl+колесо)", false);
        tBigger = Tool(7, "Крупнее", "Крупнее (Ctrl +, Ctrl+колесо)", false);
        tHelp = Tool(8, "Горячие клавиши", "Горячие клавиши (F1)", false);
        tSteps.Click += delegate { showSteps = !showSteps; StateChanged(); };
        tCharts.Click += delegate { showCharts = !showCharts; StateChanged(); };
        tIssues.Click += delegate { showIssues = !showIssues; StateChanged(); };
        tLog.Click += delegate { showLog = !showLog; StateChanged(); };
        tCompact.Click += delegate { SetCompact(!compact); };
        tPin.Click += delegate { TogglePin(); };
        tSmaller.Click += delegate { ScaleStep(-1); };
        tBigger.Click += delegate { ScaleStep(1); };
        tHelp.Click += delegate { ShowHelp(); };

        stopBtn = new LiveStopButton();
        stopBtn.Click += delegate { OnStopClick(); };
        tips.SetToolTip(stopBtn, "Остановить все нагрузочные тесты. Уже собранные данные войдут в отчёт.");
        panel.Controls.Add(stopBtn);
        bReport = Action(0, "Открыть отчёт", "Подробный технический отчёт для мастера (в браузере)");
        bSum = Action(1, "Итог для клиента", "Короткая страница для владельца компьютера: оценка и что сделать");
        bFolder = Action(1, "Папка с отчётами", "Открыть папку, где сохранены отчёты");
        bClose = Action(1, "Закрыть", "Закрыть программу");
        bReport.Click += delegate { OpenPath(DiagLive.Reports()[0], false); };
        bSum.Click += delegate { OpenPath(DiagLive.Reports()[1], false); };
        bFolder.Click += delegate { OpenPath(DiagLive.Reports()[2], true); };
        bClose.Click += delegate { ForceClose = true; Close(); };

        logBox = new RichTextBox();
        logBox.ReadOnly = true;
        logBox.BorderStyle = BorderStyle.None;
        logBox.BackColor = LT.Bg;
        logBox.ForeColor = LT.Tx2;
        logBox.ScrollBars = RichTextBoxScrollBars.Vertical;
        logBox.WordWrap = true;
        logBox.DetectUrls = false;
        logBox.HideSelection = false;
        logBox.Font = fLog;
        logBox.AccessibleName = "Журнал диагностики";
        logBox.VScroll += delegate { UpdatePaused(); };
        logBox.MouseWheel += delegate { UpdatePaused(); };
        logBox.KeyUp += delegate { UpdatePaused(); };
        logBox.HandleCreated += delegate { try { SetWindowTheme(logBox.Handle, "DarkMode_Explorer", null); } catch (Exception) { } };
        ContextMenu cm = new ContextMenu();
        cm.MenuItems.Add("Копировать", delegate { try { if (logBox.SelectionLength > 0) logBox.Copy(); } catch (Exception) { } });
        cm.MenuItems.Add("Копировать весь журнал", delegate { CopyAllLog(); });
        cm.MenuItems.Add("Выделить всё", delegate { logBox.SelectAll(); });
        cm.MenuItems.Add("-");
        cm.MenuItems.Add("К концу журнала (автопрокрутка)", delegate { ScrollLogEnd(); });
        logBox.ContextMenu = cm;
        panel.Controls.Add(logBox);

        SyncTools();
        timer = new System.Windows.Forms.Timer();
        timer.Interval = 250;
        timer.Tick += delegate { OnTick(); };
        timer.Start();
    }

    LiveIconButton Tool(int glyph, string text, string tip, bool label) {
        LiveIconButton b = new LiveIconButton(glyph, text, tip);
        b.ShowLabel = label;
        b.Font = fBold;
        tips.SetToolTip(b, tip);
        header.Controls.Add(b);
        return b;
    }

    LiveActionButton Action(int kind, string text, string tip) {
        LiveActionButton b = new LiveActionButton(kind, text, tip);
        b.Visible = false;
        b.Font = fBtn;
        tips.SetToolTip(b, tip);
        panel.Controls.Add(b);
        return b;
    }

    void MakeFonts() {
        float u = uiScale;
        fTitle = LT.MakeFont("Bahnschrift SemiBold", 12.5f * u, FontStyle.Regular, "Segoe UI Semibold");
        fBig = LT.MakeFont("Bahnschrift SemiBold", 16f * u, FontStyle.Regular, "Segoe UI Semibold");
        fBold = LT.MakeFont("Segoe UI Semibold", 9f * u, FontStyle.Regular, "Segoe UI");
        fNorm = new Font("Segoe UI", 9f * u);
        fSmall = new Font("Segoe UI", 8f * u);
        fCap = LT.MakeFont("Segoe UI Semibold", 7.5f * u, FontStyle.Regular, "Segoe UI");
        fMono = new Font("Consolas", 8f * u);
        fMonoB = new Font("Consolas", 11f * u, FontStyle.Bold);
        fScore = LT.MakeFont("Bahnschrift SemiBold", 20f * u, FontStyle.Regular, "Segoe UI Semibold");
        fBtn = LT.MakeFont("Segoe UI Semibold", 10f * u, FontStyle.Regular, "Segoe UI");
        fLog = new Font("Consolas", 9f * u);
    }

    internal void ApplyFonts() {
        foreach (Control c in header.Controls) c.Font = fBold;
        foreach (LiveActionButton b in new LiveActionButton[] { stopBtn, bReport, bSum, bFolder, bClose }) b.Font = fBtn;
        stopBtn.Font = LT.MakeFont("Segoe UI Semibold", 11.5f * uiScale, FontStyle.Regular, "Segoe UI");
        try { logBox.SelectAll(); logBox.SelectionFont = fLog; logBox.Font = fLog; logBox.Select(logBox.TextLength, 0); } catch (Exception) { }
    }

    void SyncTools() {
        tSteps.Checked = showSteps; tCharts.Checked = showCharts; tIssues.Checked = showIssues; tLog.Checked = showLog;
        tCompact.Checked = compact; tPin.Checked = pinned;
        foreach (Control c in header.Controls) c.Invalidate();
    }

    internal void StateChanged() {
        LiveCfg.Set("Live.Panels", (showSteps ? "1" : "0") + (showCharts ? "1" : "0") + (showIssues ? "1" : "0") + (showLog ? "1" : "0"));
        SyncTools();
        LayoutAll();
    }

    internal void LayoutAll() {
        if (tHelp == null || logBox == null) return;
        header.Height = S(compact ? 40 : 54);
        LayoutHeader();
        panel.DoLayout();
        header.Invalidate();
        panel.Invalidate();
    }

    void LayoutHeader() {
        int h = S(34), y = (header.Height - h) / 2, gap = S(4);
        int x = header.ClientSize.Width - S(12);
        LiveIconButton[] right = compact ? new LiveIconButton[] { tCompact, tPin } : new LiveIconButton[] { tHelp, tPin, tCompact, tBigger, tSmaller };
        foreach (LiveIconButton b in new LiveIconButton[] { tSteps, tCharts, tIssues, tLog, tCompact, tPin, tSmaller, tBigger, tHelp }) b.Visible = false;
        for (int i = 0; i < right.Length; i++) {
            LiveIconButton b = right[i];
            if (b == tSmaller) x += gap - S(1);
            x -= h; b.Bounds = new Rectangle(x, y, h, h); b.Visible = true;
            x -= (b == tCompact && !compact) ? S(12) : gap;
        }
        int rightEdge = x;
        if (!compact) {
            // переключатели панелей: с подписью, если хватает места, иначе только значки
            LiveIconButton[] tg = { tLog, tIssues, tCharts, tSteps };
            int need = 0;
            using (Graphics g = CreateGraphics()) {
                foreach (LiveIconButton b in tg) need += LT.TW(g, b.Text, fBold) + S(42) + gap;
                bool lbl = rightEdge - need > S(330);
                foreach (LiveIconButton b in tg) {
                    b.ShowLabel = lbl;
                    int bw = lbl ? LT.TW(g, b.Text, fBold) + S(42) : h;
                    x -= bw; b.Bounds = new Rectangle(x, y, bw, h); b.Visible = x > S(200);
                    x -= gap;
                }
            }
        }
        header.TitleRight = x;
    }

    internal void SetCompact(bool on) {
        if (on == compact) return;
        if (on) {
            if (WindowState == FormWindowState.Maximized) WindowState = FormWindowState.Normal;
            normalBounds = Bounds;
            compact = true;
            MinimumSize = new Size(S(420), S(150));
            Rectangle wa = Screen.FromControl(this).WorkingArea;
            int w = Math.Min(S(620), wa.Width);
            Size cs = new Size(w, S(40) + S(24) + S(122));
            Size = SizeFromClientSize(new Size(w - (Width - ClientSize.Width), cs.Height));
            Location = new Point(Math.Max(wa.X, Math.Min(Left, wa.Right - Width)), Math.Max(wa.Y, Math.Min(Top, wa.Bottom - Height)));
        } else {
            compact = false;
            MinimumSize = new Size(Math.Min((int)(760 * dpiK), Screen.FromControl(this).WorkingArea.Width), Math.Min((int)(520 * dpiK), Screen.FromControl(this).WorkingArea.Height));
            if (normalBounds.Width > 0) Bounds = normalBounds;
        }
        SyncTools();
        LayoutAll();
    }

    internal void TogglePin() {
        pinned = !pinned; TopMost = pinned;
        LiveCfg.Set("Live.Pin", pinned ? "1" : "0");
        SyncTools();
    }

    internal void ScaleStep(int dir) {
        float s = dir == 0 ? 1f : uiScale + 0.1f * dir;
        s = (float)Math.Round(Math.Max(0.8f, Math.Min(1.6f, s)) * 10f) / 10f;
        if (Math.Abs(s - uiScale) < 0.01f) return;
        uiScale = s;
        LiveCfg.Set("Live.Scale", uiScale.ToString("0.##", CultureInfo.InvariantCulture));
        MakeFonts();
        ApplyFonts();
        if (compact) { compact = false; SetCompact(true); }
        LayoutAll();
    }

    internal void ShowHelp() {
        string[][] rows = {
            new string[] { "F1", "эта справка" },
            new string[] { "Ctrl+1 / Ctrl+2", "этапы / графики" },
            new string[] { "Ctrl+3 / Ctrl+4", "находки / журнал" },
            new string[] { "Ctrl+M", "компактный режим" },
            new string[] { "Ctrl+T", "поверх всех окон" },
            new string[] { "Ctrl + / Ctrl −", "крупнее / мельче (и Ctrl+колесо)" },
            new string[] { "Ctrl+0", "обычный масштаб" },
            new string[] { "Ctrl+C", "копировать выделенное в журнале" },
            new string[] { "Ctrl+End", "к концу журнала, автопрокрутка" },
            new string[] { "Ctrl+Shift+S", "остановить тесты" } };
        if (CallUi("DiagHelpForm", "ShowFor", new object[] { this, Bounds, "Горячие клавиши", rows })) return;
        StringBuilder sb = new StringBuilder();
        foreach (string[] r in rows) sb.Append(r[0]).Append(" — ").Append(r[1]).Append("\r\n");
        MessageBox.Show(this, sb.ToString(), "Горячие клавиши");
    }

    // вызов фирменных окон из ui.cs (собирается отдельно — через отражение)
    static object uiResult;
    internal static bool CallUi(string type, string method, object[] args) {
        uiResult = null;
        try {
            foreach (System.Reflection.Assembly a in AppDomain.CurrentDomain.GetAssemblies()) {
                Type t = null;
                try { t = a.GetType(type, false); } catch (Exception) { }
                if (t == null) continue;
                foreach (System.Reflection.MethodInfo m in t.GetMethods(System.Reflection.BindingFlags.Public | System.Reflection.BindingFlags.Static)) {
                    if (m.Name != method || m.GetParameters().Length != args.Length) continue;
                    uiResult = m.Invoke(null, args);
                    return true;
                }
            }
        } catch (Exception) { }
        return false;
    }

    internal bool Ask(string title, string text, string yes, string no) {
        if (CallUi("DiagDialog", "AskOn", new object[] { this, title, text, yes, no }) && uiResult is bool) return (bool)uiResult;
        return MessageBox.Show(this, text, title, MessageBoxButtons.YesNo, MessageBoxIcon.Question, MessageBoxDefaultButton.Button2) == DialogResult.Yes;
    }

    void OnStopClick() {
        if (DiagLive.StopRequested || DiagLive.IsFinished) return;
        if (!Ask("Остановить тесты", "Остановить все тесты? Уже собранные данные войдут в отчёт, затем программа сформирует его как обычно.", "Остановить", "Продолжить")) return;
        stopBtn.Text = "Останавливаю…";
        stopBtn.Enabled = false;
        DiagLive.StopRequested = true;
        ThreadPool.QueueUserWorkItem(delegate { DiagLive.StopAll(); });
    }

    void OpenPath(string p, bool folder) {
        if (string.IsNullOrEmpty(p)) return;
        try {
            if (folder) Process.Start("explorer.exe", "\"" + p + "\"");
            else Process.Start(p);
        } catch (Exception ex) {
            CallUi("DiagDialog", "InfoOn", new object[] { this, "Не удалось открыть", p + "\n\n" + ex.Message });
        }
    }

    internal void OnFinished() {
        if (compact) SetCompact(false);
        LayoutAll();
    }

    void OnTick() {
        try {
            bool fin = DiagLive.IsFinished;
            if (fin && !finalShown) {
                string[] rp = DiagLive.Reports();
                bool have = rp[0].Length > 0 || rp[1].Length > 0;
                stopBtn.Visible = false;
                if (have || !DiagLive.GuiMode) {
                    finalShown = true;
                    bReport.Enabled = rp[0].Length > 0; bSum.Enabled = rp[1].Length > 0; bFolder.Enabled = rp[2].Length > 0;
                    if (compact) SetCompact(false);
                    panel.DoLayout();
                    if (bSum.Enabled) bSum.Focus(); else if (bReport.Enabled) bReport.Focus();
                }
            }
            PumpLog();
            if (Visible && WindowState != FormWindowState.Minimized) panel.Invalidate();
        } catch (Exception) { }
    }

    // ---------- журнал
    static Color LogColor(string s) {
        if (s.StartsWith("▶")) return LT.AcText;
        if (s.StartsWith("[OK]")) return LT.Ok;
        if (s.StartsWith("[!]")) return LT.Wn;
        if (s.StartsWith("[X]")) return LT.Cr;
        if (s.StartsWith("-")) return LT.Tx2;
        return LT.Dim;
    }

    bool LogAtBottom() {
        try {
            ScrollInf si = new ScrollInf();
            si.cbSize = Marshal.SizeOf(typeof(ScrollInf));
            si.fMask = 0x17;   // SIF_ALL
            if (!GetScrollInfo(logBox.Handle, 1, ref si)) return true;
            if (si.nMax <= 0 || si.nPage <= 0) return true;
            return si.nPos + si.nPage >= si.nMax - 2;
        } catch (Exception) { return true; }
    }

    bool pumping;
    void UpdatePaused() {
        if (pumping) return;
        bool p = !LogAtBottom();
        if (p != logPaused) { logPaused = p; panel.Invalidate(); }
    }

    internal void ScrollLogEnd() {
        try { logBox.Select(logBox.TextLength, 0); logBox.ScrollToCaret(); SendMessage(logBox.Handle, 0x115, (IntPtr)7, IntPtr.Zero); } catch (Exception) { }
        logPaused = false; panel.Invalidate();
    }

    internal void CopyAllLog() {
        try { string t = DiagLive.AllLog(); if (t.Length > 0) Clipboard.SetText(t); } catch (Exception) { }
    }

    void PumpLog() {
        if (!logBox.IsHandleCreated) return;
        List<string> lines = DiagLive.LogSince(ref logSeq);
        if (lines.Count == 0) {
            // после изменения размеров окна держим конец журнала в виду (если пользователь не листал вверх)
            if (!logPaused && logBox.SelectionLength == 0 && logBox.Visible && !LogAtBottom()) { pumping = true; try { ScrollLogEnd(); } finally { pumping = false; } }
            return;
        }
        bool atEnd = !logPaused && logBox.SelectionLength == 0;
        pumping = true;
        int selS = logBox.SelectionStart, selL = logBox.SelectionLength;
        int first = (int)SendMessage(logBox.Handle, 0xCE, IntPtr.Zero, IntPtr.Zero);   // EM_GETFIRSTVISIBLELINE
        SendMessage(logBox.Handle, 0x0B, IntPtr.Zero, IntPtr.Zero);                    // WM_SETREDRAW off
        try {
            logBox.ReadOnly = false;
            foreach (string ln in lines) {
                logBox.Select(logBox.TextLength, 0);
                logBox.SelectionColor = LogColor(ln);
                logBox.SelectedText = (logLines > 0 ? "\n" : "") + ln;
                logLines++;
            }
            if (logLines > 12000 && atEnd) {
                int cut = logBox.GetFirstCharIndexFromLine(3000);
                if (cut > 0) { logBox.Select(0, cut); logBox.SelectedText = ""; logLines -= 3000; }
            }
            logBox.ReadOnly = true;
            if (atEnd) logBox.Select(logBox.TextLength, 0);
            else {
                logBox.Select(selS, selL);
                int now = (int)SendMessage(logBox.Handle, 0xCE, IntPtr.Zero, IntPtr.Zero);
                if (now != first) SendMessage(logBox.Handle, 0xB6, IntPtr.Zero, (IntPtr)(first - now));   // EM_LINESCROLL
            }
        } catch (Exception) {
            pumping = false;
        } finally {
            logBox.ReadOnly = true;
            SendMessage(logBox.Handle, 0x0B, (IntPtr)1, IntPtr.Zero);
            logBox.Invalidate();
        }
        if (atEnd) { logBox.ScrollToCaret(); SendMessage(logBox.Handle, 0x115, (IntPtr)7, IntPtr.Zero); }
        pumping = false;
    }

    // ---------- клавиши и колесо
    protected override bool ProcessCmdKey(ref Message msg, Keys keyData) {
        if (keyData == Keys.F1) { ShowHelp(); return true; }
        if (keyData == (Keys.Control | Keys.D1)) { showSteps = !showSteps; StateChanged(); return true; }
        if (keyData == (Keys.Control | Keys.D2)) { showCharts = !showCharts; StateChanged(); return true; }
        if (keyData == (Keys.Control | Keys.D3)) { showIssues = !showIssues; StateChanged(); return true; }
        if (keyData == (Keys.Control | Keys.D4)) { showLog = !showLog; StateChanged(); return true; }
        if (keyData == (Keys.Control | Keys.M)) { SetCompact(!compact); return true; }
        if (keyData == (Keys.Control | Keys.T)) { TogglePin(); return true; }
        if (keyData == (Keys.Control | Keys.Oemplus) || keyData == (Keys.Control | Keys.Add) || keyData == (Keys.Control | Keys.Shift | Keys.Oemplus)) { ScaleStep(1); return true; }
        if (keyData == (Keys.Control | Keys.OemMinus) || keyData == (Keys.Control | Keys.Subtract)) { ScaleStep(-1); return true; }
        if (keyData == (Keys.Control | Keys.D0) || keyData == (Keys.Control | Keys.NumPad0)) { ScaleStep(0); return true; }
        if (keyData == (Keys.Control | Keys.End)) { ScrollLogEnd(); return true; }
        if (keyData == (Keys.Control | Keys.Shift | Keys.S)) { if (stopBtn.Visible && stopBtn.Enabled) OnStopClick(); return true; }
        if (keyData == (Keys.Control | Keys.C) && !logBox.Focused) {
            try { if (logBox.SelectionLength > 0) logBox.Copy(); } catch (Exception) { }
            return true;
        }
        return base.ProcessCmdKey(ref msg, keyData);
    }

    public bool PreFilterMessage(ref Message m) {
        if (m.Msg == 0x020A && (Control.ModifierKeys & Keys.Control) != 0) {
            Control c = Control.FromHandle(m.HWnd);
            if (c != null && c.FindForm() == this) {
                int delta = (short)((m.WParam.ToInt64() >> 16) & 0xFFFF);
                ScaleStep(delta > 0 ? 1 : -1);
                return true;
            }
        }
        return false;
    }

    protected override bool ShowWithoutActivation { get { return !DiagLive.GuiMode; } }

    protected override void OnHandleCreated(EventArgs e) {
        base.OnHandleCreated(e);
        try {
            int one = 1;
            if (DwmSetWindowAttribute(Handle, 20, ref one, 4) != 0) DwmSetWindowAttribute(Handle, 19, ref one, 4);
        } catch (Exception) { }
    }

    protected override void OnLoad(EventArgs e) {
        base.OnLoad(e);
        if (savedMax) WindowState = FormWindowState.Maximized;
        LayoutAll();
    }

    protected override void OnResize(EventArgs e) {
        base.OnResize(e);
        if (header != null && panel != null && tHelp != null && logBox != null) { LayoutHeader(); panel.DoLayout(); header.Invalidate(); }
    }

    protected override void OnResizeEnd(EventArgs e) { base.OnResizeEnd(e); SaveBounds(); }

    void SaveBounds() {
        try {
            if (WindowState == FormWindowState.Minimized) return;
            LiveCfg.Set("Live.Max", WindowState == FormWindowState.Maximized ? "1" : "0");
            Rectangle r = compact ? normalBounds : (WindowState == FormWindowState.Normal ? Bounds : RestoreBounds);
            if (r.Width > 0) LiveCfg.Set("Live.Bounds", string.Format(CultureInfo.InvariantCulture, "{0},{1},{2},{3}", r.X, r.Y, r.Width, r.Height));
        } catch (Exception) { }
    }

    protected override void OnFormClosing(FormClosingEventArgs e) {
        if (!ForceClose && e.CloseReason == CloseReason.UserClosing && !DiagLive.IsFinished) {
            // закрытие окна не прерывает диагностику
            e.Cancel = true;
            if (DiagLive.GuiMode) {
                object[] a = new object[] { this, "Диагностика ещё идёт",
                    "Закрыть окно сейчас нельзя: программа доделает проверку и сохранит отчёт.\n\nМожно остановить нагрузочные тесты — тогда отчёт будет готов быстрее.",
                    new string[] { "Свернуть окно", "Остановить тесты", "Отмена" } };
                int r = 0;
                if (CallUi("DiagDialog", "ChoiceOn", a) && uiResult is int) r = (int)uiResult;
                if (r == 0) WindowState = FormWindowState.Minimized;
                else if (r == 1) OnStopClick();
            } else WindowState = FormWindowState.Minimized;
            return;
        }
        SaveBounds();
        try { timer.Stop(); Application.RemoveMessageFilter(this); } catch (Exception) { }
        base.OnFormClosing(e);
    }
}

internal class LivePanel : Control {
    readonly LiveForm F;
    float scrollY, maxScroll;
    bool manual;
    string lastCur = "";
    Rectangle listRect = Rectangle.Empty, issRect = Rectangle.Empty;
    int rowH = 26, issScroll;
    int tick;
    // прямоугольники панелей и их заголовков (для сворачивания щелчком)
    internal Rectangle statusR, stepsR, chartsR, issuesR, logR, logStripR, logEndR, logCopyR;
    Rectangle hdrCharts, hdrIssues, hdrLog, hdrSteps;
    int hoverHdr = -1;

    public LivePanel(LiveForm f) {
        F = f;
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        DoubleBuffered = true;
        BackColor = LT.Bg;
    }

    int S(double v) { return F.S(v); }

    static string FmtTime(double sec) {
        if (sec < 0) sec = 0;
        int t = (int)sec;
        int h = t / 3600, m = (t / 60) % 60, s = t % 60;
        if (h > 0) return string.Format("{0}:{1:00}:{2:00}", h, m, s);
        return string.Format("{0:00}:{1:00}", m, s);
    }

    static string FmtEta(double sec) {
        if (sec < 0) return "";
        if (sec < 60) return "меньше минуты";
        int m = (int)Math.Ceiling(sec / 60.0);
        if (m < 60) return "≈ " + m + " мин";
        return string.Format("≈ {0} ч {1:00} мин", m / 60, m % 60);
    }

    void Panel(Graphics g, Rectangle r) {
        LT.Fill(g, r, S(12), LT.Pn);
        LT.Stroke(g, new RectangleF(r.X + 0.5f, r.Y + 0.5f, r.Width - 1, r.Height - 1), S(12), LT.Line, 1f);
    }

    // ---------- раскладка
    internal void DoLayout() {
        int W = ClientSize.Width, H = ClientSize.Height;
        if (W < 50 || H < 50 || F.stopBtn == null || F.bClose == null || F.logBox == null) return;
        int pad = S(12), gap = S(10), strip = S(36);
        bool fin = DiagLive.IsFinished;
        bool showFinal = fin && F.bReport != null && !F.stopBtn.Visible && (F.bReport.Enabled || F.bSum.Enabled || !DiagLive.GuiMode);
        int cardH = F.compact ? H - 2 * pad : (fin ? S(168) : S(122));
        statusR = new Rectangle(pad, pad, W - 2 * pad, cardH);
        // кнопка «Стоп»
        int sbW = S(F.compact ? 168 : 200), sbH = S(46);
        F.stopBtn.Bounds = new Rectangle(statusR.Right - S(18) - sbW, statusR.Y + (statusR.Height - sbH) / 2, sbW, sbH);
        F.stopBtn.Visible = !fin;
        // итоговые кнопки
        LiveActionButton[] fb = { F.bReport, F.bSum, F.bFolder, F.bClose };
        int bx = statusR.X + S(18) + S(84) + S(18), by = statusR.Bottom - S(18) - S(40);
        using (Graphics g = CreateGraphics()) {
            foreach (LiveActionButton b in fb) {
                int bw = LT.TW(g, b.Text, F.fBtn) + S(40);
                b.Bounds = new Rectangle(bx, by, bw, S(40));
                bx += bw + S(10);
                b.Visible = showFinal && !F.compact;
                b.Back = LT.Pn;
            }
        }
        int top = statusR.Bottom + gap;
        bool body = !F.compact && H - top > S(80);
        // этапы слева
        int lw = 0;
        if (body && F.showSteps) {
            lw = Math.Max(S(250), Math.Min(S(380), (int)(W * 0.3)));
            stepsR = new Rectangle(pad, top, lw, H - pad - top);
        } else stepsR = Rectangle.Empty;
        int rx = lw > 0 ? pad + lw + gap : pad, rw = W - pad - rx;
        int avail = H - pad - top;
        chartsR = issuesR = logR = Rectangle.Empty;
        if (body) {
            bool[] open = { F.showCharts, F.showIssues, F.showLog };
            int[] pref = { S(200), S(140), 0 };
            int nOpen = 0; foreach (bool o in open) if (o) nOpen++;
            int fixedH = 0, flex = -1;
            for (int i = 2; i >= 0; i--) if (open[i] && flex < 0) flex = i;
            for (int i = 0; i < 3; i++) fixedH += open[i] ? (i == flex ? 0 : pref[i]) : strip;
            fixedH += 2 * gap;
            int flexH = avail - fixedH;
            if (flex >= 0 && flexH < S(120)) {
                // мало места: ужимаем фиксированные панели
                int over = S(120) - flexH;
                for (int i = 0; i < 3 && over > 0; i++) if (open[i] && i != flex) { int cut = Math.Min(over, pref[i] - S(90)); if (cut > 0) { pref[i] -= cut; over -= cut; } }
                flexH = S(120) - over;
            }
            int y = top;
            Rectangle[] rs = new Rectangle[3];
            for (int i = 0; i < 3; i++) {
                int h = open[i] ? (i == flex ? Math.Max(strip, flexH) : pref[i]) : strip;
                rs[i] = new Rectangle(rx, y, rw, h);
                y += h + gap;
            }
            chartsR = rs[0]; issuesR = rs[1]; logR = rs[2];
        }
        hdrSteps = stepsR.Width > 0 ? new Rectangle(stepsR.X, stepsR.Y, stepsR.Width, strip) : Rectangle.Empty;
        hdrCharts = chartsR.Width > 0 ? new Rectangle(chartsR.X, chartsR.Y, chartsR.Width / 2, strip) : Rectangle.Empty;
        hdrIssues = issuesR.Width > 0 ? new Rectangle(issuesR.X, issuesR.Y, S(120), strip) : Rectangle.Empty;
        hdrLog = logR.Width > 0 ? new Rectangle(logR.X, logR.Y, S(120), strip) : Rectangle.Empty;
        logStripR = logR.Width > 0 ? new Rectangle(logR.X, logR.Y, logR.Width, strip) : Rectangle.Empty;
        // журнал — настоящий текстовый элемент (выделение, Ctrl+C, прокрутка)
        if (logR.Width > 0 && F.showLog && logR.Height > strip + S(30)) {
            F.logBox.Bounds = new Rectangle(logR.X + S(12), logR.Y + strip, logR.Width - S(16), logR.Height - strip - S(8));
            F.logBox.Visible = true;
        } else F.logBox.Visible = false;
        Invalidate();
    }

    protected override void OnResize(EventArgs e) { base.OnResize(e); DoLayout(); }

    int HdrHit(Point p) {
        if (hdrSteps.Contains(p)) return 0;
        if (hdrCharts.Contains(p)) return 1;
        if (hdrIssues.Contains(p)) return 2;
        if (hdrLog.Contains(p)) return 3;
        if (logEndR.Contains(p)) return 4;
        if (logCopyR.Contains(p)) return 5;
        return -1;
    }

    protected override void OnMouseMove(MouseEventArgs e) {
        base.OnMouseMove(e);
        int h = HdrHit(e.Location);
        if (h != hoverHdr) {
            hoverHdr = h;
            Cursor = h >= 0 ? Cursors.Hand : Cursors.Default;
            string tip = h == 0 ? "Скрыть этапы (Ctrl+1)" : h == 1 ? (F.showCharts ? "Свернуть графики (Ctrl+2)" : "Развернуть графики (Ctrl+2)")
                : h == 2 ? (F.showIssues ? "Свернуть находки (Ctrl+3)" : "Развернуть находки (Ctrl+3)") : h == 3 ? (F.showLog ? "Свернуть журнал (Ctrl+4)" : "Развернуть журнал (Ctrl+4)")
                : h == 4 ? "Перейти к концу журнала и включить автопрокрутку (Ctrl+End)" : h == 5 ? "Скопировать весь журнал в буфер обмена" : null;
            try { F.tips.SetToolTip(this, tip); } catch (Exception) { }
            Invalidate();
        }
    }
    protected override void OnMouseLeave(EventArgs e) { base.OnMouseLeave(e); if (hoverHdr != -1) { hoverHdr = -1; Invalidate(); } }

    protected override void OnMouseDown(MouseEventArgs e) {
        base.OnMouseDown(e);
        if (e.Button != MouseButtons.Left) return;
        int h = HdrHit(e.Location);
        if (h == 0) { F.showSteps = !F.showSteps; F.StateChanged(); }
        else if (h == 1) { F.showCharts = !F.showCharts; F.StateChanged(); }
        else if (h == 2) { F.showIssues = !F.showIssues; F.StateChanged(); }
        else if (h == 3) { F.showLog = !F.showLog; F.StateChanged(); }
        else if (h == 4) F.ScrollLogEnd();
        else if (h == 5) { F.CopyAllLog(); }
    }

    protected override void OnMouseWheel(MouseEventArgs e) {
        base.OnMouseWheel(e);
        if (listRect.Contains(e.Location)) {
            manual = true;
            scrollY -= (e.Delta / 120f) * rowH * 2;
            if (scrollY < 0) scrollY = 0;
            if (scrollY > maxScroll) scrollY = maxScroll;
            Invalidate();
        } else if (issRect.Contains(e.Location)) {
            issScroll = Math.Max(0, issScroll - Math.Sign(e.Delta) * 2);
            Invalidate();
        }
    }

    protected override void OnPaint(PaintEventArgs e) {
        try { Draw(e.Graphics); } catch (Exception) { }
    }

    void Draw(Graphics g) {
        tick++;
        g.Clear(LT.Bg);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.TextRenderingHint = TextRenderingHint.ClearTypeGridFit;
        if (statusR.Width <= 0) return;
        LiveSnap s = DiagLive.TakeSnap();
        DrawStatus(g, statusR, s);
        if (stepsR.Width > 0) DrawSteps(g, stepsR, s);
        if (chartsR.Width > 0) DrawCharts(g, chartsR, s);
        if (issuesR.Width > 0) DrawIssues(g, issuesR, s);
        if (logR.Width > 0) DrawLogFrame(g, logR);
    }

    // заголовок панели со стрелкой сворачивания
    void Strip(Graphics g, Rectangle r, string title, bool open, bool hov, string extra) {
        Rectangle hr = new Rectangle(r.X, r.Y, r.Width, S(36));
        float cx = r.X + S(18), cy = hr.Y + hr.Height / 2f;
        using (Pen p = new Pen(hov ? LT.Tx : LT.Faint, Math.Max(1.4f, S(1.6)))) {
            p.StartCap = LineCap.Round; p.EndCap = LineCap.Round;
            if (open) g.DrawLines(p, new PointF[] { new PointF(cx - S(4), cy - S(2)), new PointF(cx, cy + S(2)), new PointF(cx + S(4), cy - S(2)) });
            else g.DrawLines(p, new PointF[] { new PointF(cx - S(2), cy - S(4)), new PointF(cx + S(2), cy), new PointF(cx - S(2), cy + S(4)) });
        }
        int tw = LT.TW(g, title, F.fBold);
        LT.T(g, title, F.fBold, new Rectangle(r.X + S(30), hr.Y, tw + S(4), hr.Height), hov ? Color.White : LT.Tx);
        if (!string.IsNullOrEmpty(extra)) LT.T(g, extra, F.fSmall, new Rectangle(r.X + S(36) + tw, hr.Y, Math.Max(10, r.Width / 2 - tw), hr.Height), LT.Faint);
    }

    // ---------- текущий этап, прогресс, оценка времени / итог
    void DrawStatus(Graphics g, Rectangle r, LiveSnap s) {
        Panel(g, r);
        if (s.Finished) { DrawFinal(g, r, s); return; }
        int ix = r.X + S(20);
        int rightW = F.stopBtn.Visible ? F.stopBtn.Width + S(36) : S(20);
        int iw = r.Width - S(20) - rightW;
        bool cmp = F.compact;
        int y = r.Y + (cmp ? (r.Height - S(98)) / 2 : S(14));
        string cap = s.Cur.Length > 0 ? "СЕЙЧАС" : "ПОДГОТОВКА";
        LT.T(g, cap, F.fCap, new Rectangle(ix, y, S(200), S(16)), LT.AcText);
        LT.TR(g, FmtTime(s.Now), F.fMonoB, new Rectangle(r.Right - rightW - S(130), y - S(2), S(130), S(20)), LT.Tx);
        string stage = s.Cur.Length > 0 ? s.Cur : "Подготовка к диагностике…";
        LT.T(g, stage, cmp ? F.fTitle : F.fBig, new Rectangle(ix, y + S(16), iw, S(32)), LT.Tx);
        LT.T(g, s.Activity.Length > 0 ? s.Activity : " ", F.fNorm, new Rectangle(ix, y + S(48), iw, S(20)), LT.Dim);
        int barY = y + S(74);
        Rectangle bar = new Rectangle(ix, barY, iw, S(8));
        LT.Fill(g, bar, S(4), LT.Bd);
        int fw = (int)(bar.Width * s.Pct / 100.0);
        if (fw >= S(8)) {
            Rectangle fr = new Rectangle(bar.X, bar.Y, fw, bar.Height);
            using (GraphicsPath fp = LT.RR(fr, S(4)))
            using (LinearGradientBrush lb = new LinearGradientBrush(new Rectangle(fr.X - 1, fr.Y, fr.Width + 2, fr.Height), LT.Ac, LT.AcHi, 0f)) g.FillPath(lb, fp);
        }
        string eta = s.Eta >= 0 ? "  ·  осталось " + FmtEta(s.Eta) : "";
        string line = string.Format("{0}%  ·  этап {1} из {2}{3}", s.Pct, Math.Min(s.Total, s.Done + (s.Cur.Length > 0 ? 1 : 0)), s.Total, eta);
        LT.T(g, line, F.fSmall, new Rectangle(ix, barY + S(12), iw, S(18)), LT.Dim);
        if (DiagLive.StopRequested) LT.TR(g, "остановка тестов…", F.fSmall, new Rectangle(ix, barY + S(12), iw, S(18)), LT.Wn);
    }

    void DrawFinal(Graphics g, Rectangle r, LiveSnap s) {
        Rectangle ring = new Rectangle(r.X + S(20), r.Y + S(18), S(84), S(84));
        if (s.Score >= 0) DrawScore(g, ring, s.Score);
        else LT.Fill(g, ring, S(20), LT.Soft);
        int ix = ring.Right + S(18), iw = r.Right - ix - S(20);
        LT.T(g, "ГОТОВО · " + FmtTime(s.Now), F.fCap, new Rectangle(ix, r.Y + S(18), iw, S(16)), LT.Ok);
        string verdict = s.Score < 0 ? "Диагностика завершена" : s.Score >= 85 ? "Компьютер в хорошем состоянии" : s.Score >= 60 ? "Есть замечания — см. отчёт" : "Найдены серьёзные проблемы";
        LT.T(g, verdict, F.fBig, new Rectangle(ix, r.Y + S(34), iw, S(32)), LT.Tx);
        LT.T(g, s.Summary, F.fNorm, new Rectangle(ix, r.Y + S(66), iw, S(20)), LT.Dim);
        if (!F.bReport.Visible) LT.T(g, "Формирую отчёт…", F.fNorm, new Rectangle(ix, r.Bottom - S(46), iw, S(24)), LT.Faint);
    }

    void DrawScore(Graphics g, Rectangle r, int score) {
        Color c = score >= 85 ? LT.Ok : (score >= 60 ? LT.Wn : LT.Cr);
        Rectangle ring = new Rectangle(r.X + S(4), r.Y + S(4), r.Width - S(8), r.Height - S(8));
        using (Pen p = new Pen(LT.Bd, S(6))) g.DrawEllipse(p, ring);
        using (Pen p = new Pen(c, S(6))) {
            p.StartCap = LineCap.Round; p.EndCap = LineCap.Round;
            float sweep = Math.Max(2f, Math.Min(100, score) * 3.6f);
            g.DrawArc(p, ring, -90f, sweep);
        }
        LT.TC(g, score.ToString(CultureInfo.InvariantCulture), F.fScore, new Rectangle(r.X, r.Y - S(4), r.Width, r.Height - S(8)), c);
        LT.TC(g, "из 100", F.fCap, new Rectangle(r.X, r.Y + r.Height / 2 + S(6), r.Width, S(14)), LT.Faint);
    }

    // ---------- этапы
    void DrawSteps(Graphics g, Rectangle sr, LiveSnap s) {
        Panel(g, sr);
        Strip(g, sr, "Этапы", true, hoverHdr == 0, s.Done + " из " + s.Total);
        listRect = new Rectangle(sr.X + S(6), sr.Y + S(38), sr.Width - S(12), sr.Height - S(44));
        rowH = S(28);
        int content = s.Steps.Count * rowH;
        maxScroll = Math.Max(0, content - listRect.Height);
        int runIdx = -1;
        for (int i = 0; i < s.Steps.Count; i++) if (s.Steps[i].St == 1) runIdx = i;
        if (!string.Equals(lastCur, s.Cur, StringComparison.Ordinal)) { lastCur = s.Cur; manual = false; }
        if (!manual) {
            float target = 0;
            if (runIdx >= 0) target = runIdx * rowH + rowH / 2f - listRect.Height / 2f;
            if (target < 0) target = 0;
            if (target > maxScroll) target = maxScroll;
            float d = target - scrollY;
            if (Math.Abs(d) < 1f) scrollY = target; else scrollY += d * 0.45f;
        }
        if (scrollY > maxScroll) scrollY = maxScroll;
        if (scrollY < 0) scrollY = 0;

        Region old = g.Clip;
        g.SetClip(listRect);
        int first = Math.Max(0, (int)(scrollY / rowH));
        for (int i = first; i < s.Steps.Count; i++) {
            int y = listRect.Y + (int)(i * rowH - scrollY);
            if (y > listRect.Bottom) break;
            LiveStep st = s.Steps[i];
            int eff = (!st.En && st.St == 0) ? 5 : st.St;
            Rectangle row = new Rectangle(listRect.X, y, listRect.Width - S(8), rowH);
            if (eff == 1) {
                LT.Fill(g, new Rectangle(row.X, row.Y + 1, row.Width, row.Height - 2), S(7), Color.FromArgb(48, LT.Ac));
                using (SolidBrush b = new SolidBrush(LT.Ac)) g.FillRectangle(b, row.X, row.Y + S(6), S(3), row.Height - S(12));
            }
            DrawIcon(g, eff, row.X + S(18), row.Y + row.Height / 2f, S(7));
            Color tc = eff == 1 ? Color.White : (eff == 5 ? LT.Faint : (eff == 0 ? LT.Dim : LT.Tx));
            Font tf = eff == 1 ? F.fBold : F.fNorm;
            string tm = "";
            if (st.T0 >= 0 && eff != 5) tm = FmtTime((st.T1 >= 0 ? st.T1 : s.Now) - st.T0);
            int tmW = tm.Length > 0 ? S(46) : 0;
            LT.T(g, st.Name, tf, new Rectangle(row.X + S(34), row.Y, row.Width - S(36) - tmW, row.Height), tc);
            if (tmW > 0) LT.TR(g, tm, F.fMono, new Rectangle(row.Right - tmW - S(2), row.Y, tmW, row.Height), eff == 1 ? LT.Tx : LT.Faint);
        }
        g.Clip = old;
        if (maxScroll > 0) {
            int th = Math.Max(S(24), (int)((long)listRect.Height * listRect.Height / content));
            int ty = listRect.Y + (int)((listRect.Height - th) * (scrollY / maxScroll));
            LT.Fill(g, new Rectangle(listRect.Right - S(5), ty, S(3), th), S(1), Color.FromArgb(120, LT.Faint));
        }
    }

    void DrawIcon(Graphics g, int st, float cx, float cy, float r) {
        float lw = Math.Max(1.5f, r * 0.28f);
        RectangleF c = new RectangleF(cx - r, cy - r, 2 * r, 2 * r);
        switch (st) {
            case 1: {
                int a = 50 + (int)(40 * (1 + Math.Sin(tick * 0.5)) / 2);
                using (SolidBrush b = new SolidBrush(Color.FromArgb(a, LT.Ac))) g.FillEllipse(b, cx - r - 3, cy - r - 3, 2 * r + 6, 2 * r + 6);
                using (SolidBrush b = new SolidBrush(LT.Ac)) g.FillEllipse(b, c);
                PointF[] tri = new PointF[] { new PointF(cx - r * 0.25f, cy - r * 0.5f), new PointF(cx - r * 0.25f, cy + r * 0.5f), new PointF(cx + r * 0.55f, cy) };
                g.FillPolygon(Brushes.White, tri);
                break;
            }
            case 2: {
                using (SolidBrush b = new SolidBrush(LT.Ok)) g.FillEllipse(b, c);
                using (Pen p = new Pen(Color.White, lw)) {
                    p.StartCap = LineCap.Round; p.EndCap = LineCap.Round; p.LineJoin = LineJoin.Round;
                    g.DrawLines(p, new PointF[] { new PointF(cx - r * 0.45f, cy), new PointF(cx - r * 0.1f, cy + r * 0.38f), new PointF(cx + r * 0.5f, cy - r * 0.35f) });
                }
                break;
            }
            case 3: {
                using (SolidBrush b = new SolidBrush(LT.Wn)) g.FillEllipse(b, c);
                using (Pen p = new Pen(Color.White, lw)) {
                    p.StartCap = LineCap.Round; p.EndCap = LineCap.Round;
                    g.DrawLine(p, cx, cy - r * 0.55f, cx, cy + r * 0.1f);
                    g.DrawLine(p, cx, cy + r * 0.48f, cx, cy + r * 0.5f);
                }
                break;
            }
            case 4:
            case 6: {
                using (SolidBrush b = new SolidBrush(st == 4 ? LT.Cr : Color.FromArgb(0xb9, 0x1c, 0x1c))) g.FillEllipse(b, c);
                using (Pen p = new Pen(Color.White, lw)) {
                    p.StartCap = LineCap.Round; p.EndCap = LineCap.Round;
                    g.DrawLine(p, cx - r * 0.4f, cy - r * 0.4f, cx + r * 0.4f, cy + r * 0.4f);
                    g.DrawLine(p, cx - r * 0.4f, cy + r * 0.4f, cx + r * 0.4f, cy - r * 0.4f);
                }
                break;
            }
            case 5: {
                using (Pen p = new Pen(LT.Faint, lw)) { p.StartCap = LineCap.Round; p.EndCap = LineCap.Round; g.DrawLine(p, cx - r * 0.5f, cy, cx + r * 0.5f, cy); }
                break;
            }
            default: {
                using (Pen p = new Pen(LT.Faint, 1.5f)) g.DrawEllipse(p, c);
                break;
            }
        }
    }

    // ---------- графики датчиков
    static double LastVal(List<LiveSample> smp, int idx) {
        for (int i = smp.Count - 1; i >= 0; i--) {
            double v = smp[i].V[idx];
            if (!double.IsNaN(v) && !double.IsInfinity(v)) return v;
        }
        return double.NaN;
    }

    void DrawCharts(Graphics g, Rectangle r, LiveSnap s) {
        Panel(g, r);
        Strip(g, r, "Датчики", F.showCharts, hoverHdr == 1, null);
        DrawChips(g, new Rectangle(r.X + r.Width / 3, r.Y + S(6), r.Width - r.Width / 3 - S(12), S(24)), s.Samples);
        if (!F.showCharts || r.Height < S(90)) return;
        Rectangle body = new Rectangle(r.X + S(8), r.Y + S(38), r.Width - S(16), r.Height - S(44));
        int n = 3, gap = S(8);
        bool horiz = body.Width >= S(600);
        double t1 = s.Now, win = Math.Min(300.0, Math.Max(60.0, s.Now));
        Rectangle[] cr = new Rectangle[n];
        for (int i = 0; i < n; i++) {
            if (horiz) { int w = (body.Width - 2 * gap) / 3; cr[i] = new Rectangle(body.X + i * (w + gap), body.Y, w, body.Height); }
            else { int h = (body.Height - 2 * gap) / 3; cr[i] = new Rectangle(body.X, body.Y + i * (h + gap), body.Width, h); }
        }
        Chart(g, cr[0], "Температура", "°C", "0", new int[] { 0, 3 }, new string[] { "CPU", "GPU" }, new Color[] { LT.CCpu, LT.CGpu }, s.Samples, t1, win, 20, false, 80, 90);
        Chart(g, cr[1], "Мощность", "Вт", "0", new int[] { 1, 4 }, new string[] { "CPU", "GPU" }, new Color[] { LT.CCpu, LT.CGpu }, s.Samples, t1, win, 20, true, double.NaN, double.NaN);
        Chart(g, cr[2], "Частота", "МГц", "0", new int[] { 2, 6 }, new string[] { "CPU", "GPU" }, new Color[] { LT.CCpu, LT.CGpu }, s.Samples, t1, win, 300, true, double.NaN, double.NaN);
    }

    void DrawChips(Graphics g, Rectangle r, List<LiveSample> smp) {
        List<string[]> items = new List<string[]>();
        double v;
        v = LastVal(smp, 5); if (!double.IsNaN(v)) items.Add(new string[] { "GPU", v.ToString("0", CultureInfo.CurrentCulture) + " %" });
        v = LastVal(smp, 7); if (!double.IsNaN(v)) items.Add(new string[] { "12 В", v.ToString("0.00", CultureInfo.CurrentCulture) });
        v = LastVal(smp, 8); if (!double.IsNaN(v)) items.Add(new string[] { "Vcore", v.ToString("0.000", CultureInfo.CurrentCulture) });
        v = LastVal(smp, 9); if (!double.IsNaN(v)) items.Add(new string[] { "Кулер", v.ToString("0", CultureInfo.CurrentCulture) + " об/мин" });
        if (items.Count == 0) {
            LT.TR(g, "датчики появятся, когда начнётся мониторинг", F.fSmall, r, LT.Faint);
            return;
        }
        int x = r.Right;
        for (int i = items.Count - 1; i >= 0; i--) {
            int a = LT.TW(g, items[i][0], F.fSmall), b = LT.TW(g, items[i][1], F.fBold);
            int w = a + b + S(22);
            if (x - w < r.X) break;
            x -= w;
            Rectangle pr = new Rectangle(x, r.Y, w, r.Height);
            LT.Fill(g, pr, pr.Height / 2f, LT.Soft);
            LT.T(g, items[i][0], F.fSmall, new Rectangle(pr.X + S(9), pr.Y, a + S(2), pr.Height), LT.Dim);
            LT.T(g, items[i][1], F.fBold, new Rectangle(pr.X + S(13) + a, pr.Y, b + S(4), pr.Height), LT.Tx);
            x -= S(6);
        }
    }

    void Chart(Graphics g, Rectangle r, string title, string unit, string fmt, int[] idx, string[] names, Color[] cols,
               List<LiveSample> smp, double t1, double win, double minSpan, bool zeroFloor, double warnAt, double critAt) {
        LT.Fill(g, r, S(10), LT.Bg);
        int ml = S(36), mr = S(10), mt = S(28), mb = S(18);
        Rectangle pr = new Rectangle(r.X + ml, r.Y + mt, r.Width - ml - mr, r.Height - mt - mb);
        if (pr.Width < 20 || pr.Height < 10) return;
        double t0 = t1 - win;
        int n = idx.Length;
        bool[] has = new bool[n];
        double mn = double.MaxValue, mx = double.MinValue;
        for (int i = 0; i < smp.Count; i++) {
            if (smp[i].T < t0) continue;
            for (int k = 0; k < n; k++) {
                double v = smp[i].V[idx[k]];
                if (double.IsNaN(v) || double.IsInfinity(v)) continue;
                has[k] = true;
                if (v < mn) mn = v;
                if (v > mx) mx = v;
            }
        }
        int lx = r.Right - S(8);
        for (int k = n - 1; k >= 0; k--) {
            if (!has[k]) continue;
            double cur = LastVal(smp, idx[k]);
            string txt = names[k] + " " + cur.ToString(fmt, CultureInfo.CurrentCulture) + " " + unit;
            Color vc = LT.Tx;
            if (!double.IsNaN(critAt) && cur >= critAt) vc = LT.Cr;
            else if (!double.IsNaN(warnAt) && cur >= warnAt) vc = LT.Wn;
            int w = LT.TW(g, txt, F.fBold) + S(4);
            lx -= w;
            LT.T(g, txt, F.fBold, new Rectangle(lx, r.Y + S(4), w, S(20)), vc);
            lx -= S(10);
            using (SolidBrush b = new SolidBrush(cols[k])) g.FillEllipse(b, lx, r.Y + S(10), S(7), S(7));
            lx -= S(8);
        }
        if (lx - r.X - S(12) >= LT.TW(g, title, F.fSmall)) LT.T(g, title, F.fSmall, new Rectangle(r.X + S(10), r.Y + S(4), lx - r.X - S(12), S(20)), LT.Dim);
        Rectangle xl = new Rectangle(pr.X, r.Bottom - mb, pr.Width, mb - S(2));
        LT.T(g, "−" + FmtTime(win), F.fSmall, xl, LT.Faint);
        LT.TR(g, "сейчас", F.fSmall, xl, LT.Faint);
        if (mx < mn) {
            LT.TC(g, "нет данных", F.fSmall, pr, LT.Faint);
            return;
        }
        double span = mx - mn;
        double lo = mn - span * 0.12, hi = mx + span * 0.12;
        if (hi - lo < minSpan) { double mid = (hi + lo) / 2; lo = mid - minSpan / 2; hi = mid + minSpan / 2; }
        if (zeroFloor && lo < 0) { hi -= lo; lo = 0; }
        double raw = (hi - lo) / 3.0;
        double mag = Math.Pow(10, Math.Floor(Math.Log10(raw)));
        double nm = raw / mag;
        double step = (nm <= 1 ? 1 : (nm <= 2 ? 2 : (nm <= 5 ? 5 : 10))) * mag;
        lo = Math.Floor(lo / step) * step;
        hi = Math.Ceiling(hi / step) * step;
        if (hi <= lo) hi = lo + step;
        string yfmt = step < 1 ? "0.0" : "0";
        using (Pen gp = new Pen(Color.FromArgb(55, LT.Faint), 1f)) {
            for (double yv = lo; yv <= hi + step * 0.001; yv += step) {
                float y = (float)(pr.Bottom - (yv - lo) / (hi - lo) * pr.Height);
                g.DrawLine(gp, pr.X, y, pr.Right, y);
                LT.TR(g, yv.ToString(yfmt, CultureInfo.CurrentCulture), F.fSmall, new Rectangle(r.X + S(2), (int)y - S(8), ml - S(6), S(16)), LT.Faint);
            }
        }
        Region old = g.Clip;
        g.SetClip(pr);
        double[] lv = new double[] { warnAt, critAt };
        Color[] lc = new Color[] { LT.Wn, LT.Cr };
        for (int q = 0; q < 2; q++) {
            if (double.IsNaN(lv[q]) || lv[q] < lo || lv[q] > hi) continue;
            float y = (float)(pr.Bottom - (lv[q] - lo) / (hi - lo) * pr.Height);
            using (Pen dp = new Pen(Color.FromArgb(120, lc[q]), 1f)) { dp.DashStyle = DashStyle.Dash; g.DrawLine(dp, pr.X, y, pr.Right, y); }
        }
        for (int k = 0; k < n; k++) {
            if (!has[k]) continue;
            List<PointF> run = new List<PointF>();
            double prevT = -1000;
            PointF lastPt = PointF.Empty;
            double lastT = -1000;
            for (int i = 0; i <= smp.Count; i++) {
                bool end = i == smp.Count;
                double v = double.NaN, t = 0;
                if (!end) {
                    t = smp[i].T;
                    if (t < t0) continue;
                    v = smp[i].V[idx[k]];
                }
                bool bad = end || double.IsNaN(v) || double.IsInfinity(v) || (run.Count > 0 && t - prevT > 20);
                if (bad && run.Count > 0) { DrawRun(g, run, cols[k], pr); run = new List<PointF>(); }
                if (!end && !double.IsNaN(v) && !double.IsInfinity(v)) {
                    PointF pt = new PointF((float)(pr.X + (t - t0) / win * pr.Width), (float)(pr.Bottom - (v - lo) / (hi - lo) * pr.Height));
                    run.Add(pt);
                    prevT = t;
                    lastPt = pt; lastT = t;
                }
            }
            if (lastT > t1 - 20) using (SolidBrush b = new SolidBrush(cols[k])) g.FillEllipse(b, lastPt.X - S(3), lastPt.Y - S(3), S(6), S(6));
        }
        g.Clip = old;
    }

    void DrawRun(Graphics g, List<PointF> run, Color c, Rectangle pr) {
        if (run.Count == 1) {
            using (SolidBrush b = new SolidBrush(c)) g.FillEllipse(b, run[0].X - S(2), run[0].Y - S(2), S(4), S(4));
            return;
        }
        PointF[] pts = run.ToArray();
        PointF[] poly = new PointF[pts.Length + 2];
        Array.Copy(pts, poly, pts.Length);
        poly[pts.Length] = new PointF(pts[pts.Length - 1].X, pr.Bottom);
        poly[pts.Length + 1] = new PointF(pts[0].X, pr.Bottom);
        using (SolidBrush b = new SolidBrush(Color.FromArgb(26, c))) g.FillPolygon(b, poly);
        using (Pen p = new Pen(c, Math.Max(1.6f, S(1.8)))) {
            p.LineJoin = LineJoin.Round;
            if (pts.Length >= 3) g.DrawCurve(p, pts, 0.25f); else g.DrawLines(p, pts);
        }
    }

    // ---------- находки
    void DrawIssues(Graphics g, Rectangle r, LiveSnap s) {
        Panel(g, r);
        Strip(g, r, "Находки", F.showIssues, hoverHdr == 2, null);
        int x = r.X + S(130);
        string[] lab = new string[] { s.NCrit + " критичных", s.NWarn + " предупр.", s.NInfo + " советов" };
        Color[] cc = new Color[] { LT.Cr, LT.Wn, LT.Faint };
        int[] cn = new int[] { s.NCrit, s.NWarn, s.NInfo };
        for (int i = 0; i < 3; i++) {
            int w = LT.TW(g, lab[i], F.fSmall) + S(26);
            if (x + w > r.Right - S(8)) break;
            Rectangle pr = new Rectangle(x, r.Y + S(7), w, S(22));
            LT.Fill(g, pr, pr.Height / 2f, cn[i] > 0 ? Color.FromArgb(34, cc[i]) : LT.Soft);
            using (SolidBrush b = new SolidBrush(cn[i] > 0 ? cc[i] : LT.Faint)) g.FillEllipse(b, pr.X + S(9), pr.Y + S(8), S(6), S(6));
            LT.T(g, lab[i], F.fSmall, new Rectangle(pr.X + S(20), pr.Y, w - S(22), pr.Height), cn[i] > 0 ? LT.Tx : LT.Faint);
            x += w + S(6);
        }
        issRect = Rectangle.Empty;
        if (!F.showIssues || r.Height < S(60)) return;
        int lh = S(22);
        int y = r.Y + S(40);
        issRect = new Rectangle(r.X, y, r.Width, r.Bottom - y);
        int fit = Math.Max(0, (r.Bottom - S(6) - y) / lh);
        if (s.Issues.Count == 0) {
            LT.T(g, "Проблем пока не найдено", F.fNorm, new Rectangle(r.X + S(18), y, r.Width - S(30), lh), LT.Faint);
            return;
        }
        // сначала критичные, затем предупреждения, затем советы; внутри — новые сверху
        List<LiveIssue> ord = new List<LiveIssue>();
        foreach (string lv in new string[] { "crit", "warn", "info" })
            for (int i = s.Issues.Count - 1; i >= 0; i--) if (s.Issues[i].Level == lv) ord.Add(s.Issues[i]);
        if (issScroll > Math.Max(0, ord.Count - fit)) issScroll = Math.Max(0, ord.Count - fit);
        for (int i = issScroll; i < ord.Count && i - issScroll < fit; i++) {
            LiveIssue it = ord[i];
            Color c = it.Level == "crit" ? LT.Cr : (it.Level == "warn" ? LT.Wn : LT.Faint);
            using (SolidBrush b = new SolidBrush(c)) g.FillEllipse(b, r.X + S(18), y + (lh - S(7)) / 2, S(7), S(7));
            LT.T(g, it.Text, F.fNorm, new Rectangle(r.X + S(34), y, r.Width - S(48), lh), it.Level == "info" ? LT.Dim : LT.Tx);
            y += lh;
        }
        if (ord.Count > fit) LT.TR(g, (issScroll + 1) + "–" + Math.Min(ord.Count, issScroll + fit) + " из " + ord.Count + " · колесо — листать", F.fSmall, new Rectangle(r.X, r.Y + S(7), r.Width - S(14), S(22)), LT.Faint);
    }

    // ---------- рамка журнала (сам текст — RichTextBox поверх)
    void DrawLogFrame(Graphics g, Rectangle r) {
        Panel(g, r);
        if (F.showLog) LT.Fill(g, new Rectangle(r.X + S(6), r.Y + S(36), r.Width - S(12), r.Height - S(42)), S(8), LT.Bg);
        Strip(g, r, "Журнал", F.showLog, hoverHdr == 3, F.showLog ? "все сообщения программы · выделите и Ctrl+C" : null);
        logEndR = logCopyR = Rectangle.Empty;
        if (!F.showLog) return;
        int x = r.Right - S(12);
        string c1 = "Копировать всё";
        int w1 = LT.TW(g, c1, F.fSmall) + S(20);
        x -= w1; logCopyR = new Rectangle(x, r.Y + S(7), w1, S(22));
        LT.Fill(g, logCopyR, S(11), hoverHdr == 5 ? LT.PlateHi : LT.Soft);
        LT.TC(g, c1, F.fSmall, logCopyR, hoverHdr == 5 ? LT.Tx : LT.Tx2);
        if (F.logPaused) {
            string c2 = "Пауза · к концу ↓";
            int w2 = LT.TW(g, c2, F.fSmall) + S(20);
            x -= w2 + S(6); logEndR = new Rectangle(x, r.Y + S(7), w2, S(22));
            LT.Fill(g, logEndR, S(11), hoverHdr == 4 ? Color.FromArgb(70, LT.Wn) : Color.FromArgb(40, LT.Wn));
            LT.TC(g, c2, F.fSmall, logEndR, LT.Wn);
        }
    }
}
'@
                Add-Type -AssemblyName System.Windows.Forms, System.Drawing
                Add-Type -TypeDefinition $liveSrc -ReferencedAssemblies System.Windows.Forms, System.Drawing -ErrorAction Stop
            }
            $G.LiveReady = $true
        } catch {
            $G.LiveReady = $false
            $G.LiveOk = $false
            try { $G.Log.Add('DiagLive: ' + $_.Exception.Message) } catch {}
        }
    }
}

# ---------------------------------------------------------------- обёртки (никогда не бросают исключений)
function Live-Num($v) {
    if ($null -eq $v) { return [double]::NaN }
    try { return [double]$v } catch { return [double]::NaN }
}
function Live-Start {
    if ($env:DIAG_NOLIVE -or -not $G.LiveReady) { return }
    try {
        $names = New-Object System.Collections.Generic.List[string]
        $flags = New-Object System.Collections.Generic.List[bool]
        if ($G.AllSteps) {
            foreach ($stepName in $G.AllSteps) {
                $on = $true
                if ($G.Sel -and $STEPKEYS.ContainsKey($stepName)) {
                    $key = $STEPKEYS[$stepName]
                    if ($key -eq '_inter') { $on = [bool]$G.Interactive }
                    elseif ($key -eq '_cpu') { $on = [bool]($G.Sel.cpu -or $G.Sel.prime) }
                    else { $on = [bool]$G.Sel[$key] }
                }
                $names.Add([string]$stepName); $flags.Add($on)
            }
        }
        # ожидаемая длительность этапов, с (для «осталось ≈»): тяжёлый ключ — первому этапу с этим ключом
        $est = New-Object System.Collections.Generic.List[double]
        $sel = $G.Sel; if (-not $sel) { $sel = @{} }
        $byKey = @{ cpu = 30 + [int]$sel.cpusec; prime = 20 + 60 * [int]$sel.primemin; ycr = 30 + 60 * [int]$sel.ycrmin; linpack = 60 + 60 * [int]$sel.linpackmin
            tm5 = 30 + 60 * [int]$sel.tm5min; psu = 20 + 60 * [int]$sel.psumin; surface = 20 + 60 * [int]$sel.surfacemin; gpu = 40 + [int]$sel.gpusec
            gpustab = 30 + 60 * [int]$sel.gpustabmin; batdrain = 120 + 60 * [int]$sel.batmin; sys = 1500; av = 360; drivers = 300; vram = 360; coolcurve = 240
            frametime = 100; selftest = 150; disk = 90; kvrt = 900; ram = $(if ($sel.ramfull) { 240 } else { 60 }); net = 60; fakeflash = 600; periph = 180; screenfull = 180 }
        $usedKey = @{}
        foreach ($stepName in $names) {
            $sec = 15.0
            if ($stepName -eq 'Подготовка инструментов') { $sec = 60.0 }
            elseif ($STEPKEYS.ContainsKey($stepName)) {
                $key = $STEPKEYS[$stepName]
                if ($byKey.ContainsKey($key) -and -not $usedKey.ContainsKey($key)) { $sec = [double]$byKey[$key]; $usedKey[$key] = 1 }
                elseif ($key -eq '_inter') { $sec = 60.0 }
            }
            $est.Add($sec)
        }
        $appName = 'BigTechoTest'
        if ($G.UiOk) { try { $appName = [string][DiagTheme]::AppName } catch {} }
        [DiagLive]::GuiMode = ($env:DIAG_GUI -eq '1')
        [DiagLive]::Start(($appName + ' — диагностика ПК'), $names.ToArray(), $flags.ToArray(), $est.ToArray())
        $G.LiveOk = $true
    } catch { $G.LiveOk = $false }
}
function Live-Step($Name) { if (-not $G.LiveOk) { return }; try { [DiagLive]::StepStart([string]$Name) } catch {} }
function Live-StepEnd($Name, $State = 'ok') { if (-not $G.LiveOk) { return }; try { [DiagLive]::StepEnd([string]$Name, [string]$State) } catch {} }
function Live-Activity($Text) { if (-not $G.LiveOk) { return }; try { [DiagLive]::SetActivity([string]$Text) } catch {} }
function Live-Log($Text) { if (-not $G.LiveOk) { return }; try { [DiagLive]::Log([string]$Text) } catch {} }
function Live-Issue($Sev, $Text) { if (-not $G.LiveOk) { return }; try { [DiagLive]::Issue([string]$Sev, [string]$Text) } catch {} }
function Live-Sensors($k) {
    if (-not $G.LiveOk -or $null -eq $k) { return }
    try {
        [DiagLive]::Sensor((Live-Num $k.CpuTemp), (Live-Num $k.CpuPower), (Live-Num $k.CpuClock), (Live-Num $k.GpuTemp), (Live-Num $k.GpuPower),
            (Live-Num $k.GpuLoad), (Live-Num $k.GpuClock), (Live-Num $k.V12), (Live-Num $k.Vcore), (Live-Num $k.FanMin))
    } catch {}
}
function Live-Finish($Summary, $Score = -1) {
    if (-not $G.LiveOk) { return }
    try { [DiagLive]::Finish([string]$Summary, [int]$Score) } catch {}
}
function Live-Close { if (-not $G.LiveOk) { return }; try { [DiagLive]::Close() } catch {} }
function Live-SetReports($Full, $Sum, $Dir) { if (-not $G.LiveOk) { return }; try { [DiagLive]::SetReports([string]$Full, [string]$Sum, [string]$Dir) } catch {} }
function Live-WaitClosed { if (-not $G.LiveOk) { return }; try { [DiagLive]::WaitClosed() } catch {} }
# Состояние этапа по проблемам, добавленным с момента $N0 = $G.Issues.Count
function Live-StateSince($N0) {
    $st = 'ok'
    try {
        for ($i = [int]$N0; $i -lt $G.Issues.Count; $i++) {
            $sev = $G.Issues[$i].Sev
            if ($sev -eq 'crit') { return 'crit' }
            if ($sev -eq 'warn') { $st = 'warn' }
        }
    } catch {}
    return $st
}
# Датчики читаются только внутри тестов; в долгих ожиданиях можно звать Live-Tick (не чаще раза в 2 с) — он дёрнет Read-Key, а тот сам кормит окно
function Live-Tick {
    if (-not $G.LiveOk -or $G.LiveInTick) { return }
    try {
        $now = [DateTime]::UtcNow
        if ($G.LiveLastTick -and (($now - $G.LiveLastTick).TotalSeconds -lt 2)) { return }
        $G.LiveLastTick = $now
        $G.LiveInTick = $true
        [void](Read-Key)
    } catch {} finally { $G.LiveInTick = $false }
}
