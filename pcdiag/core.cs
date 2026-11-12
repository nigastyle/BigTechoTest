using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public class DiagMemResult {
    public long Errors;
    public double WriteMBs;
    public double ReadMBs;
    public int TestedMB;
    public string Note = "";
}

public static class DiagCore {
    public const int Block = 2000000;
    static ulong reference;
    static long[] counts;
    static long errors;
    static Thread[] threads;
    static Stopwatch watch = new Stopwatch();
    static double elapsed;

    static ulong Work(int n) {
        ulong x = 0x9E3779B97F4A7C15UL;
        double d = 1.0;
        for (int i = 1; i <= n; i++) {
            x = unchecked(x * 6364136223846793005UL + 1442695040888963407UL);
            x ^= x >> 29;
            d += Math.Sqrt(i) * 1e-9;
        }
        return x ^ (ulong)(d * 1000000.0);
    }

    public static volatile bool StopFlag;
    public static void Stop() { StopFlag = true; }
    public static void Start(int threadCount, int seconds) {
        if (threadCount < 1) threadCount = 1;
        StopFlag = false;
        reference = Work(Block);
        counts = new long[threadCount];
        errors = 0;
        elapsed = 0;
        threads = new Thread[threadCount];
        DateTime deadline = DateTime.UtcNow.AddSeconds(seconds);
        watch.Reset();
        watch.Start();
        for (int t = 0; t < threadCount; t++) {
            int idx = t;
            threads[t] = new Thread(delegate() {
                while (DateTime.UtcNow < deadline && !StopFlag) {
                    ulong r = Work(Block);
                    if (r != reference) Interlocked.Increment(ref errors);
                    counts[idx]++;
                }
            });
            threads[t].IsBackground = true;
            threads[t].Priority = ThreadPriority.BelowNormal;
            threads[t].Start();
        }
    }

    public static bool IsRunning {
        get {
            if (threads == null) return false;
            foreach (Thread th in threads) if (th.IsAlive) return true;
            return false;
        }
    }

    public static void Wait() {
        if (threads == null) return;
        foreach (Thread th in threads) th.Join();
        watch.Stop();
        elapsed = watch.Elapsed.TotalSeconds;
    }

    public static long TotalBlocks {
        get { long s = 0; if (counts != null) foreach (long c in counts) s += c; return s; }
    }
    public static long Errors { get { return Interlocked.Read(ref errors); } }
    public static double BlocksPerSec { get { return elapsed > 0 ? TotalBlocks / elapsed : 0; } }

    public static DiagMemResult MemTest(int megabytes) {
        DiagMemResult res = new DiagMemResult();
        const int chunkMB = 64;
        int per = chunkMB * 1024 * 1024 / 8;
        int chunks = Math.Max(1, megabytes / chunkMB);
        List<ulong[]> list = new List<ulong[]>();
        try {
            for (int c = 0; c < chunks; c++) list.Add(new ulong[per]);
        } catch (OutOfMemoryException) {
            res.Note = "Удалось выделить только " + (list.Count * chunkMB) + " МБ";
        }
        res.TestedMB = list.Count * chunkMB;
        if (list.Count == 0) return res;
        ulong[] patterns = new ulong[] { 0xAAAAAAAAAAAAAAAAUL, 0x5555555555555555UL, 0UL, 0xFFFFFFFFFFFFFFFFUL };
        double bytes = (double)list.Count * per * 8;
        double tw = 0, tr = 0;
        Stopwatch sw = new Stopwatch();
        int passes = patterns.Length + 1;
        for (int p = 0; p < passes; p++) {
            sw.Reset(); sw.Start();
            for (int c = 0; c < list.Count; c++) {
                ulong[] a = list[c];
                if (p < patterns.Length) {
                    ulong v = patterns[p];
                    for (int i = 0; i < a.Length; i++) a[i] = v;
                } else {
                    ulong b = (ulong)c * (ulong)per;
                    for (int i = 0; i < a.Length; i++) a[i] = unchecked((b + (ulong)i) * 0x9E3779B97F4A7C15UL);
                }
            }
            sw.Stop(); tw += sw.Elapsed.TotalSeconds;
            sw.Reset(); sw.Start();
            for (int c = 0; c < list.Count; c++) {
                ulong[] a = list[c];
                if (p < patterns.Length) {
                    ulong v = patterns[p];
                    for (int i = 0; i < a.Length; i++) if (a[i] != v) res.Errors++;
                } else {
                    ulong b = (ulong)c * (ulong)per;
                    for (int i = 0; i < a.Length; i++) if (a[i] != unchecked((b + (ulong)i) * 0x9E3779B97F4A7C15UL)) res.Errors++;
                }
            }
            sw.Stop(); tr += sw.Elapsed.TotalSeconds;
        }
        if (tw > 0) res.WriteMBs = bytes * passes / 1048576.0 / tw;
        if (tr > 0) res.ReadMBs = bytes * passes / 1048576.0 / tr;
        list.Clear();
        GC.Collect();
        return res;
    }

