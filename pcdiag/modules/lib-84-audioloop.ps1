# Звук: петля динамик -> микрофон. Ключ выбора и компиляция помощника (winmm waveOut/waveIn, C# 5).
# Тест только с участием пользователя (нужно подтверждение, громкость, тишина) — в автоматическом режиме пропускается.
$STEPKEYS['Звук: проверка динамиков микрофоном'] = 'audioloop'
$G.PresetHooks.Add({ param($full) $G.Sel.audioloop = $true })

function Ensure-AudioLoop {
    if ('DiagAudioLoop' -as [type]) { return $true }
    try { Add-Type -TypeDefinition $script:AudioLoopCs -Language CSharp -ErrorAction Stop; return $true }
    catch { $G.Log.Add('AudioLoop compile: ' + $_.Exception.Message); return $false }
}

$script:AudioLoopCs = @'
using System;
using System.Runtime.InteropServices;
using System.Threading;

public static class DiagAudioLoop {
    public const int Rate = 44100;
    public static string LastError = "";

    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    struct WAVEFORMATEX { public ushort wFormatTag; public ushort nChannels; public uint nSamplesPerSec; public uint nAvgBytesPerSec; public ushort nBlockAlign; public ushort wBitsPerSample; public ushort cbSize; }
    [StructLayout(LayoutKind.Sequential)]
    struct WAVEHDR { public IntPtr lpData; public uint dwBufferLength; public uint dwBytesRecorded; public IntPtr dwUser; public uint dwFlags; public uint dwLoops; public IntPtr lpNext; public IntPtr reserved; }

    [DllImport("winmm.dll")] static extern int waveInOpen(out IntPtr h, uint dev, ref WAVEFORMATEX f, IntPtr cb, IntPtr inst, uint flags);
    [DllImport("winmm.dll")] static extern int waveInPrepareHeader(IntPtr h, IntPtr hdr, int size);
    [DllImport("winmm.dll")] static extern int waveInUnprepareHeader(IntPtr h, IntPtr hdr, int size);
    [DllImport("winmm.dll")] static extern int waveInAddBuffer(IntPtr h, IntPtr hdr, int size);
    [DllImport("winmm.dll")] static extern int waveInStart(IntPtr h);
    [DllImport("winmm.dll")] static extern int waveInStop(IntPtr h);
    [DllImport("winmm.dll")] static extern int waveInReset(IntPtr h);
    [DllImport("winmm.dll")] static extern int waveInClose(IntPtr h);
    [DllImport("winmm.dll")] static extern int waveOutOpen(out IntPtr h, uint dev, ref WAVEFORMATEX f, IntPtr cb, IntPtr inst, uint flags);
    [DllImport("winmm.dll")] static extern int waveOutPrepareHeader(IntPtr h, IntPtr hdr, int size);
    [DllImport("winmm.dll")] static extern int waveOutUnprepareHeader(IntPtr h, IntPtr hdr, int size);
    [DllImport("winmm.dll")] static extern int waveOutWrite(IntPtr h, IntPtr hdr, int size);
    [DllImport("winmm.dll")] static extern int waveOutReset(IntPtr h);
    [DllImport("winmm.dll")] static extern int waveOutClose(IntPtr h);

    const uint WAVE_MAPPER = 0xFFFFFFFF;
    const uint WHDR_DONE = 1;

    static WAVEFORMATEX Fmt(int ch) {
        WAVEFORMATEX f = new WAVEFORMATEX();
        f.wFormatTag = 1; f.nChannels = (ushort)ch; f.nSamplesPerSec = Rate; f.wBitsPerSample = 16;
        f.nBlockAlign = (ushort)(ch * 2); f.nAvgBytesPerSec = (uint)(Rate * ch * 2); f.cbSize = 0;
        return f;
    }

    static bool Done(IntPtr hdr) {
        WAVEHDR h = (WAVEHDR)Marshal.PtrToStructure(hdr, typeof(WAVEHDR));
        return (h.dwFlags & WHDR_DONE) != 0;
    }

