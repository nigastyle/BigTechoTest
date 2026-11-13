using System.Drawing.Text;
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public class DiagInputForm : Form, IMessageFilter {
    Dictionary<int, Label> keys = new Dictionary<int, Label>();
    Dictionary<int, string> names = new Dictionary<int, string>();
    public HashSet<int> Pressed = new HashSet<int>();
    public HashSet<string> Buttons = new HashSet<string>();
    public int WheelUp, WheelDown, HWheel, Clicks;
    public double Distance;
    public string KeyboardVerdict = "skip";
    public string MouseVerdict = "skip";
    public string TouchpadVerdict = "skip";
    public string Comment = "";
    Label lblKb, lblMouse;
    TextBox tbComment;
    Panel pad;
    Point last = Point.Empty;
    const int U = 44;

    static readonly string[] Rows = new string[] {
        "27|Esc|1~0||1~112|F1|1~113|F2|1~114|F3|1~115|F4|1~0||0.5~116|F5|1~117|F6|1~118|F7|1~119|F8|1~0||0.5~120|F9|1~121|F10|1~122|F11|1~123|F12|1~0||0.25~44|PrtSc|1~145|ScrLk|1~19|Pause|1",
        "192|`|1~49|1|1~50|2|1~51|3|1~52|4|1~53|5|1~54|6|1~55|7|1~56|8|1~57|9|1~48|0|1~189|-|1~187|=|1~8|Backspace|2~0||0.25~45|Ins|1~36|Home|1~33|PgUp|1~0||0.25~144|Num|1~111|/|1~106|*|1~109|-|1",
        "9|Tab|1.5~81|Q|1~87|W|1~69|E|1~82|R|1~84|T|1~89|Y|1~85|U|1~73|I|1~79|O|1~80|P|1~219|[|1~221|]|1~220|\\|1.5~0||0.25~46|Del|1~35|End|1~34|PgDn|1~0||0.25~103|7|1~104|8|1~105|9|1~107|+|1",
        "20|Caps|1.75~65|A|1~83|S|1~68|D|1~70|F|1~71|G|1~72|H|1~74|J|1~75|K|1~76|L|1~186|;|1~222|'|1~13|Enter|2.25~0||3.5~100|4|1~101|5|1~102|6|1",
        "160|Shift|2.25~90|Z|1~88|X|1~67|C|1~86|V|1~66|B|1~78|N|1~77|M|1~188|,|1~190|.|1~191|/|1~161|Shift|2.75~0||1.25~38|↑|1~0||1.25~97|1|1~98|2|1~99|3|1~1013|Ent|1",
        "162|Ctrl|1.25~91|Win|1.25~164|Alt|1.25~32|Пробел|6.25~165|Alt|1.25~92|Win|1.25~93|Menu|1.25~163|Ctrl|1.25~0||0.25~37|←|1~40|↓|1~39|→|1~0||0.25~96|0|2~110|.|1"
    };

    static string KeyName(int vk, string label) {
        switch (vk) {
            case 160: return "Левый Shift";
            case 161: return "Правый Shift";
            case 162: return "Левый Ctrl";
            case 163: return "Правый Ctrl";
            case 164: return "Левый Alt";
            case 165: return "Правый Alt";
            case 91: return "Левый Win";
            case 92: return "Правый Win";
            case 1013: return "Num Enter";
            case 144: return "NumLock";
        }
        if (vk >= 96 && vk <= 111) return "Num " + label;
        return label;
    }

    public DiagInputForm(bool hasTouchpad) {
        Text = "Проверка клавиатуры, мыши и тачпада";
        StartPosition = FormStartPosition.CenterScreen;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = false;
        TopMost = true;
        KeyPreview = true;
        Font = new Font("Segoe UI", 9f);
        ClientSize = new Size(1030, 690);
        BackColor = Color.FromArgb(245, 246, 248);
        if (!hasTouchpad) TouchpadVerdict = "none";

        Label help = new Label();
        help.Text = "1) Нажмите по очереди все клавиши — они загорятся зелёным. Клавишу Fn программа не видит — это нормально.\n" +
                    "2) В белой области ниже кликните левой, правой и средней кнопкой мыши, покрутите колесо, сделайте двойной клик.\n" +
                    "3) Повторите то же тачпадом: движение курсора, тап, прокрутка двумя пальцами.\n" +
                    "4) Отметьте результат внизу и нажмите «Завершить».";
        help.SetBounds(12, 8, 1006, 66);
        Controls.Add(help);

        int top = 78;
        for (int r = 0; r < Rows.Length; r++) {
            double x = 0;
            int y = top + r * (U + 4) + (r > 0 ? 10 : 0);
            foreach (string tok in Rows[r].Split('~')) {
                string[] p = tok.Split('|');
                int vk = int.Parse(p[0], CultureInfo.InvariantCulture);
                double w = double.Parse(p[2], CultureInfo.InvariantCulture);
                if (vk != 0) {
                    Label k = new Label();
                    k.Text = p[1];
                    k.TextAlign = ContentAlignment.MiddleCenter;
                    k.BorderStyle = BorderStyle.FixedSingle;
                    k.BackColor = Color.White;
                    k.SetBounds(12 + (int)(x * U), y, (int)(w * U) - 4, U - 4);
                    Controls.Add(k);
                    keys[vk] = k;
                    names[vk] = KeyName(vk, p[1]);
                }
                x += w;
            }
        }

        lblKb = new Label();
        lblKb.SetBounds(12, 380, 1006, 20);
        lblKb.Font = new Font("Segoe UI", 9.5f, FontStyle.Bold);
        Controls.Add(lblKb);

        pad = new Panel();
        pad.BackColor = Color.White;
        pad.BorderStyle = BorderStyle.FixedSingle;
        pad.SetBounds(12, 405, 600, 170);
        pad.Cursor = Cursors.Cross;
        pad.Paint += delegate(object s, PaintEventArgs e) {
            e.Graphics.DrawString("Область проверки мыши и тачпада: кликайте, крутите колесо, водите курсором",
                Font, Brushes.Gray, 8, 8);
        };
        pad.MouseDown += delegate(object s, MouseEventArgs e) { Clicks++; Buttons.Add(e.Button.ToString()); UpdateMouse(); };
        pad.MouseDoubleClick += delegate(object s, MouseEventArgs e) { Buttons.Add("Double"); UpdateMouse(); };
        pad.MouseMove += delegate(object s, MouseEventArgs e) {
            if (last != Point.Empty) {
                double dx = e.X - last.X, dy = e.Y - last.Y;
                Distance += Math.Sqrt(dx * dx + dy * dy);
            }
            last = e.Location;
            UpdateMouse();
        };
        pad.MouseLeave += delegate { last = Point.Empty; };
        Controls.Add(pad);

        lblMouse = new Label();
        lblMouse.SetBounds(628, 405, 390, 170);
        lblMouse.Font = new Font("Segoe UI", 10f);
        Controls.Add(lblMouse);

        VerdictRow("Клавиатура:", 588, new string[] { "Всё работает", "Есть проблемы" }, new string[] { "ok", "bad" }, 0);
        VerdictRow("Мышь:", 620, new string[] { "Работает", "Есть проблемы", "Мыши нет" }, new string[] { "ok", "bad", "none" }, 1);
        VerdictRow("Тачпад:", 652, new string[] { "Работает", "Есть проблемы", "Тачпада нет" }, new string[] { "ok", "bad", "none" }, 2);

        Label lc = new Label();
        lc.Text = "Комментарий (необязательно):";
        lc.SetBounds(560, 586, 300, 18);
        Controls.Add(lc);
        tbComment = new TextBox();
        tbComment.Multiline = true;
        tbComment.SetBounds(560, 606, 300, 72);
        Controls.Add(tbComment);

        Button fin = new Button();
        fin.Text = "Завершить";
        fin.Font = new Font("Segoe UI", 10f, FontStyle.Bold);
        fin.SetBounds(876, 630, 142, 48);
        fin.Click += delegate { Comment = tbComment.Text; DialogResult = DialogResult.OK; Close(); };
        Controls.Add(fin);

        KeyUp += delegate(object s, KeyEventArgs e) { if (e.KeyCode == Keys.PrintScreen) MarkKey(44); };
    }

    void VerdictRow(string title, int y, string[] labels, string[] codes, int which) {
        Label l = new Label();
        l.Text = title;
        l.SetBounds(12, y + 5, 90, 20);
        Controls.Add(l);
        List<Button> group = new List<Button>();
        int x = 105;
        for (int i = 0; i < labels.Length; i++) {
            Button b = new Button();
            b.Text = labels[i];
            b.SetBounds(x, y, 140, 27);
            b.FlatStyle = FlatStyle.Flat;
            b.BackColor = Color.White;
            b.Tag = codes[i];
            x += 146;
            group.Add(b);
            Controls.Add(b);
            b.Click += delegate(object s, EventArgs e) {
                foreach (Button gb in group) gb.BackColor = Color.White;
                Button me = (Button)s;
                string code = (string)me.Tag;
                me.BackColor = code == "ok" ? Color.LightGreen : (code == "bad" ? Color.LightSalmon : Color.Gainsboro);
                if (which == 0) KeyboardVerdict = code;
                else if (which == 1) MouseVerdict = code;
                else TouchpadVerdict = code;
            };
        }
    }

    protected override void OnLoad(EventArgs e) {
        base.OnLoad(e);
        Application.AddMessageFilter(this);
        UpdateKb();
        UpdateMouse();
    }

    protected override void OnFormClosed(FormClosedEventArgs e) {
        Application.RemoveMessageFilter(this);
        Comment = tbComment.Text;
        base.OnFormClosed(e);
    }

    public bool PreFilterMessage(ref Message m) {
        if (m.Msg == 0x020A) {
            int delta = (short)((m.WParam.ToInt64() >> 16) & 0xFFFF);
            if (delta > 0) WheelUp++; else WheelDown++;
            UpdateMouse();
        } else if (m.Msg == 0x020E) {
            HWheel++;
            UpdateMouse();
        }
        return false;
    }

    protected override void WndProc(ref Message m) {
        // Не даём одиночному Alt/F10 уводить фокус в системное меню
        if (m.Msg == 0x0112 && (int)(m.WParam.ToInt64() & 0xFFF0) == 0xF100) return;
        base.WndProc(ref m);
    }

    protected override bool ProcessCmdKey(ref Message msg, Keys keyData) {
        if (msg.Msg == 0x100 || msg.Msg == 0x104) {
            int vk = ResolveVk((int)(msg.WParam.ToInt64() & 0xFFFF), msg.LParam.ToInt64());
            MarkKey(vk);
            if (tbComment != null && tbComment.Focused) return base.ProcessCmdKey(ref msg, keyData);
            return true;
        }
        return base.ProcessCmdKey(ref msg, keyData);
    }

    static int ResolveVk(int vk, long lp) {
        int sc = (int)((lp >> 16) & 0xFF);
        bool ext = ((lp >> 24) & 1) == 1;
        if (vk == 16) return sc == 0x36 ? 161 : 160;
        if (vk == 17) return ext ? 163 : 162;
        if (vk == 18) return ext ? 165 : 164;
        if (vk == 13) return ext ? 1013 : 13;
        return vk;
    }

    void MarkKey(int vk) {
        Pressed.Add(vk);
        Label l;
        if (keys.TryGetValue(vk, out l)) l.BackColor = Color.LightGreen;
        UpdateKb();
    }

    void UpdateKb() {
        if (lblKb == null) return;
        lblKb.Text = "Нажато клавиш: " + PressedKeys + " из " + keys.Count +
                     "   (если на ноутбуке нет цифрового блока, Num-клавиши можно пропустить)";
    }

    string Mark(string b) { return Buttons.Contains(b) ? "✔" : "—"; }

    void UpdateMouse() {
        if (lblMouse == null) return;
        lblMouse.Text =
            "Левая кнопка: " + Mark("Left") + "\n" +
            "Правая кнопка: " + Mark("Right") + "\n" +
            "Средняя кнопка (колесо): " + Mark("Middle") + "\n" +
            "Боковые кнопки: " + ((Buttons.Contains("XButton1") || Buttons.Contains("XButton2")) ? "✔" : "—") + "\n" +
            "Двойной клик: " + Mark("Double") + "\n" +
            "Прокрутка вверх / вниз: " + WheelUp + " / " + WheelDown + "\n" +
            "Горизонтальная прокрутка: " + HWheel + "\n" +
            "Пройдено курсором: " + (int)Distance + " px";
    }

    public int TotalKeys { get { return keys.Count; } }
    public int PressedKeys {
        get { int n = 0; foreach (int k in keys.Keys) if (Pressed.Contains(k)) n++; return n; }
    }
    public string Untested() {
        List<string> l = new List<string>();
        foreach (int k in keys.Keys) if (!Pressed.Contains(k)) l.Add(names[k]);
        return string.Join(", ", l.ToArray());
    }
    public string ButtonsText() {
        List<string> l = new List<string>();
        if (Buttons.Contains("Left")) l.Add("левая");
        if (Buttons.Contains("Right")) l.Add("правая");
        if (Buttons.Contains("Middle")) l.Add("средняя");
        if (Buttons.Contains("XButton1") || Buttons.Contains("XButton2")) l.Add("боковые");
        if (Buttons.Contains("Double")) l.Add("двойной клик");
        return l.Count == 0 ? "не нажимались" : string.Join(", ", l.ToArray());
    }
}

public static class DiagUi {
    static Form MakeOwner() {
        Form f = new Form();
        f.TopMost = true;
        f.ShowInTaskbar = false;
        f.StartPosition = FormStartPosition.Manual;
        f.Location = new Point(-3000, -3000);
        f.Size = new Size(1, 1);
        f.FormBorderStyle = FormBorderStyle.None;
        f.Show();
        f.Activate();
        return f;
    }

    public static string Ask(string text, string title, bool yesNo) {
        int r = DiagDialog.Run(null, title, text, yesNo ? new string[] { "Да", "Нет" } : new string[] { "OK", "Отмена" }, yesNo ? 0 : 1, 0, 1);
        return r == 0 ? "yes" : "no";
    }
    internal static Form Owner0() { return MakeOwner(); }

    public static string ScreenTest() {
        Color[] colors = new Color[] { Color.FromArgb(255, 0, 0), Color.FromArgb(0, 255, 0), Color.FromArgb(0, 0, 255),
                                       Color.White, Color.Black, Color.FromArgb(128, 128, 128) };
        Form f = new Form();
        f.FormBorderStyle = FormBorderStyle.None;
        f.WindowState = FormWindowState.Maximized;
        f.TopMost = true;
        f.ShowInTaskbar = false;
        f.KeyPreview = true;
        f.BackColor = colors[0];
        int idx = 0;
        bool skipped = false;
        Label hint = new Label();
        hint.AutoSize = true;
        hint.Font = new Font("Segoe UI", 14f);
        hint.ForeColor = Color.White;
        hint.BackColor = Color.FromArgb(40, 40, 40);
        hint.Location = new Point(20, 20);
        hint.Text = "Внимательно осмотрите весь экран на каждом цвете.\nКлик или пробел — следующий цвет (всего 6), Esc — прервать.";
        f.Controls.Add(hint);
        Action advance = delegate {
            hint.Visible = false;
            idx++;
            if (idx >= colors.Length) f.Close();
            else f.BackColor = colors[idx];
        };
        f.MouseClick += delegate { advance(); };
        hint.MouseClick += delegate { advance(); };
        f.KeyDown += delegate(object s, KeyEventArgs e) {
            if (e.KeyCode == Keys.Escape) { skipped = true; f.Close(); }
            else advance();
        };
        f.ShowDialog();
        f.Dispose();
        if (skipped) return "skip";
        return Ask("Заметили ли вы на каком-либо цвете битые пиксели (точки другого цвета), полосы, пятна или засветы?",
                   "Проверка экрана", true) == "yes" ? "bad" : "ok";
    }
}

// ======================================================================
// Фирменная палитра «Биг Техно Клаб» (тёмная тема сайта бигтехноклаб.рф).
// Те же значения продублированы в modules/lib-05-live.ps1 (LivePanel).
// ======================================================================
public static class DiagTheme {
    public static string AppName = "BigTechoTest";                 // название программы — меняется здесь
    public static string AppTagline = "диагностика ПК и ноутбуков";
    public static readonly Color Bg = Color.FromArgb(0x0e, 0x0e, 0x10);        // --bg
    public static readonly Color Panel = Color.FromArgb(0x17, 0x17, 0x1a);     // --panel-solid
    public static readonly Color Plate = Color.FromArgb(0x1a, 0x1a, 0x1d);     // --plate-b
    public static readonly Color PlateHi = Color.FromArgb(0x23, 0x23, 0x27);   // --plate-a
    public static readonly Color Soft = Color.FromArgb(0x21, 0x21, 0x25);      // --soft
    public static readonly Color Line = Color.FromArgb(0x29, 0x29, 0x2e);      // --hairline (12% белого)
    public static readonly Color LineHi = Color.FromArgb(0x3a, 0x3a, 0x40);
    public static readonly Color Accent = Color.FromArgb(0xdd, 0x0a, 0x0a);    // фирменный красный
    public static readonly Color AccentHi = Color.FromArgb(0xff, 0x3a, 0x28);  // --accent-grad (верх)
    public static readonly Color AccentLo = Color.FromArgb(0xc4, 0x08, 0x08);  // --accent-grad (низ)
    public static readonly Color AccentText = Color.FromArgb(0xff, 0x7a, 0x68);// --accent-text
    public static readonly Color AccentSoft = Color.FromArgb(0x3a, 0x16, 0x14);// --accent-soft
    public static readonly Color Ok = Color.FromArgb(0x45, 0xd1, 0x7a);        // --ok
    public static readonly Color Warn = Color.FromArgb(0xf0, 0xb2, 0x3c);      // --warn
    public static readonly Color Crit = Color.FromArgb(0xff, 0x4d, 0x4f);
    public static readonly Color Ink = Color.FromArgb(0xf4, 0xf4, 0xf5);       // --ink
    public static readonly Color Ink2 = Color.FromArgb(0xc2, 0xc2, 0xc6);      // --ink-2
    public static readonly Color Ink3 = Color.FromArgb(0x8e, 0x8e, 0x94);      // --ink-3
    public static readonly Color Ink4 = Color.FromArgb(0x6e, 0x6e, 0x74);      // --ink-4

    // Шрифты сайта (Manrope / Archivo) в Windows заменяем на Segoe UI / Bahnschrift
    public static Font MakeFont(string family, float size, FontStyle style, string fallback) {
        Font f = null;
        try { f = new Font(family, size, style); } catch (Exception) { f = null; }
        if (f == null || !string.Equals(f.Name, family, StringComparison.OrdinalIgnoreCase)) {
            if (f != null) f.Dispose();
            f = new Font(fallback, size, style);
        }
        return f;
    }
    public static Font Head(float size) { return MakeFont("Bahnschrift SemiBold", size, FontStyle.Regular, "Segoe UI Semibold"); }
    public static Font Body(float size) { return MakeFont("Segoe UI", size, FontStyle.Regular, "Tahoma"); }
    public static Font Semi(float size) { return MakeFont("Segoe UI Semibold", size, FontStyle.Regular, "Segoe UI"); }

    public static GraphicsPath Round(RectangleF r, float rad) {
        GraphicsPath p = new GraphicsPath();
        float d = Math.Min(rad * 2f, Math.Min(r.Width, r.Height));
        if (d < 1f) { p.AddRectangle(r); return p; }
        p.AddArc(r.X, r.Y, d, d, 180, 90);
        p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        p.CloseFigure();
        return p;
    }
    public static void Fill(Graphics g, RectangleF r, float rad, Color c) {
        using (GraphicsPath p = Round(r, rad)) using (SolidBrush b = new SolidBrush(c)) g.FillPath(b, p);
    }
    public static void Stroke(Graphics g, RectangleF r, float rad, Color c, float w) {
        using (GraphicsPath p = Round(r, rad)) using (Pen pen = new Pen(c, w)) g.DrawPath(pen, p);
    }
    public static void FillAccent(Graphics g, RectangleF r, float rad, bool hover) {
        using (GraphicsPath p = Round(r, rad))
        using (LinearGradientBrush b = new LinearGradientBrush(new RectangleF(r.X, r.Y - 1, r.Width, r.Height + 2),
                   hover ? Color.FromArgb(0xff, 0x55, 0x45) : AccentHi, hover ? Color.FromArgb(0xd8, 0x10, 0x10) : AccentLo, 90f))
            g.FillPath(b, p);
    }
    const TextFormatFlags Base = TextFormatFlags.NoPrefix | TextFormatFlags.NoPadding |
        TextFormatFlags.PreserveGraphicsTranslateTransform | TextFormatFlags.PreserveGraphicsClipping;
    public static void Text(Graphics g, string s, Font f, Rectangle r, Color c) {
        TextRenderer.DrawText(g, s, f, r, c, Base | TextFormatFlags.SingleLine | TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis);
    }
    public static void TextR(Graphics g, string s, Font f, Rectangle r, Color c) {
        TextRenderer.DrawText(g, s, f, r, c, Base | TextFormatFlags.SingleLine | TextFormatFlags.VerticalCenter | TextFormatFlags.Right | TextFormatFlags.EndEllipsis);
    }
    public static void TextC(Graphics g, string s, Font f, Rectangle r, Color c) {
        TextRenderer.DrawText(g, s, f, r, c, Base | TextFormatFlags.SingleLine | TextFormatFlags.VerticalCenter | TextFormatFlags.HorizontalCenter);
    }
    public static void Wrap(Graphics g, string s, Font f, Rectangle r, Color c) {
        TextRenderer.DrawText(g, s, f, r, c, Base | TextFormatFlags.WordBreak | TextFormatFlags.TextBoxControl);
    }
    public static int WrapH(Graphics g, string s, Font f, int w) {
        if (string.IsNullOrEmpty(s) || w < 10) return 0;
        return TextRenderer.MeasureText(g, s, f, new Size(w, 100000), Base | TextFormatFlags.WordBreak | TextFormatFlags.TextBoxControl).Height;
    }
    public static int TextW(Graphics g, string s, Font f) {
        return TextRenderer.MeasureText(g, s, f, new Size(100000, 1000), Base | TextFormatFlags.SingleLine).Width;
    }
}

