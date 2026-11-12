# USB: ключ выбора, C#-помощник (топология хабов/скорости через IOCTL, тест записи/чтения на флешке без кэша).
$STEPKEYS['USB-порты: проверка'] = 'usb'
$G.PresetHooks.Add({ param($full) $G.Sel.usb = $true })

function Get-PcDiagUsbSrc {
@'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.IO;
using System.Security.Cryptography;
using System.Diagnostics;
using Microsoft.Win32.SafeHandles;

public static class PcDiagUsb {
    [StructLayout(LayoutKind.Sequential)] struct SP_DEVICE_INTERFACE_DATA { public int cbSize; public Guid InterfaceClassGuid; public int Flags; public IntPtr Reserved; }
    [StructLayout(LayoutKind.Sequential)] struct SP_DEVINFO_DATA { public int cbSize; public Guid ClassGuid; public int DevInst; public IntPtr Reserved; }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr sec, uint disp, uint flags, IntPtr tmpl);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool DeviceIoControl(SafeFileHandle h, uint code, IntPtr inBuf, int inSize, IntPtr outBuf, int outSize, out int ret, IntPtr ov);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool WriteFile(SafeFileHandle h, IntPtr buf, uint n, out uint written, IntPtr ov);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool ReadFile(SafeFileHandle h, IntPtr buf, uint n, out uint read, IntPtr ov);
    [DllImport("setupapi.dll", SetLastError = true)]
    static extern IntPtr SetupDiGetClassDevs(ref Guid g, IntPtr enumerator, IntPtr hwnd, uint flags);
    [DllImport("setupapi.dll", SetLastError = true)]
    static extern bool SetupDiEnumDeviceInterfaces(IntPtr set, IntPtr devInfo, ref Guid g, uint idx, ref SP_DEVICE_INTERFACE_DATA d);
    [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "SetupDiGetDeviceInterfaceDetailW")]
    static extern bool SetupDiGetDetailSize(IntPtr set, ref SP_DEVICE_INTERFACE_DATA d, IntPtr detail, int size, out int req, IntPtr devInfo);
    [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "SetupDiGetDeviceInterfaceDetailW")]
    static extern bool SetupDiGetDetail(IntPtr set, ref SP_DEVICE_INTERFACE_DATA d, IntPtr detail, int size, out int req, ref SP_DEVINFO_DATA devInfo);
    [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool SetupDiGetDeviceRegistryProperty(IntPtr set, ref SP_DEVINFO_DATA devInfo, uint prop, out uint regType, IntPtr buf, int size, out int req);
    [DllImport("setupapi.dll")] static extern bool SetupDiDestroyDeviceInfoList(IntPtr set);

    const uint GENERIC_READ = 0x80000000, GENERIC_WRITE = 0x40000000;

    static void Zero(IntPtr p, int n) { for (int i = 0; i < n; i += 4) Marshal.WriteInt32(p, i, 0); }

    // Строки: "HC|метка|описание", "HUB|метка|портов|глубина", "ERR|метка порта|код статуса",
    // "DEV|метка порта|глубина|vid|pid|speed|bcdUSB|isHub|class|opSS|capSS|opSSP|capSSP|имя"  (op*/cap* = -1 если неизвестно)
    public static string[] Enumerate() {
        List<string> res = new List<string>();
        Guid g = new Guid("3abf6f2d-71c4-462a-8a92-1e6861e6af27");
        IntPtr set = SetupDiGetClassDevs(ref g, IntPtr.Zero, IntPtr.Zero, 0x12);
        if (set == new IntPtr(-1) || set == IntPtr.Zero) return res.ToArray();
        try {
            int hcNo = 0;
            for (uint i = 0; i < 32; i++) {
                SP_DEVICE_INTERFACE_DATA d = new SP_DEVICE_INTERFACE_DATA();
                d.cbSize = Marshal.SizeOf(typeof(SP_DEVICE_INTERFACE_DATA));
                if (!SetupDiEnumDeviceInterfaces(set, IntPtr.Zero, ref g, i, ref d)) break;
                hcNo++;
                string label = "HC" + hcNo;
                try {
                    int req = 0;
                    SetupDiGetDetailSize(set, ref d, IntPtr.Zero, 0, out req, IntPtr.Zero);
                    if (req <= 4 || req > 8192) continue;
                    IntPtr det = Marshal.AllocHGlobal(req);
                    string path = null; string desc = "";
                    try {
                        Marshal.WriteInt32(det, 0, IntPtr.Size == 8 ? 8 : 6);
                        SP_DEVINFO_DATA di = new SP_DEVINFO_DATA();
                        di.cbSize = Marshal.SizeOf(typeof(SP_DEVINFO_DATA));
                        int req2;
                        if (!SetupDiGetDetail(set, ref d, det, req, out req2, ref di)) continue;
                        path = Marshal.PtrToStringUni(new IntPtr(det.ToInt64() + 4));
                        IntPtr pb = Marshal.AllocHGlobal(512);
                        try {
                            Zero(pb, 512);
                            uint rt; int rq;
                            if (SetupDiGetDeviceRegistryProperty(set, ref di, 0, out rt, pb, 510, out rq)) desc = Marshal.PtrToStringUni(pb);
                        } catch { } finally { Marshal.FreeHGlobal(pb); }
                    } finally { Marshal.FreeHGlobal(det); }
                    res.Add("HC|" + label + "|" + (desc ?? ""));
                    if (string.IsNullOrEmpty(path)) continue;
                    SafeFileHandle h = CreateFile(path, GENERIC_WRITE, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
                    if (h.IsInvalid) continue;
                    IntPtr buf = Marshal.AllocHGlobal(1024);
                    string root = null;
                    try {
                        Zero(buf, 1024);
                        int ret;
                        if (DeviceIoControl(h, 0x220408, IntPtr.Zero, 0, buf, 1024, out ret, IntPtr.Zero)) root = Marshal.PtrToStringUni(new IntPtr(buf.ToInt64() + 4));
                    } finally { Marshal.FreeHGlobal(buf); h.Dispose(); }
                    if (!string.IsNullOrEmpty(root)) ScanHub(root, label, 0, res);
                } catch { }
            }
        } catch { } finally { SetupDiDestroyDeviceInfoList(set); }
        return res.ToArray();
    }

    static string ProductString(SafeFileHandle h, int port, int idx) {
        if (idx <= 0) return "";
        IntPtr b = Marshal.AllocHGlobal(512);
        try {
            Zero(b, 512);
            Marshal.WriteInt32(b, 0, port);
            Marshal.WriteByte(b, 4, 0x80); Marshal.WriteByte(b, 5, 6);
            Marshal.WriteInt16(b, 6, (short)((3 << 8) | idx));
            Marshal.WriteInt16(b, 8, 0x0409);
            Marshal.WriteInt16(b, 10, 254);
            int ret;
            if (!DeviceIoControl(h, 0x220410, b, 12, b, 12 + 254, out ret, IntPtr.Zero)) return "";
            int len = Marshal.ReadByte(b, 12); int typ = Marshal.ReadByte(b, 13);
            if (typ != 3 || len < 4 || len > 254) return "";
            return Marshal.PtrToStringUni(new IntPtr(b.ToInt64() + 14), (len - 2) / 2).Replace("|", "/").Trim();
        } catch { return ""; } finally { Marshal.FreeHGlobal(b); }
    }

    static void ScanHub(string hubName, string label, int depth, List<string> res) {
        if (depth > 6) return;
        SafeFileHandle h = CreateFile("\\\\.\\" + hubName, GENERIC_WRITE, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
        if (h.IsInvalid) return;
        IntPtr buf = Marshal.AllocHGlobal(1024);
        try {
            int ret;
            Zero(buf, 1024);
            if (!DeviceIoControl(h, 0x220408, buf, 76, buf, 76, out ret, IntPtr.Zero)) return;
            int ports = Marshal.ReadByte(buf, 6);
            res.Add("HUB|" + label + "|" + ports + "|" + depth);
            for (int p = 1; p <= ports; p++) {
                try {
                    string pl = label + "." + p;
                    Zero(buf, 1024);
                    Marshal.WriteInt32(buf, 0, p);
                    if (!DeviceIoControl(h, 0x220448, buf, 1024, buf, 1024, out ret, IntPtr.Zero)) continue;
                    int st = Marshal.ReadByte(buf, 31);
                    if (st == 0) st = Marshal.ReadByte(buf, 32);
                    if (st == 0) continue;
                    if (st != 1) { res.Add("ERR|" + pl + "|" + st); continue; }
                    int bcd = Marshal.ReadInt16(buf, 6) & 0xFFFF;
                    int cls = Marshal.ReadByte(buf, 8);
                    int vid = Marshal.ReadInt16(buf, 12) & 0xFFFF;
                    int pid = Marshal.ReadInt16(buf, 14) & 0xFFFF;
                    int iProd = Marshal.ReadByte(buf, 20);
                    int speed = Marshal.ReadByte(buf, 23);
                    bool isHub = Marshal.ReadByte(buf, 24) != 0;
                    int opSS = -1, capSS = -1, opSSP = -1, capSSP = -1;
                    Zero(buf, 64);
                    Marshal.WriteInt32(buf, 0, p); Marshal.WriteInt32(buf, 4, 16);
                    if (DeviceIoControl(h, 0x22045C, buf, 16, buf, 16, out ret, IntPtr.Zero)) {
                        int fl = Marshal.ReadInt32(buf, 12);
                        opSS = fl & 1; capSS = (fl >> 1) & 1; opSSP = (fl >> 2) & 1; capSSP = (fl >> 3) & 1;
                    }
                    string name = ProductString(h, p, iProd);
                    string nodeName = null;
                    if (isHub) {
                        Zero(buf, 1024);
                        Marshal.WriteInt32(buf, 0, p);
                        if (DeviceIoControl(h, 0x220414, buf, 1024, buf, 1024, out ret, IntPtr.Zero)) nodeName = Marshal.PtrToStringUni(new IntPtr(buf.ToInt64() + 8));
                    }
                    res.Add("DEV|" + pl + "|" + depth + "|" + vid.ToString("X4") + "|" + pid.ToString("X4") + "|" + speed + "|" + bcd.ToString("X4") + "|" + (isHub ? 1 : 0) + "|" + cls + "|" + opSS + "|" + capSS + "|" + opSSP + "|" + capSSP + "|" + name);
                    if (isHub && !string.IsNullOrEmpty(nodeName)) ScanHub(nodeName, pl, depth + 1, res);
                } catch { }
            }
        } catch { } finally { Marshal.FreeHGlobal(buf); h.Dispose(); }
    }

    // ---------------------------------------------------------------- тест записи/чтения (без кэша Windows), только свой временный файл
    const int Chunk = 4 * 1024 * 1024;
    static byte[][] ring;
    static void Fill(byte[] dst, long idx) {
        if (ring == null) {
            Random r = new Random(20240607);
            byte[][] t = new byte[8][];
            for (int i = 0; i < 8; i++) { t[i] = new byte[Chunk]; r.NextBytes(t[i]); }
            ring = t;
        }
        Buffer.BlockCopy(ring[(int)(idx & 7)], 0, dst, 0, Chunk);
        byte[] c = BitConverter.GetBytes(idx);
        Buffer.BlockCopy(c, 0, dst, 0, 8);
    }

    // Результат: "OK|запись МБ/с|чтение МБ/с|записано МБ|плохих блоков|первый плохой блок(МБ)|хэш совпал 1/0|сообщение"
    //            "ERR|сообщение|..." при сбое (путь к файлу удаляется)
    public static string DiskTest(string file, int mb, int maxSec) {
        int chunks = mb / 4; if (chunks < 1) chunks = 1;
        SafeFileHandle hw = null, hr = null;
        IntPtr raw = IntPtr.Zero;
        string msg = "";
        double wsec = 0, rsec = 0; int done = 0; int bad = 0; int firstBad = -1; bool hashOk = false;
        try {
            raw = Marshal.AllocHGlobal(Chunk + 4096);
            IntPtr al = new IntPtr((raw.ToInt64() + 4095) & ~4095L);
            byte[] data = new byte[Chunk];
            byte[] back = new byte[Chunk];
            hw = CreateFile(file, GENERIC_WRITE, 0, IntPtr.Zero, 1, 0x20000000u | 0x80000000u, IntPtr.Zero);
            if (hw.IsInvalid) return "ERR|не удалось создать файл (Win32 " + Marshal.GetLastWin32Error() + ")";
            Stopwatch sw = new Stopwatch();
            for (int i = 0; i < chunks; i++) {
                Fill(data, i);
                Marshal.Copy(data, 0, al, Chunk);
                uint wr; bool ok;
                sw.Start();
                ok = WriteFile(hw, al, (uint)Chunk, out wr, IntPtr.Zero);
                sw.Stop();
                if (!ok || wr != (uint)Chunk) { msg = "ошибка записи на блоке " + (i * 4) + " МБ (Win32 " + Marshal.GetLastWin32Error() + ")"; bad++; break; }
                done++;
                if (sw.Elapsed.TotalSeconds > maxSec) { msg = "тест записи прерван по времени (очень медленно)"; break; }
            }
            wsec = sw.Elapsed.TotalSeconds;
            hw.Dispose(); hw = null;
            if (done == 0) return "ERR|" + (msg.Length > 0 ? msg : "запись не удалась");
            hr = CreateFile(file, GENERIC_READ, 1, IntPtr.Zero, 3, 0x20000000u | 0x08000000u, IntPtr.Zero);
            if (hr.IsInvalid) return "ERR|не удалось открыть файл для чтения (Win32 " + Marshal.GetLastWin32Error() + ")";
            SHA256 hs1 = SHA256.Create(); SHA256 hs2 = SHA256.Create();
            Stopwatch sr = new Stopwatch();
            int readOk = 0;
            for (int i = 0; i < done; i++) {
                uint rd; bool ok;
                sr.Start();
                ok = ReadFile(hr, al, (uint)Chunk, out rd, IntPtr.Zero);
                sr.Stop();
                if (!ok || rd != (uint)Chunk) { if (msg.Length == 0) msg = "ошибка чтения на блоке " + (i * 4) + " МБ (Win32 " + Marshal.GetLastWin32Error() + ")"; bad++; if (firstBad < 0) firstBad = i * 4; break; }
                readOk++;
                Marshal.Copy(al, back, 0, Chunk);
                Fill(data, i);
                hs1.TransformBlock(data, 0, Chunk, null, 0);
                hs2.TransformBlock(back, 0, Chunk, null, 0);
                bool same = true;
                for (int k = 0; k < Chunk; k += 8) { if (BitConverter.ToInt64(data, k) != BitConverter.ToInt64(back, k)) { same = false; break; } }
                if (!same) { bad++; if (firstBad < 0) firstBad = i * 4; }
                if (sr.Elapsed.TotalSeconds > maxSec * 2) { if (msg.Length == 0) msg = "тест чтения прерван по времени"; break; }
            }
            rsec = sr.Elapsed.TotalSeconds;
            hs1.TransformFinalBlock(new byte[0], 0, 0); hs2.TransformFinalBlock(new byte[0], 0, 0);
            hashOk = readOk == done && Convert.ToBase64String(hs1.Hash) == Convert.ToBase64String(hs2.Hash);
            double wm = wsec > 0 ? done * 4.0 / wsec : 0;
            double rm = rsec > 0 ? readOk * 4.0 / rsec : 0;
            return "OK|" + wm.ToString("0.0", System.Globalization.CultureInfo.InvariantCulture) + "|" + rm.ToString("0.0", System.Globalization.CultureInfo.InvariantCulture) + "|" + (done * 4) + "|" + bad + "|" + firstBad + "|" + (hashOk ? 1 : 0) + "|" + msg;
        } catch (Exception ex) {
            return "ERR|" + ex.Message.Replace("|", "/");
        } finally {
            if (hw != null) hw.Dispose();
            if (hr != null) hr.Dispose();
            if (raw != IntPtr.Zero) Marshal.FreeHGlobal(raw);
            try { if (File.Exists(file)) File.Delete(file); } catch { }
        }
    }
}
'@
}

function Initialize-PcDiagUsb {
    if ('PcDiagUsb' -as [type]) { return $true }
    try { Add-Type -TypeDefinition (Get-PcDiagUsbSrc) -Language CSharp -ErrorAction Stop; return $true }
    catch { $G.Log.Add("usb: Add-Type: $($_.Exception.Message)"); return $false }
}