    // Воспроизводит стерео (interleaved L,R) через устройство вывода по умолчанию и одновременно пишет
    // микрофон по умолчанию (моно). Запись: preMs тишины до звука + длительность звука + tailMs хвоста.
    // Возвращает моно-запись (16 бит, 44100) или null (причина в LastError).
    public static short[] PlayRecord(short[] stereo, int preMs, int tailMs) {
        LastError = "";
        int playSamples = stereo.Length / 2;
        int recSamples = Rate * preMs / 1000 + playSamples + Rate * tailMs / 1000;
        int recBytes = recSamples * 2, playBytes = stereo.Length * 2;
        int hs = Marshal.SizeOf(typeof(WAVEHDR));
        IntPtr hIn = IntPtr.Zero, hOut = IntPtr.Zero;
        IntPtr recBuf = Marshal.AllocHGlobal(recBytes), playBuf = Marshal.AllocHGlobal(playBytes);
        IntPtr recHdr = Marshal.AllocHGlobal(hs), playHdr = Marshal.AllocHGlobal(hs);
        bool inPrep = false, outPrep = false;
        short[] result = null;
        try {
            for (int i = 0; i < recBytes; i++) Marshal.WriteByte(recBuf, i, 0);
            Marshal.Copy(stereo, 0, playBuf, stereo.Length);
            WAVEHDR rh = new WAVEHDR(); rh.lpData = recBuf; rh.dwBufferLength = (uint)recBytes;
            WAVEHDR ph = new WAVEHDR(); ph.lpData = playBuf; ph.dwBufferLength = (uint)playBytes;
            Marshal.StructureToPtr(rh, recHdr, false); Marshal.StructureToPtr(ph, playHdr, false);

            WAVEFORMATEX fi = Fmt(1), fo = Fmt(2);
            int r = waveInOpen(out hIn, WAVE_MAPPER, ref fi, IntPtr.Zero, IntPtr.Zero, 0);
            if (r != 0) { LastError = "waveInOpen " + r; return null; }
            r = waveOutOpen(out hOut, WAVE_MAPPER, ref fo, IntPtr.Zero, IntPtr.Zero, 0);
            if (r != 0) { LastError = "waveOutOpen " + r; return null; }
            r = waveInPrepareHeader(hIn, recHdr, hs); if (r != 0) { LastError = "waveInPrepare " + r; return null; }
            inPrep = true;
            r = waveOutPrepareHeader(hOut, playHdr, hs); if (r != 0) { LastError = "waveOutPrepare " + r; return null; }
            outPrep = true;
            r = waveInAddBuffer(hIn, recHdr, hs); if (r != 0) { LastError = "waveInAddBuffer " + r; return null; }
            r = waveInStart(hIn); if (r != 0) { LastError = "waveInStart " + r; return null; }
            Thread.Sleep(preMs);
            r = waveOutWrite(hOut, playHdr, hs); if (r != 0) { LastError = "waveOutWrite " + r; return null; }
            int waited = 0, limit = recSamples * 1000 / Rate + 4000;
            while (waited < limit && !Done(recHdr)) { Thread.Sleep(20); waited += 20; }
            if (!Done(recHdr)) { LastError = "таймаут записи"; return null; }
            result = new short[recSamples];
            Marshal.Copy(recBuf, result, 0, recSamples);
            return result;
        } catch (Exception e) {
            LastError = e.Message; return null;
        } finally {
            if (hIn != IntPtr.Zero) { waveInStop(hIn); waveInReset(hIn); if (inPrep) waveInUnprepareHeader(hIn, recHdr, hs); waveInClose(hIn); }
            if (hOut != IntPtr.Zero) { waveOutReset(hOut); if (outPrep) waveOutUnprepareHeader(hOut, playHdr, hs); waveOutClose(hOut); }
            Marshal.FreeHGlobal(recBuf); Marshal.FreeHGlobal(playBuf); Marshal.FreeHGlobal(recHdr); Marshal.FreeHGlobal(playHdr);
        }
    }