// Небольшие векторные значки (рисуются пером в квадрате r)
static class DiagGlyph {
    public static void Draw(Graphics g, int kind, RectangleF r, Color c, float w) {
        SmoothingMode old = g.SmoothingMode;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        float x = r.X, y = r.Y, s = Math.Min(r.Width, r.Height);
        using (Pen p = new Pen(c, w)) {
            p.StartCap = LineCap.Round; p.EndCap = LineCap.Round; p.LineJoin = LineJoin.Round;
            switch (kind) {
                case 0: // режим: ползунки
                    for (int i = 0; i < 3; i++) {
                        float yy = y + s * (0.22f + 0.28f * i);
                        g.DrawLine(p, x + s * 0.1f, yy, x + s * 0.9f, yy);
                        float kx = x + s * (i == 1 ? 0.62f : (i == 0 ? 0.32f : 0.45f));
                        using (SolidBrush b = new SolidBrush(c)) g.FillEllipse(b, kx - s * 0.1f, yy - s * 0.1f, s * 0.2f, s * 0.2f);
                    }
                    break;
                case 1: // процессор
                    using (GraphicsPath gp = DiagTheme.Round(new RectangleF(x + s * 0.22f, y + s * 0.22f, s * 0.56f, s * 0.56f), s * 0.08f)) g.DrawPath(p, gp);
                    g.DrawRectangle(p, x + s * 0.38f, y + s * 0.38f, s * 0.24f, s * 0.24f);
                    for (int i = 0; i < 3; i++) {
                        float t = s * (0.34f + 0.16f * i);
                        g.DrawLine(p, x + t, y + s * 0.06f, x + t, y + s * 0.2f);
                        g.DrawLine(p, x + t, y + s * 0.8f, x + t, y + s * 0.94f);
                        g.DrawLine(p, x + s * 0.06f, y + t, x + s * 0.2f, y + t);
                        g.DrawLine(p, x + s * 0.8f, y + t, x + s * 0.94f, y + t);
                    }
                    break;
                case 2: // память
                    using (GraphicsPath gp = DiagTheme.Round(new RectangleF(x + s * 0.06f, y + s * 0.28f, s * 0.88f, s * 0.36f), s * 0.05f)) g.DrawPath(p, gp);
                    for (int i = 0; i < 4; i++) g.DrawRectangle(p, x + s * (0.16f + 0.19f * i), y + s * 0.38f, s * 0.1f, s * 0.14f);
                    for (int i = 0; i < 6; i++) g.DrawLine(p, x + s * (0.14f + 0.14f * i), y + s * 0.66f, x + s * (0.14f + 0.14f * i), y + s * 0.76f);
                    break;
                case 3: // видеокарта
                    using (GraphicsPath gp = DiagTheme.Round(new RectangleF(x + s * 0.06f, y + s * 0.24f, s * 0.88f, s * 0.48f), s * 0.06f)) g.DrawPath(p, gp);
                    g.DrawEllipse(p, x + s * 0.18f, y + s * 0.32f, s * 0.32f, s * 0.32f);
                    g.DrawEllipse(p, x + s * 0.3f, y + s * 0.44f, s * 0.08f, s * 0.08f);
                    g.DrawLine(p, x + s * 0.6f, y + s * 0.4f, x + s * 0.82f, y + s * 0.4f);
                    g.DrawLine(p, x + s * 0.6f, y + s * 0.54f, x + s * 0.82f, y + s * 0.54f);
                    g.DrawLine(p, x + s * 0.2f, y + s * 0.72f, x + s * 0.2f, y + s * 0.84f);
                    g.DrawLine(p, x + s * 0.2f, y + s * 0.84f, x + s * 0.56f, y + s * 0.84f);
                    break;
                case 4: // питание: молния
                    g.DrawPolygon(p, new PointF[] {
                        new PointF(x + s * 0.58f, y + s * 0.06f), new PointF(x + s * 0.2f, y + s * 0.56f), new PointF(x + s * 0.48f, y + s * 0.56f),
                        new PointF(x + s * 0.4f, y + s * 0.94f), new PointF(x + s * 0.8f, y + s * 0.42f), new PointF(x + s * 0.52f, y + s * 0.42f) });
                    break;
                case 5: // накопитель
                    using (GraphicsPath gp = DiagTheme.Round(new RectangleF(x + s * 0.1f, y + s * 0.14f, s * 0.8f, s * 0.72f), s * 0.08f)) g.DrawPath(p, gp);
                    g.DrawEllipse(p, x + s * 0.3f, y + s * 0.26f, s * 0.4f, s * 0.4f);
                    g.DrawLine(p, x + s * 0.5f, y + s * 0.46f, x + s * 0.7f, y + s * 0.72f);
                    break;
                case 6: // журналы: документ
                    g.DrawLines(p, new PointF[] { new PointF(x + s * 0.6f, y + s * 0.06f), new PointF(x + s * 0.2f, y + s * 0.06f),
                        new PointF(x + s * 0.2f, y + s * 0.94f), new PointF(x + s * 0.8f, y + s * 0.94f), new PointF(x + s * 0.8f, y + s * 0.26f),
                        new PointF(x + s * 0.6f, y + s * 0.06f), new PointF(x + s * 0.6f, y + s * 0.26f), new PointF(x + s * 0.8f, y + s * 0.26f) });
                    for (int i = 0; i < 3; i++) g.DrawLine(p, x + s * 0.32f, y + s * (0.46f + 0.15f * i), x + s * 0.68f, y + s * (0.46f + 0.15f * i));
                    break;
                case 7: // с участием: мышь
                    using (GraphicsPath gp = DiagTheme.Round(new RectangleF(x + s * 0.26f, y + s * 0.06f, s * 0.48f, s * 0.88f), s * 0.24f)) g.DrawPath(p, gp);
                    g.DrawLine(p, x + s * 0.5f, y + s * 0.18f, x + s * 0.5f, y + s * 0.34f);
                    g.DrawLine(p, x + s * 0.26f, y + s * 0.42f, x + s * 0.74f, y + s * 0.42f);
                    break;
                case 8: // обслуживание: шестерёнка
                    g.DrawEllipse(p, x + s * 0.26f, y + s * 0.26f, s * 0.48f, s * 0.48f);
                    g.DrawEllipse(p, x + s * 0.42f, y + s * 0.42f, s * 0.16f, s * 0.16f);
                    for (int i = 0; i < 8; i++) {
                        double a = Math.PI * i / 4.0;
                        g.DrawLine(p, x + s * 0.5f + (float)Math.Cos(a) * s * 0.26f, y + s * 0.5f + (float)Math.Sin(a) * s * 0.26f,
                                      x + s * 0.5f + (float)Math.Cos(a) * s * 0.42f, y + s * 0.5f + (float)Math.Sin(a) * s * 0.42f);
                    }
                    break;
                case 9: // безопасность: щит
                    using (GraphicsPath gp = new GraphicsPath()) {
                        gp.AddLine(x + s * 0.5f, y + s * 0.06f, x + s * 0.86f, y + s * 0.2f);
                        gp.AddBezier(x + s * 0.86f, y + s * 0.2f, x + s * 0.86f, y + s * 0.6f, x + s * 0.7f, y + s * 0.8f, x + s * 0.5f, y + s * 0.94f);
                        gp.AddBezier(x + s * 0.5f, y + s * 0.94f, x + s * 0.3f, y + s * 0.8f, x + s * 0.14f, y + s * 0.6f, x + s * 0.14f, y + s * 0.2f);
                        gp.CloseFigure();
                        g.DrawPath(p, gp);
                    }
                    g.DrawLines(p, new PointF[] { new PointF(x + s * 0.34f, y + s * 0.5f), new PointF(x + s * 0.46f, y + s * 0.62f), new PointF(x + s * 0.68f, y + s * 0.38f) });
                    break;
                case 10: // о программе
                    g.DrawEllipse(p, x + s * 0.08f, y + s * 0.08f, s * 0.84f, s * 0.84f);
                    g.DrawLine(p, x + s * 0.5f, y + s * 0.46f, x + s * 0.5f, y + s * 0.72f);
                    using (SolidBrush b = new SolidBrush(c)) g.FillEllipse(b, x + s * 0.44f, y + s * 0.26f, s * 0.12f, s * 0.12f);
                    break;
                case 11: // часы
                    g.DrawEllipse(p, x + s * 0.08f, y + s * 0.08f, s * 0.84f, s * 0.84f);
                    g.DrawLines(p, new PointF[] { new PointF(x + s * 0.5f, y + s * 0.26f), new PointF(x + s * 0.5f, y + s * 0.5f), new PointF(x + s * 0.68f, y + s * 0.62f) });
                    break;
                case 12: // галочка
                    g.DrawLines(p, new PointF[] { new PointF(x + s * 0.18f, y + s * 0.52f), new PointF(x + s * 0.42f, y + s * 0.74f), new PointF(x + s * 0.82f, y + s * 0.28f) });
                    break;
                case 13: // восклицательный знак
                    g.DrawLine(p, x + s * 0.5f, y + s * 0.2f, x + s * 0.5f, y + s * 0.58f);
                    using (SolidBrush b = new SolidBrush(c)) g.FillEllipse(b, x + s * 0.43f, y + s * 0.7f, s * 0.14f, s * 0.14f);
                    break;
                case 14: // слои (полная)
                    for (int i = 2; i >= 0; i--) {
                        float yy = y + s * (0.2f + 0.2f * i);
                        g.DrawPolygon(p, new PointF[] { new PointF(x + s * 0.5f, yy), new PointF(x + s * 0.92f, yy + s * 0.16f),
                            new PointF(x + s * 0.5f, yy + s * 0.32f), new PointF(x + s * 0.08f, yy + s * 0.16f) });
                    }
                    break;
                case 16: // инструменты: флешка
                    using (GraphicsPath gp = DiagTheme.Round(new RectangleF(x + s * 0.3f, y + s * 0.34f, s * 0.4f, s * 0.6f), s * 0.07f)) g.DrawPath(p, gp);
                    g.DrawRectangle(p, x + s * 0.37f, y + s * 0.08f, s * 0.26f, s * 0.26f);
                    g.DrawLine(p, x + s * 0.45f, y + s * 0.17f, x + s * 0.45f, y + s * 0.2f);
                    g.DrawLine(p, x + s * 0.55f, y + s * 0.17f, x + s * 0.55f, y + s * 0.2f);
                    break;
                case 17: // булавка (поверх всех окон)
                    g.DrawLines(p, new PointF[] { new PointF(x + s * 0.36f, y + s * 0.1f), new PointF(x + s * 0.64f, y + s * 0.1f) });
                    g.DrawLines(p, new PointF[] { new PointF(x + s * 0.42f, y + s * 0.1f), new PointF(x + s * 0.4f, y + s * 0.42f), new PointF(x + s * 0.24f, y + s * 0.6f),
                        new PointF(x + s * 0.76f, y + s * 0.6f), new PointF(x + s * 0.6f, y + s * 0.42f), new PointF(x + s * 0.58f, y + s * 0.1f) });
                    g.DrawLine(p, x + s * 0.5f, y + s * 0.6f, x + s * 0.5f, y + s * 0.94f);
                    break;
                case 18: // вопрос
                    g.DrawEllipse(p, x + s * 0.08f, y + s * 0.08f, s * 0.84f, s * 0.84f);
                    g.DrawArc(p, x + s * 0.38f, y + s * 0.24f, s * 0.24f, s * 0.22f, 180, 250);
                    g.DrawLine(p, x + s * 0.52f, y + s * 0.47f, x + s * 0.5f, y + s * 0.56f);
                    using (SolidBrush b = new SolidBrush(c)) g.FillEllipse(b, x + s * 0.45f, y + s * 0.66f, s * 0.1f, s * 0.1f);
                    break;
                case 19: // папка
                    g.DrawLines(p, new PointF[] { new PointF(x + s * 0.08f, y + s * 0.8f), new PointF(x + s * 0.08f, y + s * 0.2f), new PointF(x + s * 0.38f, y + s * 0.2f),
                        new PointF(x + s * 0.46f, y + s * 0.3f), new PointF(x + s * 0.92f, y + s * 0.3f), new PointF(x + s * 0.92f, y + s * 0.8f), new PointF(x + s * 0.08f, y + s * 0.8f) });
                    break;
                case 15: // пульс
                    g.DrawLines(p, new PointF[] { new PointF(x + s * 0.04f, y + s * 0.56f), new PointF(x + s * 0.3f, y + s * 0.56f),
                        new PointF(x + s * 0.4f, y + s * 0.24f), new PointF(x + s * 0.54f, y + s * 0.82f), new PointF(x + s * 0.64f, y + s * 0.44f),
                        new PointF(x + s * 0.72f, y + s * 0.56f), new PointF(x + s * 0.96f, y + s * 0.56f) });
                    break;
            }
        }
        g.SmoothingMode = old;
    }

    // Логотип программы (как иконка BigTechoTest.exe): красная скруглённая плашка, «BTT», линия пульса
    public static void Logo(Graphics g, RectangleF r) {
        SmoothingMode old = g.SmoothingMode; TextRenderingHint oth = g.TextRenderingHint;
        g.SmoothingMode = SmoothingMode.AntiAlias; g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
        DiagTheme.FillAccent(g, r, r.Width * 0.22f, false);
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
}

// Стартовое окно: быстрая / полная диагностика или выбор отдельных тестов.
// Возвращает "key=value;key=value..." или "cancel".
public class DiagChooser : Form {
    public static string Version = "";       // body.ps1: [DiagChooser]::Version = $VER
    public static Icon AppIcon;              // body.ps1: иконка из BigTechoTest.exe (заголовок окна и панель задач)
    public static string[] HistoryItems;   // body.ps1: "дата|оценка|режим|путь_или_url|источник(local/server)"
    public static string MachineInfo = "";   // body.ps1: [DiagChooser]::MachineInfo = 'Производитель Модель · CPU · RAM'
    public static string Brand = "BIG TECHNO CLUB";
    public static bool RequireAccept = true;  // body.ps1 в авто-режиме окно не показывает; можно выключить: [DiagChooser]::RequireAccept = $false
    public static string[] Complaints;       // body.ps1: жалобы из $G.Complaints — "ключ|Название|тест=1,тест=20"
    public static string ReportsDir = "";    // body.ps1: папка с копиями отчётов (<папка программы>\reports)
    const string RegKey = "Software\\BigTechoTest";

    // Приняты ли условия на этом компьютере (HKCU\Software\BigTechoTest, Accepted=1)
    public static bool IsAccepted() {
        try {
            using (Microsoft.Win32.RegistryKey rk = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(RegKey)) {
                if (rk == null) return false;
                object v = rk.GetValue("Accepted");
                return v != null && Convert.ToString(v, CultureInfo.InvariantCulture) == "1";
            }
        } catch (Exception) { return false; }
    }
    public static void SaveAccepted() {
        try {
            using (Microsoft.Win32.RegistryKey rk = Microsoft.Win32.Registry.CurrentUser.CreateSubKey(RegKey)) {
                if (rk != null) rk.SetValue("Accepted", 1, Microsoft.Win32.RegistryValueKind.DWord);
            }
        } catch (Exception) { }
    }

    internal class Opt {
        public string Key, Title, Desc, Badge, TimeText, ComboKey;
        public int Cat;
        public bool On, Locked, Enabled = true, NotTest;
        public double Minutes;
        public string[] Labels, Values;
        public double[] ComboMin;
        public int Idx;
        public bool BadgeWarn;
        public double Est() { return Minutes + (ComboMin != null ? ComboMin[Idx] : 0); }
    }

    internal readonly List<Opt> opts = new List<Opt>();
    internal int mode;            // 0 быстрая, 1 полная, 2 выборочная, 3 по жалобе
    internal readonly HashSet<string> complaintSel = new HashSet<string>();
    internal float dpiK = 1f, uiScale = 1f;
    internal bool pinned;
    internal ToolTip tips;
    internal int tab;
    internal int sub;             // подраздел «О программе»
    internal bool accepted = true, needAccept;
    internal readonly bool isLaptop, hasPawn;
    internal float k = 1f;
    public string Result = "cancel";

    internal static readonly string[] TabNames = { "Режим", "Процессор", "Память", "Видеокарта", "Питание", "Накопители",
        "Система и журналы", "С вашим участием", "Обслуживание", "История проверок", "Безопасность", "О программе", "Инструменты" };
    // порядок в меню слева: тесты, затем «СЕРВИС» (инструменты, история), затем «СПРАВКА»
    internal static readonly int[] NavOrder = { 0, 1, 2, 3, 4, 5, 6, 7, 8, 12, 9, 10, 11 };
    public const int TabTools = 12, TabHistory = 9;
    internal static readonly string[] SubNames = { "Обзор", "Как читать отчёт", "Правила использования", "Конфиденциальность", "Программы и лицензии", "Благодарности" };
    public const int SubRules = 2;
    public static int TabCount { get { return TabNames.Length; } }

    internal Font fTitle, fH2, fH3, fBody, fSmall, fSemi, fSemiS, fBtn, fCap, fBrand, fBig;
    readonly DcHeader header;
    readonly DcNav nav;
    readonly DcPage page;
    readonly DcBottom bottom;

    [DllImport("dwmapi.dll")]
    static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int val, int size);

    public DiagChooser(bool isLaptop, bool hasPawn) {
        if (AppIcon != null) { Icon = AppIcon; ShowIcon = true; }
        this.isLaptop = isLaptop;
        this.hasPawn = hasPawn;
        Text = DiagTheme.AppName + " — " + DiagTheme.AppTagline;
        AutoScaleMode = AutoScaleMode.Dpi;
        Font = DiagTheme.Body(9f);
        BackColor = DiagTheme.Bg;
        ForeColor = DiagTheme.Ink;
        StartPosition = FormStartPosition.CenterScreen;
        FormBorderStyle = FormBorderStyle.Sizable;
        MinimizeBox = false;
        TopMost = true;
        KeyPreview = true;
        DoubleBuffered = true;
        try { using (Graphics g = CreateGraphics()) dpiK = g.DpiX / 96f; } catch (Exception) { }
        if (dpiK < 1f) dpiK = 1f;
        uiScale = DiagWinCfg.GetF("Chooser.Scale", 1f, 0.8f, 1.5f);
        k = dpiK * uiScale;
        MakeFonts();
        tips = new ToolTip(); tips.InitialDelay = 400; tips.ReshowDelay = 100; tips.AutoPopDelay = 8000;

        BuildOptions();

        page = new DcPage(this); page.Dock = DockStyle.Fill;
        nav = new DcNav(this); nav.Dock = DockStyle.Left; nav.Width = S(236);
        bottom = new DcBottom(this); bottom.Dock = DockStyle.Bottom; bottom.Height = S(84);
        header = new DcHeader(this); header.Dock = DockStyle.Top; header.Height = S(72);
        Controls.Add(page); Controls.Add(nav); Controls.Add(bottom); Controls.Add(header);

        Rectangle wa = Screen.PrimaryScreen.WorkingArea;
        int w = Math.Min((int)(1120 * dpiK), wa.Width), h = Math.Min((int)(740 * dpiK), wa.Height);
        MinimumSize = new Size(Math.Min((int)(900 * dpiK), wa.Width), Math.Min((int)(600 * dpiK), wa.Height));
        Size = new Size(w, h);
        Rectangle saved;
        if (DiagWinCfg.GetRect("Chooser.Bounds", MinimumSize, out saved)) {
            StartPosition = FormStartPosition.Manual;
            Bounds = saved;
            if (DiagWinCfg.Get("Chooser.Max", "0") == "1") WindowState = FormWindowState.Maximized;
        }
        pinned = DiagWinCfg.Get("Chooser.Pin", "0") == "1";

        ApplyPreset(false);
        mode = 0;
        if (RequireAccept && !IsAccepted()) { accepted = false; needAccept = true; tab = 11; sub = SubRules; }
        Shown += delegate { Activate(); TopMost = pinned; page.Focus(); };
    }

    internal int S(double v) { return (int)Math.Round(v * k); }

    void MakeFonts() {
        float u = uiScale;
        fTitle = DiagTheme.Head(19f * u);
        fH2 = DiagTheme.Head(14f * u);
        fH3 = DiagTheme.Head(11.5f * u);
        fBig = DiagTheme.Head(17f * u);
        fBrand = DiagTheme.Head(10f * u);
        fBody = DiagTheme.Body(9.5f * u);
        fSmall = DiagTheme.Body(8.5f * u);
        fSemi = DiagTheme.Semi(10.5f * u);
        fSemiS = DiagTheme.Semi(9f * u);
        fBtn = DiagTheme.Semi(11f * u);
        fCap = DiagTheme.Semi(7.5f * u);
    }

    // масштаб интерфейса: Ctrl+колесо, Ctrl +/−/0, кнопки в шапке
    internal void SetScale(float s) {
        s = (float)Math.Round(Math.Max(0.8f, Math.Min(1.5f, s)) * 10f) / 10f;
        if (Math.Abs(s - uiScale) < 0.01f) return;
        uiScale = s; k = dpiK * uiScale;
        MakeFonts();
        SuspendLayout();
        nav.Width = S(236); bottom.Height = S(84); header.Height = S(72);
        ResumeLayout(true);
        page.Rebuild(false);
        Changed(); header.Invalidate();
        DiagWinCfg.SetF("Chooser.Scale", uiScale);
    }
    internal void ScaleStep(int dir) { SetScale(dir == 0 ? 1f : uiScale + 0.1f * dir); }

