# ---------------------------------------------------------------- Периферия (ключ periph)
# Окно из 5 шагов: клавиатура (сколько клавиш одновременно + WASD+Shift+Пробел), мышь (частота опроса по Raw Input,
# двойные срабатывания кнопок, колесо и боковые кнопки), геймпад (XInput: кнопки, стики, курки, дрифт, вибрация).
# Запуск: stress-81-periph.ps1 (только при $G.Interactive). Веб-камера уже проверяется отдельным тестом.
$STEPKEYS['Периферия: клавиатура, мышь, геймпад'] = 'periph'
$G.PresetHooks.Add({ param($full) $G.Sel.periph = $full })

function Get-PcDiagPeriphSrc {
@'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

public static class DiagPeriphTheme {
    public static readonly Color Bg = Color.FromArgb(0x0e, 0x0e, 0x10);
    public static readonly Color Panel = Color.FromArgb(0x17, 0x17, 0x1a);
    public static readonly Color Soft = Color.FromArgb(0x21, 0x21, 0x25);
    public static readonly Color Line = Color.FromArgb(0x29, 0x29, 0x2e);
    public static readonly Color LineHi = Color.FromArgb(0x3a, 0x3a, 0x40);
    public static readonly Color Accent = Color.FromArgb(0xdd, 0x0a, 0x0a);
    public static readonly Color AccentText = Color.FromArgb(0xff, 0x7a, 0x68);
    public static readonly Color Ok = Color.FromArgb(0x45, 0xd1, 0x7a);
    public static readonly Color Crit = Color.FromArgb(0xff, 0x4d, 0x4f);
    public static readonly Color Warn = Color.FromArgb(0xf0, 0xb2, 0x3c);
    public static readonly Color Ink = Color.FromArgb(0xf4, 0xf4, 0xf5);
    public static readonly Color Ink2 = Color.FromArgb(0xc2, 0xc2, 0xc6);
    public static readonly Color Ink3 = Color.FromArgb(0x8e, 0x8e, 0x94);
    public static Font F(float px, FontStyle st) { return new Font("Segoe UI", px, st, GraphicsUnit.Pixel); }
}

public class DiagPeriphResult {
    // клавиатура
    public int KbMax, KbDistinct, ComboBest;
    public string KbMaxKeys = "", ComboMissing = "";
    // мышь: частота опроса
    public double PollHz, PollMax; public int PollSamples; public bool PollTried;
    // клики: индексы 0 = левая, 1 = правая, 2 = средняя
    public int[] Clk = new int[3], Chat = new int[3], Fast = new int[3];
    public double[] MinInt = new double[] { -1, -1, -1 };
    // колесо и кнопки
    public int WheelUp, WheelDown, WheelGlitch;
    public bool BtnL, BtnR, BtnM, BtnX1, BtnX2;
    // геймпад
    public bool PadFound, DriftDone;
    public int PadBtnsSeen, TrigL, TrigR;
    public double DriftL, DriftR, DriftLx, DriftLy, DriftRx, DriftRy, StickMaxL, StickMaxR;
    public string VibL = "skip", VibR = "skip";
    public bool[] Visited = new bool[5];
}

[StructLayout(LayoutKind.Sequential)] public struct DiagXPad { public ushort Buttons; public byte LT, RT; public short LX, LY, RX, RY; }
[StructLayout(LayoutKind.Sequential)] public struct DiagXState { public uint Packet; public DiagXPad Pad; }
[StructLayout(LayoutKind.Sequential)] public struct DiagXVib { public ushort L, R; }

public static class DiagXInput {
    [DllImport("xinput1_4.dll", EntryPoint = "XInputGetState")] static extern uint Get14(uint i, out DiagXState s);
    [DllImport("xinput1_4.dll", EntryPoint = "XInputSetState")] static extern uint Set14(uint i, ref DiagXVib v);
    [DllImport("xinput9_1_0.dll", EntryPoint = "XInputGetState")] static extern uint Get910(uint i, out DiagXState s);
    [DllImport("xinput9_1_0.dll", EntryPoint = "XInputSetState")] static extern uint Set910(uint i, ref DiagXVib v);
    static int mode = 0;   // 0 - не определено, 1 - xinput1_4, 2 - xinput9_1_0, -1 - нет
    public static uint GetState(uint i, out DiagXState s) {
        s = new DiagXState();
        if (mode == 0 || mode == 1) {
            try { uint r = Get14(i, out s); mode = 1; return r; }
            catch (DllNotFoundException) { mode = 0; }
            catch (EntryPointNotFoundException) { mode = 0; }
            catch (Exception) { mode = 0; }
            if (mode == 0) mode = 2;
        }
        if (mode == 2) {
            try { return Get910(i, out s); }
            catch (Exception) { mode = -1; }
        }
        return 1167;
    }
    public static void Vibrate(uint i, int left, int right) {
        DiagXVib v = new DiagXVib(); v.L = (ushort)left; v.R = (ushort)right;
        try { if (mode == 1) Set14(i, ref v); else if (mode == 2) Set910(i, ref v); } catch (Exception) { }
    }
}

public class DiagPeriphForm : Form, IMessageFilter {
    // ---- Win32
    [StructLayout(LayoutKind.Sequential)] struct RAWINPUTDEVICE { public ushort usagePage; public ushort usage; public uint flags; public IntPtr hwnd; }
    [DllImport("user32.dll", SetLastError = true)] static extern bool RegisterRawInputDevices(RAWINPUTDEVICE[] d, uint n, uint size);
    [DllImport("user32.dll")] static extern int GetRawInputData(IntPtr h, uint cmd, IntPtr data, ref uint size, uint hdrSize);

    public DiagPeriphResult R = new DiagPeriphResult();
    const int CX = 32, CY = 150, CW = 916, CH = 432;
    static readonly string[] Titles = new string[] { "Клавиатура: одновременные нажатия", "Мышь: частота опроса", "Мышь: двойные срабатывания кнопок", "Мышь: колесо и кнопки", "Геймпад" };
    static readonly string[] Instr = new string[] {
        "Зажмите как можно больше клавиш сразу: обеими руками, можно ладонью. Затем проверьте игровое сочетание W + A + S + D + Shift + Пробел: зажмите все шесть и подержите 2 секунды. Клавишу Win не нажимайте.",
        "Нажмите «Старт» и 5 секунд быстро водите мышь кругами по всему окну. Чем быстрее движение, тем точнее замер. Измерение идёт по сырому вводу (Raw Input).",
        "Нажимайте ЛЕВУЮ кнопку мыши по одному разу, примерно раз в секунду, 20 раз. Не делайте двойных кликов. При желании затем нажмите по 10 раз правую и среднюю кнопки.",
        "Покрутите колесо по одному щелчку: 10 вверх, затем 10 вниз. Нажмите колесо и боковые кнопки (назад, вперёд), если они есть. Нажатые кнопки подсветятся.",
        "Если геймпад подключён, он определится сам. Подвигайте стики по кругу, нажмите все кнопки и курки. Затем отпустите стики и нажмите «Замерить дрифт»." };

    int stage;
    Font fTitle, fText, fBig, fSmall, fChip, fHuge;
    Button btnA, btnB, btnC, btnNext, btnSkip;
    System.Windows.Forms.Timer timer = new System.Windows.Forms.Timer();
    Stopwatch clock = Stopwatch.StartNew();
    bool filterOn;
    IntPtr rawBuf = IntPtr.Zero;

    // клавиатура
    HashSet<int> down = new HashSet<int>();
    HashSet<int> ever = new HashSet<int>();
    static readonly int[] Combo = new int[] { 0x57, 0x41, 0x53, 0x44, 0x10, 0x20 };
    HashSet<int> comboSeen = new HashSet<int>();

    // опрос мыши
    bool measuring; long pollStart; List<long> stamps = new List<long>(); string pollNote = "";

    // клики
    long[] lastDown = new long[] { 0, 0, 0 };
    List<double> recentL = new List<double>();

    // колесо
    int lastWheelDir; long lastWheelTs;
    bool dL, dR, dM, dX1, dX2;

    // геймпад
    int padIdx = -1; DiagXState padState; bool padOn;
    int padSeenMask; int[] driftTicks = new int[1];
    bool drifting; long driftStart; double sLX, sLY, sRX, sRY; int sN; double maxDev; string driftMsg = "";
    int vibMotor = -1; long vibUntil; bool vibAsk; long padLastScan;

    public DiagPeriphForm() {
        AutoScaleMode = AutoScaleMode.None;
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer, true);
        FormBorderStyle = FormBorderStyle.FixedDialog; MaximizeBox = false; MinimizeBox = false; ShowIcon = false;
        StartPosition = FormStartPosition.CenterScreen;
        ClientSize = new Size(980, 690);
        BackColor = DiagPeriphTheme.Bg; ForeColor = DiagPeriphTheme.Ink;
        Text = "Проверка периферии";
        fTitle = DiagPeriphTheme.F(26, FontStyle.Bold); fText = DiagPeriphTheme.F(15, FontStyle.Regular);
        fBig = DiagPeriphTheme.F(40, FontStyle.Bold); fSmall = DiagPeriphTheme.F(13, FontStyle.Regular);
        fChip = DiagPeriphTheme.F(14, FontStyle.Bold); fHuge = DiagPeriphTheme.F(72, FontStyle.Bold);
        btnA = MkBtn(32, 0); btnB = MkBtn(216, 0); btnC = MkBtn(400, 0);
        btnSkip = MkBtn(598, 0); btnSkip.Text = "Пропустить этап";
        btnNext = MkBtn(778, 0); btnNext.Text = "Далее";
        btnA.Click += new EventHandler(OnA); btnB.Click += new EventHandler(OnB); btnC.Click += new EventHandler(OnC);
        btnSkip.Click += new EventHandler(OnSkip); btnNext.Click += new EventHandler(OnNext);
        timer.Interval = 16; timer.Tick += new EventHandler(OnTick);
        GoStage(0);
    }

    Button MkBtn(int x, int dummy) {
        Button b = new Button();
        b.SetBounds(x, 622, (x >= 598) ? 170 : 176, 44);
        b.FlatStyle = FlatStyle.Flat; b.TabStop = false; b.Cursor = Cursors.Hand;
        b.Font = new Font("Segoe UI", 10f, FontStyle.Bold);
        Controls.Add(b);
        return b;
    }

    void Style(Button b, bool primary) {
        b.BackColor = primary ? DiagPeriphTheme.Accent : DiagPeriphTheme.Soft;
        b.ForeColor = primary ? Color.White : DiagPeriphTheme.Ink2;
        b.FlatAppearance.BorderColor = primary ? DiagPeriphTheme.Accent : DiagPeriphTheme.LineHi;
    }

    // ------------------------------------------------------------ жизненный цикл
    protected override void OnHandleCreated(EventArgs e) {
        base.OnHandleCreated(e);
        try {
            RAWINPUTDEVICE[] d = new RAWINPUTDEVICE[1];
            d[0].usagePage = 1; d[0].usage = 2; d[0].flags = 0x100; d[0].hwnd = Handle;
            RegisterRawInputDevices(d, 1, (uint)Marshal.SizeOf(typeof(RAWINPUTDEVICE)));
        } catch (Exception) { }
        rawBuf = Marshal.AllocHGlobal(256);
        Application.AddMessageFilter(this); filterOn = true;
        timer.Start();
    }

    protected override void OnHandleDestroyed(EventArgs e) {
        timer.Stop();
        if (filterOn) { Application.RemoveMessageFilter(this); filterOn = false; }
        try {
            RAWINPUTDEVICE[] d = new RAWINPUTDEVICE[1];
            d[0].usagePage = 1; d[0].usage = 2; d[0].flags = 0x1; d[0].hwnd = IntPtr.Zero;
            RegisterRawInputDevices(d, 1, (uint)Marshal.SizeOf(typeof(RAWINPUTDEVICE)));
        } catch (Exception) { }
        if (rawBuf != IntPtr.Zero) { Marshal.FreeHGlobal(rawBuf); rawBuf = IntPtr.Zero; }
        if (padIdx >= 0) DiagXInput.Vibrate((uint)padIdx, 0, 0);
        base.OnHandleDestroyed(e);
    }

    protected override void Dispose(bool disposing) {
        if (disposing) { timer.Dispose(); fTitle.Dispose(); fText.Dispose(); fBig.Dispose(); fSmall.Dispose(); fChip.Dispose(); fHuge.Dispose(); }
        base.Dispose(disposing);
    }

    protected override void OnDeactivate(EventArgs e) { down.Clear(); dL = dR = dM = dX1 = dX2 = false; base.OnDeactivate(e); Invalidate(); }

    void GoStage(int s) {
        stage = s; R.Visited[s] = true;
        measuring = false; drifting = false; vibAsk = false;
        btnA.Visible = btnB.Visible = btnC.Visible = true;
        btnB.Enabled = btnC.Enabled = true; btnA.Enabled = true;
        Style(btnA, false); Style(btnB, false); Style(btnC, false);
        btnB.Visible = btnC.Visible = false;
        switch (s) {
            case 0: btnA.Text = "Сбросить счёт"; break;
            case 1: btnA.Text = "Старт (5 секунд)"; Style(btnA, true); break;
            case 2: btnA.Text = "Сбросить счёт"; break;
            case 3: btnA.Text = "Сбросить счёт"; break;
            case 4: btnA.Text = "Замерить дрифт"; btnB.Text = "Вибрация: левый"; btnC.Text = "Вибрация: правый"; btnB.Visible = btnC.Visible = true; break;
        }
        btnNext.Text = (s == 4) ? "Завершить" : "Далее";
        Style(btnNext, true); Style(btnSkip, false);
        Invalidate();
    }

    void OnNext(object s, EventArgs e) { if (stage >= 4) { DialogResult = DialogResult.OK; Close(); } else GoStage(stage + 1); }
    void OnSkip(object s, EventArgs e) { OnNext(s, e); }

    void OnA(object s, EventArgs e) {
        if (stage == 0) { down.Clear(); ever.Clear(); comboSeen.Clear(); R.KbMax = 0; R.KbDistinct = 0; R.ComboBest = 0; R.KbMaxKeys = ""; R.ComboMissing = ""; }
        else if (stage == 1) { stamps.Clear(); measuring = true; pollStart = Stopwatch.GetTimestamp(); pollNote = ""; R.PollHz = 0; R.PollMax = 0; R.PollSamples = 0; R.PollTried = true; btnA.Enabled = false; }
        else if (stage == 2) { for (int i = 0; i < 3; i++) { R.Clk[i] = 0; R.Chat[i] = 0; R.Fast[i] = 0; R.MinInt[i] = -1; lastDown[i] = 0; } recentL.Clear(); }
        else if (stage == 3) { R.WheelUp = 0; R.WheelDown = 0; R.WheelGlitch = 0; R.BtnL = R.BtnR = R.BtnM = R.BtnX1 = R.BtnX2 = false; lastWheelDir = 0; }
        else if (stage == 4) {
            if (padIdx < 0) return;
            drifting = true; driftStart = Stopwatch.GetTimestamp(); sLX = sLY = sRX = sRY = 0; sN = 0; maxDev = 0; driftMsg = "Не трогайте стики...";
            btnA.Enabled = false;
        }
        Invalidate();
    }

    void OnB(object s, EventArgs e) {
        if (stage != 4 || padIdx < 0) return;
        if (vibAsk) { SetVib(true); return; }
        StartVib(0);
    }
    void OnC(object s, EventArgs e) {
        if (stage != 4 || padIdx < 0) return;
        if (vibAsk) { SetVib(false); return; }
        StartVib(1);
    }
    void StartVib(int motor) {
        vibMotor = motor;
        DiagXInput.Vibrate((uint)padIdx, motor == 0 ? 65535 : 0, motor == 1 ? 65535 : 0);
        vibUntil = Stopwatch.GetTimestamp() + Stopwatch.Frequency * 8 / 10;
        btnA.Enabled = btnB.Enabled = btnC.Enabled = false;
    }
    void SetVib(bool yes) {
        string v = yes ? "yes" : "no";
        if (vibMotor == 0) R.VibL = v; else R.VibR = v;
        vibAsk = false; vibMotor = -1;
        btnB.Text = "Вибрация: левый"; btnC.Text = "Вибрация: правый";
        btnA.Enabled = !drifting; Style(btnB, false); Style(btnC, false);
        Invalidate();
    }

    // ------------------------------------------------------------ ввод
    public bool PreFilterMessage(ref Message m) {
        if (stage != 0 || m.Msg < 0x100 || m.Msg > 0x107) return false;
        if (Form.ActiveForm != this) return false;
        if (m.Msg == 0x100 || m.Msg == 0x101 || m.Msg == 0x104 || m.Msg == 0x105) {
            int vk = (int)(m.WParam.ToInt64() & 0xFF);
            long lp = m.LParam.ToInt64();
            int scan = (int)((lp >> 16) & 0xFF); bool ext = ((lp >> 24) & 1) != 0;
            if (vk == 0x10) vk = (scan == 0x36) ? 0xA1 : 0xA0;
            else if (vk == 0x11) vk = ext ? 0xA3 : 0xA2;
            else if (vk == 0x12) vk = ext ? 0xA5 : 0xA4;
            KeyEvent(vk, m.Msg == 0x100 || m.Msg == 0x104);
        }
        return true;
    }

    static bool IsCombo(int vk) { return vk == 0x57 || vk == 0x41 || vk == 0x53 || vk == 0x44 || vk == 0xA0 || vk == 0xA1 || vk == 0x20; }
    static int ComboSlot(int vk) {
        switch (vk) { case 0x57: return 0; case 0x41: return 1; case 0x53: return 2; case 0x44: return 3; case 0xA0: case 0xA1: return 4; case 0x20: return 5; }
        return -1;
    }

    void KeyEvent(int vk, bool isDown) {
        if (isDown) { down.Add(vk); ever.Add(vk); } else down.Remove(vk);
        R.KbDistinct = ever.Count;
        if (down.Count > R.KbMax) { R.KbMax = down.Count; R.KbMaxKeys = JoinKeys(down); }
        bool[] have = new bool[6]; int n = 0;
        foreach (int k in down) { int sl = ComboSlot(k); if (sl >= 0 && !have[sl]) { have[sl] = true; n++; } }
        if (n > R.ComboBest) {
            R.ComboBest = n;
            string[] nm = new string[] { "W", "A", "S", "D", "Shift", "Пробел" };
            List<string> miss = new List<string>();
            for (int i = 0; i < 6; i++) if (!have[i]) miss.Add(nm[i]);
            R.ComboMissing = string.Join(", ", miss.ToArray());
        }
        comboSeen.Clear();
        Invalidate(new Rectangle(CX, CY, CW, CH));
    }

    public static string KeyName(int vk) {
        switch (vk) {
            case 0x20: return "Пробел"; case 0xA0: return "Shift (л)"; case 0xA1: return "Shift (п)";
            case 0xA2: return "Ctrl (л)"; case 0xA3: return "Ctrl (п)"; case 0xA4: return "Alt (л)"; case 0xA5: return "Alt (п)";
            case 0x5B: case 0x5C: return "Win"; case 0x0D: return "Enter"; case 0x1B: return "Esc"; case 0x09: return "Tab";
            case 0x08: return "Backspace"; case 0x14: return "Caps"; case 0x25: return "←"; case 0x26: return "↑"; case 0x27: return "→"; case 0x28: return "↓";
        }
        if (vk >= 0x30 && vk <= 0x39) return ((char)vk).ToString();
        if (vk >= 0x41 && vk <= 0x5A) return ((char)vk).ToString();
        return ((Keys)vk).ToString();
    }
    static string JoinKeys(HashSet<int> set) {
        List<string> l = new List<string>();
        foreach (int k in set) l.Add(KeyName(k));
        return string.Join(" + ", l.ToArray());
    }

    protected override void WndProc(ref Message m) {
        if (m.Msg == 0x00FF && measuring) {
            try { OnRawInput(m.LParam); } catch (Exception) { }
        }
        base.WndProc(ref m);
    }

    void OnRawInput(IntPtr hRaw) {
        long ts = Stopwatch.GetTimestamp();
        uint size = 256;
        int hdr = IntPtr.Size == 8 ? 24 : 16;
        int got = GetRawInputData(hRaw, 0x10000003, rawBuf, ref size, (uint)hdr);
        if (got <= 0) return;
        if (Marshal.ReadInt32(rawBuf, 0) != 0) return;   // только мышь
        int flags = Marshal.ReadInt16(rawBuf, hdr) & 0xFFFF;
        int lx = Marshal.ReadInt32(rawBuf, hdr + 12), ly = Marshal.ReadInt32(rawBuf, hdr + 16);
        if ((flags & 1) != 0) return;   // абсолютные координаты (не мышь)
        if (lx == 0 && ly == 0) return;
        stamps.Add(ts);
    }

    void FinishPoll() {
        measuring = false; btnA.Enabled = true; btnA.Text = "Повторить"; Style(btnA, false);
        double fq = Stopwatch.Frequency;
        if (stamps.Count < 50) { pollNote = "Мало данных: двигайте мышь быстрее и по большой площади."; Invalidate(); return; }
        long t0 = stamps[0];
        int nb = (int)((stamps[stamps.Count - 1] - t0) / fq / 0.1) + 1;
        int[] cnt = new int[nb];
        for (int i = 0; i < stamps.Count; i++) { int ix = (int)((stamps[i] - t0) / fq / 0.1); if (ix >= 0 && ix < nb) cnt[ix]++; }
        List<double> hz = new List<double>();
        for (int i = 1; i < nb - 1; i++) if (cnt[i] >= 5) hz.Add(cnt[i] * 10.0);
        if (hz.Count < 4) { pollNote = "Мало плавных отрезков: двигайте мышь непрерывно кругами."; Invalidate(); return; }
        hz.Sort();
        R.PollHz = hz[(int)((hz.Count - 1) * 0.75)];
        R.PollMax = hz[hz.Count - 1];
        R.PollSamples = hz.Count;
        pollNote = "";
        Invalidate();
    }

    protected override void OnMouseDown(MouseEventArgs e) {
        base.OnMouseDown(e);
        if (stage == 2 && new Rectangle(CX, CY, CW, CH).Contains(e.Location)) {
            int b = e.Button == MouseButtons.Left ? 0 : (e.Button == MouseButtons.Right ? 1 : (e.Button == MouseButtons.Middle ? 2 : -1));
            if (b >= 0) {
                long now = Stopwatch.GetTimestamp();
                R.Clk[b]++;
                if (lastDown[b] != 0) {
                    double ms = (now - lastDown[b]) * 1000.0 / Stopwatch.Frequency;
                    if (ms < 80) R.Chat[b]++;
                    if (ms < 40) R.Fast[b]++;
                    if (R.MinInt[b] < 0 || ms < R.MinInt[b]) R.MinInt[b] = ms;
                    if (b == 0) { recentL.Add(ms); if (recentL.Count > 10) recentL.RemoveAt(0); }
                }
                lastDown[b] = now;
                Invalidate(new Rectangle(CX, CY, CW, CH));
            }
        }
        if (stage == 3) {
            if (e.Button == MouseButtons.Left) { dL = true; R.BtnL = true; }
            else if (e.Button == MouseButtons.Right) { dR = true; R.BtnR = true; }
            else if (e.Button == MouseButtons.Middle) { dM = true; R.BtnM = true; }
            else if (e.Button == MouseButtons.XButton1) { dX1 = true; R.BtnX1 = true; }
            else if (e.Button == MouseButtons.XButton2) { dX2 = true; R.BtnX2 = true; }
            Invalidate(new Rectangle(CX, CY, CW, CH));
        }
    }
    protected override void OnMouseUp(MouseEventArgs e) {
        base.OnMouseUp(e);
        if (stage == 3) { dL = dR = dM = dX1 = dX2 = false; Invalidate(new Rectangle(CX, CY, CW, CH)); }
    }
    protected override void OnMouseWheel(MouseEventArgs e) {
        base.OnMouseWheel(e);
        if (stage != 3 || e.Delta == 0) return;
        int dir = e.Delta > 0 ? 1 : -1;
        int notches = Math.Max(1, Math.Abs(e.Delta) / 120);
        long now = Stopwatch.GetTimestamp();
        double dt = (now - lastWheelTs) * 1000.0 / Stopwatch.Frequency;
        if (lastWheelDir != 0 && dir != lastWheelDir && dt < 120) R.WheelGlitch++;
        lastWheelDir = dir; lastWheelTs = now;
        if (dir > 0) R.WheelUp += notches; else R.WheelDown += notches;
        Invalidate(new Rectangle(CX, CY, CW, CH));
    }

    // ------------------------------------------------------------ таймер
    void OnTick(object s, EventArgs e) {
        bool redraw = false;
        long now = Stopwatch.GetTimestamp();
        if (measuring) {
            if ((now - pollStart) / (double)Stopwatch.Frequency >= 5.0) FinishPoll();
            redraw = true;
        }
        if (stage == 4) {
            if (padIdx < 0 || now - padLastScan > Stopwatch.Frequency) {
                if (padIdx < 0) {
                    for (uint i = 0; i < 4; i++) { DiagXState st; if (DiagXInput.GetState(i, out st) == 0) { padIdx = (int)i; R.PadFound = true; break; } }
                }
                padLastScan = now;
            }
            if (padIdx >= 0) {
                uint rc = DiagXInput.GetState((uint)padIdx, out padState);
                padOn = rc == 0;
                if (!padOn) { padIdx = -1; }
                else {
                    padSeenMask |= padState.Pad.Buttons; R.PadBtnsSeen = CountBits(padSeenMask);
                    if (padState.Pad.LT > R.TrigL) R.TrigL = padState.Pad.LT;
                    if (padState.Pad.RT > R.TrigR) R.TrigR = padState.Pad.RT;
                    double rl = Math.Sqrt((double)padState.Pad.LX * padState.Pad.LX + (double)padState.Pad.LY * padState.Pad.LY) / 32768.0 * 100.0;
                    double rr = Math.Sqrt((double)padState.Pad.RX * padState.Pad.RX + (double)padState.Pad.RY * padState.Pad.RY) / 32768.0 * 100.0;
                    if (rl > R.StickMaxL) R.StickMaxL = rl;
                    if (rr > R.StickMaxR) R.StickMaxR = rr;
                    if (drifting) {
                        sLX += padState.Pad.LX; sLY += padState.Pad.LY; sRX += padState.Pad.RX; sRY += padState.Pad.RY; sN++;
                        if (rl > maxDev) maxDev = rl; if (rr > maxDev) maxDev = rr;
                        if ((now - driftStart) / (double)Stopwatch.Frequency >= 1.5) FinishDrift();
                    }
                }
            }
            if (vibMotor >= 0 && !vibAsk && now >= vibUntil) {
                DiagXInput.Vibrate((uint)padIdx, 0, 0);
                vibAsk = true;
                btnB.Enabled = btnC.Enabled = true;
                btnB.Text = "Да, чувствую"; btnC.Text = "Нет"; Style(btnB, true); Style(btnC, false);
            }
            redraw = true;
        }
        if (redraw) Invalidate(new Rectangle(CX, CY, CW, CH));
    }

    static int CountBits(int v) { int c = 0; while (v != 0) { c += v & 1; v >>= 1; } return c; }

    void FinishDrift() {
        drifting = false; btnA.Enabled = true;
        if (sN < 10) { driftMsg = "Мало данных, повторите."; return; }
        if (maxDev > 35) { driftMsg = "Стик двигался во время замера. Отпустите стики и повторите."; return; }
        R.DriftLx = sLX / sN / 327.68; R.DriftLy = sLY / sN / 327.68; R.DriftRx = sRX / sN / 327.68; R.DriftRy = sRY / sN / 327.68;
        R.DriftL = Math.Sqrt(R.DriftLx * R.DriftLx + R.DriftLy * R.DriftLy);
        R.DriftR = Math.Sqrt(R.DriftRx * R.DriftRx + R.DriftRy * R.DriftRy);
        R.DriftDone = true; driftMsg = "";
    }

    // ------------------------------------------------------------ рисование
    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = e.Graphics;
        g.Clear(DiagPeriphTheme.Bg);
        g.TextRenderingHint = TextRenderingHint.ClearTypeGridFit;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        using (SolidBrush ab = new SolidBrush(DiagPeriphTheme.Accent)) g.FillRectangle(ab, 0, 0, 6, 120);
        g.DrawString(Titles[stage], fTitle, new SolidBrush(DiagPeriphTheme.Ink), 32, 18);
        string stp = "Шаг " + (stage + 1) + " из 5";
        SizeF ss = g.MeasureString(stp, fText);
        g.DrawString(stp, fText, new SolidBrush(DiagPeriphTheme.AccentText), 948 - ss.Width, 26);
        g.DrawString(Instr[stage], fText, new SolidBrush(DiagPeriphTheme.Ink2), new RectangleF(32, 62, 916, 80));
        Rectangle cr = new Rectangle(CX, CY, CW, CH);
        using (SolidBrush pb = new SolidBrush(DiagPeriphTheme.Panel)) g.FillRectangle(pb, cr);
        using (Pen pn = new Pen(DiagPeriphTheme.Line)) g.DrawRectangle(pn, cr);
        GraphicsState gs = g.Save();
        g.TranslateTransform(CX, CY);
        g.SetClip(new Rectangle(0, 0, CW, CH));
        switch (stage) {
            case 0: PaintKbd(g); break;
            case 1: PaintPoll(g); break;
            case 2: PaintClick(g); break;
            case 3: PaintWheel(g); break;
            case 4: PaintPad(g); break;
        }
        g.Restore(gs);
    }

    void Txt(Graphics g, string s, Font f, Color c, float x, float y) { using (SolidBrush b = new SolidBrush(c)) g.DrawString(s, f, b, x, y); }
    void TxtR(Graphics g, string s, Font f, Color c, RectangleF r) { using (SolidBrush b = new SolidBrush(c)) g.DrawString(s, f, b, r); }

    // state: 0 - не нажата, 1 - нажата сейчас, 2 - уже нажималась
    float Chip(Graphics g, float x, float y, string text, int state, float minW) {
        SizeF sz = g.MeasureString(text, fChip);
        float w = Math.Max(minW, sz.Width + 22), h = 34;
        Color bg = state == 1 ? DiagPeriphTheme.Accent : (state == 2 ? Color.FromArgb(0x1b, 0x3a, 0x2a) : DiagPeriphTheme.Soft);
        Color fg = state == 1 ? Color.White : (state == 2 ? DiagPeriphTheme.Ok : DiagPeriphTheme.Ink3);
        using (SolidBrush b = new SolidBrush(bg)) g.FillRectangle(b, x, y, w, h);
        using (Pen p = new Pen(state == 0 ? DiagPeriphTheme.LineHi : bg)) g.DrawRectangle(p, x, y, w, h);
        using (SolidBrush t = new SolidBrush(fg)) g.DrawString(text, fChip, t, x + (w - sz.Width) / 2, y + (h - sz.Height) / 2);
        return w;
    }

    void PaintKbd(Graphics g) {
        Txt(g, "Нажато сейчас", fSmall, DiagPeriphTheme.Ink3, 24, 16);
        Txt(g, down.Count.ToString(), fHuge, DiagPeriphTheme.Ink, 24, 34);
        Txt(g, "Максимум за сеанс", fSmall, DiagPeriphTheme.Ink3, 250, 16);
        Txt(g, R.KbMax.ToString(), fHuge, R.KbMax >= 6 ? DiagPeriphTheme.Ok : DiagPeriphTheme.AccentText, 250, 34);
        Txt(g, "Разных клавиш", fSmall, DiagPeriphTheme.Ink3, 480, 16);
        Txt(g, R.KbDistinct.ToString(), fHuge, DiagPeriphTheme.Ink2, 480, 34);
        Txt(g, "Нажатые сейчас клавиши", fSmall, DiagPeriphTheme.Ink3, 24, 138);
        float x = 24, y = 160;
        List<int> keys = new List<int>(down); keys.Sort();
        foreach (int k in keys) {
            string nm = KeyName(k);
            if (x > CW - 120) { x = 24; y += 40; }
            x += Chip(g, x, y, nm, 1, 44) + 6;
        }
        Txt(g, "Игровое сочетание W + A + S + D + Shift + Пробел", fSmall, DiagPeriphTheme.Ink3, 24, 252);
        string[] nms = new string[] { "W", "A", "S", "D", "Shift", "Пробел" };
        bool[] have = new bool[6];
        foreach (int k in down) { int sl = ComboSlot(k); if (sl >= 0) have[sl] = true; }
        x = 24;
        for (int i = 0; i < 6; i++) x += Chip(g, x, 276, nms[i], have[i] ? 1 : 0, 56) + 6;
        string best = "Лучший результат: " + R.ComboBest + " из 6" + (R.ComboBest > 0 && R.ComboBest < 6 ? "   (не зарегистрированы: " + R.ComboMissing + ")" : "");
        Txt(g, best, fText, R.ComboBest >= 6 ? DiagPeriphTheme.Ok : DiagPeriphTheme.Ink2, 24, 322);
        TxtR(g, "Справка. Обычная USB-клавиатура без NKRO гарантирует 6 обычных клавиш плюс модификаторы (Shift, Ctrl, Alt). Офисные мембранные модели часто теряют нажатия уже при 2-4 клавишах в неудобных сочетаниях (ghosting). PS/2 и игровые клавиатуры с N-key rollover ограничений не имеют. Результат важен для игр, но не для набора текста.",
            fSmall, DiagPeriphTheme.Ink3, new RectangleF(24, 356, CW - 48, 70));
    }

    void PaintPoll(Graphics g) {
        double el = measuring ? (Stopwatch.GetTimestamp() - pollStart) / (double)Stopwatch.Frequency : 0;
        if (measuring) {
            Txt(g, "Идёт замер... двигайте мышь кругами", fText, DiagPeriphTheme.Ink, 24, 24);
            using (SolidBrush b = new SolidBrush(DiagPeriphTheme.Soft)) g.FillRectangle(b, 24, 64, CW - 48, 14);
            using (SolidBrush b = new SolidBrush(DiagPeriphTheme.Accent)) g.FillRectangle(b, 24, 64, (float)((CW - 48) * Math.Min(1.0, el / 5.0)), 14);
            Txt(g, "Событий мыши: " + stamps.Count, fText, DiagPeriphTheme.Ink2, 24, 100);
            long now = Stopwatch.GetTimestamp(); int recent = 0;
            for (int i = stamps.Count - 1; i >= 0 && now - stamps[i] < Stopwatch.Frequency / 4; i--) recent++;
            Txt(g, "Сейчас примерно " + (recent * 4) + " Гц", fBig, DiagPeriphTheme.Ink, 24, 140);
            return;
        }
        if (R.PollHz <= 0) {
            Txt(g, R.PollTried ? "Замер не удался." : "Нажмите «Старт (5 секунд)» и водите мышь кругами.", fText, DiagPeriphTheme.Ink, 24, 24);
            if (pollNote.Length > 0) Txt(g, pollNote, fText, DiagPeriphTheme.Warn, 24, 56);
        } else {
            Txt(g, "Частота опроса мыши", fSmall, DiagPeriphTheme.Ink3, 24, 16);
            Txt(g, "≈ " + NiceHz(R.PollHz) + " Гц", fHuge, DiagPeriphTheme.Ok, 24, 34);
            Txt(g, "Пик: " + NiceHz(R.PollMax) + " Гц; измерено окон по 100 мс: " + R.PollSamples, fText, DiagPeriphTheme.Ink2, 24, 128);
            int[] marks = new int[] { 125, 250, 500, 1000, 2000, 4000, 8000 };
            float bx = 24, bw = CW - 48, by = 220;
            using (SolidBrush b = new SolidBrush(DiagPeriphTheme.Soft)) g.FillRectangle(b, bx, by, bw, 10);
            for (int i = 0; i < marks.Length; i++) {
                float px = bx + bw * (float)(Math.Log(marks[i] / 62.5) / Math.Log(8000 / 62.5));
                using (Pen p = new Pen(DiagPeriphTheme.LineHi)) g.DrawLine(p, px, by - 6, px, by + 16);
                string t = marks[i].ToString();
                SizeF sz = g.MeasureString(t, fSmall);
                Txt(g, t, fSmall, DiagPeriphTheme.Ink3, px - sz.Width / 2, by + 20);
            }
            double hzc = Math.Max(62.5, Math.Min(8000, R.PollHz));
            float mx = bx + bw * (float)(Math.Log(hzc / 62.5) / Math.Log(8000 / 62.5));
            using (SolidBrush b = new SolidBrush(DiagPeriphTheme.Accent)) g.FillRectangle(b, mx - 4, by - 10, 8, 30);
        }
        TxtR(g, "Справка. Офисные и недорогие мыши работают на 125 Гц, игровые на 500-1000 Гц и выше. Заметно ниже 100 Гц обычно значит слабые батарейки или режим экономии у беспроводной мыши, неисправный порт или перегруженный USB-хаб. Замер зависит от скорости движения: при медленном движении мышь может отправлять данные реже.",
            fSmall, DiagPeriphTheme.Ink3, new RectangleF(24, 330, CW - 48, 90));
    }

    static string NiceHz(double hz) {
        int[] std = new int[] { 125, 250, 500, 1000, 2000, 4000, 8000 };
        foreach (int s in std) if (Math.Abs(hz - s) <= s * 0.12) return s.ToString();
        return ((int)Math.Round(hz)).ToString();
    }

    void PaintClick(Graphics g) {
        string[] nm = new string[] { "Левая кнопка", "Правая кнопка", "Средняя кнопка" };
        for (int i = 0; i < 3; i++) {
            float x = 24 + i * 300;
            Txt(g, nm[i], fSmall, DiagPeriphTheme.Ink3, x, 16);
            Txt(g, R.Clk[i].ToString() + (i == 0 ? " / 20" : ""), fBig, DiagPeriphTheme.Ink, x, 36);
            bool bad = R.Fast[i] >= 1 || R.Chat[i] >= 2;
            string ch = "Двойных срабатываний: " + R.Chat[i];
            Txt(g, ch, fText, R.Clk[i] == 0 ? DiagPeriphTheme.Ink3 : (bad ? DiagPeriphTheme.Crit : (R.Chat[i] > 0 ? DiagPeriphTheme.Warn : DiagPeriphTheme.Ok)), x, 94);
            if (R.MinInt[i] >= 0) Txt(g, "Минимальный интервал: " + R.MinInt[i].ToString("0") + " мс", fSmall, DiagPeriphTheme.Ink3, x, 122);
        }
        Txt(g, "Последние интервалы между нажатиями левой кнопки, мс (красные - подозрительно быстрые)", fSmall, DiagPeriphTheme.Ink3, 24, 176);
        float cx = 24;
        for (int i = 0; i < recentL.Count; i++) {
            bool bad = recentL[i] < 80;
            cx += Chip(g, cx, 202, recentL[i].ToString("0"), bad ? 1 : 2, 60) + 6;
        }
        using (Pen p = new Pen(DiagPeriphTheme.LineHi) { DashStyle = DashStyle.Dash }) g.DrawRectangle(p, 24, 256, CW - 48, 90);
        string hint = R.Clk[0] >= 20 ? "Готово: нажмите «Далее»." : "Кликайте в любом месте этой области, окна и серой рамки.";
        Txt(g, hint, fText, R.Clk[0] >= 20 ? DiagPeriphTheme.Ok : DiagPeriphTheme.Ink2, 40, 290);
        TxtR(g, "Справка. Если за один щелчок мышь регистрирует два нажатия с промежутком меньше 40-80 мс, микропереключатель изношен (типично для левой кнопки после 1-3 лет). Признаки в жизни: самопроизвольные двойные клики, обрыв перетаскивания.",
            fSmall, DiagPeriphTheme.Ink3, new RectangleF(24, 360, CW - 48, 60));
    }

    void PaintWheel(Graphics g) {
        Txt(g, "Колесо вверх", fSmall, DiagPeriphTheme.Ink3, 24, 16);
        Txt(g, "▲ " + R.WheelUp, fBig, R.WheelUp > 0 ? DiagPeriphTheme.Ok : DiagPeriphTheme.Ink, 24, 36);
        Txt(g, "Колесо вниз", fSmall, DiagPeriphTheme.Ink3, 250, 16);
        Txt(g, "▼ " + R.WheelDown, fBig, R.WheelDown > 0 ? DiagPeriphTheme.Ok : DiagPeriphTheme.Ink, 250, 36);
        Txt(g, "Ложные обратные щелчки", fSmall, DiagPeriphTheme.Ink3, 476, 16);
        Txt(g, R.WheelGlitch.ToString(), fBig, R.WheelGlitch > 0 ? DiagPeriphTheme.Warn : DiagPeriphTheme.Ink, 476, 36);
        Txt(g, "Кнопки мыши (зелёная - нажималась, красная - нажата сейчас)", fSmall, DiagPeriphTheme.Ink3, 24, 130);
        float x = 24, y = 158;
        x += Chip(g, x, y, "Левая", dL ? 1 : (R.BtnL ? 2 : 0), 100) + 8;
        x += Chip(g, x, y, "Правая", dR ? 1 : (R.BtnR ? 2 : 0), 100) + 8;
        x += Chip(g, x, y, "Колесо (нажатие)", dM ? 1 : (R.BtnM ? 2 : 0), 100) + 8;
        x += Chip(g, x, y, "Назад (X1)", dX1 ? 1 : (R.BtnX1 ? 2 : 0), 100) + 8;
        x += Chip(g, x, y, "Вперёд (X2)", dX2 ? 1 : (R.BtnX2 ? 2 : 0), 100) + 8;
        TxtR(g, "Справка. «Ложный обратный щелчок» - когда при прокрутке в одну сторону колесо на мгновение отдаёт щелчок в другую (грязь или износ энкодера): страница дёргается. Боковые кнопки есть не у всех мышей.",
            fSmall, DiagPeriphTheme.Ink3, new RectangleF(24, 250, CW - 48, 70));
    }

    void PaintPad(Graphics g) {
        if (padIdx < 0 || !padOn) {
            Txt(g, "Геймпад не найден", fBig, DiagPeriphTheme.Ink, 24, 24);
            TxtR(g, "Подключите геймпад (Xbox или любой с поддержкой XInput) - он определится автоматически. Если геймпада нет, нажмите «Пропустить этап».",
                fText, DiagPeriphTheme.Ink2, new RectangleF(24, 90, CW - 48, 60));
            if (R.PadFound) Txt(g, "(геймпад был подключён, затем отключился)", fSmall, DiagPeriphTheme.Warn, 24, 150);
            return;
        }
        DiagXPad p = padState.Pad;
        Txt(g, "Геймпад " + (padIdx + 1) + " (XInput), пакет " + padState.Packet, fSmall, DiagPeriphTheme.Ink3, 24, 12);
        DrawStick(g, 110, 130, p.LX, p.LY, "Левый стик");
        DrawStick(g, 330, 130, p.RX, p.RY, "Правый стик");
        DrawTrigger(g, 480, 50, "LT", p.LT, R.TrigL); DrawTrigger(g, 540, 50, "RT", p.RT, R.TrigR);
        string[] bn = new string[] { "A", "B", "X", "Y", "LB", "RB", "Back", "Start", "L3", "R3", "↑", "↓", "←", "→" };
        int[] bm = new int[] { 0x1000, 0x2000, 0x4000, 0x8000, 0x100, 0x200, 0x20, 0x10, 0x40, 0x80, 1, 2, 4, 8 };
        float x = 620, y = 40;
        for (int i = 0; i < bn.Length; i++) {
            int st = (p.Buttons & bm[i]) != 0 ? 1 : ((padSeenMask & bm[i]) != 0 ? 2 : 0);
            if (x > CW - 80) { x = 620; y += 42; }
            x += Chip(g, x, y, bn[i], st, 52) + 6;
        }
        Txt(g, "Кнопок проверено: " + R.PadBtnsSeen + " из 14", fSmall, DiagPeriphTheme.Ink3, 620, 12);
        if (vibAsk) Txt(g, "Вы почувствовали вибрацию " + (vibMotor == 0 ? "ЛЕВОГО (большого)" : "ПРАВОГО (малого)") + " мотора?", fText, DiagPeriphTheme.Warn, 24, 270);
        else if (vibMotor >= 0) Txt(g, "Вибрация...", fText, DiagPeriphTheme.Warn, 24, 270);
        else if (drifting) Txt(g, driftMsg, fText, DiagPeriphTheme.Warn, 24, 270);
        else if (driftMsg.Length > 0) Txt(g, driftMsg, fText, DiagPeriphTheme.Crit, 24, 270);
        else if (R.DriftDone) {
            Txt(g, "Дрифт левого стика: " + R.DriftL.ToString("0.0") + " %   правого: " + R.DriftR.ToString("0.0") + " %", fText, 
                (Math.Max(R.DriftL, R.DriftR) >= 8) ? DiagPeriphTheme.Warn : DiagPeriphTheme.Ok, 24, 270);
            Txt(g, "Смещение центра (X, Y): левый " + R.DriftLx.ToString("0.0") + " / " + R.DriftLy.ToString("0.0") + "; правый " + R.DriftRx.ToString("0.0") + " / " + R.DriftRy.ToString("0.0") + " %", fSmall, DiagPeriphTheme.Ink3, 24, 300);
        }
        string vl = R.VibL == "skip" ? "не проверялась" : (R.VibL == "yes" ? "работает" : "НЕ РАБОТАЕТ");
        string vr = R.VibR == "skip" ? "не проверялась" : (R.VibR == "yes" ? "работает" : "НЕ РАБОТАЕТ");
        Txt(g, "Вибрация: левый мотор - " + vl + "; правый - " + vr, fSmall, DiagPeriphTheme.Ink3, 24, 330);
        TxtR(g, "Справка. В покое стик должен показывать ноль. Смещение центра более 8-10 % уже ощутимо в играх (персонаж или камера «уплывают»), более 20-25 % выходит за стандартную мёртвую зону Windows.",
            fSmall, DiagPeriphTheme.Ink3, new RectangleF(24, 362, CW - 48, 60));
    }

    void DrawStick(Graphics g, float cx, float cy, int sx, int sy, string cap) {
        float r = 70;
        SizeF sz = g.MeasureString(cap, fSmall);
        Txt(g, cap, fSmall, DiagPeriphTheme.Ink3, cx - sz.Width / 2, cy - r - 30);
        using (SolidBrush b = new SolidBrush(DiagPeriphTheme.Soft)) g.FillEllipse(b, cx - r, cy - r, 2 * r, 2 * r);
        using (Pen pn = new Pen(DiagPeriphTheme.LineHi)) g.DrawEllipse(pn, cx - r, cy - r, 2 * r, 2 * r);
        float rd = r * 0.08f;
        using (Pen pn = new Pen(DiagPeriphTheme.Warn) { DashStyle = DashStyle.Dot }) g.DrawEllipse(pn, cx - rd, cy - rd, 2 * rd, 2 * rd);
        using (Pen pn = new Pen(DiagPeriphTheme.Line)) { g.DrawLine(pn, cx - r, cy, cx + r, cy); g.DrawLine(pn, cx, cy - r, cx, cy + r); }
        float dx = sx / 32768f * r, dy = -sy / 32768f * r;
        using (SolidBrush b = new SolidBrush(DiagPeriphTheme.Accent)) g.FillEllipse(b, cx + dx - 9, cy + dy - 9, 18, 18);
        Txt(g, (sx / 327.68).ToString("0") + " ; " + (sy / 327.68).ToString("0"), fSmall, DiagPeriphTheme.Ink3, cx - 30, cy + r + 8);
    }

    void DrawTrigger(Graphics g, float x, float y, string cap, int v, int maxV) {
        float h = 150, w = 36;
        using (SolidBrush b = new SolidBrush(DiagPeriphTheme.Soft)) g.FillRectangle(b, x, y, w, h);
        float fh = h * v / 255f;
        using (SolidBrush b = new SolidBrush(DiagPeriphTheme.Accent)) g.FillRectangle(b, x, y + h - fh, w, fh);
        float mh = h * maxV / 255f;
        using (Pen p = new Pen(DiagPeriphTheme.Ok, 2)) g.DrawLine(p, x - 3, y + h - mh, x + w + 3, y + h - mh);
        Txt(g, cap, fChip, DiagPeriphTheme.Ink2, x + 6, y + h + 8);
    }

    // ------------------------------------------------------------ для проверки внешнего вида
    public void Demo(int st) {
        if (st == 0) { foreach (int k in new int[] { 0x57, 0x41, 0x53, 0xA0, 0x20 }) { down.Add(k); ever.Add(k); } R.KbMax = 6; R.KbDistinct = 9; R.ComboBest = 5; R.ComboMissing = "D"; }
        if (st == 1) { R.PollTried = true; R.PollHz = 985; R.PollMax = 1010; R.PollSamples = 38; }
        if (st == 2) { R.Clk[0] = 14; R.Clk[1] = 3; R.Chat[0] = 2; R.Fast[0] = 1; R.MinInt[0] = 31; recentL.AddRange(new double[] { 900, 1040, 31, 870, 1210, 760 }); }
        if (st == 3) { R.WheelUp = 10; R.WheelDown = 7; R.WheelGlitch = 1; R.BtnL = true; R.BtnM = true; dR = true; R.BtnR = true; }
        if (st == 4) { padIdx = 0; padOn = true; padState.Packet = 1234; padState.Pad.LX = 9000; padState.Pad.LY = -12000; padState.Pad.RT = 180; padState.Pad.Buttons = 0x1000; padSeenMask = 0x1000 | 0x2000 | 0x100; R.PadBtnsSeen = 3; R.TrigR = 255; R.DriftDone = true; R.DriftL = 12.3; R.DriftR = 1.1; R.VibL = "yes"; R.VibR = "no"; }
        GoStage(st);
    }
}

public static class DiagPeriph {
    public static DiagPeriphResult Run() {
        using (DiagPeriphForm f = new DiagPeriphForm()) {
            f.ShowDialog();
            return f.R;
        }
    }
}
'@
}

function Initialize-PcDiagPeriph {
    if ('DiagPeriph' -as [type]) { return $true }
    try {
        Add-Type -AssemblyName System.Windows.Forms, System.Drawing -ErrorAction Stop
        Add-Type -TypeDefinition (Get-PcDiagPeriphSrc) -Language CSharp -ReferencedAssemblies System.Windows.Forms, System.Drawing -ErrorAction Stop
        return $true
    } catch { $G.Log.Add("periph: Add-Type: $($_.Exception.Message)"); return $false }
}

# Вопрос Да/Нет перед полноэкранными тестами (использует окна программы, если они загружены)
function Ask-PcDiagYesNo($Text, $Title) {
    if ('DiagUi' -as [type]) { return ([DiagUi]::Ask($Text, $Title, $true) -eq 'yes') }
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
    return ([System.Windows.Forms.MessageBox]::Show($Text, $Title, 'YesNo', 'Question') -eq 'Yes')
}