    // ---- генерация сигналов (стерео interleaved); amp 0..1; chan: 0 = только левый, 1 = только правый, 2 = оба
    public static short[] Tone(int freq, int ms, double amp, int chan) {
        int n = Rate * ms / 1000, fade = Rate / 50;
        short[] s = new short[n * 2];
        for (int i = 0; i < n; i++) {
            double env = 1.0;
            if (i < fade) env = (double)i / fade; else if (i > n - fade) env = (double)(n - i) / fade;
            short v = (short)(Math.Sin(2 * Math.PI * freq * i / Rate) * amp * 32767 * env);
            s[2 * i] = chan == 1 ? (short)0 : v;
            s[2 * i + 1] = chan == 0 ? (short)0 : v;
        }
        return s;
    }

    // Логарифмический свип f0..f1
    public static short[] Sweep(int f0, int f1, int ms, double amp) {
        int n = Rate * ms / 1000, fade = Rate / 50;
        short[] s = new short[n * 2];
        double T = ms / 1000.0, k = Math.Log((double)f1 / f0), phase;
        for (int i = 0; i < n; i++) {
            double t = (double)i / Rate;
            phase = 2 * Math.PI * f0 * T / k * (Math.Exp(k * t / T) - 1);
            double env = 1.0;
            if (i < fade) env = (double)i / fade; else if (i > n - fade) env = (double)(n - i) / fade;
            short v = (short)(Math.Sin(phase) * amp * 32767 * env);
            s[2 * i] = v; s[2 * i + 1] = v;
        }
        return s;
    }

    // ---- анализ
    // Амплитуда синусоиды частоты f в окне [start, start+len) (Goertzel + окно Ханна), 0..1
    public static double Goertzel(short[] x, int start, int len, double f) {
        if (start < 0 || start + len > x.Length || len < 16) return 0;
        double w = 2 * Math.PI * f / Rate, c = 2 * Math.Cos(w), s1 = 0, s2 = 0, wsum = 0;
        for (int i = 0; i < len; i++) {
            double hw = 0.5 - 0.5 * Math.Cos(2 * Math.PI * i / (len - 1));
            double v = x[start + i] / 32768.0 * hw;
            double s0 = v + c * s1 - s2; s2 = s1; s1 = s0; wsum += hw;
        }
        double re = s1 - s2 * Math.Cos(w), im = s2 * Math.Sin(w);
        return 2 * Math.Sqrt(re * re + im * im) / wsum;
    }

    static double Rms(short[] x, int a, int b) {
        if (a < 0) a = 0; if (b > x.Length) b = x.Length;
        if (b - a < 1) return 0;
        double acc = 0;
        for (int i = a; i < b; i++) { double v = x[i] / 32768.0; acc += v * v; }
        return Math.Sqrt(acc / (b - a));
    }

