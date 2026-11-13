# ---------------------------------------------------------------- Полный тест экрана (ключ screenfull)
# Полноэкранные окна без рамки на каждом мониторе: однотонные цвета (битые пиксели), чёрный (засветы), серый 5 % и 50 %,
# градиенты (banding), резкость/муар/текст, шлейфы (UFO-блоки, синхронно с развёрткой DWM), Overdrive, подсказка по ШИМ (камерой).
# Управление: Пробел / стрелка вправо - дальше, стрелка влево - назад, H - показать подсказку, Esc - выйти.
# Потом окно с вопросами (засветы / битые пиксели / серый / полосы / шлейфы / ШИМ). Запуск: stress-80-display.ps1 (только при $G.Interactive).
# Окно рисуется в физических пикселях (per-monitor DPI только для этого потока), поэтому пиксельные тесты не размываются масштабом.
$STEPKEYS['Полный тест экрана'] = 'screenfull'
$G.PresetHooks.Add({ param($full) $G.Sel.screenfull = $full })

function Get-PcDiagScreenSrc {
@'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Drawing.Text;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

public class DiagScreenResult {
    public string Monitor = "";
    public int Width, Height;
    public bool Primary;
    public bool Aborted;
    public int PagesSeen;
    public double MeasuredHz;
    // yes / no / unk / skip
    public string Light = "skip", Dead = "skip", Gray = "skip", Banding = "skip", Ghost = "skip", Pwm = "skip";
}

public static class DiagScreenTheme {
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
}

public static class DiagScreenPages {
    public const int Count = 12;
    public static readonly string[] Titles = new string[] {
        "Белый экран", "Красный экран", "Зелёный экран", "Синий экран", "Чёрный экран (засветы)", "Серый 5 %",
        "Серый 50 %", "Градиенты (полосы)", "Резкость, текст и муар", "Шлейфы: движущиеся блоки",
        "Overdrive: ореолы за блоками", "Мерцание подсветки (ШИМ)" };
    public static readonly string[] Hints = new string[] {
        "Ищите тёмные точки (битые пиксели), пятна, грязь и жёлтый или синий оттенок по краям. Посмотрите вблизи на углы и края.",
        "Ищите чёрные точки и точки другого цвета. Яркая цветная точка на однотонном красном - «застрявший» пиксель.",
        "Ищите чёрные точки и точки другого цвета. Особенно заметны красные и синие точки на зелёном.",
        "Ищите чёрные точки и точки другого цвета. Яркие белые или красные точки на синем - застрявшие пиксели.",
        "Выключите свет в комнате. Светлые пятна по краям и углам - засветы подсветки (backlight bleed). Слабое сияние под углом - IPS glow, у IPS допустимо. Яркие точки - застрявшие пиксели.",
        "Тёмно-серый фон выявляет пятна и «облачность» подсветки, вертикальные и горизонтальные полосы, затемнение краёв.",
        "Средний серый - лучший фон для неоднородности: пятна, оттенок (зеленоватый или розоватый), полосы матрицы, тёмные углы.",
        "Переходы должны быть плавными. Резкие ступеньки и полосы - banding. Самые показательные тёмная и светлая шкалы.",
        "Линии в 1 пиксель должны быть чёткими, без цветной каймы и ряби (муар). Мелкий текст должен читаться. Масштаб Windows лучше 100 %.",
        "Блоки движутся с разной скоростью. Следите за блоком глазами. Чёткий блок - хорошо; длинный размытый хвост на ряду 960 пикс/с и быстрее - медленная матрица или выключенный Overdrive.",
        "Светлый ореол впереди или позади тёмного блока (или тёмный у светлого) - перерегулирование Overdrive. Сравните режимы Response Time / Overdrive в меню монитора.",
        "Сделайте яркость около 25 %. Наведите камеру смартфона на экран с 10-15 см (ручной режим, выдержка 1/1000 с, или замедленная съёмка 240 к/с). Тёмные бегущие полосы на картинке камеры - подсветка мерцает (ШИМ). Ровный серый - мерцания нет." };

    public static bool IsAnimated(int p) { return p == 9 || p == 10; }
    public static bool IsSticky(int p) { return p == 11; }
    static Color G(int v) { return Color.FromArgb(v, v, v); }

    public static Font F(float px, FontStyle st) { return new Font("Segoe UI", px, st, GraphicsUnit.Pixel); }

    public static void Draw(Graphics g, int w, int h, int page, double t) {
        g.SmoothingMode = SmoothingMode.None;
        g.PixelOffsetMode = PixelOffsetMode.None;
        g.InterpolationMode = InterpolationMode.NearestNeighbor;
        switch (page) {
            case 0: g.Clear(Color.White); break;
            case 1: g.Clear(Color.FromArgb(255, 0, 0)); break;
            case 2: g.Clear(Color.FromArgb(0, 255, 0)); break;
            case 3: g.Clear(Color.FromArgb(0, 0, 255)); break;
            case 4: g.Clear(Color.Black); break;
            case 5: g.Clear(G(13)); break;
            case 6: g.Clear(G(128)); break;
            case 7: DrawGradients(g, w, h); break;
            case 8: DrawSharp(g, w, h); break;
            case 9: DrawUfo(g, w, h, t); break;
            case 10: DrawOverdrive(g, w, h, t); break;
            case 11: g.Clear(G(64)); break;
            default: g.Clear(Color.Black); break;
        }
    }

    static void Ramp(Graphics g, int x0, int y0, int w, int h, int lo, int hi, int ch) {
        int prev = -1, start = 0;
        for (int x = 0; x <= w; x++) {
            int lv = -2;
            if (x < w) lv = (int)Math.Round(lo + (hi - lo) * (w > 1 ? (double)x / (w - 1) : 0.0));
            if (lv != prev) {
                if (prev >= 0) {
                    Color c = ch == 0 ? G(prev) : (ch == 1 ? Color.FromArgb(prev, 0, 0) : (ch == 2 ? Color.FromArgb(0, prev, 0) : Color.FromArgb(0, 0, prev)));
                    using (SolidBrush b = new SolidBrush(c)) g.FillRectangle(b, x0 + start, y0, x - start, h);
                }
                prev = lv; start = x;
            }
        }
    }

    static void DrawGradients(Graphics g, int w, int h) {
        g.Clear(Color.Black);
        int y = 0;
        int[] hs = new int[] { 22, 18, 15, 15, 15, 15 };
        int[] los = new int[] { 0, 0, 0, 0, 0, 215 };
        int[] his = new int[] { 255, 40, 255, 255, 255, 255 };
        int[] chs = new int[] { 0, 0, 1, 2, 3, 0 };
        for (int i = 0; i < hs.Length; i++) {
            int bh = (i == hs.Length - 1) ? (h - y) : h * hs[i] / 100;
            Ramp(g, 0, y, w, bh, los[i], his[i], chs[i]);
            y += bh;
        }
    }

    static Bitmap Pattern(int cw, int ch, int kind) {
        int[] px = new int[cw * ch];
        for (int y = 0; y < ch; y++)
            for (int x = 0; x < cw; x++) {
                bool on = kind == 0 ? ((x & 1) == 0) : (kind == 1 ? ((y & 1) == 0) : (((x + y) & 1) == 0));
                px[y * cw + x] = on ? -1 : unchecked((int)0xFF000000);
            }
        Bitmap bmp = new Bitmap(cw, ch, PixelFormat.Format32bppRgb);
        BitmapData bd = bmp.LockBits(new Rectangle(0, 0, cw, ch), ImageLockMode.WriteOnly, PixelFormat.Format32bppRgb);
        Marshal.Copy(px, 0, bd.Scan0, px.Length);
        bmp.UnlockBits(bd);
        return bmp;
    }

    static void DrawSharp(Graphics g, int w, int h) {
        g.Clear(Color.Black);
        int m = Math.Max(6, h / 90);
        int cw = (w - 4 * m) / 3, chh = (h - 3 * m) / 2;
        if (cw < 50 || chh < 50) return;
        string[] caps = new string[] { "вертикальные линии 1 px", "горизонтальные линии 1 px", "шахматка 1 px" };
        for (int i = 0; i < 3; i++) {
            int x = m + i * (cw + m);
            using (Bitmap bmp = Pattern(cw, chh, i)) g.DrawImageUnscaled(bmp, x, m);
            float fs = Math.Max(12, h / 70f);
            using (Font f = F(fs, FontStyle.Bold)) {
                g.TextRenderingHint = TextRenderingHint.AntiAlias;
                SizeF sz = g.MeasureString(caps[i], f);
                using (SolidBrush bb = new SolidBrush(Color.FromArgb(220, 0, 0, 0))) g.FillRectangle(bb, x + 6, m + 6, sz.Width + 8, sz.Height + 2);
                g.DrawString(caps[i], f, Brushes.Yellow, x + 10, m + 7);
            }
        }
        // концентрические окружности (зонная пластинка) - показывают муар
        int y2 = 2 * m + chh;
        Rectangle r1 = new Rectangle(m, y2, cw, chh);
        g.SetClip(r1);
        int R = Math.Min(cw, chh) / 2;
        double scale = Math.Sqrt(2.0 * R);
        int n = R / 2;
        using (Pen p = new Pen(Color.White, 1f)) {
            int cx = r1.X + cw / 2, cy = r1.Y + chh / 2;
            for (int k = 1; k <= n; k++) {
                int rr = (int)(Math.Sqrt(k) * scale);
                g.DrawEllipse(p, cx - rr, cy - rr, 2 * rr, 2 * rr);
            }
        }
        g.ResetClip();
        // текст: белый на чёрном
        string sample = "Съешь ещё этих мягких французских булок, да выпей чаю. 0123456789 ABC xyz";
        float[] sizes = new float[] { 9, 11, 13, 16, 20, 26 };
        float fscale = Math.Max(1f, h / 1080f);
        for (int pass = 0; pass < 2; pass++) {
            int x = m + (pass + 1) * (cw + m);
            Rectangle rc = new Rectangle(x, y2, cw, chh);
            using (SolidBrush bg = new SolidBrush(pass == 0 ? Color.Black : Color.White)) g.FillRectangle(bg, rc);
            g.TextRenderingHint = TextRenderingHint.ClearTypeGridFit;
            float yy = rc.Y + 6;
            for (int i = 0; i < sizes.Length; i++) {
                using (Font f = F(sizes[i] * fscale, FontStyle.Regular)) {
                    RectangleF lay = new RectangleF(rc.X + 6, yy, rc.Width - 12, rc.Bottom - yy);
                    SizeF sz = g.MeasureString(sample, f, (int)lay.Width);
                    if (yy + sz.Height > rc.Bottom) break;
                    using (SolidBrush tb = new SolidBrush(pass == 0 ? Color.White : Color.Black)) g.DrawString(sample, f, tb, lay);
                    yy += sz.Height + 4;
                }
            }
        }
    }

    static int Wrap(double v, int period) { double r = v % period; if (r < 0) r += period; return (int)r; }

    static void DrawUfo(Graphics g, int w, int h, double t) {
        int[] speeds = new int[] { 240, 480, 960, 1440, 1920, 2880 };
        int n = speeds.Length;
        int rowH = h / n;
        float k = Math.Max(0.8f, Math.Min(2.5f, h / 1080f));
        g.TextRenderingHint = TextRenderingHint.AntiAlias;
        using (Font f = F(16 * k, FontStyle.Regular)) {
            for (int i = 0; i < n; i++) {
                bool dark = (i % 2) == 0;
                int y = i * rowH;
                int bh = (i == n - 1) ? (h - y) : rowH;
                using (SolidBrush bg = new SolidBrush(dark ? G(30) : G(215))) g.FillRectangle(bg, 0, y, w, bh);
                int boxW = (int)(rowH * 0.75), boxH = (int)(rowH * 0.55);
                int period = w + boxW;
                int x = Wrap(t * speeds[i], period) - boxW;
                int by = y + (bh - boxH) / 2;
                Color boxC = dark ? Color.White : Color.Black;
                Color markC = dark ? Color.Black : Color.White;
                using (SolidBrush bb = new SolidBrush(boxC)) g.FillRectangle(bb, x, by, boxW, boxH);
                using (SolidBrush mb = new SolidBrush(markC)) {
                    g.FillRectangle(mb, x + boxW / 2 - 1, by + 4, 2, boxH - 8);
                    g.FillRectangle(mb, x + 4, by + boxH / 2 - 1, boxW - 8, 2);
                }
                using (SolidBrush tb = new SolidBrush(dark ? G(140) : G(90))) g.DrawString(speeds[i] + " пикс/с", f, tb, 8, y + 4);
            }
        }
    }

    static void DrawOverdrive(Graphics g, int w, int h, double t) {
        int[,] pairs = new int[,] { { 16, 64 }, { 64, 16 }, { 64, 192 }, { 192, 64 }, { 128, 240 }, { 240, 128 } };
        int n = 6;
        int rowH = h / n;
        float k = Math.Max(0.8f, Math.Min(2.5f, h / 1080f));
        g.TextRenderingHint = TextRenderingHint.AntiAlias;
        using (Font f = F(16 * k, FontStyle.Regular)) {
            for (int i = 0; i < n; i++) {
                int bgv = pairs[i, 0], fgv = pairs[i, 1];
                int y = i * rowH;
                int bh = (i == n - 1) ? (h - y) : rowH;
                using (SolidBrush bg = new SolidBrush(G(bgv))) g.FillRectangle(bg, 0, y, w, bh);
                int boxW = (int)(rowH * 0.8), boxH = (int)(rowH * 0.55);
                int x = Wrap(t * 960, w + boxW) - boxW;
                int by = y + (bh - boxH) / 2;
                using (SolidBrush bb = new SolidBrush(G(fgv))) g.FillRectangle(bb, x, by, boxW, boxH);
                string cap = "фон " + (int)Math.Round(bgv / 2.55) + " % -> блок " + (int)Math.Round(fgv / 2.55) + " %";
                using (SolidBrush tb = new SolidBrush(G(bgv > 128 ? 40 : 190))) g.DrawString(cap, f, tb, 8, y + 4);
            }
        }
    }

    public static void DrawOverlay(Graphics g, int w, int h, int page, int monIdx, int monCount, float alpha) {
        if (alpha <= 0.003f) return;
        float k = Math.Max(0.8f, Math.Min(2.5f, h / 1080f));
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.TextRenderingHint = TextRenderingHint.AntiAlias;
        int pad = (int)(20 * k), margin = (int)(24 * k);
        int pw = (int)Math.Min(w - 2 * margin, 860 * k);
        int tw = pw - 2 * pad - (int)(6 * k);
        using (Font fHead = F(13 * k, FontStyle.Regular))
        using (Font fTitle = F(26 * k, FontStyle.Bold))
        using (Font fBody = F(16 * k, FontStyle.Regular))
        using (Font fFoot = F(13 * k, FontStyle.Regular)) {
            string head = "Страница " + (page + 1) + " из " + Count + (monCount > 1 ? "   Монитор " + (monIdx + 1) + " из " + monCount : "");
            string body = Hints[page];
            string foot = "Пробел / стрелка вправо - дальше     стрелка влево - назад     H - показать подсказку     Esc - выйти";
            SizeF sh = g.MeasureString(head, fHead, tw), st = g.MeasureString(Titles[page], fTitle, tw);
            SizeF sb2 = g.MeasureString(body, fBody, tw), sf = g.MeasureString(foot, fFoot, tw);
            float gap = 8 * k;
            int ph = (int)(pad + sh.Height + st.Height + gap + sb2.Height + gap * 1.5f + sf.Height + pad);
            int px = margin, py = h - margin - ph;
            if (py < margin) py = margin;
            int a = (int)(alpha * 235);
            Rectangle rc = new Rectangle(px, py, pw, ph);
            using (SolidBrush bb = new SolidBrush(Color.FromArgb(a, DiagScreenTheme.Bg))) g.FillRectangle(bb, rc);
            using (Pen pn = new Pen(Color.FromArgb((int)(alpha * 255), DiagScreenTheme.LineHi), 1f)) g.DrawRectangle(pn, rc);
            using (SolidBrush ab = new SolidBrush(Color.FromArgb((int)(alpha * 255), DiagScreenTheme.Accent))) g.FillRectangle(ab, px, py, (int)(6 * k), ph);
            float x = px + pad + 6 * k, y = py + pad;
            int ia = (int)(alpha * 255);
            using (SolidBrush b1 = new SolidBrush(Color.FromArgb(ia, DiagScreenTheme.AccentText))) g.DrawString(head, fHead, b1, new RectangleF(x, y, tw, sh.Height));
            y += sh.Height;
            using (SolidBrush b2 = new SolidBrush(Color.FromArgb(ia, DiagScreenTheme.Ink))) g.DrawString(Titles[page], fTitle, b2, new RectangleF(x, y, tw, st.Height));
            y += st.Height + gap;
            using (SolidBrush b3 = new SolidBrush(Color.FromArgb(ia, DiagScreenTheme.Ink2))) g.DrawString(body, fBody, b3, new RectangleF(x, y, tw, sb2.Height));
            y += sb2.Height + gap * 1.5f;
            using (SolidBrush b4 = new SolidBrush(Color.FromArgb(ia, DiagScreenTheme.Ink3))) g.DrawString(foot, fFoot, b4, new RectangleF(x, y, tw, sf.Height));
        }
    }

    // для проверки внешнего вида без полноэкранного окна
    public static Bitmap RenderToBitmap(int w, int h, int page, double t, bool overlay) {
        Bitmap bmp = new Bitmap(w, h, PixelFormat.Format32bppRgb);
        using (Graphics g = Graphics.FromImage(bmp)) {
            Draw(g, w, h, page, t);
            if (overlay) DrawOverlay(g, w, h, page, 0, 2, 1f);
        }
        return bmp;
    }
}

public class DiagScreenForm : Form {
    [DllImport("dwmapi.dll")] static extern int DwmFlush();
    public DiagScreenResult Result = new DiagScreenResult();
    int page, maxPage, monIdx, monCount;
    Stopwatch pageSw = Stopwatch.StartNew(), animSw = Stopwatch.StartNew();
    System.Windows.Forms.Timer timer = new System.Windows.Forms.Timer();
    List<double> frames = new List<double>();
    long lastTick;
    float lastAlpha = -1f;
    bool hideSticky;
    double fps;
    bool cursorHidden;

    public DiagScreenForm(Rectangle bounds, int idx, int count) {
        monIdx = idx; monCount = count;
        AutoScaleMode = AutoScaleMode.None;
        FormBorderStyle = FormBorderStyle.None;
        StartPosition = FormStartPosition.Manual;
        Bounds = bounds;
        TopMost = true;
        ShowInTaskbar = false;
        BackColor = Color.Black;
        KeyPreview = true;
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer, true);
        timer.Tick += new EventHandler(OnTick);
        ShowPage(0);
    }

    void ShowPage(int p) {
        page = p;
        if (p > maxPage) maxPage = p;
        pageSw.Reset(); pageSw.Start();
        animSw.Reset(); animSw.Start();
        frames.Clear(); lastTick = 0; hideSticky = false; lastAlpha = -1f;
        timer.Stop();
        timer.Interval = DiagScreenPages.IsAnimated(p) ? 1 : 33;
        timer.Start();
        Invalidate();
    }

    float HintAlpha() {
        if (DiagScreenPages.IsSticky(page)) return hideSticky ? 0f : 1f;
        double e = pageSw.Elapsed.TotalSeconds;
        if (e < 5.0) return 1f;
        if (e < 6.5) return (float)(1.0 - (e - 5.0) / 1.5);
        return 0f;
    }

    void OnTick(object s, EventArgs e) {
        if (DiagScreenPages.IsAnimated(page)) {
            Invalidate(); Update();
            int hr = 1;
            try { hr = DwmFlush(); } catch (Exception) { hr = 1; }
            if (hr != 0) Thread.Sleep(10);
            long now = Stopwatch.GetTimestamp();
            if (lastTick != 0) {
                frames.Add((now - lastTick) * 1000.0 / Stopwatch.Frequency);
                if (frames.Count > 120) frames.RemoveAt(0);
                if (frames.Count >= 30) {
                    List<double> c = new List<double>(frames);
                    c.Sort();
                    double med = c[c.Count / 2];
                    if (med > 1) { fps = 1000.0 / med; if (page == 9 && frames.Count >= 60) Result.MeasuredHz = fps; }
                }
            }
            lastTick = now;
        } else {
            float a = HintAlpha();
            if (a != lastAlpha) Invalidate();
        }
    }

    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = e.Graphics;
        int w = ClientSize.Width, h = ClientSize.Height;
        DiagScreenPages.Draw(g, w, h, page, animSw.Elapsed.TotalSeconds);
        float a = HintAlpha();
        lastAlpha = a;
        DiagScreenPages.DrawOverlay(g, w, h, page, monIdx, monCount, a);
        if (DiagScreenPages.IsAnimated(page) && fps > 0) {
            float k = Math.Max(0.8f, Math.Min(2.5f, h / 1080f));
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.TextRenderingHint = TextRenderingHint.AntiAlias;
            string s = "Кадров/с: " + fps.ToString("0.0");
            using (Font f = DiagScreenPages.F(15 * k, FontStyle.Bold)) {
                SizeF sz = g.MeasureString(s, f);
                using (SolidBrush bb = new SolidBrush(Color.FromArgb(200, 14, 14, 16))) g.FillRectangle(bb, w - sz.Width - 20 * k, 8 * k, sz.Width + 12 * k, sz.Height + 4 * k);
                g.DrawString(s, f, Brushes.White, w - sz.Width - 14 * k, 10 * k);
            }
        }
    }

    protected override void OnKeyDown(KeyEventArgs e) {
        e.Handled = true; e.SuppressKeyPress = true;
        switch (e.KeyCode) {
            case Keys.Space: case Keys.Right: case Keys.Down: case Keys.PageDown: case Keys.Enter: Next(); break;
            case Keys.Left: case Keys.Up: case Keys.PageUp: case Keys.Back: if (page > 0) ShowPage(page - 1); break;
            case Keys.Escape: Result.Aborted = true; Close(); break;
            case Keys.H: case Keys.F1:
                if (DiagScreenPages.IsSticky(page) && HintAlpha() > 0) hideSticky = true;
                else { hideSticky = false; pageSw.Reset(); pageSw.Start(); }
                lastAlpha = -1f; Invalidate(); break;
            default: e.Handled = false; e.SuppressKeyPress = false; break;
        }
    }

    protected override void OnMouseDown(MouseEventArgs e) {
        if (e.Button == MouseButtons.Left) Next();
        else if (e.Button == MouseButtons.Right && page > 0) ShowPage(page - 1);
    }

    void Next() {
        if (page + 1 >= DiagScreenPages.Count) Close(); else ShowPage(page + 1);
    }

    protected override void OnShown(EventArgs e) {
        base.OnShown(e);
        Activate(); Focus();
        Cursor.Hide(); cursorHidden = true;
    }

    protected override void OnFormClosing(FormClosingEventArgs e) {
        timer.Stop();
        if (cursorHidden) { Cursor.Show(); cursorHidden = false; }
        Result.PagesSeen = maxPage + 1;
        base.OnFormClosing(e);
    }

    protected override void Dispose(bool disposing) {
        if (disposing) timer.Dispose();
        base.Dispose(disposing);
    }
}

