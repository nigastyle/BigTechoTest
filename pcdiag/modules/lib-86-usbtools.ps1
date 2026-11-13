# Инструменты для USB-флешек (НЕ шаг диагностики): запись образов на флешку.
#   Invoke-DiagTool 'memtest86usb' -> Start-MemTest86Usb   (флешка MemTest86 в один клик)
#   Invoke-DiagTool 'rescueusb'    -> New-BttRescueUsb     (загрузочная флешка BTT на WinPE, lib-87-winpe.ps1)
# Хук для body.ps1 (сразу после строки #%%MOD:lib%%):
#   if ($env:DIAG_TOOL) { Invoke-DiagTool $env:DIAG_TOOL; exit }
# БЕЗОПАСНОСТЬ: пишем ТОЛЬКО на диск с шиной USB, не загрузочный/не системный, не тот, где лежит Windows,
# сама программа или временные файлы; выбор подтверждается вводом размера диска (а для дисков > 256 ГБ — дважды);
# в авторежиме (DIAG_AUTO) и в WinPE-режиме инструменты не запускаются.

# MemTest86 Free (PassMark), v11.7 build 1000, zip от 03.05.2026 (12 715 306 байт). URL без версии:
# когда PassMark выпустит новую версию, Sha перестанет совпадать — обновите Sha/ImgSha (Get-Tool откажется от файла).
$TOOLS.MemTest86 = @{ Url = 'https://www.memtest86.com/downloads/memtest86-usb.zip'; Sha = '1C01E03ADAC5C9E4D5D4E863DE16771161B00E06032B7E91B1AEEBA86C35A4DE'; Dir = 'MemTest86'; Exe = 'MemTest86\memtest86-usb.img'; ImgSha = '1CE1C2069C59149F114E8CB83948C7DA360027555AE859D5BCB6ABD094593808'; ImgLen = 1073741824 }

$G.BttUsbMaxPlainGB = 256    # больше — только после второго подтверждения
$G.BttUsbCsSrc = @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using Microsoft.Win32.SafeHandles;

namespace BttUsb
{
    public delegate void ProgressFn(string phase, long done, long total);

    public class WriteResult
    {
        public bool Ok;
        public string Error = "";
        public long Bytes;
        public string ImageSha = "";
        public string ReadBackSha = "";
        public double WriteSeconds;
        public double VerifySeconds;
        public int LockedVolumes;
        public int Volumes;
    }

    public static class RawDisk
    {
        const uint GENERIC_READ = 0x80000000, GENERIC_WRITE = 0x40000000;
        const uint FILE_SHARE_READ = 1, FILE_SHARE_WRITE = 2, OPEN_EXISTING = 3;
        const uint FILE_FLAG_NO_BUFFERING = 0x20000000, FILE_FLAG_WRITE_THROUGH = 0x80000000;
        const uint FSCTL_LOCK_VOLUME = 0x00090018, FSCTL_DISMOUNT_VOLUME = 0x00090020;
        const uint IOCTL_STORAGE_QUERY_PROPERTY = 0x002D1400, IOCTL_STORAGE_GET_DEVICE_NUMBER = 0x002D1080;
        const uint IOCTL_DISK_GET_LENGTH_INFO = 0x0007405C, IOCTL_DISK_GET_DRIVE_GEOMETRY = 0x00070000;
        const uint IOCTL_DISK_UPDATE_PROPERTIES = 0x00070140, IOCTL_VOLUME_GET_VOLUME_DISK_EXTENTS = 0x00560000;
        const uint MEM_COMMIT = 0x1000, MEM_RESERVE = 0x2000, MEM_RELEASE = 0x8000, PAGE_READWRITE = 4;
        public const int BusTypeUsb = 7;
        public const int Block = 1024 * 1024;

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr sa, uint disp, uint flags, IntPtr tmpl);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool DeviceIoControl(SafeFileHandle h, uint code, IntPtr inBuf, int inSize, IntPtr outBuf, int outSize, out int ret, IntPtr ov);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool WriteFile(SafeFileHandle h, IntPtr buf, int len, out int done, IntPtr ov);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool ReadFile(SafeFileHandle h, IntPtr buf, int len, out int done, IntPtr ov);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool SetFilePointerEx(SafeFileHandle h, long dist, out long newPos, uint method);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool FlushFileBuffers(SafeFileHandle h);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern IntPtr VirtualAlloc(IntPtr addr, UIntPtr size, uint type, uint protect);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool VirtualFree(IntPtr addr, UIntPtr size, uint type);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern IntPtr FindFirstVolumeW(System.Text.StringBuilder name, int len);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool FindNextVolumeW(IntPtr h, System.Text.StringBuilder name, int len);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool FindVolumeClose(IntPtr h);

