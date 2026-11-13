# Проверка поверхности накопителей ЧТЕНИЕМ (никакой записи): \\.\PhysicalDriveN открывается только на чтение,
# диск делится на зоны, в каждой зоне читается несколько МБ подряд; меряется скорость по зонам, задержка блоков, ошибки чтения.
$STEPKEYS['Накопители: проверка поверхности (чтение)'] = 'surface'
$G.PresetHooks.Add({ param($full) $G.Sel.surface = $full; $G.Sel.surfacemin = $(if ($full) { 20 } else { 3 }) })
$G.SurfaceOk = $false
& {
    if ('DiagSurface' -as [type]) { $G.SurfaceOk = $true; return }
    $src = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;
using Microsoft.Win32.SafeHandles;

public class DiagSurfaceResult {
    public int Disk;
    public long DiskBytes;
    public int ZonesPlanned;
    public int ZonesDone;
    public double[] ZoneMBs = new double[0];      // скорость по зонам, МБ/с (NaN — зона не прочитана из-за ошибки)
    public long[] ZoneOffsets = new long[0];      // начало зоны, байт
    public double[] ZoneMaxLatMs = new double[0]; // худшая задержка блока в зоне, мс
    public int[] ZoneErrors = new int[0];
    public double MinSpeed;
    public double AvgSpeed;
    public double MaxLatencyMs;
    public int SlowBlocks;
    public int Errors;
    public long[] ErrorPositions = new long[0];   // первые 20 позиций (байт)
    public int[] ErrorCodes = new int[0];         // Win32-коды этих ошибок
    public long BytesRead;
    public double Seconds;
    public bool TimedOut;
    public bool Aborted;
    public string Note = "";
}

// ТОЛЬКО ЧТЕНИЕ: в классе нет ни одного вызова записи (WriteFile/DeviceIoControl с изменением), handle открыт с GENERIC_READ.
public static class DiagSurface {
    const uint GENERIC_READ = 0x80000000;
    const uint FILE_SHARE_READ = 1, FILE_SHARE_WRITE = 2;
    const uint OPEN_EXISTING = 3;
    const uint FILE_FLAG_NO_BUFFERING = 0x20000000;
    const uint MEM_COMMIT = 0x1000, MEM_RESERVE = 0x2000, MEM_RELEASE = 0x8000, PAGE_READWRITE = 4;
    const uint IOCTL_DISK_GET_LENGTH_INFO = 0x0007405C;
    const uint IOCTL_STORAGE_QUERY_PROPERTY = 0x002D1400;
    const long ALIGN = 4096;

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr sec, uint disp, uint flags, IntPtr tmpl);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool ReadFile(SafeFileHandle h, IntPtr buf, int toRead, out int read, IntPtr ovl);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetFilePointerEx(SafeFileHandle h, long dist, out long newPos, uint method);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool DeviceIoControl(SafeFileHandle h, uint code, IntPtr inBuf, int inSize, IntPtr outBuf, int outSize, out int ret, IntPtr ovl);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr VirtualAlloc(IntPtr addr, UIntPtr size, uint type, uint protect);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool VirtualFree(IntPtr addr, UIntPtr size, uint type);

    // ---- прогресс для опроса из PowerShell (фоновый режим StartScan)
    public static volatile int ProgZones;
    public static volatile int ProgTotal;
    public static volatile int ProgErrors;
    public static volatile int ProgSlow;
    public static double ProgLastMBs;
    public static volatile bool Cancel;
    public static DiagSurfaceResult LastResult;
    public static string LastError = "";
    static Thread worker;

    static SafeFileHandle Open(int disk, bool noBuffering) {
        return CreateFile(@"\\.\PhysicalDrive" + disk, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, IntPtr.Zero, OPEN_EXISTING, noBuffering ? FILE_FLAG_NO_BUFFERING : 0, IntPtr.Zero);
    }

    // Размер диска в байтах (IOCTL только чтения); -1 при ошибке
    public static long GetDiskLength(int disk) {
        using (SafeFileHandle h = Open(disk, false)) {
            if (h.IsInvalid) return -1;
            IntPtr b = Marshal.AllocHGlobal(8);
            try {
                int ret;
                if (!DeviceIoControl(h, IOCTL_DISK_GET_LENGTH_INFO, IntPtr.Zero, 0, b, 8, out ret, IntPtr.Zero)) return -1;
                return Marshal.ReadInt64(b);
            } finally { Marshal.FreeHGlobal(b); }
        }
    }

    // 1 — есть задержка позиционирования (HDD), 0 — нет (SSD), -1 — неизвестно
    public static int SeekPenalty(int disk) {
        using (SafeFileHandle h = Open(disk, false)) {
            if (h.IsInvalid) return -1;
            IntPtr q = Marshal.AllocHGlobal(12), r = Marshal.AllocHGlobal(12);
            try {
                Marshal.WriteInt32(q, 0, 7);  // StorageDeviceSeekPenaltyProperty
                Marshal.WriteInt32(q, 4, 0);  // PropertyStandardQuery
                Marshal.WriteInt32(q, 8, 0);
                int ret;
                if (!DeviceIoControl(h, IOCTL_STORAGE_QUERY_PROPERTY, q, 12, r, 12, out ret, IntPtr.Zero) || ret < 9) return -1;
                return Marshal.ReadByte(r, 8) != 0 ? 1 : 0;
            } finally { Marshal.FreeHGlobal(q); Marshal.FreeHGlobal(r); }
        }
    }

    public static DiagSurfaceResult ScanDisk(int diskNumber, long startByte, long length, int blockMB, int timeLimitSec) {
        return ScanDisk(diskNumber, startByte, length, blockMB, timeLimitSec, 200, 500);
    }

    public static DiagSurfaceResult ScanDisk(int diskNumber, long startByte, long length, int blockMB, int timeLimitSec, int zones, int slowMs) {
        DiagSurfaceResult res = new DiagSurfaceResult();
        res.Disk = diskNumber;
        if (blockMB < 1) blockMB = 1;
        if (blockMB > 16) blockMB = 16;
        if (zones < 1) zones = 1;
        if (timeLimitSec < 5) timeLimitSec = 5;
        if (slowMs < 10) slowMs = 10;
        long block = (long)blockMB * 1048576;

        long diskLen = GetDiskLength(diskNumber);
        res.DiskBytes = diskLen;
        if (startByte < 0) startByte = 0;
        startByte = startByte / ALIGN * ALIGN;
        if (diskLen > 0) {
            if (length <= 0 || startByte + length > diskLen) length = diskLen - startByte;
        }
        length = length / ALIGN * ALIGN;
        if (length < ALIGN) { res.Note = "нет данных о размере диска"; return res; }
        long zoneLen = length / zones;
        if (zoneLen < block) { zones = (int)Math.Max(1, length / block); zoneLen = length / zones; }
        res.ZonesPlanned = zones;
        ProgTotal = zones; ProgZones = 0; ProgErrors = 0; ProgSlow = 0; ProgLastMBs = 0;

        List<double> zSpeed = new List<double>(), zLat = new List<double>();
        List<long> zOff = new List<long>(), errPos = new List<long>();
        List<int> zErr = new List<int>(), errCode = new List<int>();
        Stopwatch total = Stopwatch.StartNew();
        double limitMs = timeLimitSec * 1000.0;

        SafeFileHandle h = Open(diskNumber, true);
        if (h.IsInvalid) { res.Note = "диск не открылся на чтение (код " + Marshal.GetLastWin32Error() + ")"; return res; }
        IntPtr buf = VirtualAlloc(IntPtr.Zero, (UIntPtr)(ulong)block, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE); // выровнен по странице 4 КБ
        if (buf == IntPtr.Zero) { h.Dispose(); res.Note = "нет памяти под буфер"; return res; }
        int consecutiveErr = 0;
        try {
            for (int z = 0; z < zones; z++) {
                if (Cancel) { res.Aborted = true; res.Note = "прервано"; break; }
                double leftMs = limitMs - total.Elapsed.TotalMilliseconds;
                if (leftMs <= 0) { res.TimedOut = true; break; }
                double sliceMs = leftMs / (zones - z);            // время на зону пересчитывается: все зоны успеют
                long zStart = startByte + (long)z * zoneLen;
                zStart = zStart / 1048576 * 1048576;              // выравнивание на 1 МБ
                if (zStart < startByte) zStart = startByte / ALIGN * ALIGN;
                long zEnd = (z == zones - 1) ? startByte + length : startByte + (long)(z + 1) * zoneLen;
                zEnd = zEnd / ALIGN * ALIGN;
                long pos = zStart;
                long measBytes = 0; double measMs = 0, maxLat = 0; int nBlk = 0, errs = 0;
                Stopwatch zw = Stopwatch.StartNew();
                while (pos < zEnd) {
                    if (Cancel) break;
                    int want = (int)Math.Min(block, zEnd - pos);
                    want = (int)(want / ALIGN * ALIGN);
                    if (want <= 0) break;
                    long np;
                    long t0 = Stopwatch.GetTimestamp();
                    bool ok = SetFilePointerEx(h, pos, out np, 0);
                    int got = 0;
                    if (ok) ok = ReadFile(h, buf, want, out got, IntPtr.Zero);
                    int code = ok ? 0 : Marshal.GetLastWin32Error();
                    double ms = (Stopwatch.GetTimestamp() - t0) * 1000.0 / Stopwatch.Frequency;
                    nBlk++;
                    if (ms > maxLat) maxLat = ms;
                    if (ms > res.MaxLatencyMs) res.MaxLatencyMs = ms;
                    if (!ok || got <= 0) {
                        if (code == 38 || (ok && got == 0)) break;   // конец диска
                        errs++; res.Errors++; ProgErrors = res.Errors; consecutiveErr++;
                        if (errPos.Count < 20) { errPos.Add(pos); errCode.Add(code); }
                        // диск пропал / не готов — дальше читать бессмысленно
                        if (code == 21 || code == 1167 || code == 2 || code == 6 || code == 55 || consecutiveErr >= 30) { res.Aborted = true; res.Note = "диск перестал отвечать (код " + code + ")"; break; }
                        break;  // зону с ошибкой не «долбим» — переходим к следующей
                    }
                    consecutiveErr = 0;
                    res.BytesRead += got;
                    if (ms > slowMs) { res.SlowBlocks++; ProgSlow = res.SlowBlocks; }
                    if (nBlk > 1 || zEnd - zStart <= block) { measBytes += got; measMs += ms; } // 1-й блок зоны включает позиционирование головок
                    pos += got;
                    if (zw.Elapsed.TotalMilliseconds >= sliceMs && nBlk >= 2) break;
                    if (total.Elapsed.TotalMilliseconds >= limitMs) break;
                }
                if (measMs <= 0 && res.BytesRead > 0 && errs == 0 && nBlk == 1) {
                    // зона из одного блока — считаем с позиционированием
                    measBytes = Math.Min(block, zEnd - zStart); measMs = maxLat;
                }
                double sp = (measMs > 0 && measBytes > 0) ? measBytes / 1048576.0 / (measMs / 1000.0) : double.NaN;
                zSpeed.Add(sp); zLat.Add(maxLat); zOff.Add(zStart); zErr.Add(errs);
                if (!double.IsNaN(sp)) ProgLastMBs = sp;
                ProgZones = z + 1;
                if (res.Aborted || Cancel) break;
                if (total.Elapsed.TotalMilliseconds >= limitMs && z < zones - 1) { res.TimedOut = true; break; }
            }
        } finally {
            VirtualFree(buf, UIntPtr.Zero, MEM_RELEASE);
            h.Dispose();
        }
        total.Stop();
        res.Seconds = total.Elapsed.TotalSeconds;
        res.ZonesDone = zSpeed.Count;
        res.ZoneMBs = zSpeed.ToArray(); res.ZoneMaxLatMs = zLat.ToArray(); res.ZoneOffsets = zOff.ToArray(); res.ZoneErrors = zErr.ToArray();
        res.ErrorPositions = errPos.ToArray(); res.ErrorCodes = errCode.ToArray();
        double sum = 0, mn = double.MaxValue; int n = 0;
        foreach (double v in zSpeed) { if (double.IsNaN(v)) continue; sum += v; n++; if (v < mn) mn = v; }
        res.AvgSpeed = n > 0 ? sum / n : 0;
        res.MinSpeed = n > 0 ? mn : 0;
        return res;
    }

    // Фоновый запуск: PowerShell опрашивает ProgZones/ProgLastMBs/IsRunning и забирает LastResult
    public static void StartScan(int diskNumber, long startByte, long length, int blockMB, int timeLimitSec, int zones, int slowMs) {
        Cancel = false; LastResult = null; LastError = "";
        ProgZones = 0; ProgTotal = zones; ProgErrors = 0; ProgSlow = 0; ProgLastMBs = 0;
        worker = new Thread(delegate() {
            try { LastResult = ScanDisk(diskNumber, startByte, length, blockMB, timeLimitSec, zones, slowMs); }
            catch (Exception e) { LastError = e.Message; }
        });
        worker.IsBackground = true;
        worker.Start();
    }
    public static bool IsRunning { get { return worker != null && worker.IsAlive; } }
    public static void Wait(int ms) { if (worker != null) worker.Join(ms); }
}
'@
    try { Add-Type -TypeDefinition $src -Language CSharp -ErrorAction Stop; $G.SurfaceOk = $true }
    catch { $G.Log.Add('surface cs: ' + $_.Exception.Message) }
}
function Get-SurfaceDiskSize($Number) {
    # Размер диска: Get-Disk → Get-PhysicalDisk → IOCTL
    $sz = $null
    try { $sz = [double](Get-Disk -Number $Number -ErrorAction Stop).Size } catch {}
    if (-not $sz) { try { $sz = [double](Get-PhysicalDisk -ErrorAction Stop | Where-Object { "$($_.DeviceId)" -eq "$Number" } | Select-Object -First 1).Size } catch {} }
    if (-not $sz -and $G.SurfaceOk) { try { $l = [DiagSurface]::GetDiskLength([int]$Number); if ($l -gt 0) { $sz = [double]$l } } catch {} }
    return $sz
}
function Get-SpeedGraph($vals, [int]$Width = 60, $errIdx = @()) {
    # Компактный «график» скорости по зонам: ▁▂▃▄▅▆▇█, × — зона с ошибкой чтения
    $ch = [char[]]@(0x2581, 0x2582, 0x2583, 0x2584, 0x2585, 0x2586, 0x2587, 0x2588)
    $v = (AsArr $vals); if (-not $v.Count) { return '' }
    $ok = @($v | Where-Object { -not [double]::IsNaN([double]$_) })
    $mx = if ($ok.Count) { ($ok | Measure-Object -Maximum).Maximum } else { 0 }
    $w = [math]::Min($Width, $v.Count); $sbG = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $w; $i++) {
        $a = [int][math]::Floor($i * $v.Count / $w); $b = [int][math]::Floor(($i + 1) * $v.Count / $w) - 1; if ($b -lt $a) { $b = $a }
        $bad = $false; $sum = 0.0; $n = 0; $lo = [double]::MaxValue
        for ($j = $a; $j -le $b; $j++) {
            if ($errIdx -contains $j) { $bad = $true }
            $x = [double]$v[$j]; if ([double]::IsNaN($x)) { $bad = $true; continue }
            $sum += $x; $n++; if ($x -lt $lo) { $lo = $x }
        }
        if ($bad) { [void]$sbG.Append([char]0x00D7); continue }
        if (-not $n -or $mx -le 0) { [void]$sbG.Append(' '); continue }
        # минимум в корзине — чтобы провал не «размазался» усреднением
        $k = [int][math]::Floor(($lo / $mx) * 7.999); if ($k -lt 0) { $k = 0 }; if ($k -gt 7) { $k = 7 }
        [void]$sbG.Append($ch[$k])
    }
    return $sbG.ToString()
}