public class DiagScreenAsk : Form {
    string[] qtext = new string[] {
        "Засветы: на чёрном экране есть светлые пятна по краям или углам, заметное сияние?",
        "Есть битые или застрявшие пиксели (точки не того цвета на однотонных экранах)?",
        "Серые экраны неравномерные: пятна, тёмные углы, оттенок, «грязный» экран?",
        "Полосы или ступеньки на градиентах?",
        "За движущимися блоками тянутся шлейфы или светлые и тёмные ореолы?",
        "Камера показала мерцание подсветки (ШИМ) - тёмные бегущие полосы?" };
    string[] ans = new string[6];
    Button[][] btn = new Button[6][];
    Button done, skip;
    public bool Skipped;
    static readonly string[] Codes = new string[] { "no", "yes", "unk" };
    static readonly string[] Names = new string[] { "Нет", "Да", "Не знаю" };

    public string Answer(int i) { return ans[i]; }

    public DiagScreenAsk(string title) {
        AutoScaleMode = AutoScaleMode.None;
        Font = new Font("Segoe UI", 10f);
        BackColor = DiagScreenTheme.Bg; ForeColor = DiagScreenTheme.Ink;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false; MinimizeBox = false; ShowIcon = false; ShowInTaskbar = false;
        StartPosition = FormStartPosition.CenterScreen; TopMost = true;
        Text = "Проверка экрана: ваши наблюдения";
        ClientSize = new Size(860, 96 + 6 * 58 + 84);
        Label head = new Label();
        head.Text = title; head.Font = new Font("Segoe UI", 15f, FontStyle.Bold);
        head.ForeColor = DiagScreenTheme.Ink; head.SetBounds(28, 18, 800, 30); Controls.Add(head);
        Label sub = new Label();
        sub.Text = "Ответьте по тому, что увидели в тесте. «Не знаю» - если не уверены или не проверяли.";
        sub.ForeColor = DiagScreenTheme.Ink3; sub.SetBounds(28, 52, 800, 22); Controls.Add(sub);
        for (int i = 0; i < 6; i++) {
            int y = 92 + i * 58;
            Panel line = new Panel(); line.BackColor = DiagScreenTheme.Line; line.SetBounds(28, y - 6, 804, 1); Controls.Add(line);
            Label q = new Label();
            q.Text = qtext[i]; q.ForeColor = DiagScreenTheme.Ink2; q.SetBounds(28, y, 520, 46); Controls.Add(q);
            btn[i] = new Button[3];
            for (int j = 0; j < 3; j++) {
                Button b = new Button();
                b.Text = Names[j]; b.SetBounds(572 + j * 86, y + 4, 80, 36);
                b.FlatStyle = FlatStyle.Flat; b.TabStop = false; b.Cursor = Cursors.Hand;
                b.Tag = new int[] { i, j };
                b.Click += new EventHandler(OnPick);
                Controls.Add(b); btn[i][j] = b;
            }
            Restyle(i);
        }
        done = new Button(); done.Text = "Готово"; done.SetBounds(860 - 28 - 160, 96 + 6 * 58 + 18, 160, 42);
        done.FlatStyle = FlatStyle.Flat; done.Enabled = false; done.Click += new EventHandler(OnDone); Controls.Add(done);
        skip = new Button(); skip.Text = "Пропустить вопросы"; skip.SetBounds(28, 96 + 6 * 58 + 18, 200, 42);
        skip.FlatStyle = FlatStyle.Flat; skip.Click += new EventHandler(OnSkip); Controls.Add(skip);
        StyleMain();
    }