        static Exception Win32(string what)
        {
            int e = Marshal.GetLastWin32Error();
            return new Exception(what + ": " + new Win32Exception(e).Message + " (код " + e + ")");
        }

        static SafeFileHandle Open(string path, uint access, uint flags)
        {
            SafeFileHandle h = CreateFile(path, access, FILE_SHARE_READ | FILE_SHARE_WRITE, IntPtr.Zero, OPEN_EXISTING, flags, IntPtr.Zero);
            if (h.IsInvalid) throw Win32("не открыть " + path);
            return h;
        }

        static byte[] Ioctl(SafeFileHandle h, uint code, byte[] input, int outSize)
        {
            IntPtr ib = IntPtr.Zero, ob = Marshal.AllocHGlobal(outSize);
            try
            {
                int inLen = 0;
                if (input != null) { inLen = input.Length; ib = Marshal.AllocHGlobal(inLen); Marshal.Copy(input, 0, ib, inLen); }
                int ret;
                if (!DeviceIoControl(h, code, ib, inLen, ob, outSize, out ret, IntPtr.Zero)) return null;
                byte[] r = new byte[ret];
                Marshal.Copy(ob, r, 0, ret);
                return r;
            }
            finally { Marshal.FreeHGlobal(ob); if (ib != IntPtr.Zero) Marshal.FreeHGlobal(ib); }
        }

        static string Disk(int n) { return @"\\.\PhysicalDrive" + n; }

        // Шина диска (STORAGE_DEVICE_DESCRIPTOR.BusType, смещение 28): 7 = USB
        public static int GetBusType(int disk)
        {
            using (SafeFileHandle h = Open(Disk(disk), 0, 0))
            {
                byte[] q = new byte[12];   // PropertyId=StorageDeviceProperty(0), QueryType=PropertyStandardQuery(0)
                byte[] r = Ioctl(h, IOCTL_STORAGE_QUERY_PROPERTY, q, 1024);
                if (r == null || r.Length < 32) throw Win32("IOCTL_STORAGE_QUERY_PROPERTY");
                return BitConverter.ToInt32(r, 28);
            }
        }

        public static long GetLength(int disk)
        {
            using (SafeFileHandle h = Open(Disk(disk), 0, 0))
            {
                byte[] r = Ioctl(h, IOCTL_DISK_GET_LENGTH_INFO, null, 8);
                if (r == null || r.Length < 8) throw Win32("IOCTL_DISK_GET_LENGTH_INFO");
                return BitConverter.ToInt64(r, 0);
            }
        }

        static int GetSectorSize(SafeFileHandle h)
        {
            byte[] r = Ioctl(h, IOCTL_DISK_GET_DRIVE_GEOMETRY, null, 24);
            if (r == null || r.Length < 24) return 512;
            int bps = BitConverter.ToInt32(r, 20);
            if (bps < 512 || bps > 65536 || (bps & (bps - 1)) != 0) return 512;
            return bps;
        }