    internal void TogglePin() {
        pinned = !pinned; TopMost = pinned;
        DiagWinCfg.Set("Chooser.Pin", pinned ? "1" : "0");
        header.Invalidate();
    }

    internal void ShowHelp() {
        DiagHelpForm.ShowFor(this, Bounds, "Горячие клавиши", new string[][] {
            new string[] { "Enter", "начать диагностику" },
            new string[] { "Esc", "отмена и выход" },
            new string[] { "Ctrl+Tab / Ctrl+Shift+Tab", "следующий / предыдущий раздел" },
            new string[] { "Ctrl+колесо / Ctrl + / Ctrl −", "крупнее / мельче" },
            new string[] { "Ctrl+0", "обычный масштаб" },
            new string[] { "Ctrl+T", "поверх всех окон" },
            new string[] { "↑ ↓ / PgUp PgDn", "прокрутка страницы" },
            new string[] { "F1", "эта справка" } });
    }

    protected override void OnFormClosing(FormClosingEventArgs e) {
        try {
            DiagWinCfg.Set("Chooser.Max", WindowState == FormWindowState.Maximized ? "1" : "0");
            DiagWinCfg.SetRect("Chooser.Bounds", WindowState == FormWindowState.Normal ? Bounds : RestoreBounds);
        } catch (Exception) { }
        base.OnFormClosing(e);
    }

    protected override void OnHandleCreated(EventArgs e) {
        base.OnHandleCreated(e);
        try {
            int one = 1;
            if (DwmSetWindowAttribute(Handle, 20, ref one, 4) != 0) DwmSetWindowAttribute(Handle, 19, ref one, 4);
        } catch (Exception) { }
    }

    // ------------------------------------------------------------ данные
    Opt Add(int cat, string key, string title, string desc, double minutes) {
        Opt o = new Opt(); o.Cat = cat; o.Key = key; o.Title = title; o.Desc = desc; o.Minutes = minutes;
        opts.Add(o);
        return o;
    }
    Opt AddC(int cat, string key, string title, string desc, double minutes, string comboKey, string[] labels, string[] values, double[] cmin) {
        Opt o = Add(cat, key, title, desc, minutes);
        o.ComboKey = comboKey; o.Labels = labels; o.Values = values; o.ComboMin = cmin;
        return o;
    }

    void BuildOptions() {
        // 1 Процессор
        AddC(1, "cpu", "Бенчмарк и стресс-тест процессора",
            "Ловит перегрев, троттлинг и слабое охлаждение; заодно проверяет, как разгоняются вентиляторы под нагрузкой.",
            1.5, "cpusec", new string[] { "90 с", "5 мин", "10 мин", "30 мин" }, new string[] { "90", "300", "600", "1800" }, new double[] { 1.5, 5, 10, 30 });
        AddC(1, "prime", "Prime95",
            "Ловит нестабильность и перегрев процессора: ошибки вычислений, зависания, вылеты.",
            0, "primemin", new string[] { "3 мин", "10 мин", "30 мин", "60 мин" }, new string[] { "3", "10", "30", "60" }, new double[] { 3, 10, 30, 60 });
        AddC(1, "ycr", "y-cruncher (вычисление π)",
            "Ловит ошибки процессора и контроллера памяти под тяжёлой нагрузкой — результат сверяется с эталоном.",
            1, "ycrmin", new string[] { "2 мин", "10 мин", "30 мин" }, new string[] { "2", "10", "30" }, new double[] { 2, 10, 30 });
        AddC(1, "linpack", "Intel MKL Linpack",
            "Максимальный нагрев: ловит перегрев, слабое питание процессора (VRM) и неверные результаты расчётов.",
            0.5, "linpackmin", new string[] { "3 мин", "10 мин", "30 мин" }, new string[] { "3", "10", "30" }, new double[] { 3, 10, 30 });
        Add(1, "coolcurve", "Кривая нагрева и остывания",
            "Ловит деградацию охлаждения: засохшую термопасту, забитый пылью радиатор, медленную реакцию вентилятора.", 4);
        // 2 Память
        AddC(2, "ram", "Быстрый тест оперативной памяти",
            "Ловит битые ячейки ОЗУ — частую причину синих экранов и «случайных» вылетов программ.",
            0, "ramfull", new string[] { "4 ГБ (быстро)", "почти вся свободная" }, new string[] { "0", "1" }, new double[] { 0.5, 4 });
        AddC(2, "tm5", "TestMem5 (глубокий тест)",
            "Ловит редкие, плавающие ошибки памяти и нестабильный разгон XMP / EXPO.",
            0.5, "tm5min", new string[] { "10 мин", "20 мин", "60 мин" }, new string[] { "10", "20", "60" }, new double[] { 10, 20, 60 }).Idx = 1;
        Opt md = Add(2, "memdiag", "Полная проверка памяти при перезагрузке",
            "Средство проверки памяти Windows вне системы — ловит то, что не видно из-под Windows.", 0);
        md.Badge = "перезагрузка"; md.BadgeWarn = true; md.TimeText = "после отчёта";
        // 3 Видеокарта
        AddC(3, "gpu", "Стресс-тест видеокарты (FurMark 2)",
            "Ловит перегрев, артефакты, отвалы чипа, троттлинг и сбои видеодрайвера под нагрузкой.",
            0.5, "gpusec", new string[] { "1 мин", "5 мин", "15 мин", "30 мин" }, new string[] { "60", "300", "900", "1800" }, new double[] { 1, 5, 15, 30 });
        Add(3, "vram", "Тест видеопамяти (memtest_vulkan)",
            "Ловит ошибки видеопамяти — причину артефактов, полос на экране и вылетов игр.", 6);
        AddC(3, "gpustab", "Стабильность видеокарты (Vulkan, долгий)",
            "Ловит то, что не видно за минуту: сбои драйвера, просадки частоты, дребезг лимита мощности, медленный прогрев.",
            0.5, "gpustabmin", new string[] { "10 мин", "20 мин", "60 мин" }, new string[] { "10", "20", "60" }, new double[] { 10, 20, 60 }).Idx = 1;
        Add(3, "frametime", "Фризы и статтеры (frametime)",
            "Ловит рывки и подвисания кадров под ровной нагрузкой — признак проблем с драйверами, задержками DPC или охлаждением.", 1.5);
        // 4 Питание
        Opt psu = AddC(4, "psu", "Блок питания: CPU + GPU одновременно",
            "Максимальная совместная нагрузка — ловит просадки напряжений, перезагрузки и выключения под нагрузкой.",
            0.5, "psumin", new string[] { "2 мин", "10 мин", "30 мин" }, new string[] { "2", "10", "30" }, new double[] { 2, 10, 30 });
        if (isLaptop) { psu.Badge = "ноутбук — осторожно"; psu.BadgeWarn = true; }
        Opt bd = AddC(4, "batdrain", "Аккумулятор: тест разряда под нагрузкой",
            "Ловит изношенную батарею и сбитую калибровку: реальная автономность против заявленной. Понадобится отключить зарядку.",
            1, "batmin", new string[] { "5 мин", "10 мин", "20 мин" }, new string[] { "5", "10", "20" }, new double[] { 5, 10, 20 });
        bd.Idx = 1;
        if (!isLaptop) { bd.Enabled = false; bd.Badge = "только ноутбук"; } else bd.Badge = "с участием";
        // 5 Накопители
        Add(5, "disk", "Скорость чтения и записи (DiskSpd)",
            "Ловит медленные и деградирующие диски, неверный режим работы (SATA II, PCIe x1).", 1.5);
        AddC(5, "surface", "Поверхность диска (только чтение)",
            "Ловит медленные и нечитаемые участки — первые признаки умирающего диска.",
            0, "surfacemin", new string[] { "3 мин", "10 мин", "20 мин", "60 мин" }, new string[] { "3", "10", "20", "60" }, new double[] { 3, 10, 20, 60 });
        Add(5, "selftest", "Самотест SMART (короткий)",
            "Диск сам проверяет свою механику и электронику — ловит скрытые аппаратные неисправности.", 2.5);
        Opt ff = Add(5, "fakeflash", "Поддельный объём флешки",
            "Ловит флешки и карты памяти с фальшивым объёмом (как H2testw): записывает и сверяет данные. Только съёмные USB-накопители, чужие файлы не трогаются.", 10);
        ff.Badge = "вставьте флешку";
        // 6 Система и журналы
        Opt info = Add(6, "info", "Сведения о компьютере",
            "Процессор, плата, BIOS, память, диски и SMART, видеокарта, батарея — основа отчёта.", 1);
        info.On = true; info.Locked = true; info.Badge = "всегда";
        Add(6, "programs", "Программы и автозагрузка",
            "Ловит лишнее в автозапуске, тормозящий и подозрительный софт.", 0.2);
        Add(6, "logs", "Журналы ошибок за 30 дней",
            "Синие экраны (дампы BSOD), сбои видеодрайвера, скорость загрузки, ошибки дисков, задержки DPC.", 0.2);
        Add(6, "net", "Сеть и интернет",
            "Адаптеры, Wi-Fi, пинг и скорость интернета (Speedtest by Ookla) — ловит обрывы и низкую скорость.", 0.7);
        Add(6, "usb", "USB-порты",
            "Ловит порты, работающие как USB 2.0 вместо 3.x, перегруженные хабы и медленные флешки.", 0.5);
        Add(6, "used", "Проверка Б/У перед покупкой",
            "Ловит следы износа и «скрученный» пробег: наработку дисков, циклы батареи, переустановку Windows, замену комплектующих.", 0.5);
        // 7 С вашим участием
        Add(7, "kbd", isLaptop ? "Клавиатура, мышь и тачпад" : "Клавиатура и мышь",
            "Каждая клавиша, кнопки мыши, колесо" + (isLaptop ? ", жесты тачпада" : "") + " — ловит залипшие и мёртвые клавиши.", 1.5);
        Add(7, "screen", "Экран", "Заливка цветами — ловит битые пиксели, полосы, пятна и засветы.", 0.5);
        Add(7, "sound", "Динамики", "Звук по очереди слева и справа — ловит хрип и неработающий канал.", 0.5);
        Add(7, "mic", "Микрофон", "Запись и воспроизведение — ловит тихий, шумящий или отключённый микрофон.", 0.5);
        Add(7, "cam", "Веб-камера", "Показывает изображение с камеры — ловит неработающую или тёмную камеру.", 0.5);
        Add(7, "audioloop", "Динамики через микрофон", "Программа сама слушает свой сигнал микрофоном — ловит хрип, искажения и молчащий динамик.", 0.5);
        Add(7, "screenfull", "Полный тест экрана", "Цвета, градиенты, засветы, шлейфы на каждом мониторе — ловит битые пиксели, полосы, banding и мерцание ШИМ.", 3);
        Add(7, "periph", "Периферия: клавиатура, мышь, геймпад", "Сколько клавиш нажимается одновременно, частота опроса и двойные клики мыши, дрифт стиков геймпада.", 3);
        // 8 Обслуживание
        Add(8, "sys", "Целостность Windows и WinSAT",
            "DISM, SFC и CHKDSK — ловят повреждённые системные файлы и ошибки файловой системы; WinSAT — оценка.", 30);
        Add(8, "av", "Проверка на вирусы (Defender, быстрая)", "Ловит вирусы, майнеры и рекламные программы.", 6);
        Add(8, "kvrt", "Глубокая проверка Kaspersky (KVRT)", "Ловит вирусы и руткиты, пропущенные Defender. Скачивает 100+ МБ, проверка долгая.", 20);
        Add(8, "drivers", "Установить / обновить драйверы", "Находит устройства без драйверов и устаревшие драйверы.", 10);
        Opt fw = Add(8, "firmware", "…и прошивки BIOS", "Только если их предложит Windows Update; доступно вместе с драйверами.", 0);
        fw.TimeText = "—";
        Opt sd = Add(8, "sdio", "…и Snappy Driver Installer", "Дополнительный поиск драйверов по драйверпакам (скачивает несколько ГБ). Доступно вместе с драйверами.", 15);
        sd.Badge = "долго";
        if (!hasPawn) Add(8, "pawn", "Драйвер датчиков PawnIO", "Нужен, чтобы видеть температуру процессора. Ставится один раз.", 0.1);
        // 9 Безопасность (настройка, не тест)
        Opt nh = Add(9, "nohwinfo", "Не запускать HWiNFO",
            "ТемпературныйНюхач будет следить только по LibreHardwareMonitor. Включайте, если HWiNFO на этом ПК зависает или конфликтует.", 0);
        nh.NotTest = true; nh.TimeText = "";
        // 12 Инструменты
        Opt rm = Add(TabTools, "remote", "Удалённая диагностика: включить",
            "Мастер видит ход проверки вживую по ссылке: этапы, датчики, найденные проблемы. Нужен интернет.", 0);
        rm.NotTest = true; rm.TimeText = "";
    }

    internal Opt Find(string key) { foreach (Opt o in opts) if (o.Key == key) return o; return null; }
    void Set(string key, bool on) { Opt o = Find(key); if (o != null && o.Enabled && !o.Locked) o.On = on; }
    void SetCombo(string key, int idx) { Opt o = Find(key); if (o != null && o.Labels != null) o.Idx = idx; }

    void ApplyPreset(bool full) {
        string[] all = { "programs", "logs", "net", "kbd", "screen", "sound", "mic", "cam", "cpu", "prime", "ycr", "linpack", "gpu", "psu",
                         "ram", "disk", "surface", "selftest", "av", "drivers", "pawn", "usb", "audioloop" };
        foreach (Opt o in opts) if (!o.Locked && !o.NotTest) o.On = false;
        Fix();
        foreach (string key in all) Set(key, true);
        Set("sys", full); Set("vram", full); Set("tm5", full);
        Set("gpustab", full); Set("frametime", full); Set("screenfull", full); Set("periph", full); Set("coolcurve", full);
        Set("batdrain", full && isLaptop);
        SetCombo("gpustab", 1); SetCombo("batdrain", 1);
        SetCombo("cpu", full ? 1 : 0); SetCombo("gpu", full ? 1 : 0); SetCombo("ram", full ? 1 : 0); SetCombo("prime", full ? 1 : 0);
        SetCombo("ycr", full ? 1 : 0); SetCombo("psu", full ? 1 : 0); SetCombo("surface", full ? 2 : 0); SetCombo("linpack", full ? 1 : 0);
        SetCombo("tm5", 1);
        Fix();
    }

    // зависимости: прошивки — только вместе с драйверами
    void Fix() {
        Opt fw = Find("firmware"), dr = Find("drivers");
        if (fw != null && dr != null) { fw.Enabled = dr.On; if (!dr.On) fw.On = false; }
        Opt sd = Find("sdio");
        if (sd != null && dr != null) { sd.Enabled = dr.On; if (!dr.On) sd.On = false; }
    }

    // ---- режим «По жалобе»: быстрый набор + тесты, которые подбирает выбранная жалоба
    internal static string[] ComplaintParts(string raw) {
        string[] f = (raw ?? "").Split('|');
        return new string[] { f.Length > 0 ? f[0].Trim() : "", f.Length > 1 ? f[1].Trim() : "", f.Length > 2 ? f[2].Trim() : "" };
    }
    void ApplyComplaints() {
        ApplyPreset(false);
        if (Complaints == null) return;
        foreach (string raw in Complaints) {
            string[] c = ComplaintParts(raw);
            if (!complaintSel.Contains(c[0])) continue;
            foreach (string kv in c[2].Split(',')) {
                string[] p = kv.Split('=');
                if (p.Length != 2) continue;
                string key = p[0].Trim(), val = p[1].Trim();
                int num;
                if (val == "1" || string.Equals(val, "true", StringComparison.OrdinalIgnoreCase)) { Set(key, true); continue; }
                if (!int.TryParse(val, out num) || num <= 1) continue;
                foreach (Opt o in opts) {
                    if (o.ComboKey != key || o.Values == null) continue;
                    int pick = o.Values.Length - 1;
                    for (int i = 0; i < o.Values.Length; i++) { int v; if (int.TryParse(o.Values[i], out v) && v >= num) { pick = i; break; } }
                    if (pick > o.Idx) o.Idx = pick;
                }
            }
        }
        Fix();
    }
    internal void ToggleComplaint(string key) {
        if (complaintSel.Contains(key)) complaintSel.Remove(key); else complaintSel.Add(key);
        mode = 3;
        ApplyComplaints();
        Changed();
    }

    // ---- инструменты: отдельный запуск программы с DIAG_TOOL в своём (видимом) окне консоли
    internal void StartTool(string tool, string title) {
        string self = Environment.GetEnvironmentVariable("DIAG_SELF");
        if (string.IsNullOrEmpty(self) || !System.IO.File.Exists(self)) {
            DiagDialog.InfoOn(this, title, "Не найден файл программы (DIAG_SELF). Запустите BigTechoTest заново.");
            return;
        }
        if (!DiagDialog.AskOn(this, title, "Откроется отдельное окно мастера записи флешки. Диагностика при этом не запускается — это окно выбора тестов останется открытым.\n\nВНИМАНИЕ: все данные на выбранной флешке будут стёрты.", "Запустить", "Отмена")) return;
        try {
            string cmd = System.IO.Path.Combine(Environment.SystemDirectory, "cmd.exe");
            System.Diagnostics.ProcessStartInfo psi = new System.Diagnostics.ProcessStartInfo(cmd,
                "/c start \"BigTechoTest\" \"" + cmd + "\" /c \"\"" + self + "\"\"");
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.EnvironmentVariables["DIAG_TOOL"] = tool;
            if (psi.EnvironmentVariables.ContainsKey("DIAG_GUI")) psi.EnvironmentVariables.Remove("DIAG_GUI");
            System.Diagnostics.Process.Start(psi);
        } catch (Exception ex) {
            DiagDialog.InfoOn(this, title, "Не удалось запустить: " + ex.Message);
        }
    }
    internal void OpenReports() {
        string d = ReportsDir;
        try {
            if (string.IsNullOrEmpty(d)) d = Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory);
            if (!System.IO.Directory.Exists(d)) System.IO.Directory.CreateDirectory(d);
            System.Diagnostics.Process.Start("explorer.exe", "\"" + d + "\"");
        } catch (Exception) { DiagDialog.InfoOn(this, "Папка с отчётами", "Не удалось открыть папку:\n" + d); }
    }

    internal void SetMode(int m) {
        if (m == 0 || m == 1) ApplyPreset(m == 1);
        if (m == 3) ApplyComplaints();
        bool rebuild = (m == 3) != (mode == 3);
        mode = m;
        if (rebuild && page != null) page.Rebuild(false);
        Changed();
    }

    internal void Toggle(Opt o) {
        if (o.Locked || !o.Enabled) return;
        o.On = !o.On;
        if (!o.NotTest) { if (mode == 3 && page != null) page.Rebuild(false); mode = 2; }
        Fix();
        Changed();
    }

    internal void PickCombo(Opt o, int idx) {
        if (!o.Enabled) return;
        o.Idx = idx; o.On = true;
        if (mode == 3 && page != null) page.Rebuild(false);
        mode = 2;
        Fix();
        Changed();
    }

    internal void Changed() {
        if (page != null) page.Invalidate();
        if (nav != null) nav.Invalidate();
        if (bottom != null) bottom.Invalidate();
    }

    internal double TotalMinutes() {
        double m = 0;
        foreach (Opt o in opts) if (o.On && !o.NotTest) m += o.Est();
        return m;
    }

    // время пресета без изменения текущего выбора
    internal double PresetMinutes(bool full) {
        bool[] on = new bool[opts.Count]; int[] idx = new int[opts.Count]; bool[] en = new bool[opts.Count];
        for (int i = 0; i < opts.Count; i++) { on[i] = opts[i].On; idx[i] = opts[i].Idx; en[i] = opts[i].Enabled; }
        ApplyPreset(full);
        double m = TotalMinutes();
        for (int i = 0; i < opts.Count; i++) { opts[i].On = on[i]; opts[i].Idx = idx[i]; opts[i].Enabled = en[i]; }
        return m;
    }

    internal static string FmtTime(double m) {
        if (m < 60) return string.Format("≈ {0:0} мин", Math.Max(1, Math.Ceiling(m)));
        return string.Format(CultureInfo.GetCultureInfo("ru-RU"), "≈ {0:0.#} ч", m / 60);
    }

    internal int CountSelected() {
        int n = 0;
        foreach (Opt o in opts) if (o.On && o.Key != "info" && o.Key != "pawn" && o.Key != "firmware" && o.Key != "sdio" && !o.NotTest) n++;
        return n + 1;
    }

    internal void CatCount(int cat, out int on, out int total) {
        on = 0; total = 0;
        foreach (Opt o in opts) if (o.Cat == cat && !o.NotTest) { total++; if (o.On) on++; }
    }

    string Serialize() {
        List<string> parts = new List<string>();
        parts.Add("mode=" + (mode == 0 ? "quick" : mode == 1 ? "full" : mode == 3 ? "complaint" : "custom"));
        if (mode == 3 && complaintSel.Count > 0) {
            List<string> ck = new List<string>(complaintSel);
            parts.Add("complaint=" + string.Join(",", ck.ToArray()));
        }
        foreach (Opt o in opts) {
            parts.Add(o.Key + "=" + (o.On ? "1" : "0"));
            if (o.Labels != null) parts.Add(o.ComboKey + "=" + o.Values[o.Idx]);
        }
        return string.Join(";", parts.ToArray());
    }

    // для проверки окна без запуска диагностики
    public string PreviewResult() { return Serialize(); }
    public void SelectTab(int i) {
        if (i < 0 || i >= TabNames.Length) return;
        tab = i;
        page.Rebuild(true);
        nav.Invalidate();
    }
    public void SelectMode(int m) { SetMode(m); }
    public void SelectAbout(int s) {
        if (s < 0 || s >= SubNames.Length) return;
        sub = s;
        SelectTab(11);
    }
    internal void SetAccepted(bool v) { accepted = v; Changed(); }

    internal void Start() {
        if (!accepted) { SelectAbout(SubRules); return; }
        if (needAccept) SaveAccepted();
        if (mode == 3 && complaintSel.Count == 0) {
            DiagDialog.InfoOn(this, "Режим «По жалобе»", "Отметьте хотя бы одну жалобу клиента в разделе «Режим» — или выберите другой режим.");
            SelectTab(0); return;
        }
        Result = Serialize(); DialogResult = DialogResult.OK; Close();
    }
    internal void Cancel() { Result = "cancel"; DialogResult = DialogResult.Cancel; Close(); }

    protected override bool ProcessCmdKey(ref Message msg, Keys keyData) {
        if (keyData == Keys.Enter) { Start(); return true; }
        if (keyData == Keys.Escape) { Cancel(); return true; }
        if (keyData == Keys.F1) { ShowHelp(); return true; }
        if (keyData == (Keys.Control | Keys.Oemplus) || keyData == (Keys.Control | Keys.Add) || keyData == (Keys.Control | Keys.Shift | Keys.Oemplus)) { ScaleStep(1); return true; }
        if (keyData == (Keys.Control | Keys.OemMinus) || keyData == (Keys.Control | Keys.Subtract)) { ScaleStep(-1); return true; }
        if (keyData == (Keys.Control | Keys.D0) || keyData == (Keys.Control | Keys.NumPad0)) { ScaleStep(0); return true; }
        if (keyData == (Keys.Control | Keys.T)) { TogglePin(); return true; }
        if (keyData == (Keys.Control | Keys.Tab) || keyData == (Keys.Control | Keys.PageDown)) { SelectTab((tab + 1) % TabNames.Length); return true; }
        if (keyData == (Keys.Control | Keys.Shift | Keys.Tab) || keyData == (Keys.Control | Keys.PageUp)) { SelectTab((tab + TabNames.Length - 1) % TabNames.Length); return true; }
        return base.ProcessCmdKey(ref msg, keyData);
    }

    public static string Choose(bool isLaptop, bool hasPawn) {
        Application.EnableVisualStyles();
        using (DiagChooser f = new DiagChooser(isLaptop, hasPawn)) {
            f.ShowDialog();
            return f.Result;
        }
    }
}