    void StyleMain() {
        skip.BackColor = DiagScreenTheme.Soft; skip.ForeColor = DiagScreenTheme.Ink2;
        skip.FlatAppearance.BorderColor = DiagScreenTheme.LineHi;
        bool all = true;
        for (int i = 0; i < 6; i++) if (ans[i] == null) all = false;
        done.Enabled = all;
        done.BackColor = all ? DiagScreenTheme.Accent : DiagScreenTheme.Soft;
        done.ForeColor = all ? Color.White : DiagScreenTheme.Ink3;
        done.FlatAppearance.BorderColor = all ? DiagScreenTheme.Accent : DiagScreenTheme.Line;
    }

    void Restyle(int i) {
        for (int j = 0; j < 3; j++) {
            Button b = btn[i][j];
            bool sel = ans[i] == Codes[j];
            Color c = j == 0 ? DiagScreenTheme.Ok : (j == 1 ? DiagScreenTheme.Accent : DiagScreenTheme.LineHi);
            b.BackColor = sel ? c : DiagScreenTheme.Soft;
            b.ForeColor = sel ? (j == 0 ? Color.Black : Color.White) : DiagScreenTheme.Ink2;
            b.FlatAppearance.BorderColor = sel ? c : DiagScreenTheme.LineHi;
        }
    }