        // Номер физического диска, на котором лежит том (например "C:"), или -1
        public static int DiskOfVolume(string letter)
        {
            try
            {
                using (SafeFileHandle h = Open(@"\\.\" + letter.TrimEnd('\\'), 0, 0))
                {
                    byte[] r = Ioctl(h, IOCTL_STORAGE_GET_DEVICE_NUMBER, null, 12);
                    if (r == null || r.Length < 8) return -1;
                    return BitConverter.ToInt32(r, 4);
                }
            }
            catch { return -1; }
        }

        // Все тома (\\?\Volume{...}) с хотя бы одним экстентом на диске disk
        public static List<string> VolumesOnDisk(int disk)
        {
            List<string> res = new List<string>();
            System.Text.StringBuilder name = new System.Text.StringBuilder(300);
            IntPtr f = FindFirstVolumeW(name, name.Capacity);
            if (f == new IntPtr(-1)) return res;
            try
            {
                do
                {
                    string v = name.ToString().TrimEnd('\\');
                    try
                    {
                        using (SafeFileHandle h = Open(v, 0, 0))
                        {
                            byte[] r = Ioctl(h, IOCTL_VOLUME_GET_VOLUME_DISK_EXTENTS, null, 8 + 24 * 32);
                            if (r != null && r.Length >= 8)
                            {
                                int cnt = BitConverter.ToInt32(r, 0);
                                for (int i = 0; i < cnt && 8 + 24 * i + 4 <= r.Length; i++)
                                    if (BitConverter.ToInt32(r, 8 + 24 * i) == disk) { res.Add(v); break; }
                            }
                        }
                    }
                    catch { }
                    name.Length = 0;
                } while (FindNextVolumeW(f, name, name.Capacity));
            }
            finally { FindVolumeClose(f); }
            return res;
        }

        // Блокирует и отмонтирует тома диска; дескрипторы держим открытыми до конца записи
        static List<SafeFileHandle> LockAndDismount(int disk, WriteResult wr)
        {
            List<SafeFileHandle> held = new List<SafeFileHandle>();
            foreach (string v in VolumesOnDisk(disk))
            {
                wr.Volumes++;
                SafeFileHandle h;
                try { h = Open(v, GENERIC_READ | GENERIC_WRITE, 0); } catch { continue; }
                int ret;
                bool locked = false;
                for (int t = 0; t < 10 && !locked; t++)
                {
                    locked = DeviceIoControl(h, FSCTL_LOCK_VOLUME, IntPtr.Zero, 0, IntPtr.Zero, 0, out ret, IntPtr.Zero);
                    if (!locked) System.Threading.Thread.Sleep(500);
                }
                if (locked) wr.LockedVolumes++;
                // принудительное отмонтирование работает и без блокировки (открытые файлы на флешке станут недействительны)
                DeviceIoControl(h, FSCTL_DISMOUNT_VOLUME, IntPtr.Zero, 0, IntPtr.Zero, 0, out ret, IntPtr.Zero);
                held.Add(h);
            }
            return held;
        }

        static string Hex(byte[] b) { return BitConverter.ToString(b).Replace("-", ""); }

        // Записывает образ на \\.\PhysicalDriveN блоками по 1 МБ, затем читает обратно и сверяет SHA-256.
        // expectedLength — размер диска, который подтвердил пользователь (защита от подмены диска между выбором и записью);
        // forbidden — номера дисков, на которые писать нельзя никогда (системный, диск программы и т.п.).
        public static WriteResult WriteImage(int disk, string imagePath, long expectedLength, int[] forbidden, ProgressFn progress)
        {
            WriteResult wr = new WriteResult();
            List<SafeFileHandle> held = null;
            IntPtr buf = IntPtr.Zero;
            try
            {
                if (disk < 0) throw new Exception("неверный номер диска");
                if (forbidden != null) foreach (int f in forbidden) if (f == disk) throw new Exception("диск " + disk + " запрещён для записи (системный или с программой)");
                string sysDrive = Environment.GetEnvironmentVariable("SystemDrive");
                if (string.IsNullOrEmpty(sysDrive)) sysDrive = "C:";
                int sysDisk = DiskOfVolume(sysDrive);
                if (sysDisk == disk) throw new Exception("это системный диск — запись запрещена");
                int bus = GetBusType(disk);
                if (bus != BusTypeUsb) throw new Exception("диск не на шине USB (BusType=" + bus + ") — запись запрещена");
                long len = GetLength(disk);
                if (len != expectedLength) throw new Exception("размер диска изменился (" + len + " вместо " + expectedLength + ") — флешку заменили? Запись отменена");
                FileInfo fi = new FileInfo(imagePath);
                long imgLen = fi.Length;
                if (imgLen <= 0) throw new Exception("пустой образ");
                if (imgLen > len) throw new Exception("образ больше флешки");

                held = LockAndDismount(disk, wr);

                using (SafeFileHandle h = Open(Disk(disk), GENERIC_READ | GENERIC_WRITE, FILE_FLAG_NO_BUFFERING | FILE_FLAG_WRITE_THROUGH))
                using (FileStream fs = new FileStream(imagePath, FileMode.Open, FileAccess.Read, FileShare.Read, Block, FileOptions.SequentialScan))
                {
                    int sector = GetSectorSize(h);
                    buf = VirtualAlloc(IntPtr.Zero, new UIntPtr((uint)Block), MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);  // выровнен по странице
                    if (buf == IntPtr.Zero) throw Win32("VirtualAlloc");
                    byte[] mb = new byte[Block];
                    byte[] zero = new byte[Block];
                    long pos;
                    if (!SetFilePointerEx(h, 0, out pos, 0)) throw Win32("seek");

                    // --- запись
                    DateTime t0 = DateTime.Now;
                    using (SHA256 sha = SHA256.Create())
                    {
                        long done = 0;
                        while (done < imgLen)
                        {
                            int want = (int)Math.Min(Block, imgLen - done);
                            int got = 0;
                            while (got < want) { int n = fs.Read(mb, got, want - got); if (n <= 0) throw new Exception("образ прочитан не полностью"); got += n; }
                            sha.TransformBlock(mb, 0, got, null, 0);
                            int aligned = (got + sector - 1) / sector * sector;   // хвост добиваем нулями до сектора
                            if (aligned > got) Array.Clear(mb, got, aligned - got);
                            Marshal.Copy(mb, 0, buf, aligned);
                            int w;
                            if (!WriteFile(h, buf, aligned, out w, IntPtr.Zero) || w != aligned) throw Win32("ошибка записи на смещении " + done);
                            done += got;
                            if (progress != null) progress("write", done, imgLen);
                        }
                        sha.TransformFinalBlock(new byte[0], 0, 0);
                        wr.ImageSha = Hex(sha.Hash);
                        wr.Bytes = done;
                    }
                    // Затираем последний 1 МБ флешки: старая резервная GPT в конце диска путает прошивки и Windows
                    long tail = (len - Block) / sector * sector;
                    if (tail >= imgLen + Block)
                    {
                        Marshal.Copy(zero, 0, buf, Block);
                        int w;
                        if (SetFilePointerEx(h, tail, out pos, 0)) WriteFile(h, buf, (int)Math.Min(Block, len - tail), out w, IntPtr.Zero);
                    }
                    if (!FlushFileBuffers(h)) throw Win32("FlushFileBuffers");
                    wr.WriteSeconds = (DateTime.Now - t0).TotalSeconds;

                    // --- проверка: читаем записанное обратно и считаем SHA-256
                    t0 = DateTime.Now;
                    if (!SetFilePointerEx(h, 0, out pos, 0)) throw Win32("seek");
                    using (SHA256 sha = SHA256.Create())
                    {
                        long done = 0;
                        while (done < imgLen)
                        {
                            int want = (int)Math.Min(Block, imgLen - done);
                            int aligned = (want + sector - 1) / sector * sector;
                            int r;
                            if (!ReadFile(h, buf, aligned, out r, IntPtr.Zero) || r < want) throw Win32("ошибка чтения на смещении " + done);
                            Marshal.Copy(buf, mb, 0, want);
                            sha.TransformBlock(mb, 0, want, null, 0);
                            done += want;
                            if (progress != null) progress("verify", done, imgLen);
                        }
                        sha.TransformFinalBlock(new byte[0], 0, 0);
                        wr.ReadBackSha = Hex(sha.Hash);
                    }
                    wr.VerifySeconds = (DateTime.Now - t0).TotalSeconds;
                    int ret2;
                    DeviceIoControl(h, IOCTL_DISK_UPDATE_PROPERTIES, IntPtr.Zero, 0, IntPtr.Zero, 0, out ret2, IntPtr.Zero);
                }
                wr.Ok = wr.ImageSha.Length > 0 && wr.ImageSha == wr.ReadBackSha;
                if (!wr.Ok) wr.Error = "прочитанные с флешки данные не совпали с образом — флешка неисправна или подделка по объёму";
            }
            catch (Exception ex) { wr.Ok = false; wr.Error = ex.Message; }
            finally
            {
                if (buf != IntPtr.Zero) VirtualFree(buf, UIntPtr.Zero, MEM_RELEASE);
                if (held != null) foreach (SafeFileHandle x in held) { try { x.Dispose(); } catch { } }   // закрытие снимает блокировку
            }
            return wr;
        }
    }
}
'@

function Initialize-BttUsb {
    if ('BttUsb.RawDisk' -as [type]) { return $true }
    try { Add-Type -TypeDefinition $G.BttUsbCsSrc -Language CSharp -ErrorAction Stop; return $true }
    catch { Bad ('модуль записи на флешку не загрузился: ' + $_.Exception.Message); return $false }
}

function Test-BttToolAllowed {
    # Инструменты записи — только вручную, только интерактивно, только из обычной Windows
    if ($G.Auto -or $env:DIAG_AUTO -eq '1') { Bad 'Запись на флешку в авторежиме запрещена.'; return $false }
    if ($env:DIAG_PE) { Bad 'Запись на флешку из WinPE-режима отключена.'; return $false }
    if (-not [Environment]::UserInteractive) { Bad 'Нужен интерактивный запуск (окно консоли).'; return $false }
    $adm = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $adm) { Bad 'Нужны права администратора.'; return $false }
    return $true
}