internal class DcControl : Control {
    protected readonly DiagChooser F;
    public DcControl(DiagChooser f) {
        F = f;
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer |
                 ControlStyles.ResizeRedraw, true);
        DoubleBuffered = true;
    }
    protected int S(double v) { return F.S(v); }
    protected bool CtrlWheel(MouseEventArgs e) {
        if ((Control.ModifierKeys & Keys.Control) == 0) return false;
        F.ScaleStep(e.Delta > 0 ? 1 : -1);
        return true;
    }
    protected override void OnMouseWheel(MouseEventArgs e) { if (!CtrlWheel(e)) base.OnMouseWheel(e); }
    protected static Graphics Prep(PaintEventArgs e) {
        Graphics g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.PixelOffsetMode = PixelOffsetMode.HighQuality;
        return g;
    }
}

// ------------------------------------------------------------ шапка
internal class DcHeader : DcControl {
    // кнопки шапки: 0 мельче, 1 масштаб (сброс), 2 крупнее, 3 поверх всех окон, 4 справка
    readonly Rectangle[] btn = new Rectangle[5];
    int hover = -1, pressed = -1;
    static readonly string[] Tips = { "Мельче (Ctrl −)", "Обычный масштаб (Ctrl+0)", "Крупнее (Ctrl +)", "Поверх всех окон (Ctrl+T)", "Горячие клавиши (F1)" };
    public DcHeader(DiagChooser f) : base(f) { BackColor = DiagTheme.Panel; }

    int ButtonsLeft() {
        int bs = S(34), gap = S(6);
        int x = Width - S(20);
        x -= bs; btn[4] = new Rectangle(x, (Height - bs) / 2, bs, bs);
        x -= gap + bs; btn[3] = new Rectangle(x, (Height - bs) / 2, bs, bs);
        x -= S(14) + bs; btn[2] = new Rectangle(x, (Height - bs) / 2, bs, bs);
        x -= S(52); btn[1] = new Rectangle(x, (Height - bs) / 2, S(52), bs);
        x -= bs; btn[0] = new Rectangle(x, (Height - bs) / 2, bs, bs);
        return x;
    }

    void DrawBtn(Graphics g, int i) {
        Rectangle r = btn[i];
        bool on = i == 3 && F.pinned;
        bool hov = hover == i, down = pressed == i && hov;
        bool grp = i <= 2;
        if (!grp || i == 1) {
            if (on) DiagTheme.Fill(g, r, S(9), DiagTheme.AccentSoft);
            else if (down) DiagTheme.Fill(g, r, S(9), DiagTheme.LineHi);
            else if (hov) DiagTheme.Fill(g, r, S(9), DiagTheme.PlateHi);
        } else if (hov) DiagTheme.Fill(g, r, S(9), down ? DiagTheme.LineHi : DiagTheme.PlateHi);
        Color c = on ? DiagTheme.AccentText : (hov ? DiagTheme.Ink : DiagTheme.Ink3);
        float lw = Math.Max(1.4f, S(1.6));
        RectangleF ir = new RectangleF(r.X + (r.Width - S(18)) / 2f, r.Y + (r.Height - S(18)) / 2f, S(18), S(18));
        if (i == 0 || i == 2) {
            using (Pen p = new Pen(c, lw)) {
                p.StartCap = LineCap.Round; p.EndCap = LineCap.Round;
                float cx = ir.X + ir.Width / 2f, cy = ir.Y + ir.Height / 2f;
                g.DrawLine(p, cx - S(5), cy, cx + S(5), cy);
                if (i == 2) g.DrawLine(p, cx, cy - S(5), cx, cy + S(5));
            }
        } else if (i == 1) DiagTheme.TextC(g, ((int)Math.Round(F.uiScale * 100)) + "%", F.fCap, r, c);
        else DiagGlyph.Draw(g, i == 3 ? 17 : 18, ir, c, lw);
    }

    int Hit(Point p) { for (int i = 0; i < btn.Length; i++) if (btn[i].Contains(p)) return i; return -1; }
    protected override void OnMouseMove(MouseEventArgs e) {
        base.OnMouseMove(e);
        int h = Hit(e.Location);
        if (h != hover) {
            hover = h; Invalidate();
            Cursor = h >= 0 ? Cursors.Hand : Cursors.Default;
            try { F.tips.SetToolTip(this, h >= 0 ? Tips[h] : null); } catch (Exception) { }
        }
    }
    protected override void OnMouseLeave(EventArgs e) { base.OnMouseLeave(e); hover = -1; pressed = -1; Invalidate(); }
    protected override void OnMouseDown(MouseEventArgs e) { base.OnMouseDown(e); if (e.Button == MouseButtons.Left) { pressed = Hit(e.Location); Invalidate(); } }
    protected override void OnMouseUp(MouseEventArgs e) {
        base.OnMouseUp(e);
        int h = Hit(e.Location), p0 = pressed;
        pressed = -1; Invalidate();
        if (h < 0 || h != p0) return;
        if (h == 0) F.ScaleStep(-1);
        else if (h == 1) F.ScaleStep(0);
        else if (h == 2) F.ScaleStep(1);
        else if (h == 3) F.TogglePin();
        else F.ShowHelp();
    }

    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = Prep(e);
        g.Clear(DiagTheme.Panel);
        int bl = ButtonsLeft();
        DiagTheme.Fill(g, new RectangleF(btn[0].X, btn[0].Y, btn[2].Right - btn[0].X, btn[0].Height), S(9), DiagTheme.Soft);
        for (int i = 0; i < btn.Length; i++) DrawBtn(g, i);
        using (Pen p = new Pen(DiagTheme.Line)) g.DrawLine(p, 0, Height - 1, Width, Height - 1);
        int lx = S(24), ls = S(40);
        DiagGlyph.Logo(g, new RectangleF(lx, (Height - ls) / 2f, ls, ls));
        int tx = lx + ls + S(14);
        int ty = S(12);
        string title = DiagTheme.AppName;
        int tw = DiagTheme.TextW(g, title, F.fH2);
        DiagTheme.Text(g, title, F.fH2, new Rectangle(tx, ty, tw + S(4), S(28)), DiagTheme.Ink);
        if (!string.IsNullOrEmpty(DiagChooser.Version)) {
            string v = "v" + DiagChooser.Version;
            int vw = DiagTheme.TextW(g, v, F.fCap) + S(14);
            Rectangle vr = new Rectangle(tx + tw + S(10), ty + S(5), vw, S(19));
            DiagTheme.Fill(g, vr, vr.Height / 2f, DiagTheme.AccentSoft);
            DiagTheme.TextC(g, v, F.fCap, vr, DiagTheme.AccentText);
        }
        int brandW = 0;
        if (!string.IsNullOrEmpty(DiagChooser.Brand) && bl - tx > S(560)) {
            string b = DiagChooser.Brand;
            int bw = Math.Max(DiagTheme.TextW(g, b, F.fBrand), DiagTheme.TextW(g, "компьютерный сервис", F.fSmall));
            brandW = bw + S(16) + S(24);
            int bx = bl - S(28) - bw;
            int by = (Height - S(36)) / 2;
            DiagTheme.Fill(g, new RectangleF(bx - S(16), by + S(6), S(8), S(8)), S(2), DiagTheme.Accent);
            DiagTheme.Text(g, b, F.fBrand, new Rectangle(bx, by, bw + S(2), S(20)), DiagTheme.Ink);
            DiagTheme.Text(g, "компьютерный сервис", F.fSmall, new Rectangle(bx, by + S(19), bw + S(2), S(16)), DiagTheme.Ink4);
        }
        string tag = DiagTheme.AppTagline;
        if (tag.Length > 0) tag = char.ToUpper(tag[0]) + tag.Substring(1);
        if (!string.IsNullOrEmpty(DiagChooser.MachineInfo)) tag += "   ·   " + DiagChooser.MachineInfo;
        DiagTheme.Text(g, tag, F.fSmall, new Rectangle(tx, ty + S(29), Math.Max(10, bl - tx - brandW - S(20)), S(18)), DiagTheme.Ink3);
    }
}

// ------------------------------------------------------------ навигация
internal class DcNav : DcControl {
    int hover = -1;
    readonly List<KeyValuePair<int, Rectangle>> rects = new List<KeyValuePair<int, Rectangle>>();
    public DcNav(DiagChooser f) : base(f) { BackColor = DiagTheme.Panel; Cursor = Cursors.Hand; }

    void Layout0(Graphics g) {
        rects.Clear();
        int n = DiagChooser.NavOrder.Length;
        int h = Math.Max(S(26), Math.Min(S(38), (Height - S(14) - 3 * S(28) - S(8)) / n - S(2)));
        int y = S(14), x = S(12), w = Width - S(24);
        foreach (int i in DiagChooser.NavOrder) {
            if (GroupTitle(i) != null) y += S(28);
            rects.Add(new KeyValuePair<int, Rectangle>(i, new Rectangle(x, y, w, h)));
            y += h + S(2);
        }
    }

    static string GroupTitle(int i) { return i == 1 ? "ТЕСТЫ" : i == DiagChooser.TabTools ? "СЕРВИС" : i == 10 ? "СПРАВКА" : null; }
    static int GlyphOf(int i) { return i == 9 ? 11 : i == DiagChooser.TabTools ? 16 : (i > 9 ? i - 1 : i); }

    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = Prep(e);
        g.Clear(DiagTheme.Panel);
        using (Pen p = new Pen(DiagTheme.Line)) g.DrawLine(p, Width - 1, 0, Width - 1, Height);
        Layout0(g);
        foreach (KeyValuePair<int, Rectangle> kv in rects) {
            int i = kv.Key; Rectangle r = kv.Value;
            if (GroupTitle(i) != null)
                DiagTheme.Text(g, GroupTitle(i), F.fCap, new Rectangle(r.X + S(12), r.Y - S(22), r.Width, S(18)), DiagTheme.Ink4);
            bool sel = i == F.tab, hov = i == hover;
            if (sel) {
                DiagTheme.Fill(g, r, S(12), DiagTheme.AccentSoft);
                DiagTheme.Fill(g, new RectangleF(r.X, r.Y + S(10), S(3), r.Height - S(20)), S(1.5), DiagTheme.Accent);
            } else if (hov) DiagTheme.Fill(g, r, S(12), DiagTheme.PlateHi);
            Color ic = sel ? DiagTheme.AccentText : (hov ? DiagTheme.Ink : DiagTheme.Ink3);
            DiagGlyph.Draw(g, GlyphOf(i), new RectangleF(r.X + S(14), r.Y + (r.Height - S(18)) / 2f, S(18), S(18)), ic, Math.Max(1.3f, S(1.5)));
            string badge = "";
            if (i >= 1 && i <= 8) {
                int on, total; F.CatCount(i, out on, out total);
                badge = on + "/" + total;
            } else if (i == 0) badge = F.mode == 0 ? "быстрая" : F.mode == 1 ? "полная" : F.mode == 3 ? "по жалобе" : "выборочная";
            int bw = 0;
            if (badge.Length > 0) {
                bw = DiagTheme.TextW(g, badge, F.fCap) + S(14);
                Rectangle br = new Rectangle(r.Right - S(10) - bw, r.Y + (r.Height - S(20)) / 2, bw, S(20));
                bool full = false;
                if (i >= 1 && i <= 8) { int on, total; F.CatCount(i, out on, out total); full = on > 0; }
                DiagTheme.Fill(g, br, br.Height / 2f, sel ? Color.FromArgb(0x52, 0x1c, 0x1a) : DiagTheme.Soft);
                DiagTheme.TextC(g, badge, F.fCap, br, sel ? DiagTheme.AccentText : (full ? DiagTheme.Ink2 : DiagTheme.Ink4));
            }
            DiagTheme.Text(g, DiagChooser.TabNames[i], sel ? F.fSemiS : F.fBody,
                new Rectangle(r.X + S(44), r.Y, r.Width - S(44) - bw - S(14), r.Height), sel || hov ? DiagTheme.Ink : DiagTheme.Ink2);
        }
        if (rects.Count > 0 && rects[rects.Count - 1].Value.Bottom + S(60) < Height)
            DiagTheme.Wrap(g, "F1 — горячие клавиши\nEnter — начать · Esc — отмена", F.fSmall,
                new Rectangle(S(24), Height - S(48), Width - S(36), S(40)), DiagTheme.Ink4);
    }

    int Hit(Point p) { foreach (KeyValuePair<int, Rectangle> kv in rects) if (kv.Value.Contains(p)) return kv.Key; return -1; }
    protected override void OnMouseMove(MouseEventArgs e) {
        base.OnMouseMove(e);
        int h = Hit(e.Location);
        if (h != hover) { hover = h; Invalidate(); }
    }
    protected override void OnMouseLeave(EventArgs e) { base.OnMouseLeave(e); if (hover != -1) { hover = -1; Invalidate(); } }
    protected override void OnMouseDown(MouseEventArgs e) {
        base.OnMouseDown(e);
        int h = Hit(e.Location);
        if (h >= 0) F.SelectTab(h);
    }
}

// ------------------------------------------------------------ нижняя панель
internal class DcBottom : DcControl {
    Rectangle rGo, rCancel;
    int hover;   // 1 — начать, 2 — отмена
    public DcBottom(DiagChooser f) : base(f) { BackColor = DiagTheme.Panel; }

    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = Prep(e);
        g.Clear(DiagTheme.Panel);
        using (Pen p = new Pen(DiagTheme.Line)) g.DrawLine(p, 0, 0, Width, 0);
        int bh = S(48);
        int by = F.accepted ? (Height - bh) / 2 : S(10);
        int gw = Math.Max(S(250), DiagTheme.TextW(g, "Начать диагностику", F.fBtn) + S(80));
        rGo = new Rectangle(Width - S(24) - gw, by, gw, bh);
        rCancel = new Rectangle(rGo.X - S(12) - S(124), by, S(124), bh);
        // время
        int x = S(24);
        DiagGlyph.Draw(g, 11, new RectangleF(x, (Height - S(30)) / 2f, S(30), S(30)), DiagTheme.AccentText, Math.Max(1.5f, S(2)));
        x += S(44);
        string t = DiagChooser.FmtTime(F.TotalMinutes());
        DiagTheme.Text(g, "ПРИМЕРНОЕ ВРЕМЯ", F.fCap, new Rectangle(x, S(16), S(200), S(16)), DiagTheme.Ink4);
        int tw = DiagTheme.TextW(g, t, F.fBig);
        DiagTheme.Text(g, t, F.fBig, new Rectangle(x, S(32), tw + S(6), S(34)), DiagTheme.Ink);
        x += Math.Max(tw, S(130)) + S(28);
        if (x + S(140) < rCancel.X) {
            using (Pen p = new Pen(DiagTheme.Line)) g.DrawLine(p, x - S(14), S(18), x - S(14), Height - S(18));
            DiagTheme.Text(g, "ТЕСТОВ", F.fCap, new Rectangle(x, S(16), S(120), S(16)), DiagTheme.Ink4);
            DiagTheme.Text(g, F.CountSelected().ToString(), F.fBig, new Rectangle(x, S(32), S(80), S(34)), DiagTheme.Ink);
            x += S(86);
        }
        if (x + S(150) < rCancel.X) {
            using (Pen p = new Pen(DiagTheme.Line)) g.DrawLine(p, x - S(14), S(18), x - S(14), Height - S(18));
            DiagTheme.Text(g, "РЕЖИМ", F.fCap, new Rectangle(x, S(16), S(150), S(16)), DiagTheme.Ink4);
            string m = F.mode == 0 ? "Быстрая" : F.mode == 1 ? "Полная" : F.mode == 3 ? "По жалобе" : "Выборочная";
            DiagTheme.Text(g, m, F.fH3, new Rectangle(x, S(34), S(160), S(30)), F.mode == 2 ? DiagTheme.Warn : DiagTheme.Ink);
        }
        // кнопки
        DiagTheme.Fill(g, rCancel, S(14), hover == 2 ? DiagTheme.PlateHi : DiagTheme.Panel);
        DiagTheme.Stroke(g, new RectangleF(rCancel.X + 0.5f, rCancel.Y + 0.5f, rCancel.Width - 1, rCancel.Height - 1), S(14), hover == 2 ? DiagTheme.Ink4 : DiagTheme.LineHi, 1f);
        DiagTheme.TextC(g, "Отмена", F.fSemi, rCancel, hover == 2 ? DiagTheme.Ink : DiagTheme.Ink2);
        if (hover == 1 && F.accepted) {
            using (GraphicsPath gp = DiagTheme.Round(new RectangleF(rGo.X - 3, rGo.Y - 3, rGo.Width + 6, rGo.Height + 6), S(17)))
            using (SolidBrush b = new SolidBrush(Color.FromArgb(60, DiagTheme.Accent))) g.FillPath(b, gp);
        }
        if (F.accepted) DiagTheme.FillAccent(g, rGo, S(14), hover == 1);
        else DiagTheme.Fill(g, rGo, S(14), hover == 1 ? DiagTheme.LineHi : DiagTheme.Soft);
        Color gc = F.accepted ? Color.White : DiagTheme.Ink4;
        string go = "Начать диагностику";
        int gtw = DiagTheme.TextW(g, go, F.fBtn);
        int cx = rGo.X + (rGo.Width - gtw - S(22)) / 2;
        float ty = rGo.Y + rGo.Height / 2f;
        using (SolidBrush b = new SolidBrush(gc))
            g.FillPolygon(b, new PointF[] { new PointF(cx, ty - S(7)), new PointF(cx + S(12), ty), new PointF(cx, ty + S(7)) });
        DiagTheme.Text(g, go, F.fBtn, new Rectangle(cx + S(22), rGo.Y, gtw + S(4), rGo.Height), gc);
        if (!F.accepted) DiagTheme.TextR(g, "сначала примите условия использования", F.fSmall,
            new Rectangle(rGo.X - S(400), rGo.Bottom + S(5), rGo.Width + S(400), S(16)), DiagTheme.Warn);
    }

    protected override void OnMouseMove(MouseEventArgs e) {
        base.OnMouseMove(e);
        int h = rGo.Contains(e.Location) ? 1 : rCancel.Contains(e.Location) ? 2 : 0;
        Cursor = h != 0 ? Cursors.Hand : Cursors.Default;
        if (h != hover) { hover = h; Invalidate(); }
    }
    protected override void OnMouseLeave(EventArgs e) { base.OnMouseLeave(e); if (hover != 0) { hover = 0; Invalidate(); } }
    protected override void OnMouseClick(MouseEventArgs e) {
        base.OnMouseClick(e);
        if (e.Button != MouseButtons.Left) return;
        if (rGo.Contains(e.Location)) F.Start();
        else if (rCancel.Contains(e.Location)) F.Cancel();
    }
}

// ------------------------------------------------------------ страница раздела
internal class DcPage : DcControl {
    internal delegate void PaintFn(Graphics g, Rectangle r);
    internal delegate void ClickFn(Point p);
    internal class Blk { public Rectangle R; public PaintFn Paint; public ClickFn Click; public bool Live; }

    readonly List<Blk> blocks = new List<Blk>();
    int scroll, contentH, builtW = -1, builtTab = -1;
    Point mouse = new Point(-1, -1);   // в координатах содержимого
    int hoverBlk = -1;
    bool dragBar; int dragOff;

    public DcPage(DiagChooser f) : base(f) { BackColor = DiagTheme.Bg; SetStyle(ControlStyles.Selectable, true); TabStop = true; }

    Point Mouse { get { return mouse; } }
    bool Hov(Rectangle r) { return r.Contains(mouse); }

    public void Rebuild(bool resetScroll) {
        if (resetScroll) scroll = 0;
        builtW = -1;
        Invalidate();
    }

