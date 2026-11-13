# Поддельный объём флешки (аналог H2testw): только СЪЁМНЫЕ USB-накопители (DriveType=2), не системные.
# В отдельную новую папку пишутся файлы по 256 МБ с уникальным содержимым каждого мегабайта (номер блока + псевдослучайный поток),
# затем всё читается обратно и сверяется. Подмена/зацикливание объёма (wraparound), отброшенные записи и порча данных дают «поддельный объём».
# Чужие файлы не читаются и не изменяются; после теста папка теста удаляется. Свободное место заполняется не полностью (запас 2 %, не менее 64 МБ).
# Лимиты: не более 32 ГБ, запись до 5 мин и чтение до 5 мин (если не успели - проверка частичная, это указывается).
Step 'Поиск подделок: тест объёма флешки' {
    $s = New-Section 'Поиск подделок: тест объёма флешки'
    if (-not ('PcDiagFakeFlash' -as [type])) {
        $ffSrc = @'
using System;
using System.IO;
using System.Threading;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Collections.Generic;

public class PcDiagFakeFlash {
    public const int Blk = 1048576;
    public const int PerFile = 256;
    const ulong Magic = 0x5043444941474646UL;
    public string Dir; public long Total; public int WriteSec; public int ReadSec; public ulong Seed;
    public volatile int Phase;            // 0 запись, 1 чтение, 2 готово
    public long Written, Read, Good, Bad, Wrap, Zero, Corrupt, IoErr, FirstBad = -1, WrapEst = -1;
    public double WriteMBs, ReadMBs;
    public string Error = "";
    public bool Direct = true;
    public List<string> Notes = new List<string>();
    Thread th;

    public void Start() { th = new Thread(Run); th.IsBackground = true; th.Start(); }
    public bool Alive { get { return th != null && th.IsAlive; } }

    static void Fill(ulong[] w, long idx, ulong seed) {
        ulong x = seed ^ ((ulong)(idx + 1) * 0x9E3779B97F4A7C15UL);
        if (x == 0) x = 0x1234567;
        for (int i = 3; i < w.Length; i++) { x ^= x << 13; x ^= x >> 7; x ^= x << 17; w[i] = x; }
        w[0] = Magic; w[1] = (ulong)idx; w[2] = seed;
    }
    string FileName(long fi) { return Path.Combine(Dir, "f" + fi.ToString("D5") + ".bin"); }

    FileStream Open(string p, bool write) {
        FileOptions o = FileOptions.WriteThrough;
        if (Direct) o = o | (FileOptions)0x20000000;   // FILE_FLAG_NO_BUFFERING: читаем с устройства, а не из кэша Windows
        try {
            if (write) return new FileStream(p, FileMode.CreateNew, FileAccess.Write, FileShare.None, 1, o);
            return new FileStream(p, FileMode.Open, FileAccess.Read, FileShare.None, 1, o);
        } catch (ArgumentException) { throw; }
        catch (IOException) { if (!Direct) throw; Direct = false; Notes.Add("без обхода кэша Windows (устройство не поддерживает прямой доступ)"); return Open(p, write); }
    }

    void Run() {
        GCHandle h = default(GCHandle);
        try {
            byte[] raw = new byte[Blk + 8192];
            h = GCHandle.Alloc(raw, GCHandleType.Pinned);
            long addr = h.AddrOfPinnedObject().ToInt64();
            int off = (int)((4096 - (addr & 4095)) & 4095);
            ulong[] w = new ulong[Blk / 8];
            ulong[] e = new ulong[Blk / 8];
            long blocks = Total / Blk;
            Stopwatch sw = Stopwatch.StartNew();
            // ---- запись
            long g = 0; FileStream fs = null;
            try {
                while (g < blocks) {
                    if (sw.Elapsed.TotalSeconds > WriteSec) { Notes.Add("запись остановлена по времени"); break; }
                    if (g % PerFile == 0) { if (fs != null) { fs.Flush(true); fs.Dispose(); fs = null; } fs = Open(FileName(g / PerFile), true); }
                    Fill(w, g, Seed);
                    Buffer.BlockCopy(w, 0, raw, off, Blk);
                    fs.Write(raw, off, Blk);
                    g++; Written = g;
                }
                if (fs != null) { fs.Flush(true); fs.Dispose(); fs = null; }
            } catch (Exception ex) { Error = "запись: " + ex.Message; Notes.Add("запись прервана ошибкой на блоке " + g); try { if (fs != null) fs.Dispose(); } catch { } }
            double ws = sw.Elapsed.TotalSeconds; if (ws > 0) WriteMBs = Written / ws;
            // ---- чтение и сверка
            Phase = 1;
            sw.Reset(); sw.Start();
            long total = Written; long r = 0; FileStream rs = null;
            try {
                while (r < total) {
                    if (sw.Elapsed.TotalSeconds > ReadSec) { Notes.Add("чтение остановлено по времени"); break; }
                    if (r % PerFile == 0) { if (rs != null) { rs.Dispose(); rs = null; } rs = Open(FileName(r / PerFile), false); }
                    bool ioerr = false; int got = 0;
                    try { while (got < Blk) { int n = rs.Read(raw, off + got, Blk - got); if (n <= 0) break; got += n; } }
                    catch (IOException) { ioerr = true; }
                    r++; Read = r;
                    if (ioerr || got < Blk) { IoErr++; Bad++; if (FirstBad < 0) FirstBad = r - 1; if (ioerr) { try { rs.Dispose(); } catch { } rs = null; Open2Skip(ref rs, r); } continue; }
                    Buffer.BlockCopy(raw, off, w, 0, Blk);
                    long idx = r - 1;
                    if (w[0] == Magic && w[1] == (ulong)idx && w[2] == Seed) {
                        Fill(e, idx, Seed);
                        bool same = true;
                        for (int i = 3; i < w.Length; i++) { if (w[i] != e[i]) { same = false; break; } }
                        if (same) { Good++; continue; }
                        Corrupt++; Bad++; if (FirstBad < 0) FirstBad = idx; continue;
                    }
                    Bad++; if (FirstBad < 0) FirstBad = idx;
                    if (w[0] == Magic && w[2] == Seed) { Wrap++; long j = (long)w[1]; if (WrapEst < 0 && j > idx) WrapEst = j - idx; }
                    else {
                        bool allz = true; for (int i = 0; i < 64; i++) { if (w[i] != 0) { allz = false; break; } }
                        if (allz) Zero++; else Corrupt++;
                    }
                }
                if (rs != null) rs.Dispose();
            } catch (Exception ex2) { Error = (Error.Length > 0 ? Error + "; " : "") + "чтение: " + ex2.Message; try { if (rs != null) rs.Dispose(); } catch { } }
            double rsec = sw.Elapsed.TotalSeconds; if (rsec > 0) ReadMBs = Read / rsec;
        } catch (Exception ex3) { Error = (Error.Length > 0 ? Error + "; " : "") + ex3.Message; }
        finally { if (h.IsAllocated) h.Free(); Phase = 2; }
    }
    // после ошибки чтения продолжаем со следующего блока: открываем файл заново и встаём на смещение
    void Open2Skip(ref FileStream rs, long nextBlock) {
        try {
            if (nextBlock % PerFile == 0) return;                 // следующий блок - в новом файле, откроется в цикле
            rs = Open(FileName((nextBlock - 1) / PerFile), false);
            rs.Seek((nextBlock % PerFile) * (long)Blk, SeekOrigin.Begin);
        } catch { rs = null; }
    }
}
'@
        try { Add-Type -TypeDefinition $ffSrc -Language CSharp -ErrorAction Stop } catch { Add-Row $s 'Тест' ('не удалось подготовить тест: ' + $_.Exception.Message) 'warn'; return }
    }
    $sysDrive = ($env:SystemDrive + '\').ToUpper()
    $drives = @(CIM Win32_LogicalDisk | Where-Object { $_.DriveType -eq 2 -and $_.DeviceID -and ($_.DeviceID + '\').ToUpper() -ne $sysDrive })
    if (-not $drives.Count) {
        Add-Row $s 'Съёмные накопители' 'не подключены - вставьте проверяемую флешку и запустите тест снова'
        Info 'съёмные USB-накопители не найдены'
        return
    }
    $cap = 32GB; $wSec = 300; $rSec = 300
    $res = @(); $nBad = 0; $nOk = 0; $realMin = $null
    foreach ($ld in $drives) {
        $root = $ld.DeviceID + '\'
        $lbl = '{0} {1}' -f $ld.DeviceID, $(if ($ld.VolumeName) { '«' + $ld.VolumeName + '»' } else { '' })
        $lbl = $lbl.Trim()
        $di = $null; try { $di = New-Object IO.DriveInfo($ld.DeviceID) } catch {}
        if (-not $di -or -not $di.IsReady) { Add-Row $s $lbl 'не готов (нет носителя)' 'warn'; continue }
        $sizeB = [double]$di.TotalSize; $free = [double]$di.AvailableFreeSpace
        $reserve = [math]::Max(64MB, $free * 0.02)
        $plan = [math]::Floor(([math]::Min($free - $reserve, [double]$cap)) / 1MB) * 1MB
        if ($plan -lt 128MB) { Add-Row $s $lbl ('мало свободного места ({0:N0} МБ) - тест не выполнен' -f ($free / 1MB)) 'warn'; continue }
        $dir = Join-Path $root ('_pcdiag_fakeflash_' + (Get-Date -Format 'HHmmss'))
        $seed = [uint64](Get-Random -Minimum 100000 -Maximum 2000000000)
        Info ('{0}: объём {1:N1} ГБ, свободно {2:N1} ГБ, проверяю {3:N1} ГБ (не вынимайте флешку)' -f $lbl, ($sizeB / 1GB), ($free / 1GB), ($plan / 1GB))
        $t = $null; $created = $false
        try {
            New-Item -ItemType Directory -Path $dir -ErrorAction Stop | Out-Null
            $created = $true
            $t = New-Object PcDiagFakeFlash
            $t.Dir = $dir; $t.Total = [int64]$plan; $t.WriteSec = $wSec; $t.ReadSec = $rSec; $t.Seed = [uint64]$seed
            $t.Start()
            $t0 = Get-Date
            while ($t.Alive) {
                Start-Sleep -Milliseconds 1000
                if ($t.Phase -eq 0) { Write-Host -NoNewline ("`r    запись:  {0,6:N0} МБ из {1:N0} | {2,5:N0} с   " -f $t.Written, ($plan / 1MB), ((Get-Date) - $t0).TotalSeconds) }
                elseif ($t.Phase -eq 1) { Write-Host -NoNewline ("`r    чтение:  {0,6:N0} МБ из {1:N0} | ошибок {2}   " -f $t.Read, $t.Written, $t.Bad) }
            }
            Write-Host ''
        } catch {
            Add-Row $s $lbl ('ошибка теста: ' + $_.Exception.Message) 'warn'
            if ($t) { $t.Error = "$($t.Error)" }
        }
        # ---- удаление файлов теста (только своя папка)
        if ($created) {
            for ($try = 0; $try -lt 3; $try++) {
                try { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction Stop; break } catch { Start-Sleep -Milliseconds 800 }
            }
            if (Test-Path -LiteralPath $dir) { Add-Row $s ($lbl + ': файлы теста') ('не удалось удалить папку ' + $dir + ' - удалите её вручную') 'warn' }
        }
        if (-not $t) { continue }
        $checked = [double]$t.Read; $writ = [double]$t.Written
        $partial = ($writ -lt ($plan / 1MB)) -or ($checked -lt $writ)
        $verdict = 'ok'; $txt = ''
        if ($t.Bad -gt 0 -or ($t.Error -and $writ -lt 1)) {
            $verdict = 'crit'
            $real = $null
            if ($t.WrapEst -gt 0) { $real = [double]$t.WrapEst / 1024 } elseif ($t.FirstBad -ge 0) { $real = [double]$t.FirstBad / 1024 }
            $txt = ('сбойных блоков: {0:N0} из {1:N0} МБ (зацикливание: {2:N0}, нули: {3:N0}, порча: {4:N0}, ошибки чтения: {5:N0})' -f $t.Bad, $checked, $t.Wrap, $t.Zero, $t.Corrupt, $t.IoErr)
            if ($null -ne $real) { $txt += ('; реальный объём примерно {0:N1} ГБ при заявленных {1:N0} ГБ' -f $real, ($sizeB / 1GB)); if ($null -eq $realMin -or $real -lt $realMin) { $realMin = $real } }
            $nBad++
            Add-Issue 'crit' 'Накопитель' ('{0} - поддельный объём или неисправная память: {1}' -f $lbl, $txt) 'Флешка/карта памяти не хранит заявленный объём (данные теряются или затираются). Не доверяйте ей важные файлы; при покупке - возврат средств.'
        } elseif ($t.Error) {
            $verdict = 'warn'; $txt = ('тест прерван: ' + $t.Error)
        } else {
            $nOk++
            $txt = ('записано и проверено {0:N0} МБ без ошибок' -f $checked)
            if ($partial) { $verdict = 'warn'; $txt += (' - проверка частичная ({0}); подмена объёма за пределами проверенного не исключена' -f (($t.Notes | Select-Object -Unique) -join '; ')) }
            elseif ($sizeB -gt ($cap * 1.02)) { $verdict = 'warn'; $txt += (' (проверена только первая часть: лимит 32 ГБ из {0:N0} ГБ)' -f ($sizeB / 1GB)) }
        }
        Add-Row $s $lbl $txt $verdict
        Add-Row $s ($lbl + ': скорость') ('запись {0:N1} МБ/с, чтение {1:N1} МБ/с{2}' -f $t.WriteMBs, $t.ReadMBs, $(if (-not $t.Direct) { ' (кэш Windows мог завысить чтение)' } else { '' })) $(if ($t.WriteMBs -gt 0 -and $t.WriteMBs -lt 3) { 'warn' } else { '' })
        $res += [pscustomobject]@{ 'Накопитель' = $lbl; 'Заявлено, ГБ' = ('{0:N1}' -f ($sizeB / 1GB)); 'Проверено, ГБ' = ('{0:N2}' -f ($checked / 1024)); 'Ошибок' = $t.Bad; 'Запись, МБ/с' = ('{0:N1}' -f $t.WriteMBs); 'Чтение, МБ/с' = ('{0:N1}' -f $t.ReadMBs); 'Вердикт' = $(if ($verdict -eq 'crit') { 'ПОДДЕЛКА / СБОЙ' } elseif ($verdict -eq 'warn') { 'частично' } else { 'норма' }) }
    }
    if ($res.Count) { Add-Table $s 'Тест объёма съёмных накопителей' $res }
    $G.Num.fakeflash_n = $res.Count
    $G.Num.fakeflash_bad = $nBad
    if ($null -ne $realMin) { $G.Num.fakeflash_real_gb = [math]::Round($realMin, 1) }
}