function Get-BttForbiddenDisks {
    # Диски, которые трогать нельзя никогда: системный, загрузочный, диск программы и временных файлов
    $list = New-Object System.Collections.Generic.List[int]
    foreach ($p in @($env:SystemDrive, $G.Root, $G.Temp, $G.Tools, $env:TEMP, $env:SystemRoot)) {
        if (-not $p) { continue }
        $q = "$p"
        if ($q.Length -lt 2 -or $q[1] -ne ':') { continue }
        try {
            $part = Get-Partition -DriveLetter $q[0] -ErrorAction Stop | Select-Object -First 1
            if ($part -and -not $list.Contains([int]$part.DiskNumber)) { $list.Add([int]$part.DiskNumber) }
        } catch {}
    }
    foreach ($d in @(Get-Disk -ErrorAction SilentlyContinue)) {
        if (($d.IsBoot -or $d.IsSystem) -and -not $list.Contains([int]$d.Number)) { $list.Add([int]$d.Number) }
    }
    # тома с файлом подкачки
    foreach ($pf in @(CIM Win32_PageFileUsage)) {
        $nm = "$($pf.Name)"
        if ($nm.Length -ge 2 -and $nm[1] -eq ':') {
            try { $part = Get-Partition -DriveLetter $nm[0] -ErrorAction Stop | Select-Object -First 1; if ($part -and -not $list.Contains([int]$part.DiskNumber)) { $list.Add([int]$part.DiskNumber) } } catch {}
        }
    }
    return , $list.ToArray()
}

