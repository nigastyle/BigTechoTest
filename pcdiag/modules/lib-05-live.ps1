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
using System.Threading;
using System.Windows.Forms;

internal class LiveStep {
    public string Name;
    public bool En;
    public int St;      // 0 ожидает, 1 идёт, 2 ok, 3 warn, 4 crit, 5 skip, 6 error
    public double T0 = -1;
    public double T1 = -1;
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
    public int Done;
    public int Total;
    public int NCrit;
    public int NWarn;
    public int NInfo;
    public List<LiveStep> Steps = new List<LiveStep>();
    public List<string> Log = new List<string>();
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
    static readonly List<LiveSample> samples = new List<LiveSample>();
    static readonly List<LiveIssue> issues = new List<LiveIssue>();
    static readonly Stopwatch clock = new Stopwatch();
    static LiveForm form;
    static ManualResetEvent ready;

    // «Остановить тесты»: PowerShell читает [DiagLive]::StopRequested (Stop-Requested / Step в body.ps1)
    public static volatile bool StopRequested;

    static readonly string[] StressProcs = { "prime95", "furmark", "y-cruncher", "linpack_xeon64", "memtest_vulkan", "tm5", "diskspd" };

    // Останавливает наши нагрузочные программы и внутренние тесты (DiagCore / DiagSurface, если есть)
    internal static void StopAll() {
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
                    steps.Add(s);
                }
            }
            clock.Reset();
            clock.Start();
        }
        ready = new ManualResetEvent(false);
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
            f.HandleCreated += delegate { try { ready.Set(); } catch (Exception) { } };
            Application.Run(f);
        } catch (Exception) {
        } finally {
            form = null;
            try { ready.Set(); } catch (Exception) { }
        }
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
        lock (L) { activity = Clean(text); }
    }

    static string Clean(string t) {
        if (t == null) return "";
        t = t.Replace("\r", " ").Replace("\n", " ").Replace("\t", " ");
        if (t.Length > 400) t = t.Substring(0, 400);
        return t.Trim();
    }

    public static void Log(string line) {
        lock (L) {
            if (!started) return;
            log.Add(Clean(line));
            if (log.Count > 200) log.RemoveRange(0, log.Count - 200);
        }
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
            i.Text = Clean(text);
            issues.Add(i);
            if (lv == "crit") nCrit++; else if (lv == "warn") nWarn++; else nInfo++;
            if (issues.Count > 300) issues.RemoveRange(0, issues.Count - 300);
        }
    }

    public static void Progress(int done, int total) {
        lock (L) { progDone = done; progTotal = total; }
    }

    public static void Finish(string text, int finalScore) {
        lock (L) {
            if (!started || finished) return;
            finished = true;
            summary = Clean(text);
            score = finalScore;
            activity = "";
            curStep = "";
            for (int i = 0; i < steps.Count; i++) if (steps[i].St == 1) { steps[i].St = 2; steps[i].T1 = Now(); }
            clock.Stop();
        }
        LiveForm f = form;
        if (f != null) {
            try {
                if (f.IsHandleCreated) f.BeginInvoke(new MethodInvoker(delegate {
                    try {
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
            s.Now = Now();
            s.NCrit = nCrit; s.NWarn = nWarn; s.NInfo = nInfo;
            for (int i = 0; i < steps.Count; i++) {
                LiveStep a = steps[i];
                LiveStep c = new LiveStep();
                c.Name = a.Name; c.En = a.En; c.St = a.St; c.T0 = a.T0; c.T1 = a.T1;
                s.Steps.Add(c);
                if (a.En) { s.Total++; if (a.St >= 2) s.Done++; }
            }
            if (progDone >= 0 && progTotal > 0) { s.Done = progDone; s.Total = progTotal; }
            if (finished) s.Done = s.Total;
            int ls = Math.Max(0, log.Count - 12);
            s.Log.AddRange(log.GetRange(ls, log.Count - ls));
            s.Samples.AddRange(samples);
            int isx = Math.Max(0, issues.Count - 40);
            s.Issues.AddRange(issues.GetRange(isx, issues.Count - isx));
        }
        return s;
    }
}

// Большая кнопка «Остановить тесты» (фирменный красный градиент, скруглённая)
internal class LiveStopButton : Button {
    bool hov, down;
    public LiveStopButton() {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        FlatStyle = FlatStyle.Flat;
        FlatAppearance.BorderSize = 0;
        BackColor = LivePanel.Bg;
        Cursor = Cursors.Hand;
        Text = "Остановить тесты";
    }
    protected override void OnMouseEnter(EventArgs e) { hov = true; Invalidate(); base.OnMouseEnter(e); }
    protected override void OnMouseLeave(EventArgs e) { hov = false; down = false; Invalidate(); base.OnMouseLeave(e); }
    protected override void OnMouseDown(MouseEventArgs e) { down = true; Invalidate(); base.OnMouseDown(e); }
    protected override void OnMouseUp(MouseEventArgs e) { down = false; Invalidate(); base.OnMouseUp(e); }
    protected override void OnEnabledChanged(EventArgs e) { Invalidate(); base.OnEnabledChanged(e); }
    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = e.Graphics;
        g.Clear(LivePanel.Bg);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        Rectangle r = new Rectangle(0, 0, Width - 1, Height - 1);
        float rad = Math.Min(14f * (g.DpiX / 96f), r.Height / 2f);
        float d = rad * 2;
        using (GraphicsPath p = new GraphicsPath()) {
            p.AddArc(r.X, r.Y, d, d, 180, 90);
            p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
            p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
            p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
            p.CloseFigure();
            Color c1 = hov ? Color.FromArgb(0xff, 0x55, 0x45) : Color.FromArgb(0xff, 0x3a, 0x28);
            Color c2 = hov ? Color.FromArgb(0xd8, 0x10, 0x10) : Color.FromArgb(0xc4, 0x08, 0x08);
            if (down) { c1 = Color.FromArgb(0xc4, 0x08, 0x08); c2 = Color.FromArgb(0xa0, 0x06, 0x06); }
            if (!Enabled) { c1 = Color.FromArgb(0x4a, 0x1c, 0x1a); c2 = Color.FromArgb(0x3a, 0x16, 0x14); }
            using (LinearGradientBrush b = new LinearGradientBrush(new Rectangle(0, -1, Width, Height + 2), c1, c2, 90f)) g.FillPath(b, p);
        }
        using (Font f = new Font("Segoe UI Semibold", 12f, FontStyle.Regular))
            TextRenderer.DrawText(g, Text, f, new Rectangle(0, 0, Width, Height), Enabled ? Color.White : Color.FromArgb(0xc2, 0xa0, 0x9c),
                TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine | TextFormatFlags.NoPrefix);
    }
}

internal class LiveForm : Form {
    LivePanel panel;
    Panel stopHost;
    LiveStopButton stopBtn;
    System.Windows.Forms.Timer timer;
    public bool ForceClose;

    [DllImport("dwmapi.dll")]
    static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int val, int size);

    public LiveForm(string title) {
        Text = string.IsNullOrEmpty(title) ? "BigTechoTest — диагностика ПК" : title;
        try { string ex = System.IO.Path.Combine(Environment.GetEnvironmentVariable("DIAG_ROOT") ?? "", "BigTechoTest.exe"); if (System.IO.File.Exists(ex)) { Icon = System.Drawing.Icon.ExtractAssociatedIcon(ex); ShowIcon = true; } } catch { }
        AutoScaleMode = AutoScaleMode.Dpi;
        Font = new Font("Segoe UI", 9f);
        BackColor = LivePanel.Bg;
        ShowInTaskbar = true;
        TopMost = false;
        FormBorderStyle = FormBorderStyle.Sizable;
        StartPosition = FormStartPosition.Manual;
        float k = 1f;
        try { using (Graphics g = CreateGraphics()) k = g.DpiX / 96f; } catch (Exception) { }
        Rectangle wa = Screen.PrimaryScreen.WorkingArea;
        int w = Math.Min((int)(520 * k), wa.Width);
        int h = Math.Min((int)(760 * k), wa.Height);
        Bounds = new Rectangle(wa.Right - w, wa.Top + (wa.Height - h) / 2, w, h);
        MinimumSize = new Size(Math.Min((int)(420 * k), wa.Width), Math.Min((int)(560 * k), wa.Height));
        panel = new LivePanel();
        panel.Dock = DockStyle.Fill;
        Controls.Add(panel);
        stopHost = new Panel();
        stopHost.Dock = DockStyle.Bottom;
        stopHost.Height = (int)(68 * k);
        stopHost.BackColor = LivePanel.Bg;
        stopHost.Padding = new Padding((int)(10 * k), (int)(4 * k), (int)(10 * k), (int)(12 * k));
        stopBtn = new LiveStopButton();
        stopBtn.Dock = DockStyle.Fill;
        stopBtn.Click += delegate { OnStopClick(); };
        stopHost.Controls.Add(stopBtn);
        Controls.Add(stopHost);
        timer = new System.Windows.Forms.Timer();
        timer.Interval = 250;
        timer.Tick += delegate {
            try {
                if (DiagLive.IsFinished && stopHost.Visible) stopHost.Visible = false;
                if (Visible && WindowState != FormWindowState.Minimized) panel.Invalidate();
            } catch (Exception) { }
        };
        timer.Start();
    }

    void OnStopClick() {
        if (DiagLive.StopRequested) return;
        DialogResult dr = DialogResult.No;
        try {
            // TopMost-владелец, чтобы диалог не пропадал за другими окнами
            using (Form owner = new Form()) {
                owner.TopMost = true; owner.ShowInTaskbar = false; owner.StartPosition = FormStartPosition.Manual;
                owner.Bounds = new Rectangle(Bounds.X + Bounds.Width / 2, Bounds.Y + Bounds.Height / 2, 1, 1);
                owner.Opacity = 0; owner.Show();
                dr = MessageBox.Show(owner, "Остановить все тесты? Уже собранные данные войдут в отчёт.", "Остановить тесты",
                    MessageBoxButtons.YesNo, MessageBoxIcon.Question, MessageBoxDefaultButton.Button2);
            }
        } catch (Exception) { }
        if (dr != DialogResult.Yes) return;
        stopBtn.Text = "Останавливаю…";
        stopBtn.Enabled = false;
        DiagLive.StopRequested = true;
        System.Threading.ThreadPool.QueueUserWorkItem(delegate { DiagLive.StopAll(); });
    }

    protected override bool ShowWithoutActivation { get { return true; } }

    protected override void OnHandleCreated(EventArgs e) {
        base.OnHandleCreated(e);
        try {
            int one = 1;
            if (DwmSetWindowAttribute(Handle, 20, ref one, 4) != 0) DwmSetWindowAttribute(Handle, 19, ref one, 4);
        } catch (Exception) { }
    }

    protected override void OnFormClosing(FormClosingEventArgs e) {
        if (!ForceClose && e.CloseReason == CloseReason.UserClosing && !DiagLive.IsFinished) {
            // закрытие окна не останавливает диагностику: сворачиваем
            e.Cancel = true;
            WindowState = FormWindowState.Minimized;
            return;
        }
        try { timer.Stop(); } catch (Exception) { }
        base.OnFormClosing(e);
    }
}

internal class LivePanel : Control {
    // фирменная палитра «Биг Техно Клаб» — те же значения, что DiagTheme в ui.cs
    public static readonly Color Bg = Color.FromArgb(0x0e, 0x0e, 0x10);     // DiagTheme.Bg
    static readonly Color Pn = Color.FromArgb(0x17, 0x17, 0x1a);            // DiagTheme.Panel
    static readonly Color Bd = Color.FromArgb(0x3a, 0x3a, 0x40);            // DiagTheme.LineHi
    static readonly Color Ac = Color.FromArgb(0xdd, 0x0a, 0x0a);            // DiagTheme.Accent
    static readonly Color AcHi = Color.FromArgb(0xff, 0x3a, 0x28);          // DiagTheme.AccentHi
    static readonly Color Ok = Color.FromArgb(0x45, 0xd1, 0x7a);            // DiagTheme.Ok
    static readonly Color Wn = Color.FromArgb(0xf0, 0xb2, 0x3c);            // DiagTheme.Warn
    static readonly Color Cr = Color.FromArgb(0xff, 0x4d, 0x4f);            // DiagTheme.Crit
    static readonly Color Tx = Color.FromArgb(0xf4, 0xf4, 0xf5);            // DiagTheme.Ink
    static readonly Color Dim = Color.FromArgb(0x8e, 0x8e, 0x94);           // DiagTheme.Ink3
    static readonly Color Faint = Color.FromArgb(0x6e, 0x6e, 0x74);         // DiagTheme.Ink4
    static readonly Color CCpu = Color.FromArgb(0x38, 0xbd, 0xf8);
    static readonly Color CGpu = Color.FromArgb(0xc0, 0x84, 0xfc);

    Font fBold, fBig, fNorm, fSmall, fMono, fMonoB, fScore;
    StringFormat sfL, sfR, sfC, sfW;
    float sc = 1f;
    float scrollY, maxScroll;
    bool manual;
    string lastCur = "";
    Rectangle listRect = Rectangle.Empty;
    int rowH = 26;
    int tick;

    public LivePanel() {
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        DoubleBuffered = true;
        BackColor = Bg;
        fBold = new Font("Segoe UI", 9f, FontStyle.Bold);
        fBig = new Font("Segoe UI Semibold", 14f, FontStyle.Bold);
        fNorm = new Font("Segoe UI", 9f);
        fSmall = new Font("Segoe UI", 7.5f);
        fMono = new Font("Consolas", 8f);
        fMonoB = new Font("Consolas", 11f, FontStyle.Bold);
        fScore = new Font("Segoe UI Semibold", 18f, FontStyle.Bold);
        sfL = MakeFmt(StringAlignment.Near, true);
        sfR = MakeFmt(StringAlignment.Far, true);
        sfC = MakeFmt(StringAlignment.Center, true);
        sfW = MakeFmt(StringAlignment.Near, false);
        sfW.LineAlignment = StringAlignment.Near;
    }

    static StringFormat MakeFmt(StringAlignment h, bool noWrap) {
        StringFormat f = new StringFormat();
        f.Alignment = h;
        f.LineAlignment = StringAlignment.Center;
        f.Trimming = StringTrimming.EllipsisCharacter;
        if (noWrap) f.FormatFlags = StringFormatFlags.NoWrap;
        return f;
    }

    int S(int v) { return (int)Math.Round(v * sc); }

    static string FmtTime(double sec) {
        if (sec < 0) sec = 0;
        int t = (int)sec;
        int h = t / 3600, m = (t / 60) % 60, s = t % 60;
        if (h > 0) return string.Format("{0}:{1:00}:{2:00}", h, m, s);
        return string.Format("{0:00}:{1:00}", m, s);
    }

    static GraphicsPath RR(Rectangle r, int rad) {
        GraphicsPath p = new GraphicsPath();
        int d = rad * 2;
        if (d > r.Height) d = r.Height;
        if (d > r.Width) d = r.Width;
        if (d < 2) { p.AddRectangle(r); return p; }
        p.AddArc(r.X, r.Y, d, d, 180, 90);
        p.AddArc(r.Right - d - 1, r.Y, d, d, 270, 90);
        p.AddArc(r.Right - d - 1, r.Bottom - d - 1, d, d, 0, 90);
        p.AddArc(r.X, r.Bottom - d - 1, d, d, 90, 90);
        p.CloseFigure();
        return p;
    }

    void Panel(Graphics g, Rectangle r) {
        using (GraphicsPath p = RR(r, S(8))) {
            using (SolidBrush b = new SolidBrush(Pn)) g.FillPath(b, p);
            using (Pen pen = new Pen(Bd, 1f)) g.DrawPath(pen, p);
        }
    }

    void Txt(Graphics g, string s, Font f, Color c, Rectangle r, StringFormat sf) {
        if (string.IsNullOrEmpty(s) || r.Width <= 0 || r.Height <= 0) return;
        using (SolidBrush b = new SolidBrush(c)) g.DrawString(s, f, b, (RectangleF)r, sf);
    }

    protected override void OnMouseEnter(EventArgs e) {
        base.OnMouseEnter(e);
        try { if (!Focused && Form.ActiveForm == FindForm()) Focus(); } catch (Exception) { }
    }

    protected override void OnMouseWheel(MouseEventArgs e) {
        base.OnMouseWheel(e);
        if (listRect.Contains(e.Location)) {
            manual = true;
            scrollY -= (e.Delta / 120f) * rowH * 2;
            if (scrollY < 0) scrollY = 0;
            if (scrollY > maxScroll) scrollY = maxScroll;
            Invalidate();
        }
    }

    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = e.Graphics;
        try { Draw(g); } catch (Exception) { }
    }

    void Draw(Graphics g) {
        tick++;
        sc = g.DpiX / 96f;
        g.Clear(Bg);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.TextRenderingHint = TextRenderingHint.ClearTypeGridFit;
        int W = ClientSize.Width, H = ClientSize.Height;
        if (W < S(300) || H < S(300)) return;
        LiveSnap s = DiagLive.TakeSnap();
        int pad = S(10), gap = S(8);

        // ---------- шапка
        Rectangle hr = new Rectangle(pad, pad, W - 2 * pad, S(120));
        Panel(g, hr);
        int ix = hr.X + S(14), iw = hr.Width - S(28);
        int scoreW = 0;
        if (s.Finished && s.Score >= 0) {
            scoreW = S(80);
            DrawScore(g, new Rectangle(hr.Right - S(14) - S(66), hr.Y + S(14), S(66), S(66)), s.Score);
        }
        Txt(g, s.Title, fBold, Dim, new Rectangle(ix, hr.Y + S(8), iw - S(110) - scoreW, S(20)), sfL);
        Txt(g, FmtTime(s.Now), fMonoB, Tx, new Rectangle(hr.Right - S(14) - scoreW - S(110), hr.Y + S(8), S(110), S(20)), sfR);
        string stage = s.Finished ? "Диагностика завершена" : (s.Cur.Length > 0 ? s.Cur : "Подготовка…");
        Txt(g, stage, fBig, s.Finished ? Ok : Tx, new Rectangle(ix, hr.Y + S(30), iw - scoreW, S(32)), sfL);
        string act = s.Finished ? s.Summary : s.Activity;
        Txt(g, act, fNorm, Dim, new Rectangle(ix, hr.Y + S(64), iw - scoreW, S(28)), sfW);
        int pct = s.Total > 0 ? (int)Math.Min(100, (long)s.Done * 100 / s.Total) : 0;
        int barY = hr.Bottom - S(22);
        int pctW = S(120);
        Rectangle bar = new Rectangle(ix, barY, iw - pctW - S(8), S(8));
        using (GraphicsPath tp = RR(bar, S(4))) using (SolidBrush tb = new SolidBrush(Bd)) g.FillPath(tb, tp);
        int fw = (int)(bar.Width * pct / 100.0);
        if (fw >= S(6)) {
            Rectangle fr = new Rectangle(bar.X, bar.Y, fw, bar.Height);
            using (GraphicsPath fp = RR(fr, S(4)))
            using (LinearGradientBrush lb = new LinearGradientBrush(fr, Ac, s.Finished ? Ok : AcHi, 0f)) g.FillPath(lb, fp);
        }
        Txt(g, string.Format("{0}%  ·  {1} из {2}", pct, s.Done, s.Total), fSmall, Dim, new Rectangle(bar.Right + S(8), barY - S(5), pctW, S(18)), sfR);

        // ---------- раскладка
        int bottomH = Math.Min(S(222), (int)(H * 0.34));
        int top = hr.Bottom + gap;
        int bottomY = H - pad - bottomH;
        int bodyH = bottomY - gap - top;
        if (bodyH < S(120)) bodyH = S(120);
        int lw = Math.Max(S(190), Math.Min(S(340), (int)(W * 0.36)));
        Rectangle sr = new Rectangle(pad, top, lw, bodyH);
        DrawSteps(g, sr, s);

        int rx = pad + lw + gap, rw = W - pad - rx;
        Rectangle chips = new Rectangle(rx, top, rw, S(24));
        DrawChips(g, chips, s.Samples);
        int chTop = top + S(24) + gap / 2;
        int chH = (top + bodyH - chTop - 2 * gap) / 3;
        double t1 = s.Now, win = Math.Min(300.0, Math.Max(60.0, s.Now));
        Chart(g, new Rectangle(rx, chTop, rw, chH), "Температуры, °C", "°C", "0.#", new int[] { 0, 3 }, new string[] { "CPU", "GPU" },
            new Color[] { CCpu, CGpu }, s.Samples, t1, win, 20, false, 80, 90);
        Chart(g, new Rectangle(rx, chTop + chH + gap, rw, chH), "Мощность, Вт", "Вт", "0.#", new int[] { 1, 4 }, new string[] { "CPU", "GPU" },
            new Color[] { CCpu, CGpu }, s.Samples, t1, win, 20, true, double.NaN, double.NaN);
        Chart(g, new Rectangle(rx, chTop + 2 * (chH + gap), rw, chH), "Частоты, МГц", "МГц", "0", new int[] { 2, 6 }, new string[] { "CPU", "GPU" },
            new Color[] { CCpu, CGpu }, s.Samples, t1, win, 300, true, double.NaN, double.NaN);

        // ---------- низ: находки и журнал
        int issH = (int)(bottomH * 0.38);
        DrawIssues(g, new Rectangle(pad, bottomY, W - 2 * pad, issH - gap / 2), s);
        DrawLog(g, new Rectangle(pad, bottomY + issH + gap / 2, W - 2 * pad, bottomH - issH - gap / 2), s);
    }

    void DrawScore(Graphics g, Rectangle r, int score) {
        Color c = score >= 80 ? Ok : (score >= 50 ? Wn : Cr);
        Rectangle ring = new Rectangle(r.X + S(3), r.Y + S(3), r.Width - S(6), r.Height - S(6));
        using (Pen p = new Pen(Bd, S(5))) g.DrawEllipse(p, ring);
        using (Pen p = new Pen(c, S(5))) {
            p.StartCap = LineCap.Round; p.EndCap = LineCap.Round;
            float sweep = Math.Max(2f, Math.Min(100, score) * 3.6f);
            g.DrawArc(p, ring, -90f, sweep);
        }
        Txt(g, score.ToString(CultureInfo.InvariantCulture), fScore, c, r, sfC);
    }

    // ---------- этапы
    void DrawSteps(Graphics g, Rectangle sr, LiveSnap s) {
        Panel(g, sr);
        Txt(g, "Этапы", fBold, Tx, new Rectangle(sr.X + S(12), sr.Y + S(4), sr.Width / 2, S(22)), sfL);
        Txt(g, s.Done + " / " + s.Total, fSmall, Dim, new Rectangle(sr.X + sr.Width / 2, sr.Y + S(4), sr.Width / 2 - S(12), S(22)), sfR);
        listRect = new Rectangle(sr.X + S(4), sr.Y + S(30), sr.Width - S(8), sr.Height - S(36));
        rowH = S(26);
        int content = s.Steps.Count * rowH;
        maxScroll = Math.Max(0, content - listRect.Height);
        int runIdx = -1;
        for (int i = 0; i < s.Steps.Count; i++) if (s.Steps[i].St == 1) runIdx = i;
        if (!string.Equals(lastCur, s.Cur, StringComparison.Ordinal)) { lastCur = s.Cur; manual = false; }
        if (!manual) {
            float target = 0;
            if (runIdx >= 0) target = runIdx * rowH + rowH / 2f - listRect.Height / 2f;
            else if (s.Finished) target = 0;
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
                using (GraphicsPath p = RR(new Rectangle(row.X, row.Y + 1, row.Width, row.Height - 2), S(6)))
                using (SolidBrush b = new SolidBrush(Color.FromArgb(48, Ac))) g.FillPath(b, p);
                using (SolidBrush b = new SolidBrush(Ac)) g.FillRectangle(b, row.X, row.Y + S(5), S(3), row.Height - S(10));
            }
            DrawIcon(g, eff, row.X + S(18), row.Y + row.Height / 2f, S(7));
            Color tc = eff == 1 ? Color.White : (eff == 5 ? Faint : (eff == 0 ? Dim : Tx));
            Font tf = eff == 1 ? fBold : fNorm;
            string tm = "";
            if (st.T0 >= 0 && eff != 5) tm = FmtTime((st.T1 >= 0 ? st.T1 : s.Now) - st.T0);
            int tmW = tm.Length > 0 ? S(46) : 0;
            Txt(g, st.Name, tf, tc, new Rectangle(row.X + S(34), row.Y, row.Width - S(36) - tmW, row.Height), sfL);
            if (tmW > 0) Txt(g, tm, fMono, eff == 1 ? Tx : Faint, new Rectangle(row.Right - tmW - S(2), row.Y, tmW, row.Height), sfR);
        }
        g.Clip = old;
        if (maxScroll > 0) {
            int th = Math.Max(S(24), (int)((long)listRect.Height * listRect.Height / content));
            int ty = listRect.Y + (int)((listRect.Height - th) * (scrollY / maxScroll));
            using (GraphicsPath p = RR(new Rectangle(listRect.Right - S(5), ty, S(3), th), S(1)))
            using (SolidBrush b = new SolidBrush(Color.FromArgb(120, Faint))) g.FillPath(b, p);
        }
    }

    void DrawIcon(Graphics g, int st, float cx, float cy, float r) {
        float lw = Math.Max(1.5f, r * 0.28f);
        RectangleF c = new RectangleF(cx - r, cy - r, 2 * r, 2 * r);
        switch (st) {
            case 1: {
                int a = 50 + (int)(40 * (1 + Math.Sin(tick * 0.5)) / 2);
                using (SolidBrush b = new SolidBrush(Color.FromArgb(a, Ac))) g.FillEllipse(b, cx - r - 3, cy - r - 3, 2 * r + 6, 2 * r + 6);
                using (SolidBrush b = new SolidBrush(Ac)) g.FillEllipse(b, c);
                PointF[] tri = new PointF[] { new PointF(cx - r * 0.25f, cy - r * 0.5f), new PointF(cx - r * 0.25f, cy + r * 0.5f), new PointF(cx + r * 0.55f, cy) };
                g.FillPolygon(Brushes.White, tri);
                break;
            }
            case 2: {
                using (SolidBrush b = new SolidBrush(Ok)) g.FillEllipse(b, c);
                using (Pen p = new Pen(Color.White, lw)) {
                    p.StartCap = LineCap.Round; p.EndCap = LineCap.Round; p.LineJoin = LineJoin.Round;
                    g.DrawLines(p, new PointF[] { new PointF(cx - r * 0.45f, cy + 0.0f), new PointF(cx - r * 0.1f, cy + r * 0.38f), new PointF(cx + r * 0.5f, cy - r * 0.35f) });
                }
                break;
            }
            case 3: {
                using (SolidBrush b = new SolidBrush(Wn)) g.FillEllipse(b, c);
                using (Pen p = new Pen(Color.White, lw)) {
                    p.StartCap = LineCap.Round; p.EndCap = LineCap.Round;
                    g.DrawLine(p, cx, cy - r * 0.55f, cx, cy + r * 0.1f);
                    g.DrawLine(p, cx, cy + r * 0.48f, cx, cy + r * 0.5f);
                }
                break;
            }
            case 4:
            case 6: {
                using (SolidBrush b = new SolidBrush(st == 4 ? Cr : Color.FromArgb(0xb9, 0x1c, 0x1c))) g.FillEllipse(b, c);
                using (Pen p = new Pen(Color.White, lw)) {
                    p.StartCap = LineCap.Round; p.EndCap = LineCap.Round;
                    g.DrawLine(p, cx - r * 0.4f, cy - r * 0.4f, cx + r * 0.4f, cy + r * 0.4f);
                    g.DrawLine(p, cx - r * 0.4f, cy + r * 0.4f, cx + r * 0.4f, cy - r * 0.4f);
                }
                break;
            }
            case 5: {
                using (Pen p = new Pen(Faint, lw)) { p.StartCap = LineCap.Round; p.EndCap = LineCap.Round; g.DrawLine(p, cx - r * 0.5f, cy, cx + r * 0.5f, cy); }
                break;
            }
            default: {
                using (Pen p = new Pen(Faint, 1.5f)) g.DrawEllipse(p, c);
                break;
            }
        }
    }

    // ---------- чипсы
    static double LastVal(List<LiveSample> smp, int idx) {
        for (int i = smp.Count - 1; i >= 0; i--) {
            double v = smp[i].V[idx];
            if (!double.IsNaN(v) && !double.IsInfinity(v)) return v;
        }
        return double.NaN;
    }

    void DrawChips(Graphics g, Rectangle r, List<LiveSample> smp) {
        List<string[]> items = new List<string[]>();
        double v;
        v = LastVal(smp, 5); if (!double.IsNaN(v)) items.Add(new string[] { "GPU загрузка", v.ToString("0", CultureInfo.CurrentCulture) + " %" });
        v = LastVal(smp, 7); if (!double.IsNaN(v)) items.Add(new string[] { "12 В", v.ToString("0.00", CultureInfo.CurrentCulture) });
        v = LastVal(smp, 8); if (!double.IsNaN(v)) items.Add(new string[] { "Vcore", v.ToString("0.000", CultureInfo.CurrentCulture) + " В" });
        v = LastVal(smp, 9); if (!double.IsNaN(v)) items.Add(new string[] { "Кулер", v.ToString("0", CultureInfo.CurrentCulture) + " об/мин" });
        if (items.Count == 0) {
            Txt(g, "Датчики появятся, когда начнётся мониторинг", fSmall, Faint, new Rectangle(r.X + S(4), r.Y, r.Width, r.Height), sfL);
            return;
        }
        int x = r.X;
        for (int i = 0; i < items.Count; i++) {
            SizeF a = g.MeasureString(items[i][0], fSmall);
            SizeF b = g.MeasureString(items[i][1], fBold);
            int w = (int)(a.Width + b.Width) + S(18);
            if (x + w > r.Right) break;
            Rectangle pr = new Rectangle(x, r.Y + S(2), w, r.Height - S(4));
            Panel(g, pr);
            Txt(g, items[i][0], fSmall, Dim, new Rectangle(pr.X + S(7), pr.Y, (int)a.Width + S(4), pr.Height), sfL);
            Txt(g, items[i][1], fBold, Tx, new Rectangle(pr.X + S(9) + (int)a.Width, pr.Y, (int)b.Width + S(6), pr.Height), sfL);
            x += w + S(5);
        }
    }

    // ---------- график
    void Chart(Graphics g, Rectangle r, string title, string unit, string fmt, int[] idx, string[] names, Color[] cols,
               List<LiveSample> smp, double t1, double win, double minSpan, bool zeroFloor, double warnAt, double critAt) {
        Panel(g, r);
        int ml = S(38), mr = S(10), mt = S(26), mb = S(18);
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
        // легенда справа
        int lx = r.Right - S(10);
        for (int k = n - 1; k >= 0; k--) {
            if (!has[k]) continue;
            double cur = LastVal(smp, idx[k]);
            string txt = names[k] + " " + cur.ToString(fmt, CultureInfo.CurrentCulture) + " " + unit;
            Color vc = Tx;
            if (!double.IsNaN(critAt) && cur >= critAt) vc = Cr;
            else if (!double.IsNaN(warnAt) && cur >= warnAt) vc = Wn;
            int w = (int)g.MeasureString(txt, fBold).Width + S(4);
            lx -= w;
            Txt(g, txt, fBold, vc, new Rectangle(lx, r.Y + S(4), w, S(20)), sfL);
            lx -= S(10);
            using (SolidBrush b = new SolidBrush(cols[k])) g.FillEllipse(b, lx, r.Y + S(10), S(8), S(8));
            lx -= S(8);
        }
        Txt(g, title, fBold, Dim, new Rectangle(r.X + S(10), r.Y + S(4), Math.Max(S(40), lx - r.X - S(14)), S(20)), sfL);

        // подписи времени
        Rectangle xl = new Rectangle(pr.X, r.Bottom - mb, pr.Width, mb - S(2));
        Txt(g, "-" + FmtTime(win), fSmall, Faint, xl, sfL);
        Txt(g, "-" + FmtTime(win / 2), fSmall, Faint, xl, sfC);
        Txt(g, "сейчас", fSmall, Faint, xl, sfR);

        if (mx < mn) {
            Txt(g, "нет данных", fNorm, Faint, pr, sfC);
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

        using (Pen gp = new Pen(Color.FromArgb(70, Faint), 1f)) {
            for (double yv = lo; yv <= hi + step * 0.001; yv += step) {
                float y = (float)(pr.Bottom - (yv - lo) / (hi - lo) * pr.Height);
                g.DrawLine(gp, pr.X, y, pr.Right, y);
                Txt(g, yv.ToString(yfmt, CultureInfo.CurrentCulture), fSmall, Faint, new Rectangle(r.X + S(2), (int)y - S(8), ml - S(6), S(16)), sfR);
            }
            float xm = pr.X + pr.Width / 2f;
            g.DrawLine(gp, xm, pr.Y, xm, pr.Bottom);
        }

        Region old = g.Clip;
        g.SetClip(pr);
        double[] lv = new double[] { warnAt, critAt };
        Color[] lc = new Color[] { Wn, Cr };
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
                if (bad && run.Count > 0) {
                    DrawRun(g, run, cols[k], pr);
                    run = new List<PointF>();
                }
                if (!end && !double.IsNaN(v) && !double.IsInfinity(v)) {
                    PointF pt = new PointF((float)(pr.X + (t - t0) / win * pr.Width), (float)(pr.Bottom - (v - lo) / (hi - lo) * pr.Height));
                    run.Add(pt);
                    prevT = t;
                    lastPt = pt; lastT = t;
                }
            }
            if (lastT > t1 - 20) {
                using (SolidBrush b = new SolidBrush(cols[k])) g.FillEllipse(b, lastPt.X - S(3), lastPt.Y - S(3), S(6), S(6));
            }
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
        using (Pen p = new Pen(c, Math.Max(1.6f, sc * 1.8f))) {
            p.LineJoin = LineJoin.Round;
            if (pts.Length >= 3) g.DrawCurve(p, pts, 0.25f); else g.DrawLines(p, pts);
        }
    }

    // ---------- находки и журнал
    void DrawIssues(Graphics g, Rectangle r, LiveSnap s) {
        Panel(g, r);
        Txt(g, "Находки", fBold, Tx, new Rectangle(r.X + S(12), r.Y + S(3), S(80), S(20)), sfL);
        int x = r.X + S(92);
        string[] lab = new string[] { s.NCrit + " критичных", s.NWarn + " предупр.", s.NInfo + " инфо" };
        Color[] cc = new Color[] { Cr, Wn, Faint };
        int[] cn = new int[] { s.NCrit, s.NWarn, s.NInfo };
        for (int i = 0; i < 3; i++) {
            Color c = cn[i] > 0 ? cc[i] : Faint;
            int w = (int)g.MeasureString(lab[i], fSmall).Width + S(10);
            if (x + w > r.Right - S(6)) break;
            using (SolidBrush b = new SolidBrush(c)) g.FillEllipse(b, x, r.Y + S(9), S(7), S(7));
            Txt(g, lab[i], fSmall, cn[i] > 0 ? Tx : Faint, new Rectangle(x + S(10), r.Y + S(3), w, S(20)), sfL);
            x += w + S(12);
        }
        int lh = S(17);
        int y = r.Y + S(25);
        int fit = Math.Max(0, (r.Bottom - S(4) - y) / lh);
        if (s.Issues.Count == 0) {
            Txt(g, "Проблем пока не найдено", fSmall, Faint, new Rectangle(r.X + S(12), y, r.Width - S(24), lh), sfL);
            return;
        }
        for (int i = 0; i < fit && i < s.Issues.Count; i++) {
            LiveIssue it = s.Issues[s.Issues.Count - 1 - i];
            Color c = it.Level == "crit" ? Cr : (it.Level == "warn" ? Wn : Faint);
            using (SolidBrush b = new SolidBrush(c)) g.FillEllipse(b, r.X + S(14), y + S(5), S(7), S(7));
            Txt(g, it.Text, fSmall, it.Level == "info" ? Dim : Tx, new Rectangle(r.X + S(28), y, r.Width - S(40), lh), sfL);
            y += lh;
        }
    }

    void DrawLog(Graphics g, Rectangle r, LiveSnap s) {
        Panel(g, r);
        Txt(g, "Журнал", fBold, Tx, new Rectangle(r.X + S(12), r.Y + S(3), S(120), S(20)), sfL);
        int lh = S(14);
        int y = r.Y + S(25);
        int fit = Math.Max(0, Math.Min(8, (r.Bottom - S(4) - y) / lh));
        int cnt = Math.Min(fit, s.Log.Count);
        for (int i = 0; i < cnt; i++) {
            string line = s.Log[s.Log.Count - cnt + i];
            Txt(g, line, fMono, i == cnt - 1 ? Tx : Dim, new Rectangle(r.X + S(12), y, r.Width - S(24), lh), sfL);
            y += lh;
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
        $appName = 'BigTechoTest'
        if ($G.UiOk) { try { $appName = [string][DiagTheme]::AppName } catch {} }
        [DiagLive]::Start(($appName + ' — диагностика ПК'), $names.ToArray(), $flags.ToArray())
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