    void OnPick(object s, EventArgs e) {
        int[] t = (int[])((Button)s).Tag;
        ans[t[0]] = Codes[t[1]];
        Restyle(t[0]); StyleMain();
    }
    void OnDone(object s, EventArgs e) { DialogResult = DialogResult.OK; Close(); }
    void OnSkip(object s, EventArgs e) { Skipped = true; DialogResult = DialogResult.Cancel; Close(); }
    protected override void OnFormClosing(FormClosingEventArgs e) {
        if (DialogResult != DialogResult.OK) Skipped = true;
        base.OnFormClosing(e);
    }
}

public static class DiagScreenFull {
    public class Mon { public Rectangle Bounds; public bool Primary; public string Device; }

    [StructLayout(LayoutKind.Sequential)] struct RECT { public int l, t, r, b; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct MONITORINFOEX {
        public int cbSize; public RECT rcMonitor; public RECT rcWork; public uint dwFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string szDevice;
    }
    delegate bool MonitorEnumProc(IntPtr hMon, IntPtr hdc, ref RECT rc, IntPtr data);
    [DllImport("user32.dll")] static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonitorEnumProc cb, IntPtr data);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool GetMonitorInfo(IntPtr h, ref MONITORINFOEX mi);
    [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr ctx);
    [DllImport("kernel32.dll")] static extern uint SetThreadExecutionState(uint f);