function Get-BttUsbCandidates([long]$MinBytes) {
    $bad = Get-BttForbiddenDisks
    $dd = @{}
    foreach ($w in @(CIM Win32_DiskDrive)) { $dd[[int]$w.Index] = $w }
    $res = @()
    foreach ($d in @(Get-Disk -ErrorAction SilentlyContinue | Sort-Object Number)) {
        if ("$($d.BusType)" -ne 'USB') { continue }
        if ($d.IsBoot -or $d.IsSystem) { continue }
        if ($bad -contains [int]$d.Number) { continue }
        if (-not $d.Size -or $d.Size -lt $MinBytes) { continue }
        $letters = @(Get-Partition -DiskNumber $d.Number -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter -and "$($_.DriveLetter)" -match '[A-Z]' } | ForEach-Object { "$($_.DriveLetter):" }) -join ' '
        $w = $dd[[int]$d.Number]
        $kind = 'внешний USB-диск'
        if ($w -and "$($w.MediaType)" -match 'Removable') { $kind = 'флешка/карта' }
        $res += [pscustomobject]@{ Number = [int]$d.Number; Model = ("$($d.FriendlyName)").Trim(); Size = [long]$d.Size; SizeGB = [double]$d.Size / 1e9; Letters = $letters; Kind = $kind; Serial = ("$($d.SerialNumber)").Trim(); UniqueId = "$($d.UniqueId)" }
    }
    return , $res
}