    public static byte[] MakeTone(int freq, int durationMs, int channel) {
        int rate = 44100;
        int samples = rate * durationMs / 1000;
        int dataLen = samples * 4;
        MemoryStream mem = new MemoryStream();
        BinaryWriter w = new BinaryWriter(mem);
        w.Write(Encoding.ASCII.GetBytes("RIFF")); w.Write(36 + dataLen); w.Write(Encoding.ASCII.GetBytes("WAVE"));
        w.Write(Encoding.ASCII.GetBytes("fmt ")); w.Write(16); w.Write((short)1); w.Write((short)2);
        w.Write(rate); w.Write(rate * 4); w.Write((short)4); w.Write((short)16);
        w.Write(Encoding.ASCII.GetBytes("data")); w.Write(dataLen);
        int fade = rate / 50;
        for (int i = 0; i < samples; i++) {
            double env = 1.0;
            if (i < fade) env = (double)i / fade;
            else if (i > samples - fade) env = (double)(samples - i) / fade;
            short v = (short)(Math.Sin(2 * Math.PI * freq * i / rate) * 12000 * env);
            w.Write(channel == 1 ? (short)0 : v);
            w.Write(channel == 0 ? (short)0 : v);
        }
        w.Flush();
        return mem.ToArray();
    }

    [DllImport("winmm.dll", CharSet = CharSet.Unicode)]
    static extern int mciSendString(string command, StringBuilder ret, int retLen, IntPtr callback);

    public static string LastMciError = "";

    public static double RecordLevel(int durationMs, string path) {
        mciSendString("close diagrec", null, 0, IntPtr.Zero);
        int r = mciSendString("open new type waveaudio alias diagrec", null, 0, IntPtr.Zero);
        if (r != 0) { LastMciError = "open " + r; return -1; }
        mciSendString("set diagrec bitspersample 16 channels 1 samplespersec 44100 bytespersec 88200 alignment 2", null, 0, IntPtr.Zero);
        r = mciSendString("record diagrec", null, 0, IntPtr.Zero);
        if (r != 0) { LastMciError = "record " + r; mciSendString("close diagrec", null, 0, IntPtr.Zero); return -1; }
        Thread.Sleep(durationMs);
        mciSendString("stop diagrec", null, 0, IntPtr.Zero);
        r = mciSendString("save diagrec \"" + path + "\"", null, 0, IntPtr.Zero);
        mciSendString("close diagrec", null, 0, IntPtr.Zero);
        if (r != 0) { LastMciError = "save " + r; return -1; }
        return WavLevel(path);
    }

    // Максимальный RMS по окнам 50 мс (0..1). Устойчив к одиночным щелчкам.
    public static double WavLevel(string path) {
        byte[] b = File.ReadAllBytes(path);
        if (b.Length < 44) return -1;
        int pos = 12, bits = 16, rate = 44100, channels = 1, dataStart = -1, dataLen = 0;
        while (pos + 8 <= b.Length) {
            string id = Encoding.ASCII.GetString(b, pos, 4);
            int len = BitConverter.ToInt32(b, pos + 4);
            if (id == "fmt ") {
                channels = BitConverter.ToInt16(b, pos + 10);
                rate = BitConverter.ToInt32(b, pos + 12);
                bits = BitConverter.ToInt16(b, pos + 22);
            } else if (id == "data") {
                dataStart = pos + 8;
                dataLen = Math.Min(len, b.Length - dataStart);
                break;
            }
            if (len < 0) break;
            pos += 8 + len + (len % 2);
        }
        if (dataStart < 0 || channels < 1) return -1;
        int bytesPer = bits / 8;
        if (bytesPer != 1 && bytesPer != 2) return -1;
        int count = dataLen / bytesPer;
        int win = Math.Max(1, rate * channels / 20);
        int skip = Math.Min(count, rate * channels / 5); // первые 200 мс пропускаем (щелчок включения)
        double best = 0, acc = 0; int n = 0;
        for (int i = skip; i < count; i++) {
            double v = bytesPer == 2 ? BitConverter.ToInt16(b, dataStart + i * 2) / 32768.0 : (b[dataStart + i] - 128) / 128.0;
            acc += v * v; n++;
            if (n == win) { double rms = Math.Sqrt(acc / n); if (rms > best) best = rms; acc = 0; n = 0; }
        }
        return best;
    }
}