    protected override void OnResize(EventArgs e) { base.OnResize(e); builtW = -1; Invalidate(); }

    int ViewH { get { return Height; } }
    int MaxScroll { get { return Math.Max(0, contentH - ViewH); } }

    // ---------- построение
    int cx, cw;   // колонка содержимого
    Blk AddBlk(Rectangle r, PaintFn p, ClickFn c) {
        Blk b = new Blk(); b.R = r; b.Paint = p; b.Click = c; blocks.Add(b);
        return b;
    }

    void Build(Graphics g) {
        blocks.Clear();
        int pad = S(32);
        cw = Math.Min(Width - 2 * pad - S(8), S(1000));
        if (cw < S(300)) cw = S(300);
        cx = pad;
        int y = S(28);
        switch (F.tab) {
            case 0:
                y = Title(g, y, "Режим диагностики", "Выберите готовый набор проверок или настройте тесты по разделам слева. Отчёт сохранится на Рабочий стол.");
                y = ModeCards(g, y);
                if (F.mode == 3) y = ComplaintList(g, y);
                y = Section(g, y, "Что войдёт в проверку");
                y = CatTiles(g, y);
                break;
            case 1:
                y = Title(g, y, "Процессор", "Нагрузочные тесты процессора и системы охлаждения. Во время тестов работает ТемпературныйНюхач.");
                y = Rows(g, y, 1);
                y = Note(g, y, 0, "Реакция вентиляторов на нагрузку проверяется вместе со стресс-тестом процессора. Prime95, y-cruncher и Linpack нагружают процессор сильнее обычных программ — так и должно быть.");
                break;
            case 2:
                y = Title(g, y, "Память", "Поиск ошибок оперативной памяти — от быстрого теста до глубокой проверки.");
                y = Rows(g, y, 2);
                y = Note(g, y, 1, "Полная проверка памяти выполняется средством Windows при следующей перезагрузке — компьютер перезагрузится после формирования отчёта.");
                break;
            case 3:
                y = Title(g, y, "Видеокарта", "Нагрев, стабильность и видеопамять дискретной или встроенной видеокарты.");
                y = Rows(g, y, 3);
                break;
            case 4:
                y = Title(g, y, "Питание", "Блок питания под совместной нагрузкой процессора и видеокарты; аккумулятор ноутбука.");
                y = Rows(g, y, 4);
                if (F.isLaptop) y = Note(g, y, 1, "Это ноутбук: блок питания и цепи питания рассчитаны с небольшим запасом. Тест доступен, но запускайте осторожно — с подключённой зарядкой и короткой длительностью.");
                y = Note(g, y, 2, "ТемпературныйНюхач каждую секунду следит за температурами и напряжениями и остановит тест при аномалии — до того, как она навредит железу.");
                break;
            case 5:
                y = Title(g, y, "Накопители", "Скорость, состояние поверхности и самодиагностика SSD и HDD.");
                y = Rows(g, y, 5);
                y = Note(g, y, 0, "Данные на дисках не изменяются: тест скорости пишет только во временный файл, поверхность и SMART — только чтение.");
                break;
            case 6:
                y = Title(g, y, "Система и журналы", "Сведения о компьютере, программы, журналы ошибок Windows и сеть.");
                y = Rows(g, y, 6);
                break;
            case 7:
                y = Title(g, y, "С вашим участием", "Проверки, где программа показывает окно и ждёт ответа человека за компьютером.");
                y = Rows(g, y, 7);
                y = Note(g, y, 0, "Если мастер отходит от компьютера на время диагностики — выключите эти проверки, иначе программа будет ждать ответа.");
                break;
            case 8:
                y = Title(g, y, "Обслуживание", "Действия, которые исправляют и обновляют систему.");
                y = Rows(g, y, 8);
                y = Note(g, y, 1, "Эти пункты меняют систему (восстановление файлов, установка драйверов и прошивок). Включайте с согласия владельца компьютера.");
                break;
            case 9:
                y = History(g, y);
                break;
            case 10:
                y = Title(g, y, "Безопасность", "Как программа бережёт железо во время нагрузочных тестов.");
                y = Feature(g, y, 9, DiagTheme.Ok, "ТемпературныйНюхач",
                    "ТемпературныйНюхач каждую секунду следит за датчиками (LibreHardwareMonitor + HWiNFO) и останавливает тесты при аномалии: перегреве, просадке напряжения, остановке вентилятора. После остановки можно продолжить на свой риск.");
                y = Feature(g, y, 15, DiagTheme.AccentText, "Чёрный ящик",
                    "Во время стресс-тестов показания датчиков записываются. Если компьютер выключится или зависнет, при следующем запуске программа покажет, что происходило перед сбоем.");
                y = Feature(g, y, 5, DiagTheme.Ink2, "Данные владельца не трогаются",
                    "Тесты только читают диски; временные файлы удаляются. Изменения системы — только в разделе «Обслуживание» и только если вы их включили.");
                y = Section(g, y, "Настройки");
                y = Rows(g, y, 9);
                break;
            case 11:
                y = About(g, y);
                break;
            case DiagChooser.TabTools:
                y = Tools(g, y);
                break;
        }
        contentH = y + S(32);
        if (scroll > MaxScroll) scroll = MaxScroll;
    }

    int Title(Graphics g, int y, string title, string sub) {
        int th = S(36);
        int sh = DiagTheme.WrapH(g, sub, F.fBody, cw);
        Rectangle r = new Rectangle(cx, y, cw, th + S(6) + sh);
        AddBlk(r, delegate(Graphics gg, Rectangle rr) {
            DiagTheme.Text(gg, title, F.fTitle, new Rectangle(rr.X, rr.Y, rr.Width, th), DiagTheme.Ink);
            DiagTheme.Wrap(gg, sub, F.fBody, new Rectangle(rr.X, rr.Y + th + S(6), rr.Width, sh + S(2)), DiagTheme.Ink3);
        }, null);
        return r.Bottom + S(24);
    }

    // ---------- «История проверок»: список прежних отчётов этого компьютера
    int History(Graphics g, int y) {
        y = Title(g, y, "История проверок", "Прежние диагностики этого компьютера. Откройте отчёт, чтобы сравнить состояние с прошлым разом.");
        string[] items = DiagChooser.HistoryItems;
        if (items == null || items.Length == 0) {
            Rectangle er = new Rectangle(cx, y, cw, S(150));
            AddBlk(er, delegate(Graphics gg, Rectangle rr) {
                DiagTheme.Fill(gg, rr, S(16), DiagTheme.Panel);
                DiagTheme.Stroke(gg, new RectangleF(rr.X + 0.5f, rr.Y + 0.5f, rr.Width - 1, rr.Height - 1), S(16), DiagTheme.Line, 1f);
                Rectangle ic = new Rectangle(rr.X + (rr.Width - S(56)) / 2, rr.Y + S(24), S(56), S(56));
                DiagTheme.Fill(gg, ic, S(16), Color.FromArgb(28, DiagTheme.AccentText));
                DiagGlyph.Draw(gg, 11, new RectangleF(ic.X + S(14), ic.Y + S(14), S(28), S(28)), DiagTheme.AccentText, Math.Max(1.5f, S(2)));
                DiagTheme.TextC(gg, "Проверок ещё не было — после первой диагностики отчёт появится здесь", F.fBody,
                    new Rectangle(rr.X + S(16), rr.Y + S(94), rr.Width - S(32), S(30)), DiagTheme.Ink3);
            }, null);
            return er.Bottom + S(12);
        }
        foreach (string raw in items) {
            if (string.IsNullOrEmpty(raw)) continue;
            string[] f = raw.Split('|');
            string date = f.Length > 0 ? f[0] : "", mode = f.Length > 2 ? f[2] : "", path = f.Length > 3 ? f[3] : "";
            bool server = f.Length > 4 && f[4] == "server";
            int score = -1;
            if (f.Length > 1 && !int.TryParse(f[1].Trim(), out score)) score = -1;
            Color sc = score < 0 ? DiagTheme.Ink4 : (score >= 85 ? DiagTheme.Ok : (score >= 60 ? DiagTheme.Warn : DiagTheme.Crit));
            string src = server ? "с сервера" : "на этом ПК";
            string target = path;
            Rectangle r = new Rectangle(cx, y, cw, S(72));
            Blk row = AddBlk(r, null, null);
            row.Live = true;
            row.Paint = delegate(Graphics gg, Rectangle rr) {
                DiagTheme.Fill(gg, rr, S(16), DiagTheme.Panel);
                DiagTheme.Stroke(gg, new RectangleF(rr.X + 0.5f, rr.Y + 0.5f, rr.Width - 1, rr.Height - 1), S(16), DiagTheme.Line, 1f);
                Rectangle bdg = new Rectangle(rr.X + S(16), rr.Y + S(14), S(56), S(44));
                DiagTheme.Fill(gg, bdg, S(12), Color.FromArgb(32, sc));
                DiagTheme.TextC(gg, score < 0 ? "—" : score.ToString(), F.fH3, bdg, sc);
                int tx = rr.X + S(88);
                int bw = S(110);
                DiagTheme.Text(gg, date, F.fSemiS, new Rectangle(tx, rr.Y + S(12), rr.Width - (tx - rr.X) - bw - S(130), S(26)), DiagTheme.Ink);
                string sub = (mode.Length > 0 ? mode : "диагностика") + " · " + src + (score < 0 ? "" : " · оценка " + score + " из 100");
                DiagTheme.Text(gg, sub, F.fSmall, new Rectangle(tx, rr.Y + S(38), rr.Width - (tx - rr.X) - bw - S(130), S(22)), DiagTheme.Ink3);
                Rectangle br = new Rectangle(rr.Right - S(16) - bw, rr.Y + S(18), bw, S(36));
                bool hov = Hov(br);
                if (target.Length == 0) { DiagTheme.Fill(gg, br, S(12), DiagTheme.Soft); DiagTheme.TextC(gg, "нет файла", F.fSmall, br, DiagTheme.Ink4); }
                else {
                    DiagTheme.Fill(gg, br, S(12), hov ? DiagTheme.PlateHi : DiagTheme.Soft);
                    DiagTheme.Stroke(gg, new RectangleF(br.X + 0.5f, br.Y + 0.5f, br.Width - 1, br.Height - 1), S(12), hov ? DiagTheme.AccentText : DiagTheme.LineHi, 1f);
                    DiagTheme.TextC(gg, "Открыть", F.fSemiS, br, hov ? DiagTheme.Ink : DiagTheme.Ink2);
                }
            };
            if (target.Length > 0) {
                Rectangle hit = new Rectangle(r.Right - S(16) - S(110), r.Y + S(18), S(110), S(36));
                AddBlk(hit, null, delegate(Point p) {
                    try { System.Diagnostics.Process.Start(target); }
                    catch (Exception) { MessageBox.Show(F, "Не удалось открыть отчёт:\n" + target, "История проверок"); }
                });
            }
            y = r.Bottom + S(10);
        }
        return y + S(6);
    }

    int Section(Graphics g, int y, string text) {
        Rectangle r = new Rectangle(cx, y + S(8), cw, S(22));
        AddBlk(r, delegate(Graphics gg, Rectangle rr) {
            DiagTheme.Text(gg, text.ToUpperInvariant(), F.fCap, rr, DiagTheme.Ink4);
        }, null);
        return r.Bottom + S(10);
    }

    int Rows(Graphics g, int y, int cat) {
        foreach (DiagChooser.Opt o in F.opts) if (o.Cat == cat) y = Row(g, y, o) + S(10);
        return y + S(6);
    }

    // строка теста: переключатель, название, что ловит, длительность, время
    int Row(Graphics g, int y, DiagChooser.Opt o) {
        int padL = S(20), togW = S(42), togH = S(24);
        int segH = S(32), segPad = S(14);
        int[] segW = null;
        int segTotal = 0;
        if (o.Labels != null) {
            segW = new int[o.Labels.Length];
            for (int i = 0; i < o.Labels.Length; i++) { segW[i] = DiagTheme.TextW(g, o.Labels[i], F.fSemiS) + 2 * segPad; segTotal += segW[i]; }
            segTotal += S(8);
        }
        int timeW = o.TimeText == "" ? 0 : S(96);
        int textX = padL + togW + S(18);
        int rightW = timeW + (segTotal > 0 ? segTotal + S(16) : 0) + S(20);
        bool stack = true;   // длительность всегда под описанием — одинаковая раскладка всех строк
        int textW = stack ? cw - textX - timeW - S(20) : cw - textX - rightW;
        int titleH = S(24);
        int descH = DiagTheme.WrapH(g, o.Desc, F.fBody, textW);
        int h = S(16) + titleH + S(2) + descH + S(16);
        if (stack && segTotal > 0) h += segH + S(10);
        h = Math.Max(h, S(76));
        Rectangle r = new Rectangle(cx, y, cw, h);
        int[] sw = segW;
        int segTot = segTotal;
        bool st = stack;
        Blk b = AddBlk(r, null, null);
        b.Live = true;
        b.Paint = delegate(Graphics gg, Rectangle rr) {
            bool hov = Hov(rr) && o.Enabled && !o.Locked;
            bool dis = !o.Enabled;
            DiagTheme.Fill(gg, rr, S(16), hov ? DiagTheme.PlateHi : DiagTheme.Panel);
            DiagTheme.Stroke(gg, new RectangleF(rr.X + 0.5f, rr.Y + 0.5f, rr.Width - 1, rr.Height - 1), S(16),
                o.On && !o.Locked ? Color.FromArgb(0x4a, 0x22, 0x20) : (hov ? DiagTheme.LineHi : DiagTheme.Line), 1f);
            // переключатель
            Rectangle tr = new Rectangle(rr.X + padL, rr.Y + S(18), togW, togH);
            DrawToggle(gg, tr, o.On, dis || o.Locked);
            // текст
            int tx = rr.X + textX;
            int tw = DiagTheme.TextW(gg, o.Title, F.fSemi);
            tw = Math.Min(tw, textW);
            Color tc = dis ? DiagTheme.Ink4 : DiagTheme.Ink;
            DiagTheme.Text(gg, o.Title, F.fSemi, new Rectangle(tx, rr.Y + S(16), tw + S(2), titleH), tc);
            if (!string.IsNullOrEmpty(o.Badge)) {
                int bw = DiagTheme.TextW(gg, o.Badge, F.fCap) + S(16);
                Rectangle br = new Rectangle(tx + tw + S(10), rr.Y + S(18), bw, S(20));
                Color bc = o.BadgeWarn ? DiagTheme.Warn : DiagTheme.Ink3;
                DiagTheme.Fill(gg, br, br.Height / 2f, Color.FromArgb(o.BadgeWarn ? 40 : 30, bc));
                DiagTheme.TextC(gg, o.Badge, F.fCap, br, bc);
            }
            DiagTheme.Wrap(gg, o.Desc, F.fBody, new Rectangle(tx, rr.Y + S(16) + titleH + S(2), textW, descH + S(2)), dis ? DiagTheme.Ink4 : DiagTheme.Ink3);
            // время
            if (timeW > 0) {
                string t = o.TimeText != null ? o.TimeText : (o.Est() < 1 ? "< 1 мин" : DiagChooser.FmtTime(o.Est()));
                Rectangle tmr = new Rectangle(rr.Right - S(20) - timeW, rr.Y + S(16), timeW, st || sw == null ? titleH : segH);
                if (!st && sw != null) tmr.Y = rr.Y + (rr.Height - segH) / 2;
                DiagTheme.TextR(gg, t, F.fSemiS, tmr, o.On ? DiagTheme.Ink2 : DiagTheme.Ink4);
            }
            // длительность
            if (sw != null) {
                Rectangle sr = SegRect(rr, sw, segTot, segH, st, timeW, textX, descH, titleH);
                DrawSeg(gg, sr, o, sw);
            }
        };
        b.Click = delegate(Point p) {
            if (sw != null) {
                Rectangle sr = SegRect(r, sw, segTot, segH, st, timeW, textX, descH, titleH);
                if (sr.Contains(p)) {
                    int x = sr.X + S(4);
                    for (int i = 0; i < sw.Length; i++) {
                        if (p.X >= x && p.X < x + sw[i]) { F.PickCombo(o, i); return; }
                        x += sw[i];
                    }
                    return;
                }
            }
            F.Toggle(o);
        };
        return r.Bottom;
    }

    Rectangle SegRect(Rectangle rr, int[] sw, int segTot, int segH, bool stack, int timeW, int textX, int descH, int titleH) {
        if (stack) return new Rectangle(rr.X + textX, rr.Y + S(16) + titleH + S(2) + descH + S(10), segTot, segH);
        return new Rectangle(rr.Right - S(20) - timeW - S(16) - segTot, rr.Y + (rr.Height - segH) / 2, segTot, segH);
    }

    void DrawSeg(Graphics g, Rectangle sr, DiagChooser.Opt o, int[] sw) {
        DiagTheme.Fill(g, sr, sr.Height / 2f, DiagTheme.Bg);
        DiagTheme.Stroke(g, new RectangleF(sr.X + 0.5f, sr.Y + 0.5f, sr.Width - 1, sr.Height - 1), sr.Height / 2f, DiagTheme.Line, 1f);
        int x = sr.X + S(4);
        for (int i = 0; i < sw.Length; i++) {
            Rectangle cr = new Rectangle(x, sr.Y + S(4), sw[i], sr.Height - S(8));
            bool sel = i == o.Idx;
            bool hov = Hov(cr) && o.Enabled;
            if (sel) DiagTheme.Fill(g, cr, cr.Height / 2f, o.On ? DiagTheme.Ink : DiagTheme.LineHi);
            else if (hov) DiagTheme.Fill(g, cr, cr.Height / 2f, DiagTheme.Soft);
            Color c = sel ? (o.On ? Color.FromArgb(0x11, 0x11, 0x11) : DiagTheme.Ink2) : (hov ? DiagTheme.Ink : DiagTheme.Ink3);
            DiagTheme.TextC(g, o.Labels[i], F.fSemiS, cr, c);
            x += sw[i];
        }
    }

    void DrawToggle(Graphics g, Rectangle r, bool on, bool dim) {
        if (on) {
            if (dim) DiagTheme.Fill(g, r, r.Height / 2f, Color.FromArgb(0x6a, 0x1a, 0x18));
            else DiagTheme.FillAccent(g, r, r.Height / 2f, false);
        } else {
            DiagTheme.Fill(g, r, r.Height / 2f, DiagTheme.Soft);
            DiagTheme.Stroke(g, new RectangleF(r.X + 0.5f, r.Y + 0.5f, r.Width - 1, r.Height - 1), r.Height / 2f, DiagTheme.LineHi, 1f);
        }
        int d = r.Height - S(6);
        int kx = on ? r.Right - S(3) - d : r.X + S(3);
        using (SolidBrush b = new SolidBrush(on ? (dim ? DiagTheme.Ink3 : Color.White) : DiagTheme.Ink3)) g.FillEllipse(b, kx, r.Y + S(3), d, d);
    }

    int Note(Graphics g, int y, int kind, string text) {
        Color c = kind == 0 ? DiagTheme.Ink3 : kind == 1 ? DiagTheme.Warn : DiagTheme.Ok;
        int ix = S(52);
        int th = DiagTheme.WrapH(g, text, F.fBody, cw - ix - S(20));
        Rectangle r = new Rectangle(cx, y + S(4), cw, Math.Max(S(52), th + S(30)));
        AddBlk(r, delegate(Graphics gg, Rectangle rr) {
            DiagTheme.Fill(gg, rr, S(14), Color.FromArgb(kind == 0 ? 10 : 18, c));
            DiagTheme.Stroke(gg, new RectangleF(rr.X + 0.5f, rr.Y + 0.5f, rr.Width - 1, rr.Height - 1), S(14), Color.FromArgb(kind == 0 ? 40 : 70, c), 1f);
            Rectangle ic = new Rectangle(rr.X + S(16), rr.Y + S(15), S(22), S(22));
            using (Pen p = new Pen(c, Math.Max(1.3f, S(1.5)))) { gg.DrawEllipse(p, ic); }
            DiagGlyph.Draw(gg, kind == 2 ? 12 : 13, new RectangleF(ic.X + S(3), ic.Y + S(3), S(16), S(16)), c, Math.Max(1.3f, S(1.6)));
            DiagTheme.Wrap(gg, text, F.fBody, new Rectangle(rr.X + ix, rr.Y + S(15), rr.Width - ix - S(20), th + S(2)), DiagTheme.Ink2);
        }, null);
        return r.Bottom + S(12);
    }

    int Feature(Graphics g, int y, int glyph, Color c, string title, string text) {
        int ix = S(76);
        int th = DiagTheme.WrapH(g, text, F.fBody, cw - ix - S(24));
        Rectangle r = new Rectangle(cx, y, cw, Math.Max(S(84), S(18) + S(26) + th + S(18)));
        AddBlk(r, delegate(Graphics gg, Rectangle rr) {
            DiagTheme.Fill(gg, rr, S(16), DiagTheme.Panel);
            DiagTheme.Stroke(gg, new RectangleF(rr.X + 0.5f, rr.Y + 0.5f, rr.Width - 1, rr.Height - 1), S(16), DiagTheme.Line, 1f);
            Rectangle ic = new Rectangle(rr.X + S(20), rr.Y + S(18), S(40), S(40));
            DiagTheme.Fill(gg, ic, S(12), Color.FromArgb(28, c));
            DiagGlyph.Draw(gg, glyph, new RectangleF(ic.X + S(10), ic.Y + S(10), S(20), S(20)), c, Math.Max(1.4f, S(1.7)));
            DiagTheme.Text(gg, title, F.fH3, new Rectangle(rr.X + ix, rr.Y + S(16), rr.Width - ix - S(24), S(26)), DiagTheme.Ink);
            DiagTheme.Wrap(gg, text, F.fBody, new Rectangle(rr.X + ix, rr.Y + S(44), rr.Width - ix - S(24), th + S(2)), DiagTheme.Ink3);
        }, null);
        return r.Bottom + S(12);
    }