function Read-BttUsbTarget([long]$MinBytes, [string]$Purpose) {
    # Интерактивный выбор флешки. Возвращает объект диска или $null (отказ/отмена).
    if (-not (Test-BttToolAllowed)) { return $null }
    while ($true) {
        $list = Get-BttUsbCandidates $MinBytes
        Write-Host ''
        if ($list.Count -eq 0) {
            Warn ('USB-накопители объёмом от {0:N1} ГБ не найдены (системные и диск с программой скрыты).' -f ($MinBytes / 1e9))
            $a = Read-Host 'Вставьте флешку и нажмите Enter (или введите 0 для выхода)'
            if ("$a".Trim() -eq '0') { return $null }
            Start-Sleep -Seconds 2
            continue
        }
        Write-Host '  Найдены USB-накопители:' -ForegroundColor Cyan
        Write-Host ('  {0,-4} {1,-36} {2,10}  {3,-18} {4}' -f '№', 'Модель', 'Размер', 'Тип', 'Буквы')
        foreach ($c in $list) {
            $col = 'Gray'
            if ($c.SizeGB -gt $G.BttUsbMaxPlainGB) { $col = 'Yellow' }
            $mdl = $c.Model; if ($mdl.Length -gt 36) { $mdl = $mdl.Substring(0, 36) }
            Write-Host ('  {0,-4} {1,-36} {2,7:N1} ГБ  {3,-18} {4}' -f $c.Number, $mdl, $c.SizeGB, $c.Kind, $c.Letters) -ForegroundColor $col
        }
        Write-Host ''
        $a = Read-Host ('Номер диска для «{0}» (Enter — обновить список, 0 — выход)' -f $Purpose)
        $a = "$a".Trim()
        if ($a -eq '0') { return $null }
        if ($a -eq '') { continue }
        $num = 0
        if (-not [int]::TryParse($a, [ref]$num)) { Warn 'Введите номер из первой колонки.'; continue }
        $pick = @($list | Where-Object { $_.Number -eq $num }) | Select-Object -First 1
        if (-not $pick) { Warn 'Такого номера нет в списке.'; continue }

        Write-Host ''
        Write-Host ('  ВЫБРАН ДИСК {0}: {1}' -f $pick.Number, $pick.Model) -ForegroundColor Yellow
        Write-Host ('  Размер: {0:N1} ГБ ({1:N0} байт), тип: {2}, серийный №: {3}' -f $pick.SizeGB, $pick.Size, $pick.Kind, $(if ($pick.Serial) { $pick.Serial } else { '—' })) -ForegroundColor Yellow
        foreach ($v in @(Get-Partition -DiskNumber $pick.Number -ErrorAction SilentlyContinue | Get-Volume -ErrorAction SilentlyContinue)) {
            Write-Host ('    том {0}: «{1}» {2}, {3:N1} ГБ, занято {4:N1} ГБ' -f $(if ($v.DriveLetter) { "$($v.DriveLetter):" } else { '(без буквы)' }), $v.FileSystemLabel, $v.FileSystem, ($v.Size / 1e9), (($v.Size - $v.SizeRemaining) / 1e9)) -ForegroundColor Yellow
        }
        Write-Host '  ВСЕ ДАННЫЕ НА ЭТОМ ДИСКЕ БУДУТ УНИЧТОЖЕНЫ БЕЗ ВОЗМОЖНОСТИ ВОССТАНОВЛЕНИЯ.' -ForegroundColor Red
        if ($pick.Kind -ne 'флешка/карта') { Write-Host '  Внимание: это внешний USB-диск (HDD/SSD/бокс), а не флешка. Убедитесь, что на нём нет нужных данных.' -ForegroundColor Red }
        $want = [math]::Round($pick.SizeGB)
        $typed = Read-Host 'Для подтверждения введите РАЗМЕР этого диска в ГБ (целое число, как в таблице), иначе Enter'
        $digits = ("$typed" -replace '[^\d,\.]', '') -replace ',', '.'
        $tv = 0.0
        if (-not [double]::TryParse($digits, [Globalization.NumberStyles]::Float, $IC, [ref]$tv) -or [math]::Round($tv) -ne $want) { Warn 'Размер не совпал — запись отменена.'; return $null }
        if ($pick.SizeGB -gt $G.BttUsbMaxPlainGB) {
            Write-Host ('  Диск больше {0} ГБ — для флешки это необычно. Скорее всего это внешний диск с данными!' -f $G.BttUsbMaxPlainGB) -ForegroundColor Red
            $t2 = Read-Host ('Второе подтверждение: введите  СТЕРЕТЬ {0}' -f $pick.Number)
            if ("$t2".Trim().ToUpper() -ne ('СТЕРЕТЬ ' + $pick.Number)) { Warn 'Подтверждение не совпало — запись отменена.'; return $null }
        }
        $G.Log.Add(('USB-инструмент: выбран диск {0} «{1}» {2} байт, serial {3}' -f $pick.Number, $pick.Model, $pick.Size, $pick.Serial))
        return $pick
    }
}