    public static List<Mon> Monitors() {
        List<Mon> list = new List<Mon>();
        MonitorEnumProc cb = delegate(IntPtr hMon, IntPtr hdc, ref RECT rc, IntPtr data) {
            MONITORINFOEX mi = new MONITORINFOEX();
            mi.cbSize = Marshal.SizeOf(typeof(MONITORINFOEX));
            if (GetMonitorInfo(hMon, ref mi)) {
                Mon m = new Mon();
                m.Bounds = new Rectangle(mi.rcMonitor.l, mi.rcMonitor.t, mi.rcMonitor.r - mi.rcMonitor.l, mi.rcMonitor.b - mi.rcMonitor.t);
                m.Primary = (mi.dwFlags & 1) != 0;
                m.Device = mi.szDevice;
                list.Add(m);
            }
            return true;
        };
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, cb, IntPtr.Zero);
        GC.KeepAlive(cb);
        list.Sort(delegate(Mon a, Mon b) { if (a.Primary != b.Primary) return a.Primary ? -1 : 1; return a.Bounds.X.CompareTo(b.Bounds.X); });
        return list;
    }

    public static DiagScreenResult[] Run() {
        List<DiagScreenResult> results = new List<DiagScreenResult>();
        IntPtr oldCtx = IntPtr.Zero;
        try { oldCtx = SetThreadDpiAwarenessContext(new IntPtr(-4)); } catch (Exception) { oldCtx = IntPtr.Zero; }
        List<Mon> mons = null;
        try {
            SetThreadExecutionState(0x80000000u | 0x2u | 0x1u);
            mons = Monitors();
            for (int i = 0; i < mons.Count; i++) {
                DiagScreenForm f = new DiagScreenForm(mons[i].Bounds, i, mons.Count);
                f.Result.Width = mons[i].Bounds.Width; f.Result.Height = mons[i].Bounds.Height; f.Result.Primary = mons[i].Primary;
                f.Result.Monitor = "Монитор " + (i + 1) + " (" + mons[i].Device + ", " + mons[i].Bounds.Width + "x" + mons[i].Bounds.Height + (mons[i].Primary ? ", основной" : "") + ")";
                f.ShowDialog();
                DiagScreenResult r = f.Result;
                f.Dispose();
                results.Add(r);
                if (r.Aborted) break;
            }
        } finally {
            try { SetThreadExecutionState(0x80000000u); } catch (Exception) { }
            if (oldCtx != IntPtr.Zero) { try { SetThreadDpiAwarenessContext(oldCtx); } catch (Exception) { } }
        }
        foreach (DiagScreenResult r in results) {
            if (r.Aborted) continue;
            using (DiagScreenAsk q = new DiagScreenAsk(r.Monitor)) {
                q.ShowDialog();
                if (!q.Skipped) {
                    r.Light = q.Answer(0); r.Dead = q.Answer(1); r.Gray = q.Answer(2);
                    r.Banding = q.Answer(3); r.Ghost = q.Answer(4); r.Pwm = q.Answer(5);
                }
            }
        }
        return results.ToArray();
    }
}
'@
}

function Initialize-PcDiagScreen {
    if ('DiagScreenFull' -as [type]) { return $true }
    try {
        Add-Type -AssemblyName System.Windows.Forms, System.Drawing -ErrorAction Stop
        Add-Type -TypeDefinition (Get-PcDiagScreenSrc) -Language CSharp -ReferencedAssemblies System.Windows.Forms, System.Drawing -ErrorAction Stop
        return $true
    } catch { $G.Log.Add("screenfull: Add-Type: $($_.Exception.Message)"); return $false }
}