    int ModeCards(Graphics g, int y) {
        // порядок карточек: быстрая, полная, по жалобе, выборочная (номера режимов 0, 1, 3, 2)
        int[] modes = { 0, 1, 3, 2 };
        string[] titles = { "Быстрая", "Полная", "По жалобе", "Выборочная" };
        string[] descs = {
            "Все проверки с короткими стресс-тестами. Для приёмки и первичного осмотра.",
            "Долгие стресс-тесты, TestMem5, видеопамять и проверка Windows. Для плавающих неисправностей.",
            "Отметьте, на что жалуется клиент, — программа добавит нужные тесты и назовёт вероятную причину.",
            "Только отмеченные тесты со своей длительностью. Любое изменение в разделах включает этот режим." };
        string[][] bullets = {
            new string[] { "Стресс-тесты по 1–3 мин", "Тест ОЗУ, самотест SMART", "Журналы, сеть, периферия" },
            new string[] { "Стресс-тесты по 5–10 мин", "TestMem5, видеопамять", "DISM, SFC, CHKDSK" },
            new string[] { "Быстрая + тесты под жалобу", "Вероятные причины в отчёте", "Список жалоб — ниже" },
            new string[] { "Любой набор тестов", "Своя длительность каждого", "Настройка в разделах слева" } };
        int[] glyph = { 4, 14, 13, 0 };
        int n = 4, gap = S(16);
        int cols = cw >= S(1000) ? 4 : (cw >= S(520) ? 2 : 1);
        int w = (cw - (cols - 1) * gap) / cols;
        int descMax = 0;
        for (int i = 0; i < n; i++) descMax = Math.Max(descMax, DiagTheme.WrapH(g, descs[i], F.fBody, w - S(40)));
        int h = S(20) + S(40) + S(14) + S(28) + S(30) + S(8) + descMax + S(16) + 3 * S(24) + S(18);
        for (int i = 0; i < n; i++) {
            int idx = i, md = modes[i];
            Rectangle r = new Rectangle(cx + (i % cols) * (w + gap), y + (i / cols) * (h + gap), w, h);
            Blk b = AddBlk(r, null, delegate(Point p) { F.SetMode(md); });
            b.Live = true;
            b.Paint = delegate(Graphics gg, Rectangle rr) {
                bool sel = F.mode == md, hov = Hov(rr);
                DiagTheme.Fill(gg, rr, S(20), sel ? Color.FromArgb(0x1f, 0x14, 0x14) : (hov ? DiagTheme.PlateHi : DiagTheme.Panel));
                if (sel) {
                    using (GraphicsPath gp = DiagTheme.Round(rr, S(20)))
                    using (LinearGradientBrush lb = new LinearGradientBrush(new Rectangle(rr.X, rr.Y - 1, rr.Width, rr.Height + 2),
                               Color.FromArgb(0x34, 0x14, 0x12), Color.FromArgb(0x17, 0x14, 0x15), 90f)) gg.FillPath(lb, gp);
                    DiagTheme.Stroke(gg, new RectangleF(rr.X + 1, rr.Y + 1, rr.Width - 2, rr.Height - 2), S(20), DiagTheme.Accent, Math.Max(1.5f, S(2)));
                } else DiagTheme.Stroke(gg, new RectangleF(rr.X + 0.5f, rr.Y + 0.5f, rr.Width - 1, rr.Height - 1), S(20), hov ? DiagTheme.LineHi : DiagTheme.Line, 1f);
                int x = rr.X + S(20), yy = rr.Y + S(20);
                Rectangle ic = new Rectangle(x, yy, S(40), S(40));
                if (sel) DiagTheme.FillAccent(gg, ic, S(12), false); else DiagTheme.Fill(gg, ic, S(12), DiagTheme.Soft);
                DiagGlyph.Draw(gg, glyph[idx], new RectangleF(ic.X + S(10), ic.Y + S(10), S(20), S(20)), sel ? Color.White : DiagTheme.Ink2, Math.Max(1.4f, S(1.8)));
                // радио-индикатор
                Rectangle rd = new Rectangle(rr.Right - S(42), yy + S(9), S(22), S(22));
                if (sel) {
                    using (SolidBrush sb = new SolidBrush(DiagTheme.Accent)) gg.FillEllipse(sb, rd);
                    DiagGlyph.Draw(gg, 12, new RectangleF(rd.X + S(4), rd.Y + S(4), S(14), S(14)), Color.White, Math.Max(1.5f, S(2)));
                } else using (Pen p = new Pen(DiagTheme.LineHi, Math.Max(1.2f, S(1.5)))) gg.DrawEllipse(p, rd);
                yy += S(40) + S(14);
                DiagTheme.Text(gg, titles[idx], F.fH2, new Rectangle(x, yy, rr.Width - S(40), S(28)), DiagTheme.Ink);
                yy += S(28);
                double m = md >= 2 ? F.TotalMinutes() : F.PresetMinutes(md == 1);
                string tt = md == 2 && F.mode != 2 ? "свой набор" : (md == 3 && F.mode != 3 ? "под жалобу" : DiagChooser.FmtTime(m));
                DiagTheme.Text(gg, tt, F.fH3, new Rectangle(x, yy, rr.Width - S(40), S(30)), sel ? DiagTheme.AccentText : DiagTheme.Ink2);
                yy += S(30) + S(8);
                DiagTheme.Wrap(gg, descs[idx], F.fBody, new Rectangle(x, yy, rr.Width - S(40), descMax + S(2)), DiagTheme.Ink3);
                yy += descMax + S(16);
                foreach (string bl in bullets[idx]) {
                    DiagGlyph.Draw(gg, 12, new RectangleF(x, yy + S(4), S(14), S(14)), sel ? DiagTheme.AccentText : DiagTheme.Ink4, Math.Max(1.3f, S(1.6)));
                    DiagTheme.Text(gg, bl, F.fSmall, new Rectangle(x + S(22), yy, rr.Width - S(62), S(22)), DiagTheme.Ink2);
                    yy += S(24);
                }
            };
        }
        int rows = (n + cols - 1) / cols;
        return y + rows * h + (rows - 1) * gap + S(28);
    }

    // ---------- список жалоб (режим «По жалобе»)
    int ComplaintList(Graphics g, int y) {
        y = Section(g, y - S(8), "Жалобы клиента — отметьте одну или несколько");
        string[] items = DiagChooser.Complaints;
        if (items == null || items.Length == 0) {
            return Note(g, y, 1, "Список жалоб недоступен в этой версии — будет выполнена быстрая проверка.");
        }
        int cols = cw >= S(700) ? 2 : 1, gap = S(10);
        int w = (cw - (cols - 1) * gap) / cols, h = S(48);
        int i = 0;
        foreach (string raw in items) {
            string[] c = DiagChooser.ComplaintParts(raw);
            if (c[0].Length == 0) continue;
            string key = c[0], title = c[1].Length > 0 ? c[1] : c[0];
            Rectangle r = new Rectangle(cx + (i % cols) * (w + gap), y + (i / cols) * (h + gap), w, h);
            Blk b = AddBlk(r, null, delegate(Point p) { F.ToggleComplaint(key); });
            b.Live = true;
            b.Paint = delegate(Graphics gg, Rectangle rr) {
                bool on = F.complaintSel.Contains(key), hov = Hov(rr);
                DiagTheme.Fill(gg, rr, S(12), on ? Color.FromArgb(0x24, 0x15, 0x14) : (hov ? DiagTheme.PlateHi : DiagTheme.Panel));
                DiagTheme.Stroke(gg, new RectangleF(rr.X + 0.5f, rr.Y + 0.5f, rr.Width - 1, rr.Height - 1), S(12), on ? Color.FromArgb(0x7a, 0x22, 0x1e) : (hov ? DiagTheme.LineHi : DiagTheme.Line), 1f);
                Rectangle cb = new Rectangle(rr.X + S(16), rr.Y + (rr.Height - S(22)) / 2, S(22), S(22));
                if (on) {
                    DiagTheme.FillAccent(gg, cb, S(6), false);
                    DiagGlyph.Draw(gg, 12, new RectangleF(cb.X + S(4), cb.Y + S(4), S(14), S(14)), Color.White, Math.Max(1.6f, S(2.2)));
                } else {
                    DiagTheme.Fill(gg, cb, S(6), DiagTheme.Bg);
                    DiagTheme.Stroke(gg, new RectangleF(cb.X + 0.5f, cb.Y + 0.5f, cb.Width - 1, cb.Height - 1), S(6), DiagTheme.Ink4, Math.Max(1.2f, S(1.4)));
                }
                DiagTheme.Text(gg, title, on ? F.fSemiS : F.fBody, new Rectangle(rr.X + S(50), rr.Y, rr.Width - S(62), rr.Height), on ? DiagTheme.Ink : DiagTheme.Ink2);
            };
            i++;
        }
        int rows = (i + cols - 1) / cols;
        return y + rows * h + Math.Max(0, rows - 1) * gap + S(24);
    }

    // ---------- «Инструменты»
    int ToolCard(Graphics g, int y, int glyph, string title, string text, string btnText, ClickFn act) {
        int ix = S(76), bw = S(170);
        int th = DiagTheme.WrapH(g, text, F.fBody, cw - ix - bw - S(48));
        Rectangle r = new Rectangle(cx, y, cw, Math.Max(S(96), S(16) + S(26) + th + S(20)));
        Rectangle br = new Rectangle(r.Right - S(20) - bw, r.Y + (r.Height - S(40)) / 2, bw, S(40));
        Blk b = AddBlk(r, null, null);
        b.Live = true;
        b.Paint = delegate(Graphics gg, Rectangle rr) {
            DiagTheme.Fill(gg, rr, S(16), DiagTheme.Panel);
            DiagTheme.Stroke(gg, new RectangleF(rr.X + 0.5f, rr.Y + 0.5f, rr.Width - 1, rr.Height - 1), S(16), DiagTheme.Line, 1f);
            Rectangle ic = new Rectangle(rr.X + S(20), rr.Y + S(18), S(40), S(40));
            DiagTheme.Fill(gg, ic, S(12), Color.FromArgb(28, DiagTheme.AccentText));
            DiagGlyph.Draw(gg, glyph, new RectangleF(ic.X + S(10), ic.Y + S(10), S(20), S(20)), DiagTheme.AccentText, Math.Max(1.4f, S(1.7)));
            DiagTheme.Text(gg, title, F.fH3, new Rectangle(rr.X + ix, rr.Y + S(16), rr.Width - ix - bw - S(48), S(26)), DiagTheme.Ink);
            DiagTheme.Wrap(gg, text, F.fBody, new Rectangle(rr.X + ix, rr.Y + S(44), rr.Width - ix - bw - S(48), th + S(2)), DiagTheme.Ink3);
            bool hov = Hov(br);
            DiagTheme.Fill(gg, br, S(12), hov ? DiagTheme.PlateHi : DiagTheme.Soft);
            DiagTheme.Stroke(gg, new RectangleF(br.X + 0.5f, br.Y + 0.5f, br.Width - 1, br.Height - 1), S(12), hov ? DiagTheme.AccentText : DiagTheme.LineHi, 1f);
            DiagTheme.TextC(gg, btnText, F.fSemiS, br, hov ? DiagTheme.Ink : DiagTheme.Ink2);
        };
        AddBlk(br, null, act);
        return r.Bottom + S(12);
    }

    int Tools(Graphics g, int y) {
        y = Title(g, y, "Инструменты", "Служебные утилиты мастера. Запускаются в отдельном окне и не входят в диагностику.");
        y = ToolCard(g, y, 16, "Флешка MemTest86",
            "Записывает загрузочную флешку MemTest86 — самая надёжная проверка оперативной памяти вне Windows. Все данные на флешке будут стёрты.",
            "Создать флешку", delegate(Point p) { F.StartTool("memtest86usb", "Флешка MemTest86"); });
        y = ToolCard(g, y, 9, "Спасательная флешка WinPE",
            "Загрузочная флешка " + DiagTheme.AppName + " на WinPE — для компьютеров, где Windows не загружается: диагностика и спасение файлов. Понадобится Windows ADK (скачается).",
            "Создать флешку", delegate(Point p) { F.StartTool("rescueusb", "Спасательная флешка WinPE"); });
        y = ToolCard(g, y, 19, "Папка с отчётами",
            "Все сохранённые отчёты этой программы. Копии также лежат на Рабочем столе.",
            "Открыть папку", delegate(Point p) { F.OpenReports(); });
        y = ToolCard(g, y, 11, "История проверок",
            "Прежние диагностики этого компьютера — чтобы сравнить состояние с прошлым разом.",
            "Показать", delegate(Point p) { F.SelectTab(DiagChooser.TabHistory); });
        y = Section(g, y, "Удалённая диагностика");
        y = Rows(g, y, DiagChooser.TabTools);
        return y;
    }

    int CatTiles(Graphics g, int y) {
        int cols = cw >= S(600) ? 4 : 2;
        int gap = S(12);
        int w = (cw - (cols - 1) * gap) / cols, h = S(72);
        for (int i = 1; i <= 8; i++) {
            int cat = i;
            int col = (i - 1) % cols, row = (i - 1) / cols;
            Rectangle r = new Rectangle(cx + col * (w + gap), y + row * (h + gap), w, h);
            Blk b = AddBlk(r, null, delegate(Point p) { F.SelectTab(cat); });
            b.Live = true;
            b.Paint = delegate(Graphics gg, Rectangle rr) {
                bool hov = Hov(rr);
                int on, total; F.CatCount(cat, out on, out total);
                DiagTheme.Fill(gg, rr, S(14), hov ? DiagTheme.PlateHi : DiagTheme.Panel);
                DiagTheme.Stroke(gg, new RectangleF(rr.X + 0.5f, rr.Y + 0.5f, rr.Width - 1, rr.Height - 1), S(14), hov ? DiagTheme.LineHi : DiagTheme.Line, 1f);
                Color ic = on > 0 ? DiagTheme.AccentText : DiagTheme.Ink4;
                DiagGlyph.Draw(gg, cat, new RectangleF(rr.X + S(16), rr.Y + S(16), S(20), S(20)), ic, Math.Max(1.3f, S(1.6)));
                DiagTheme.Text(gg, DiagChooser.TabNames[cat], F.fSemiS, new Rectangle(rr.X + S(46), rr.Y + S(14), rr.Width - S(56), S(24)), DiagTheme.Ink);
                DiagTheme.Text(gg, on == 0 ? "не выбрано" : (on + " из " + total), F.fSmall, new Rectangle(rr.X + S(46), rr.Y + S(36), rr.Width - S(56), S(18)), on == 0 ? DiagTheme.Ink4 : DiagTheme.Ink3);
                Rectangle bar = new Rectangle(rr.X + S(16), rr.Bottom - S(12), rr.Width - S(32), S(3));
                DiagTheme.Fill(gg, bar, S(1.5), DiagTheme.Soft);
                if (on > 0 && total > 0) DiagTheme.Fill(gg, new Rectangle(bar.X, bar.Y, Math.Max(S(4), bar.Width * on / total), bar.Height), S(1.5), DiagTheme.Accent);
            };
        }
        return y + 2 * h + gap + (cols == 2 ? 2 * (h + gap) : 0) + S(8);
    }

    // ---------- «О программе» и справочные страницы
    int SubTabs(Graphics g, int y) {
        int h = S(34), gap = S(8), x = cx, rowY = y;
        for (int i = 0; i < DiagChooser.SubNames.Length; i++) {
            int si = i;
            int w = DiagTheme.TextW(g, DiagChooser.SubNames[i], F.fSemiS) + S(32);
            if (x + w > cx + cw) { x = cx; rowY += h + gap; }
            Blk b = AddBlk(new Rectangle(x, rowY, w, h), null, delegate(Point p) { F.SelectAbout(si); });
            b.Live = true;
            b.Paint = delegate(Graphics gg, Rectangle rr) {
                bool sel = F.sub == si, hov = Hov(rr);
                if (sel) DiagTheme.Fill(gg, rr, rr.Height / 2f, DiagTheme.Ink);
                else {
                    DiagTheme.Fill(gg, rr, rr.Height / 2f, hov ? DiagTheme.PlateHi : DiagTheme.Panel);
                    DiagTheme.Stroke(gg, new RectangleF(rr.X + 0.5f, rr.Y + 0.5f, rr.Width - 1, rr.Height - 1), rr.Height / 2f, hov ? DiagTheme.LineHi : DiagTheme.Line, 1f);
                }
                DiagTheme.TextC(gg, DiagChooser.SubNames[si], F.fSemiS, rr, sel ? Color.FromArgb(0x11, 0x11, 0x11) : (hov ? DiagTheme.Ink : DiagTheme.Ink2));
            };
            x += w + gap;
        }
        return rowY + h + S(24);
    }

    int H(Graphics g, int y, string text) {
        Rectangle r = new Rectangle(cx, y + S(6), cw, S(28));
        AddBlk(r, delegate(Graphics gg, Rectangle rr) { DiagTheme.Text(gg, text, F.fH3, rr, DiagTheme.Ink); }, null);
        return r.Bottom + S(6);
    }

    int P(Graphics g, int y, string text) {
        int w = Math.Min(cw, S(900));
        int th = DiagTheme.WrapH(g, text, F.fBody, w);
        Rectangle r = new Rectangle(cx, y, w, th);
        AddBlk(r, delegate(Graphics gg, Rectangle rr) { DiagTheme.Wrap(gg, text, F.fBody, new Rectangle(rr.X, rr.Y, rr.Width, rr.Height + S(2)), DiagTheme.Ink2); }, null);
        return r.Bottom + S(12);
    }

    int Bul(Graphics g, int y, string[] items) {
        int w = Math.Min(cw, S(900));
        foreach (string it in items) {
            int th = DiagTheme.WrapH(g, it, F.fBody, w - S(24));
            Rectangle r = new Rectangle(cx, y, w, th);
            string t = it;
            AddBlk(r, delegate(Graphics gg, Rectangle rr) {
                int lh = DiagTheme.WrapH(gg, "Ж", F.fBody, S(100));
                DiagTheme.Fill(gg, new RectangleF(rr.X + S(4), rr.Y + lh / 2f - S(3), S(6), S(6)), S(2), DiagTheme.Accent);
                DiagTheme.Wrap(gg, t, F.fBody, new Rectangle(rr.X + S(24), rr.Y, rr.Width - S(24), rr.Height + S(2)), DiagTheme.Ink2);
            }, null);
            y = r.Bottom + S(8);
        }
        return y + S(6);
    }

    int KeyVals(Graphics g, int y, string[][] kv) {
        int rowH = S(40);
        Rectangle box = new Rectangle(cx, y, cw, kv.Length * rowH + S(8));
        AddBlk(box, delegate(Graphics gg, Rectangle rr) {
            DiagTheme.Fill(gg, rr, S(16), DiagTheme.Panel);
            DiagTheme.Stroke(gg, new RectangleF(rr.X + 0.5f, rr.Y + 0.5f, rr.Width - 1, rr.Height - 1), S(16), DiagTheme.Line, 1f);
            for (int i = 0; i < kv.Length; i++) {
                int yy = rr.Y + S(4) + i * rowH;
                if (i > 0) using (Pen p = new Pen(DiagTheme.Line)) gg.DrawLine(p, rr.X + S(20), yy, rr.Right - S(20), yy);
                DiagTheme.Text(gg, kv[i][0], F.fBody, new Rectangle(rr.X + S(20), yy, S(170), rowH), DiagTheme.Ink3);
                DiagTheme.Text(gg, kv[i][1], F.fSemiS, new Rectangle(rr.X + S(200), yy, rr.Width - S(220), rowH), DiagTheme.Ink);
            }
        }, null);
        return box.Bottom + S(16);
    }