function Assert-BttUsbTarget($Target) {
    # Повторная проверка прямо перед записью: тот же диск, всё ещё USB, не системный
    try { $d = Get-Disk -Number $Target.Number -ErrorAction Stop } catch { Bad 'Диск пропал — запись отменена.'; return $false }
    if ("$($d.BusType)" -ne 'USB' -or $d.IsBoot -or $d.IsSystem) { Bad 'Диск больше не похож на USB-флешку — запись отменена.'; return $false }
    if ([long]$d.Size -ne $Target.Size -or "$($d.UniqueId)" -ne $Target.UniqueId) { Bad 'Флешку заменили (другой размер/идентификатор) — запись отменена.'; return $false }
    if ((Get-BttForbiddenDisks) -contains [int]$Target.Number) { Bad 'Этот диск системный или на нём программа — запись отменена.'; return $false }
    return $true
}

function Write-BttImageToUsb($Target, [string]$Image) {
    # Сырая запись образа на выбранный диск + проверка чтением. Возвращает $true/$false.
    if (-not (Initialize-BttUsb)) { return $false }
    if (-not (Assert-BttUsbTarget $Target)) { return $false }
    $num = [int]$Target.Number
    try { Set-Disk -Number $num -IsReadOnly $false -ErrorAction Stop } catch { $G.Log.Add('Set-Disk -IsReadOnly: ' + $_.Exception.Message) }
    $wasOffline = $false
    try { Set-Disk -Number $num -IsOffline $true -ErrorAction Stop; $wasOffline = $true } catch { $G.Log.Add('Set-Disk -IsOffline (для съёмных обычно не поддерживается): ' + $_.Exception.Message) }
    $G.BttUsbLastPct = -1
    $cb = [BttUsb.ProgressFn] {
        param($phase, $done, $total)
        $pct = [int](100 * $done / $total)
        if ($pct -ne $G.BttUsbLastPct) {
            $G.BttUsbLastPct = $pct
            $nm = 'запись  '; if ($phase -eq 'verify') { $nm = 'проверка' }
            Write-Host -NoNewline ("`r    {0} {1,3}%  ({2:N0} из {3:N0} МБ)   " -f $nm, $pct, ($done / 1MB), ($total / 1MB))
            if ($done -ge $total) { Write-Host ''; $G.BttUsbLastPct = -1 }
        }
    }
    Info 'Пишу образ на флешку (не вынимайте её)...'
    $res = $null
    try { $res = [BttUsb.RawDisk]::WriteImage($num, $Image, [long]$Target.Size, [int[]](Get-BttForbiddenDisks), $cb) }
    finally {
        # вернуть диск в онлайн даже при Ctrl+C / ошибке
        if ($wasOffline) { try { Set-Disk -Number $num -IsOffline $false -ErrorAction Stop } catch { $G.Log.Add('Set-Disk online: ' + $_.Exception.Message) } }
        try { Update-Disk -Number $num -ErrorAction SilentlyContinue } catch {}
    }
    Write-Host ''
    if (-not $res) { Bad 'Запись прервана.'; return $false }
    $G.Log.Add(('USB-запись: ok={0} байт={1} sha={2} readback={3} тома {4}/{5} заблокировано, {6:N0}+{7:N0} с; {8}' -f $res.Ok, $res.Bytes, $res.ImageSha, $res.ReadBackSha, $res.LockedVolumes, $res.Volumes, $res.WriteSeconds, $res.VerifySeconds, $res.Error))
    if ($res.Ok) {
        Ok ('Записано и проверено: {0:N0} МБ, запись {1:N0} с ({2:N1} МБ/с), проверка {3:N0} с' -f ($res.Bytes / 1MB), $res.WriteSeconds, ($res.Bytes / 1MB / [math]::Max(1, $res.WriteSeconds)), $res.VerifySeconds)
        return $true
    }
    Bad ('Запись не удалась: ' + $res.Error)
    return $false
}