    // Анализ тона. Результат:
    // [0] RMS основной частоты (0..1)  [1] RMS шума до сигнала  [2] SNR, дБ  [3] 2-я гармоника, дБ отн. основной (-99 если нет)
    // [4] 3-я гармоника, дБ  [5] число «щелчков/дребезга» (блоки 25 мс с выбросом остатка)  [6] пик записи 0..1
    // [7] блоков в оценке выбросов  [8] остаток (всё кроме основной) в % от основной в лучшем окне
    public static double[] AnalyzeTone(short[] x, int freq, int preMs) {
        double[] r = new double[9];
        int win = Rate / 5, hop = Rate / 20;
        double best = 0; int bestAt = 0;
        for (int p = 0; p + win <= x.Length; p += hop) {
            double a = Goertzel(x, p, win, freq);
            if (a > best) { best = a; bestAt = p; }
        }
        double noise = Rms(x, Rate / 20, Rate * preMs / 1000 - Rate / 20);
        r[0] = best / Math.Sqrt(2); r[1] = noise;
        r[2] = noise > 1e-6 ? 20 * Math.Log10(Math.Max(r[0], 1e-9) / noise) : 99;
        r[3] = -99; r[4] = -99;
        if (best > 0) {
            if (freq * 2 < 20000) r[3] = 20 * Math.Log10(Math.Max(Goertzel(x, bestAt, win, freq * 2.0), 1e-9) / best);
            if (freq * 3 < 20000) r[4] = 20 * Math.Log10(Math.Max(Goertzel(x, bestAt, win, freq * 3.0), 1e-9) / best);
        }
        double peak = 0;
        for (int i = 0; i < x.Length; i++) { double v = Math.Abs(x[i] / 32768.0); if (v > peak) peak = v; }
        r[6] = peak;
        // остаток после вычитания основной (МНК по блокам 25 мс)
        int blk = Rate / 40, nb = x.Length / blk;
        double[] amp = new double[nb], res = new double[nb];
        double maxAmp = 0;
        for (int b = 0; b < nb; b++) {
            double ss = 0, cc = 0, sc = 0, xs = 0, xc = 0;
            for (int i = 0; i < blk; i++) {
                int idx = b * blk + i; double ph = 2 * Math.PI * freq * idx / Rate;
                double sn = Math.Sin(ph), co = Math.Cos(ph), v = x[idx] / 32768.0;
                ss += sn * sn; cc += co * co; sc += sn * co; xs += v * sn; xc += v * co;
            }
            double det = ss * cc - sc * sc, A = 0, B = 0;
            if (Math.Abs(det) > 1e-9) { A = (xs * cc - xc * sc) / det; B = (xc * ss - xs * sc) / det; }
            double acc = 0;
            for (int i = 0; i < blk; i++) {
                int idx = b * blk + i; double ph = 2 * Math.PI * freq * idx / Rate;
                double e = x[idx] / 32768.0 - A * Math.Sin(ph) - B * Math.Cos(ph); acc += e * e;
            }
            amp[b] = Math.Sqrt(A * A + B * B); res[b] = Math.Sqrt(acc / blk);
            if (amp[b] > maxAmp) maxAmp = amp[b];
        }
        int first = -1, last = -1;
        for (int b = 0; b < nb; b++) if (amp[b] > maxAmp * 0.6) { if (first < 0) first = b; last = b; }
        double[] pl = new double[Math.Max(0, last - first - 3)];
        for (int b = first + 2, k = 0; k < pl.Length; b++, k++) pl[k] = res[b];
        if (pl.Length >= 4 && maxAmp > 0) {
            double[] sorted = (double[])pl.Clone(); Array.Sort(sorted);
            double med = sorted[sorted.Length / 2]; int spikes = 0;
            for (int k = 0; k < pl.Length; k++) if (pl[k] > med * 4 && pl[k] > 0.15 * maxAmp / Math.Sqrt(2) * 0.3) spikes++;
            r[5] = spikes; r[7] = pl.Length;
            r[8] = 100.0 * med / (maxAmp / Math.Sqrt(2));
        }
        return r;
    }

    // Анализ свипа f0..f1 длиной ms: возвращает пары [частота, уровень дБ отн. максимума] для points точек (лог-шкала)
    public static double[] AnalyzeSweep(short[] x, int f0, int f1, int ms, int preMs, int points) {
        double noise = Rms(x, Rate / 20, Rate * preMs / 1000 - Rate / 20);
        double thr = Math.Max(noise * 4, 0.002);
        int start = -1, step = Rate / 100;
        for (int p = 0; p + step <= x.Length; p += step) if (Rms(x, p, p + step) > thr) { start = p; break; }
        double[] r = new double[points * 2];
        if (start < 0) { for (int i = 0; i < points; i++) { r[2 * i] = f0 * Math.Pow((double)f1 / f0, (i + 0.5) / points); r[2 * i + 1] = -99; } return r; }
        double[] a = new double[points]; double mx = 1e-9;
        for (int i = 0; i < points; i++) {
            double fr = (i + 0.5) / points, f = f0 * Math.Pow((double)f1 / f0, fr);
            double wsec = Math.Min(0.15, Math.Sqrt((ms / 1000.0) / (Math.Log((double)f1 / f0) * f)));
            int w2 = Math.Max(Rate / 250, (int)(wsec * Rate));
            int c = start + (int)(fr * ms / 1000.0 * Rate) - w2 / 2;
            a[i] = Goertzel(x, c, w2, f); r[2 * i] = f;
            if (a[i] > mx) mx = a[i];
        }
        for (int i = 0; i < points; i++) r[2 * i + 1] = 20 * Math.Log10(Math.Max(a[i], 1e-9) / mx);
        return r;
    }
}
'@