    int About(Graphics g, int y) {
        string app = DiagTheme.AppName;
        string brand = string.IsNullOrEmpty(DiagChooser.Brand) ? "Big Techno Club" : DiagChooser.Brand;
        y = Title(g, y, "О программе", app + " — " + DiagTheme.AppTagline + " с понятным отчётом для мастера и владельца.");
        y = SubTabs(g, y);
        switch (F.sub) {
            case 0: {
                y = P(g, y, app + " проверяет компьютер или ноутбук за один запуск: собирает сведения о железе, нагружает процессор, память, видеокарту, блок питания и диски, читает журналы Windows и формирует HTML-отчёт с итоговой оценкой и советами.");
                y = KeyVals(g, y, new string[][] {
                    new string[] { "Программа", app + (string.IsNullOrEmpty(DiagChooser.Version) ? "" : " v" + DiagChooser.Version) },
                    new string[] { "Отчёт", "Рабочий стол — HTML-файлы, открываются в любом браузере" },
                    new string[] { "Защита железа", "ТемпературныйНюхач — остановка тестов при аномалии датчиков" },
                    new string[] { "Разработка", brand + " · компьютерный сервис" } });
                y = Section(g, y, "Что проверяет программа");
                string[][] items = {
                    new string[] { "1", "Процессор и охлаждение", "нагрев, троттлинг, ошибки вычислений, вентиляторы" },
                    new string[] { "2", "Оперативная память", "битые ячейки, нестабильный разгон XMP / EXPO" },
                    new string[] { "3", "Видеокарта", "перегрев, артефакты, видеопамять, сбои драйвера" },
                    new string[] { "4", "Питание", "просадки и выключения под совместной нагрузкой" },
                    new string[] { "5", "Накопители", "SMART, скорость, поверхность, самотест" },
                    new string[] { "6", "Система и журналы", "синие экраны, сбои, автозагрузка, сеть" },
                    new string[] { "7", "Периферия", "клавиатура, мышь, экран, звук, микрофон, камера" },
                    new string[] { "8", "Обслуживание", "целостность Windows, вирусы, драйверы" } };
                int cols = cw >= S(720) ? 2 : 1, gap = S(10);
                int w = (cw - (cols - 1) * gap) / cols, h = S(62);
                for (int i = 0; i < items.Length; i++) {
                    string[] it = items[i];
                    Rectangle r = new Rectangle(cx + (i % cols) * (w + gap), y + (i / cols) * (h + gap), w, h);
                    AddBlk(r, delegate(Graphics gg, Rectangle rr) {
                        DiagTheme.Fill(gg, rr, S(14), DiagTheme.Panel);
                        Rectangle ic = new Rectangle(rr.X + S(14), rr.Y + S(13), S(36), S(36));
                        DiagTheme.Fill(gg, ic, S(10), DiagTheme.Soft);
                        DiagGlyph.Draw(gg, int.Parse(it[0], CultureInfo.InvariantCulture), new RectangleF(ic.X + S(9), ic.Y + S(9), S(18), S(18)), DiagTheme.AccentText, Math.Max(1.3f, S(1.6)));
                        DiagTheme.Text(gg, it[1], F.fSemiS, new Rectangle(rr.X + S(64), rr.Y + S(10), rr.Width - S(76), S(22)), DiagTheme.Ink);
                        DiagTheme.Text(gg, it[2], F.fSmall, new Rectangle(rr.X + S(64), rr.Y + S(32), rr.Width - S(76), S(18)), DiagTheme.Ink3);
                    }, null);
                }
                y += ((items.Length + cols - 1) / cols) * (h + gap) + S(8);
                break;
            }
            case 1:
                y = P(g, y, "После диагностики на Рабочем столе появляются два файла. Оба открываются в браузере и сохраняются в PDF кнопкой «Сохранить в PDF / печать».");
                y = Bul(g, y, new string[] {
                    "«Итог диагностики» — короткая страница для клиента: оценка, что проверено, что нужно сделать и конфигурация компьютера.",
                    "Подробный технический отчёт — все замеры, графики датчиков, таблицы и журналы для мастера." });
                y = H(g, y, "Итоговая оценка");
                y = P(g, y, "Оценка от 0 до 100 в цветном круге. Каждая серьёзная неисправность снижает её на 15 баллов, каждое замечание — на 5.");
                y = Legend(g, y, new Color[] { Color.FromArgb(0x1f, 0x9d, 0x55), Color.FromArgb(0x3b, 0x82, 0xf6), Color.FromArgb(0xd9, 0x8b, 0x00), Color.FromArgb(0xd6, 0x45, 0x45) },
                    new string[] { "90–100 · отличное состояние", "75–89 · хорошее, есть рекомендации", "50–74 · есть проблемы, требующие внимания", "0–49 · серьёзные проблемы" });
                y = H(g, y, "Цвета находок");
                y = Legend(g, y, new Color[] { DiagTheme.Crit, DiagTheme.Warn, DiagTheme.Ink3, DiagTheme.Ok },
                    new string[] { "Красный — неисправность: нужен ремонт или замена", "Жёлтый — требует внимания: стоит проверить или обслужить", "Серый — совет или справка, на оценку не влияет", "Зелёный — проверено, всё в порядке" });
                y = H(g, y, "Сравнение и история");
                y = P(g, y, "Если есть интернет, результаты тестов сравниваются с другими компьютерами в базе (в том числе той же модели), а при повторной диагностике того же ПК — с прошлыми визитами. Так видно, деградирует ли железо со временем.");
                break;
            case 2:
                if (!F.accepted) y = Note(g, y, 1, "Первый запуск: прочитайте условия и отметьте согласие внизу страницы — после этого станет доступна кнопка «Начать диагностику».");
                y = P(g, y, "Пожалуйста, прочитайте эти условия перед первым запуском. Запуская диагностику, вы соглашаетесь с ними.");
                y = Bul(g, y, new string[] {
                    app + " распространяется бесплатно для некоммерческого использования.",
                    "Программа и результаты диагностики предоставляются «как есть», без каких-либо гарантий. Отчёт — это помощь в поиске неисправностей, а не заключение сервисного центра.",
                    "Нагрузочные тесты (процессор, память, видеокарта, блок питания) сильно нагружают железо. Вы запускаете их на свой риск.",
                    "ТемпературныйНюхач снижает риск — останавливает тесты при перегреве и других аномалиях датчиков, — но не устраняет его полностью: датчики бывают неточными или отсутствуют.",
                    "Не запускайте стресс-тесты без присмотра на компьютере с известным перегревом, вздутыми конденсаторами или подозрением на неисправный блок питания.",
                    "Ноутбук тестируйте только с подключённым зарядным устройством.",
                    "Программа не изменяет и не удаляет файлы пользователя. Временные файлы тестов удаляются после завершения.",
                    "Перед установкой драйверов создаётся точка восстановления Windows.",
                    "BIOS / UEFI никогда не прошивается без вашего явного согласия: обновление прошивок выполняется только при отдельно включённом пункте «…и прошивки BIOS»." });
                y = AcceptRow(g, y);
                break;
            case 3:
                y = P(g, y, "Чтобы сравнивать компьютеры между собой и видеть историю одного ПК, копия отчёта отправляется в сервис статистики " + brand + ".");
                y = H(g, y, "Что отправляется");
                y = Bul(g, y, new string[] {
                    "Характеристики железа: процессор, плата, память, видеокарта, накопители, батарея.",
                    "Результаты проверок и замеры: баллы тестов, температуры, скорости, найденные неисправности.",
                    "Анонимный идентификатор компьютера — хеш (SHA-256) UUID материнской платы. По нему нельзя узнать владельца, но можно узнать тот же ПК при следующей диагностике." });
                y = H(g, y, "Что НЕ отправляется");
                y = Bul(g, y, new string[] {
                    "Личные файлы, документы, фотографии, история браузера.",
                    "Имена пользователей, пароли, ключи и учётные записи.",
                    "IP-адрес не показывается в отчётах." });
                y = H(g, y, "Зачем");
                y = Bul(g, y, new string[] {
                    "Статистика: какие неисправности встречаются чаще.",
                    "Сравнение с похожими компьютерами и той же моделью.",
                    "История и прогноз для того же ПК: деградирует ли диск, растёт ли температура." });
                y = H(g, y, "Как отключить");
                y = P(g, y, "Запускайте программу без интернета — отчёт останется только на Рабочем столе. Или задайте переменную окружения DIAG_NOSEND=1 перед запуском (например, в командной строке: set DIAG_NOSEND=1). Сравнение с базой и история при этом недоступны.");
                break;
            case 4:
                y = P(g, y, "Программа скачивает инструменты по мере необходимости — с официальных сайтов или с нашего зеркала (только неизменённые оригинальные файлы бесплатных и свободных программ) — и проверяет каждый файл по SHA-256. Все товарные знаки принадлежат их владельцам.");
                y = Licenses(g, y);
                break;
            case 5:
                y = P(g, y, "Эта программа не появилась бы без труда множества людей. Спасибо!");
                y = Bul(g, y, new string[] {
                    "Авторам инструментов: LibreHardwareMonitor, HWiNFO (REALiX), FurMark (Geeks3D), Prime95 (Mersenne Research / GIMPS), y-cruncher (Alexander J. Yee), Intel oneMKL, TestMem5 (Serj / CoolCmd), memtest_vulkan (GpuZelenograd), smartmontools, DiskSpd (Microsoft), 7-Zip (Igor Pavlov), BlueScreenView (NirSoft), CPU-Z (CPUID), Speedtest (Ookla), Snappy Driver Installer Origin, PawnIO (namazso).",
                    "anta777 и сообществу overclock.net — за конфигурации TestMem5 и методики проверки памяти.",
                    "Сообществам TechPowerUp, GIMPS, NirSoft и всем энтузиастам, которые годами собирают знания о железе и его неисправностях.",
                    "Команде " + brand + " — мастерам компьютерного сервиса, которые проверяли программу на реальных компьютерах клиентов." });
                break;
        }
        return y;
    }

    int Legend(Graphics g, int y, Color[] colors, string[] texts) {
        for (int i = 0; i < texts.Length; i++) {
            Color c = colors[i]; string t = texts[i];
            Rectangle r = new Rectangle(cx, y, cw, S(26));
            AddBlk(r, delegate(Graphics gg, Rectangle rr) {
                using (SolidBrush b = new SolidBrush(c)) gg.FillEllipse(b, rr.X + S(2), rr.Y + S(7), S(12), S(12));
                DiagTheme.Text(gg, t, F.fBody, new Rectangle(rr.X + S(24), rr.Y, rr.Width - S(24), rr.Height), DiagTheme.Ink2);
            }, null);
            y = r.Bottom + S(2);
        }
        return y + S(10);
    }

    int Licenses(Graphics g, int y) {
        string[][] t = {
            new string[] { "LibreHardwareMonitor", "MPL-2.0", "датчики температур, напряжений, частот" },
            new string[] { "HWiNFO", "freeware, некоммерч.", "© REALiX · датчики (резервный источник)" },
            new string[] { "FurMark 2", "freeware", "© Geeks3D · стресс-тест видеокарты" },
            new string[] { "Prime95", "free", "© Mersenne Research / GIMPS · стресс ЦП" },
            new string[] { "y-cruncher", "free, некоммерч.", "© Alexander J. Yee · вычисление π" },
            new string[] { "Intel oneMKL Linpack Benchmark", "Intel Simplified SL", "© Intel · максимальная нагрузка на ЦП" },
            new string[] { "TestMem5", "freeware", "© Serj / CoolCmd · конфигурации anta777" },
            new string[] { "memtest_vulkan", "zlib", "GpuZelenograd · тест видеопамяти" },
            new string[] { "smartmontools", "GPL-2.0-or-later", "SMART и самотест · исходники: smartmontools.org" },
            new string[] { "DiskSpd", "MIT", "© Microsoft · скорость дисков" },
            new string[] { "7-Zip", "LGPL", "© Igor Pavlov · распаковка, бенчмарк" },
            new string[] { "BlueScreenView", "freeware", "© NirSoft · разбор дампов синих экранов" },
            new string[] { "CPU-Z", "freeware", "© CPUID · сведения о процессоре и памяти" },
            new string[] { "Speedtest by Ookla CLI", "личное некоммерч.", "© Ookla · скорость интернета" },
            new string[] { "Snappy Driver Installer Origin", "GPL-3.0", "поиск и установка драйверов" },
            new string[] { "PawnIO", "драйвер датчиков", "namazso · доступ к датчикам процессора" } };
        int rowH = S(46);
        Rectangle box = new Rectangle(cx, y, cw, t.Length * rowH + S(8));
        AddBlk(box, delegate(Graphics gg, Rectangle rr) {
            DiagTheme.Fill(gg, rr, S(16), DiagTheme.Panel);
            DiagTheme.Stroke(gg, new RectangleF(rr.X + 0.5f, rr.Y + 0.5f, rr.Width - 1, rr.Height - 1), S(16), DiagTheme.Line, 1f);
            int c1 = Math.Min(S(260), rr.Width / 3), c2 = S(170);
            for (int i = 0; i < t.Length; i++) {
                int yy = rr.Y + S(4) + i * rowH;
                if (i > 0) using (Pen p = new Pen(DiagTheme.Line)) gg.DrawLine(p, rr.X + S(20), yy, rr.Right - S(20), yy);
                DiagTheme.Text(gg, t[i][0], F.fSemiS, new Rectangle(rr.X + S(20), yy, c1 - S(8), rowH), DiagTheme.Ink);
                int lw = Math.Min(c2 - S(12), DiagTheme.TextW(gg, t[i][1], F.fCap) + S(18));
                Rectangle lr = new Rectangle(rr.X + S(20) + c1, yy + (rowH - S(22)) / 2, lw, S(22));
                DiagTheme.Fill(gg, lr, lr.Height / 2f, DiagTheme.Soft);
                DiagTheme.TextC(gg, t[i][1], F.fCap, lr, DiagTheme.Ink2);
                DiagTheme.Text(gg, t[i][2], F.fSmall, new Rectangle(rr.X + S(20) + c1 + c2, yy, rr.Width - S(40) - c1 - c2, rowH), DiagTheme.Ink3);
            }
        }, null);
        return box.Bottom + S(16);
    }

    int AcceptRow(Graphics g, int y) {
        Rectangle r = new Rectangle(cx, y + S(8), cw, S(76));
        Blk b = AddBlk(r, null, delegate(Point p) { F.SetAccepted(!F.accepted); });
        b.Live = true;
        b.Paint = delegate(Graphics gg, Rectangle rr) {
            bool hov = Hov(rr), on = F.accepted;
            DiagTheme.Fill(gg, rr, S(16), on ? Color.FromArgb(0x14, 0x22, 0x19) : (hov ? DiagTheme.PlateHi : DiagTheme.Panel));
            DiagTheme.Stroke(gg, new RectangleF(rr.X + 1, rr.Y + 1, rr.Width - 2, rr.Height - 2), S(16), on ? Color.FromArgb(0x2c, 0x6e, 0x46) : DiagTheme.Accent, Math.Max(1.5f, S(1.5)));
            Rectangle cb = new Rectangle(rr.X + S(22), rr.Y + (rr.Height - S(26)) / 2, S(26), S(26));
            if (on) {
                DiagTheme.Fill(gg, cb, S(7), DiagTheme.Ok);
                DiagGlyph.Draw(gg, 12, new RectangleF(cb.X + S(5), cb.Y + S(5), S(16), S(16)), Color.FromArgb(0x0e, 0x0e, 0x10), Math.Max(1.8f, S(2.4)));
            } else {
                DiagTheme.Fill(gg, cb, S(7), DiagTheme.Bg);
                DiagTheme.Stroke(gg, cb, S(7), DiagTheme.Ink3, Math.Max(1.3f, S(1.5)));
            }
            DiagTheme.Text(gg, "Я прочитал(а) и принимаю условия", F.fSemi, new Rectangle(rr.X + S(64), rr.Y + S(14), rr.Width - S(84), S(26)), DiagTheme.Ink);
            DiagTheme.Text(gg, on ? "Спасибо! Можно начинать диагностику." : "Без согласия диагностику запустить нельзя. Отметка сохранится на этом компьютере.",
                F.fBody, new Rectangle(rr.X + S(64), rr.Y + S(40), rr.Width - S(84), S(22)), on ? DiagTheme.Ok : DiagTheme.Ink3);
        };
        return r.Bottom + S(12);
    }

    // ---------- отрисовка
    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = Prep(e);
        g.Clear(DiagTheme.Bg);
        if (builtW != Width || builtTab != F.tab) { Build(g); builtW = Width; builtTab = F.tab; }
        GraphicsState gs = g.Save();
        g.TranslateTransform(0, -scroll);
        Rectangle vis = new Rectangle(0, scroll, Width, Height);
        foreach (Blk b in blocks) if (b.Paint != null && b.R.IntersectsWith(vis)) b.Paint(g, b.R);
        g.Restore(gs);
        if (MaxScroll > 0) {
            Rectangle tr = Thumb();
            DiagTheme.Fill(g, tr, tr.Width / 2f, dragBar ? DiagTheme.Ink4 : DiagTheme.LineHi);
        }
    }

    Rectangle Thumb() {
        int track = Height - S(16);
        int th = Math.Max(S(40), (int)((long)track * Height / Math.Max(1, contentH)));
        int ty = S(8) + (int)((long)(track - th) * scroll / Math.Max(1, MaxScroll));
        return new Rectangle(Width - S(10), ty, S(6), th);
    }

    void ScrollTo(int v) {
        v = Math.Max(0, Math.Min(MaxScroll, v));
        if (v != scroll) { scroll = v; Invalidate(); }
    }

    protected override void OnMouseWheel(MouseEventArgs e) {
        if (CtrlWheel(e)) return;
        ScrollTo(scroll - e.Delta * S(64) / 120);
    }

    int HitBlk(Point cp) {
        for (int i = blocks.Count - 1; i >= 0; i--) if (blocks[i].R.Contains(cp)) return i;
        return -1;
    }

    protected override void OnMouseMove(MouseEventArgs e) {
        base.OnMouseMove(e);
        if (dragBar) {
            int track = Height - S(16), th = Thumb().Height;
            int pos = e.Y - dragOff - S(8);
            ScrollTo((int)((long)pos * MaxScroll / Math.Max(1, track - th)));
            return;
        }
        Point cp = new Point(e.X, e.Y + scroll);
        int hb = HitBlk(cp);
        bool needs = hb != hoverBlk || (hb >= 0 && blocks[hb].Live);
        mouse = cp;
        Cursor = hb >= 0 && blocks[hb].Click != null ? Cursors.Hand : Cursors.Default;
        if (needs) { hoverBlk = hb; Invalidate(); }
    }

    protected override void OnMouseLeave(EventArgs e) {
        base.OnMouseLeave(e);
        mouse = new Point(-1, -1); hoverBlk = -1; Invalidate();
    }

    protected override void OnMouseDown(MouseEventArgs e) {
        base.OnMouseDown(e);
        Focus();
        if (e.Button != MouseButtons.Left) return;
        if (MaxScroll > 0 && e.X >= Width - S(16)) {
            Rectangle t = Thumb();
            if (t.Contains(new Point(t.X, e.Y))) { dragBar = true; dragOff = e.Y - t.Y; Capture = true; }
            else ScrollTo(scroll + (e.Y < t.Y ? -Height : Height) * 3 / 4);
            Invalidate();
            return;
        }
        Point cp = new Point(e.X, e.Y + scroll);
        int hb = HitBlk(cp);
        if (hb >= 0 && blocks[hb].Click != null) blocks[hb].Click(cp);
    }

    protected override void OnMouseUp(MouseEventArgs e) {
        base.OnMouseUp(e);
        if (dragBar) { dragBar = false; Capture = false; Invalidate(); }
    }

    protected override bool IsInputKey(Keys keyData) {
        if (keyData == Keys.Up || keyData == Keys.Down || keyData == Keys.PageUp || keyData == Keys.PageDown) return true;
        return base.IsInputKey(keyData);
    }
    protected override void OnKeyDown(KeyEventArgs e) {
        base.OnKeyDown(e);
        if (e.KeyCode == Keys.Down) ScrollTo(scroll + S(48));
        else if (e.KeyCode == Keys.Up) ScrollTo(scroll - S(48));
        else if (e.KeyCode == Keys.PageDown) ScrollTo(scroll + Height * 3 / 4);
        else if (e.KeyCode == Keys.PageUp) ScrollTo(scroll - Height * 3 / 4);
        else if (e.KeyCode == Keys.Home) ScrollTo(0);
        else if (e.KeyCode == Keys.End) ScrollTo(MaxScroll);
    }
}

// ======================================================================
// Фирменные кнопки, диалоги, заставка и справка по клавишам.
// Диалоги заменяют консольные вопросы (body.ps1: AskYN, DiagUi.Ask).
// Владелец диалога — онлайн-окно DiagLive (если открыто), иначе экран под курсором.
// ======================================================================
public class DiagButton : Button {
    public int Kind;                       // 0 главная (красная), 1 обычная, 2 тихая
    public Color Back = DiagTheme.Panel;   // цвет под кнопкой (уголки)
    public float Radius = 10f;
    bool hov, down;
    public DiagButton() {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        FlatStyle = FlatStyle.Flat;
        FlatAppearance.BorderSize = 0;
        UseVisualStyleBackColor = false;
        Cursor = Cursors.Hand;
        ForeColor = DiagTheme.Ink;
        AccessibleRole = AccessibleRole.PushButton;
    }
    protected override void OnTextChanged(EventArgs e) { base.OnTextChanged(e); if (string.IsNullOrEmpty(AccessibleName) || AccessibleName == Text) AccessibleName = Text; Invalidate(); }
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
        float k = Math.Max(1f, g.DpiX / 96f);
        RectangleF r = new RectangleF(0.5f, 0.5f, Width - 1.5f, Height - 1.5f);
        float rad = Math.Min(Radius * k, r.Height / 2f);
        Color tc;
        if (!Enabled) { DiagTheme.Fill(g, r, rad, DiagTheme.Soft); tc = DiagTheme.Ink4; }
        else if (Kind == 0) {
            if (down) DiagTheme.Fill(g, r, rad, DiagTheme.AccentLo); else DiagTheme.FillAccent(g, r, rad, hov);
            tc = Color.White;
        } else if (Kind == 1) {
            DiagTheme.Fill(g, r, rad, down ? DiagTheme.LineHi : (hov ? DiagTheme.PlateHi : DiagTheme.Soft));
            DiagTheme.Stroke(g, r, rad, hov ? DiagTheme.Ink4 : DiagTheme.LineHi, 1f);
            tc = hov ? DiagTheme.Ink : DiagTheme.Ink2;
        } else {
            if (hov || down) DiagTheme.Fill(g, r, rad, down ? DiagTheme.LineHi : DiagTheme.PlateHi);
            tc = hov ? DiagTheme.Ink : DiagTheme.Ink3;
        }
        if (Focused && ShowFocusCues && Enabled) {
            float d = 2.5f * k;
            DiagTheme.Stroke(g, new RectangleF(r.X + d, r.Y + d, r.Width - 2 * d, r.Height - 2 * d), Math.Max(2f, rad - d),
                Kind == 0 ? Color.FromArgb(200, 255, 255, 255) : DiagTheme.AccentText, Math.Max(1f, 1.2f * k));
        }
        TextRenderer.DrawText(g, Text, Font, new Rectangle(0, 0, Width, Height), tc,
            TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix);
    }
}