function Start-MemTest86Usb {
    Title 'MemTest86 на флешку'
    Say 'Создаёт загрузочную флешку MemTest86 Free (PassMark) — самый тщательный тест оперативной памяти.'
    Say 'Тест идёт без Windows, поэтому находит ошибки ОЗУ, которые не видны из-под системы.'
    Say 'MemTest86 Free © PassMark Software, скачивается с официального сайта memtest86.com. Используя его,' 'DarkGray'
    Say 'вы принимаете лицензию PassMark (EULA показывается при загрузке). Нужен ПК с UEFI (почти все с 2012 г.).' 'DarkGray'
    $t = $TOOLS.MemTest86
    $target = Read-BttUsbTarget ([long]$t.ImgLen) 'MemTest86'
    if (-not $target) { Info 'Отменено.'; return }

    $img = Get-Tool 'MemTest86'
    if (-not $img) { Bad 'Не удалось скачать MemTest86 (нет интернета или PassMark выпустил новую версию — нужна новая контрольная сумма в программе).'; return }
    Info 'проверяю образ...'
    $h = (Get-FileHash $img -Algorithm SHA256).Hash
    if ($h -ne $t.ImgSha -or (Get-Item $img).Length -ne $t.ImgLen) {
        Bad 'Образ MemTest86 повреждён или не той версии — запись отменена.'
        Remove-Item (Join-Path $G.Tools $t.Dir) -Recurse -Force -ErrorAction SilentlyContinue
        return
    }
    $ok = Write-BttImageToUsb $target $img
    Remove-Item (Join-Path $G.Tools $t.Dir) -Recurse -Force -ErrorAction SilentlyContinue   # 1 ГБ — не держим
    if (-not $ok) { Warn 'Попробуйте другую флешку или другой USB-порт. Если ошибка повторяется на разных флешках — сообщите мастеру.'; return }
    Write-Host ''
    Write-Host '  ФЛЕШКА MemTest86 ГОТОВА. Как проверить память:' -ForegroundColor Green
    Write-Host '   1. Вставьте флешку в проверяемый ПК (лучше в USB на задней панели) и перезагрузите его.'
    Write-Host '   2. Сразу после включения жмите клавишу меню загрузки (F8 / F11 / F12 / Esc — зависит от платы/ноутбука)'
    Write-Host '      и выберите флешку с пометкой UEFI.'
    Write-Host '   3. MemTest86 запустится сам (через ~10 с без нажатий). 4 прохода занимают ~1–3 ч (зависит от объёма ОЗУ).'
    Write-Host '   4. Итог: PASS — память исправна; FAIL / любые ошибки (красные строки) — память или её настройки неисправны:'
    Write-Host '      сбросьте XMP/EXPO в BIOS и повторите; при повторе проверяйте модули по одному.'
    Write-Host '   5. Отчёт (HTML) MemTest86 сохраняет на эту же флешку — его можно открыть на любом ПК.'
    Write-Host '   Не загружается? В BIOS отключите Secure Boot или разрешите «Microsoft 3rd-party UEFI CA».' -ForegroundColor DarkGray
    Write-Host '   Чтобы снова пользоваться флешкой как обычной: Управление дисками → удалить разделы → создать том.' -ForegroundColor DarkGray
}

function Invoke-DiagTool([string]$Name) {
    # Точка входа для отдельных инструментов: запуск программы с переменной окружения DIAG_TOOL=<имя>
    switch -Regex ("$Name".Trim().ToLower()) {
        '^memtest86usb$' { Start-MemTest86Usb }
        '^rescueusb$' {
            if (Get-Command New-BttRescueUsb -ErrorAction SilentlyContinue) { New-BttRescueUsb } else { Bad 'Модуль загрузочной флешки не найден.' }
        }
        default { Bad ('Неизвестный инструмент: ' + $Name) }
    }
    Write-Host ''
    try { [void](Read-Host 'Нажмите Enter, чтобы закрыть окно') } catch {}
}