public class DiagDialog : Form {
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out WinRect r);
    [DllImport("user32.dll")] static extern bool ReleaseCapture();
    [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr h, int msg, IntPtr w, IntPtr l);
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int val, int size);
    [StructLayout(LayoutKind.Sequential)] struct WinRect { public int L, T, R, B; }

    class HwndOwner : IWin32Window {
        readonly IntPtr h;
        public HwndOwner(IntPtr x) { h = x; }
        public IntPtr Handle { get { return h; } }
    }

    // Окно онлайн-диагностики (класс DiagLive компилируется отдельно — ищем через отражение)
    internal static IntPtr LiveHandle() {
        try {
            foreach (System.Reflection.Assembly a in AppDomain.CurrentDomain.GetAssemblies()) {
                Type t = null;
                try { t = a.GetType("DiagLive", false); } catch (Exception) { }
                if (t == null) continue;
                System.Reflection.PropertyInfo pi = t.GetProperty("FormHandle", System.Reflection.BindingFlags.Public | System.Reflection.BindingFlags.Static);
                if (pi == null) continue;
                object v = pi.GetValue(null, null);
                if (v is IntPtr) return (IntPtr)v;
            }
        } catch (Exception) { }
        return IntPtr.Zero;
    }

    readonly string title, text;
    readonly int kind;
    int result = -1;
    readonly float k;
    readonly Font fT, fB, fC;
    readonly int pad, iconS, textX, textW, titleH, bodyH, top;
    TextBox box;

    int S(double v) { return (int)Math.Round(v * k); }

    DiagDialog(string title, string text, string[] buttons, int kind, int def, int cancel) {
        this.title = title ?? "";
        this.text = (text ?? "").Replace("\r\n", "\n").Replace("\n", "\r\n");
        this.kind = kind;
        k = 1f;
        try { using (Graphics g0 = CreateGraphics()) k = Math.Max(1f, g0.DpiX / 96f); } catch (Exception) { }
        AutoScaleMode = AutoScaleMode.None;
        FormBorderStyle = FormBorderStyle.None;
        StartPosition = FormStartPosition.Manual;
        TopMost = true;
        KeyPreview = true;
        DoubleBuffered = true;
        BackColor = DiagTheme.Panel;
        ForeColor = DiagTheme.Ink;
        Text = string.IsNullOrEmpty(this.title) ? DiagTheme.AppName : this.title;
        AccessibleName = Text;
        AccessibleDescription = this.text;
        if (DiagChooser.AppIcon != null) Icon = DiagChooser.AppIcon;
        fT = DiagTheme.Head(12.5f); fB = DiagTheme.Body(10f); fC = DiagTheme.Semi(8f);
        Font = DiagTheme.Semi(10f);

        int W = S(540);
        pad = S(26); iconS = S(40);
        textX = pad + iconS + S(16);
        textW = W - textX - pad;
        using (Graphics g = CreateGraphics()) {
            titleH = Math.Max(S(24), DiagTheme.WrapH(g, this.title, fT, textW));
            bodyH = DiagTheme.WrapH(g, this.text, fB, textW);
            if (bodyH > S(300) || this.text.Length > 900) {
                W = S(680); textW = W - textX - pad;
                titleH = Math.Max(S(24), DiagTheme.WrapH(g, this.title, fT, textW));
                bodyH = S(280);
                box = new TextBox();
                box.Multiline = true; box.ReadOnly = true; box.ScrollBars = ScrollBars.Vertical; box.WordWrap = true;
                box.BorderStyle = BorderStyle.None; box.BackColor = DiagTheme.Bg; box.ForeColor = DiagTheme.Ink2;
                box.Font = new Font("Consolas", 9f); box.Text = this.text; box.TabStop = true;
            }
        }
        top = S(56);
        int contentH = Math.Max(iconS, titleH + (this.text.Length > 0 ? S(8) + bodyH : 0));
        int btnH = S(40), btnY = top + contentH + S(26);
        int H = btnY + btnH + S(22);
        ClientSize = new Size(W, H);
        if (box != null) { box.Bounds = new Rectangle(textX + S(8), top + titleH + S(16), textW - S(16), bodyH - S(16)); Controls.Add(box); }

        int x = W - pad;
        DiagButton[] bs = new DiagButton[buttons.Length];
        for (int i = buttons.Length - 1; i >= 0; i--) {
            DiagButton b = new DiagButton();
            b.Text = buttons[i];
            b.Font = Font;
            b.Kind = i == 0 ? 0 : 1;
            b.Back = DiagTheme.Panel;
            int bw;
            using (Graphics g = CreateGraphics()) bw = Math.Max(S(112), DiagTheme.TextW(g, buttons[i], Font) + S(40));
            x -= bw;
            b.Bounds = new Rectangle(x, btnY, bw, btnH);
            x -= S(10);
            int idx = i;
            b.Click += delegate { result = idx; DialogResult = DialogResult.OK; Close(); };
            bs[i] = b;
            Controls.Add(b);
        }
        for (int i = 0; i < bs.Length; i++) bs[i].TabIndex = i;
        if (def >= 0 && def < bs.Length) { AcceptButton = bs[def]; ActiveControl = bs[def]; }
        if (cancel >= 0 && cancel < bs.Length) CancelButton = bs[cancel];
    }

    protected override CreateParams CreateParams {
        get { CreateParams cp = base.CreateParams; cp.ClassStyle |= 0x20000; return cp; }   // тень
    }

    protected override void OnHandleCreated(EventArgs e) {
        base.OnHandleCreated(e);
        try { int round = 2; DwmSetWindowAttribute(Handle, 33, ref round, 4); } catch (Exception) { }
    }

    protected override void OnShown(EventArgs e) {
        base.OnShown(e);
        try { Activate(); if (ActiveControl != null) ActiveControl.Focus(); } catch (Exception) { }
    }

    protected override bool ProcessCmdKey(ref Message msg, Keys keyData) {
        if (keyData == Keys.Escape && CancelButton == null) { result = -1; DialogResult = DialogResult.Cancel; Close(); return true; }
        if (keyData == (Keys.Control | Keys.C) && (box == null || !box.Focused)) {
            try { Clipboard.SetText(title + "\r\n\r\n" + text); } catch (Exception) { }
            return true;
        }
        return base.ProcessCmdKey(ref msg, keyData);
    }

    protected override void OnMouseDown(MouseEventArgs e) {
        base.OnMouseDown(e);
        if (e.Button == MouseButtons.Left) { try { ReleaseCapture(); SendMessage(Handle, 0xA1, (IntPtr)2, IntPtr.Zero); } catch (Exception) { } }
    }

    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.Clear(DiagTheme.Panel);
        // шапка: логотип и название программы
        using (SolidBrush b = new SolidBrush(DiagTheme.Accent)) g.FillRectangle(b, 0, 0, Width, S(3));
        DiagGlyph.Logo(g, new RectangleF(pad, S(16), S(22), S(22)));
        DiagTheme.Text(g, DiagTheme.AppName, fC, new Rectangle(pad + S(30), S(16), S(300), S(22)), DiagTheme.Ink3);
        using (Pen p = new Pen(DiagTheme.Line)) g.DrawLine(p, pad, S(46), Width - pad, S(46));
        // значок
        Color kc = kind == 0 ? DiagTheme.AccentText : kind == 1 ? DiagTheme.Ink2 : kind == 2 ? DiagTheme.Warn : kind == 3 ? DiagTheme.Crit : DiagTheme.Ok;
        Rectangle ic = new Rectangle(pad, top, iconS, iconS);
        using (SolidBrush b = new SolidBrush(Color.FromArgb(36, kc))) g.FillEllipse(b, ic);
        float lw = Math.Max(1.8f, S(2.2));
        using (Pen p = new Pen(kc, lw)) {
            p.StartCap = LineCap.Round; p.EndCap = LineCap.Round;
            float cx = ic.X + ic.Width / 2f, cy = ic.Y + ic.Height / 2f, s = ic.Width;
            if (kind == 0) {
                g.DrawArc(p, cx - s * 0.13f, cy - s * 0.27f, s * 0.26f, s * 0.24f, 180, 250);
                g.DrawLine(p, cx + s * 0.02f, cy - s * 0.02f, cx, cy + s * 0.08f);
                using (SolidBrush b = new SolidBrush(kc)) g.FillEllipse(b, cx - s * 0.045f, cy + s * 0.17f, s * 0.09f, s * 0.09f);
            } else if (kind == 1) {
                g.DrawLine(p, cx, cy - s * 0.04f, cx, cy + s * 0.2f);
                using (SolidBrush b = new SolidBrush(kc)) g.FillEllipse(b, cx - s * 0.045f, cy - s * 0.24f, s * 0.09f, s * 0.09f);
            } else if (kind == 2) {
                g.DrawLine(p, cx, cy - s * 0.22f, cx, cy + s * 0.06f);
                using (SolidBrush b = new SolidBrush(kc)) g.FillEllipse(b, cx - s * 0.045f, cy + s * 0.14f, s * 0.09f, s * 0.09f);
            } else if (kind == 3) {
                g.DrawLine(p, cx - s * 0.15f, cy - s * 0.15f, cx + s * 0.15f, cy + s * 0.15f);
                g.DrawLine(p, cx - s * 0.15f, cy + s * 0.15f, cx + s * 0.15f, cy - s * 0.15f);
            } else DiagGlyph.Draw(g, 12, new RectangleF(ic.X + s * 0.22f, ic.Y + s * 0.22f, s * 0.56f, s * 0.56f), kc, lw);
        }
        DiagTheme.Wrap(g, title, fT, new Rectangle(textX, top + S(6), textW, titleH + S(4)), DiagTheme.Ink);
        if (box != null) DiagTheme.Fill(g, new RectangleF(textX, top + titleH + S(8), textW, bodyH), S(8), DiagTheme.Bg);
        else if (text.Length > 0) DiagTheme.Wrap(g, text, fB, new Rectangle(textX, top + titleH + S(14), textW, bodyH + S(4)), DiagTheme.Ink2);
        DiagTheme.Stroke(g, new RectangleF(0.5f, 0.5f, Width - 1, Height - 1), 0f, DiagTheme.LineHi, 1f);
    }

    // Показать диалог: владелец — указанное окно, иначе окно DiagLive, иначе экран под курсором
    internal static int Run(IWin32Window owner, string title, string text, string[] buttons, int kind, int def, int cancel) {
        try {
            using (DiagDialog d = new DiagDialog(title, text, buttons, kind, def, cancel)) {
                Rectangle area = Rectangle.Empty;
                IntPtr oh = owner != null ? owner.Handle : LiveHandle();
                WinRect rc;
                bool useOwner = oh != IntPtr.Zero && IsWindowVisible(oh) && !IsIconic(oh) && GetWindowRect(oh, out rc) && (area = Rectangle.FromLTRB(rc.L, rc.T, rc.R, rc.B)).Width > 0;
                if (!useOwner) area = Screen.FromPoint(Cursor.Position).WorkingArea;
                Rectangle wa = Screen.FromRectangle(area).WorkingArea;
                int x = area.X + (area.Width - d.Width) / 2, y = area.Y + (area.Height - d.Height) / 2;
                x = Math.Max(wa.X, Math.Min(x, wa.Right - d.Width)); y = Math.Max(wa.Y, Math.Min(y, wa.Bottom - d.Height));
                d.Location = new Point(x, y);
                d.ShowInTaskbar = !useOwner;
                if (useOwner) d.ShowDialog(owner != null ? owner : new HwndOwner(oh)); else d.ShowDialog();
                return d.result;
            }
        } catch (Exception) {
            DialogResult r = MessageBox.Show(text, title, buttons.Length > 1 ? MessageBoxButtons.YesNo : MessageBoxButtons.OK);
            return (r == DialogResult.Yes || r == DialogResult.OK) ? 0 : 1;
        }
    }

    public static bool Ask(string title, string text, string yes, string no) { return Run(null, title, text, new string[] { yes, no }, 0, 0, 1) == 0; }
    public static bool Ask(string title, string text, string yes, string no, bool defaultYes) { return Run(null, title, text, new string[] { yes, no }, 0, defaultYes ? 0 : 1, 1) == 0; }
    public static void Info(string title, string text) { Run(null, title, text, new string[] { "OK" }, 1, 0, 0); }
    public static void Warning(string title, string text) { Run(null, title, text, new string[] { "OK" }, 2, 0, 0); }
    public static void Error(string title, string text) { Run(null, title, text, new string[] { "Закрыть" }, 3, 0, 0); }
    // Выбор из нескольких вариантов: индекс кнопки, -1 — закрыли (Esc)
    public static int Choice(string title, string text, string[] options) { return Run(null, title, text, options, 0, 0, -1); }
    public static int ChoiceOn(IWin32Window owner, string title, string text, string[] options) { return Run(owner, title, text, options, 0, 0, -1); }
    public static bool AskOn(IWin32Window owner, string title, string text, string yes, string no) { return Run(owner, title, text, new string[] { yes, no }, 0, 0, 1) == 0; }
    public static void InfoOn(IWin32Window owner, string title, string text) { Run(owner, title, text, new string[] { "OK" }, 1, 0, 0); }
}

// Справка по горячим клавишам (F1): строки { "клавиши", "что делает" }
public class DiagHelpForm : Form {
    readonly string title;
    readonly string[][] rows;
    readonly float k;
    readonly Font fT, fK, fD;
    int S(double v) { return (int)Math.Round(v * k); }

    DiagHelpForm(string title, string[][] rows) {
        this.title = title; this.rows = rows;
        k = 1f;
        try { using (Graphics g0 = CreateGraphics()) k = Math.Max(1f, g0.DpiX / 96f); } catch (Exception) { }
        AutoScaleMode = AutoScaleMode.None;
        FormBorderStyle = FormBorderStyle.None; StartPosition = FormStartPosition.Manual; ShowInTaskbar = false;
        KeyPreview = true; DoubleBuffered = true; TopMost = true; BackColor = DiagTheme.Panel;
        Text = title; AccessibleName = title;
        fT = DiagTheme.Head(13f); fK = DiagTheme.Semi(9f); fD = DiagTheme.Body(9.5f);
        ClientSize = new Size(S(560), S(92) + rows.Length * S(34) + S(40));
        System.Text.StringBuilder sb = new System.Text.StringBuilder();
        foreach (string[] r in rows) sb.Append(r[0]).Append(" — ").Append(r[1]).Append("; ");
        AccessibleDescription = sb.ToString();
    }
    protected override CreateParams CreateParams { get { CreateParams cp = base.CreateParams; cp.ClassStyle |= 0x20000; return cp; } }
    protected override void OnKeyDown(KeyEventArgs e) { base.OnKeyDown(e); Close(); }
    protected override void OnMouseDown(MouseEventArgs e) { base.OnMouseDown(e); Close(); }
    protected override void OnDeactivate(EventArgs e) { base.OnDeactivate(e); try { Close(); } catch (Exception) { } }
    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.Clear(DiagTheme.Panel);
        using (SolidBrush b = new SolidBrush(DiagTheme.Accent)) g.FillRectangle(b, 0, 0, Width, S(3));
        DiagGlyph.Logo(g, new RectangleF(S(26), S(22), S(30), S(30)));
        DiagTheme.Text(g, title, fT, new Rectangle(S(68), S(20), Width - S(90), S(34)), DiagTheme.Ink);
        int y = S(72);
        foreach (string[] r in rows) {
            int x = S(26);
            foreach (string key in r[0].Split(new string[] { " / " }, StringSplitOptions.None)) {
                int w = DiagTheme.TextW(g, key, fK) + S(18);
                Rectangle kr = new Rectangle(x, y + S(4), w, S(24));
                DiagTheme.Fill(g, kr, S(6), DiagTheme.Soft);
                DiagTheme.Stroke(g, new RectangleF(kr.X + 0.5f, kr.Y + 0.5f, kr.Width - 1, kr.Height - 1), S(6), DiagTheme.LineHi, 1f);
                DiagTheme.TextC(g, key, fK, kr, DiagTheme.Ink);
                x += w + S(6);
            }
            DiagTheme.Text(g, r[1], fD, new Rectangle(Math.Max(x + S(8), S(230)), y, Width - Math.Max(x + S(8), S(230)) - S(20), S(32)), DiagTheme.Ink2);
            y += S(34);
        }
        DiagTheme.Text(g, "Любая клавиша или щелчок — закрыть", fD, new Rectangle(S(26), Height - S(38), Width - S(52), S(24)), DiagTheme.Ink4);
        DiagTheme.Stroke(g, new RectangleF(0.5f, 0.5f, Width - 1, Height - 1), 0f, DiagTheme.LineHi, 1f);
    }
    public static void ShowFor(IWin32Window owner, Rectangle ownerBounds, string title, string[][] rows) {
        using (DiagHelpForm f = new DiagHelpForm(title, rows)) {
            Rectangle a = ownerBounds.Width > 0 ? ownerBounds : Screen.FromPoint(Cursor.Position).WorkingArea;
            f.Location = new Point(a.X + (a.Width - f.Width) / 2, a.Y + Math.Max(0, (a.Height - f.Height) / 2));
            if (owner != null) f.ShowDialog(owner); else f.ShowDialog();
        }
    }
}

// Заставка на время запуска (проверка обновлений, сбор сведений), в своём потоке
public static class DiagSplash {
    static DcSplash form;
    static readonly object lk = new object();
    static string text = "";
    public static void Show(string t) {
        lock (lk) { text = t ?? ""; if (form != null) return; }
        System.Threading.ManualResetEvent ev = new System.Threading.ManualResetEvent(false);
        System.Threading.Thread th = new System.Threading.Thread(new System.Threading.ThreadStart(delegate() {
            try {
                DcSplash f = new DcSplash();
                lock (lk) form = f;
                f.Shown += delegate { ev.Set(); };
                Application.Run(f);
            } catch (Exception) {
            } finally { lock (lk) form = null; ev.Set(); }
        }));
        th.SetApartmentState(System.Threading.ApartmentState.STA);
        th.IsBackground = true;
        th.Start();
        ev.WaitOne(3000);
    }
    public static void SetText(string t) { lock (lk) text = t ?? ""; }
    internal static string Current { get { lock (lk) return text; } }
    public static void Close() {
        DcSplash f;
        lock (lk) f = form;
        if (f == null) return;
        try { f.BeginInvoke(new MethodInvoker(delegate { try { f.Close(); } catch (Exception) { } })); } catch (Exception) { }
    }
}

internal class DcSplash : Form {
    readonly float k;
    readonly Font fT, fS, fB;
    readonly Timer tm;
    int phase;
    int S(double v) { return (int)Math.Round(v * k); }
    public DcSplash() {
        k = 1f;
        try { using (Graphics g0 = CreateGraphics()) k = Math.Max(1f, g0.DpiX / 96f); } catch (Exception) { }
        AutoScaleMode = AutoScaleMode.None;
        FormBorderStyle = FormBorderStyle.None; StartPosition = FormStartPosition.CenterScreen;
        ShowInTaskbar = true; TopMost = true; DoubleBuffered = true; BackColor = DiagTheme.Panel;
        Text = DiagTheme.AppName;
        if (DiagChooser.AppIcon != null) Icon = DiagChooser.AppIcon;
        fT = DiagTheme.Head(17f); fS = DiagTheme.Body(9f); fB = DiagTheme.Body(9.5f);
        ClientSize = new Size(S(460), S(176));
        tm = new Timer(); tm.Interval = 40;
        tm.Tick += delegate { phase++; Invalidate(); };
        tm.Start();
    }
    protected override CreateParams CreateParams { get { CreateParams cp = base.CreateParams; cp.ClassStyle |= 0x20000; return cp; } }
    protected override void OnFormClosed(FormClosedEventArgs e) { tm.Stop(); base.OnFormClosed(e); }
    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.Clear(DiagTheme.Panel);
        DiagGlyph.Logo(g, new RectangleF(S(30), S(32), S(60), S(60)));
        DiagTheme.Text(g, DiagTheme.AppName, fT, new Rectangle(S(108), S(34), Width - S(130), S(34)), DiagTheme.Ink);
        string tag = DiagTheme.AppTagline;
        if (tag.Length > 0) tag = char.ToUpper(tag[0]) + tag.Substring(1);
        DiagTheme.Text(g, tag, fS, new Rectangle(S(108), S(68), Width - S(130), S(22)), DiagTheme.Ink3);
        DiagTheme.Text(g, DiagSplash.Current, fB, new Rectangle(S(30), S(118), Width - S(60), S(24)), DiagTheme.Ink2);
        Rectangle tr = new Rectangle(S(30), S(150), Width - S(60), S(4));
        DiagTheme.Fill(g, tr, S(2), DiagTheme.Soft);
        int segW = tr.Width / 4;
        int pos = (int)((phase * S(6)) % (tr.Width + segW)) - segW;
        Rectangle seg = Rectangle.Intersect(tr, new Rectangle(tr.X + pos, tr.Y, segW, tr.Height));
        if (seg.Width > 0) DiagTheme.Fill(g, seg, S(2), DiagTheme.Accent);
        DiagTheme.Stroke(g, new RectangleF(0.5f, 0.5f, Width - 1, Height - 1), 0f, DiagTheme.LineHi, 1f);
    }
}

// Сохранение размеров и положения окон: HKCU\Software\BigTechoTest\Windows
public static class DiagWinCfg {
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
    public static float GetF(string name, float def, float min, float max) {
        float v;
        if (!float.TryParse(Get(name, ""), NumberStyles.Float, CultureInfo.InvariantCulture, out v)) return def;
        return Math.Max(min, Math.Min(max, v));
    }
    public static void SetF(string name, float v) { Set(name, v.ToString("0.##", CultureInfo.InvariantCulture)); }
    // прямоугольник «x,y,w,h», только если заметная часть видна на одном из экранов
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
                Rectangle wa = s.WorkingArea;
                if (r.Width > wa.Width) r.Width = wa.Width;
                if (r.Height > wa.Height) r.Height = wa.Height;
                return true;
            }
        }
        return false;
    }
    public static void SetRect(string name, Rectangle r) {
        Set(name, string.Format(CultureInfo.InvariantCulture, "{0},{1},{2},{3}", r.X, r.Y, r.Width, r.Height));
    }
}
