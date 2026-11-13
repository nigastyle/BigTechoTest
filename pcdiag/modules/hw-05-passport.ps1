# Паспорт компьютера: подробные характеристики КАЖДОЙ комплектующей (как сводка CPU-Z / AIDA64 / HWiNFO).
# Источники: WMI/CIM, реестр, PnP, WinAPI (топология ядер и кэшей, режимы дисплеев) + отчёт CPU-Z (SPD памяти: XMP/EXPO,
# тайминги, дата выпуска, производитель чипов; чипсет; кодовые имена; подробности видеокарт). Без CPU-Z — только данные Windows.
$TOOLS.CPUZ = @{ Url = 'https://download.cpuid.com/cpu-z/cpu-z_3.02-en.zip'; Sha = 'FAF62F6E883056A40F291BF9F3F348F51A2AB339D0A512F4724FDAE964F35D8B'; Dir = 'CPUZ'; Exe = 'CPUZ\cpuz_x64.exe' }

Step 'Паспорт компьютера: все комплектующие' {
    # ------------------------------------------------------------ WinAPI-помощник (топология CPU, функции CPU, режимы дисплеев)
    if (-not ('PcDiagHw' -as [type])) {
        $hwSrc = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class PcDiagHw {
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetLogicalProcessorInformationEx(int rel, IntPtr buf, ref uint len);
    [DllImport("kernel32.dll")] static extern bool IsProcessorFeaturePresent(uint f);
    [DllImport("kernel32.dll")] static extern bool GetFirmwareType(out int t);
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DD {
        public int cb;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
        public int StateFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DM {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
        public short dmSpecVersion; public short dmDriverVersion; public short dmSize; public short dmDriverExtra; public int dmFields;
        public int dmPositionX; public int dmPositionY; public int dmDisplayOrientation; public int dmDisplayFixedOutput;
        public short dmColor; public short dmDuplex; public short dmYResolution; public short dmTTOption; public short dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
        public short dmLogPixels; public int dmBitsPerPel; public int dmPelsWidth; public int dmPelsHeight; public int dmDisplayFlags; public int dmDisplayFrequency;
        public int dmICMMethod; public int dmICMIntent; public int dmMediaType; public int dmDitherType; public int dmReserved1; public int dmReserved2; public int dmPanningWidth; public int dmPanningHeight;
    }
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool EnumDisplayDevices(string dev, uint i, ref DD dd, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool EnumDisplaySettings(string dev, int mode, ref DM dm);

    public static bool Feature(uint f) { try { return IsProcessorFeaturePresent(f); } catch { return false; } }
    public static int FirmwareType() { int t = 0; try { if (GetFirmwareType(out t)) return t; } catch { } return 0; }

    // "core|класс_эффективности|потоков|флаги", "cache|уровень|тип|байт|ассоциативность|строка", "pkg"
    public static string[] Topology() {
        List<string> res = new List<string>();
        if (IntPtr.Size != 8) return res.ToArray();
        uint len = 0;
        GetLogicalProcessorInformationEx(0xFFFF, IntPtr.Zero, ref len);
        if (len == 0 || len > 4000000) return res.ToArray();
        IntPtr buf = Marshal.AllocHGlobal((int)len);
        try {
            if (!GetLogicalProcessorInformationEx(0xFFFF, buf, ref len)) return res.ToArray();
            long off = 0;
            while (off + 8 <= len) {
                IntPtr p = new IntPtr(buf.ToInt64() + off);
                int rel = Marshal.ReadInt32(p, 0); int size = Marshal.ReadInt32(p, 4);
                if (size <= 0) break;
                if (rel == 0) {
                    int flags = Marshal.ReadByte(p, 8); int eff = Marshal.ReadByte(p, 9);
                    int gc = Marshal.ReadInt16(p, 30); int threads = 0;
                    for (int g = 0; g < gc && 32 + g * 16 + 8 <= size; g++) {
                        ulong m = (ulong)Marshal.ReadInt64(p, 32 + g * 16);
                        while (m != 0) { threads += (int)(m & 1UL); m >>= 1; }
                    }
                    res.Add("core|" + eff + "|" + threads + "|" + flags);
                } else if (rel == 2) {
                    res.Add("cache|" + Marshal.ReadByte(p, 8) + "|" + Marshal.ReadInt32(p, 16) + "|" + (uint)Marshal.ReadInt32(p, 12) + "|" + Marshal.ReadByte(p, 9) + "|" + (ushort)Marshal.ReadInt16(p, 10));
                } else if (rel == 3) {
                    res.Add("pkg");
                }
                off += size;
            }
        } catch { } finally { Marshal.FreeHGlobal(buf); }
        return res.ToArray();
    }

    // "адаптер|описание|ширина|высота|Гц|макс.Гц при этом разрешении|макс.Гц вообще|бит|ID мониторов через ;"
    public static string[] Displays() {
        List<string> res = new List<string>();
        try {
            for (uint i = 0; i < 32; i++) {
                DD a = new DD(); a.cb = Marshal.SizeOf(typeof(DD));
                if (!EnumDisplayDevices(null, i, ref a, 0)) break;
                if ((a.StateFlags & 1) == 0) continue;
                DM cur = new DM(); cur.dmSize = (short)Marshal.SizeOf(typeof(DM));
                if (!EnumDisplaySettings(a.DeviceName, -1, ref cur)) continue;
                int maxCur = 0, maxAny = 0;
                for (int m = 0; m < 4000; m++) {
                    DM d = new DM(); d.dmSize = (short)Marshal.SizeOf(typeof(DM));
                    if (!EnumDisplaySettings(a.DeviceName, m, ref d)) break;
                    if (d.dmDisplayFrequency <= 1) continue;
                    if (d.dmDisplayFrequency > maxAny) maxAny = d.dmDisplayFrequency;
                    if (d.dmPelsWidth == cur.dmPelsWidth && d.dmPelsHeight == cur.dmPelsHeight && d.dmDisplayFrequency > maxCur) maxCur = d.dmDisplayFrequency;
                }
                List<string> mons = new List<string>();
                for (uint j = 0; j < 8; j++) {
                    DD mo = new DD(); mo.cb = Marshal.SizeOf(typeof(DD));
                    if (!EnumDisplayDevices(a.DeviceName, j, ref mo, 1)) break;
                    if (!String.IsNullOrEmpty(mo.DeviceID)) mons.Add(mo.DeviceID);
                }
                res.Add(a.DeviceName + "|" + (a.DeviceString ?? "").Replace("|", "/") + "|" + cur.dmPelsWidth + "|" + cur.dmPelsHeight + "|" + cur.dmDisplayFrequency + "|" + maxCur + "|" + maxAny + "|" + cur.dmBitsPerPel + "|" + String.Join(";", mons.ToArray()));
            }
        } catch { }
        return res.ToArray();
    }
}
'@
        try { Add-Type -TypeDefinition $hwSrc -Language CSharp -ErrorAction Stop } catch { $G.Log.Add("passport: Add-Type: $($_.Exception.Message)") }
    }
    $api = [bool]('PcDiagHw' -as [type])

    # ------------------------------------------------------------ CPU-Z: запускаем в фоне, пока собираем данные Windows
    $czProc = $null; $czDir = $null; $czName = 'pcdiag_cpuz_' + (Get-Date -Format 'HHmmss')
    $czExe = Get-Tool 'CPUZ'
    if ($czExe) {
        $czDir = Split-Path -Parent $czExe
        if (-not [Environment]::Is64BitOperatingSystem) { $x32 = Join-Path $czDir 'cpuz_x32.exe'; if (Test-Path $x32) { $czExe = $x32 } }
        try {
            # отключаем проверку обновлений (только наш ini в папке инструментов)
            $ini = Join-Path $czDir 'cpuz.ini'
            if (Test-Path $ini) {
                $it = [IO.File]::ReadAllText($ini)
                if ($it -match 'CheckUpdates=1') { [IO.File]::WriteAllText($ini, ($it -replace 'CheckUpdates=1', 'CheckUpdates=0'), [Text.Encoding]::Unicode) }
            }
        } catch {}
        Get-ChildItem $czDir -Filter 'pcdiag_cpuz_*.txt' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
        try { $czProc = Start-Process $czExe -ArgumentList ('-txt=' + $czName) -WorkingDirectory $czDir -PassThru -WindowStyle Hidden -ErrorAction Stop; Info 'CPU-Z собирает данные SPD памяти и чипсета (до 90 с)...' }
        catch { $G.Log.Add("passport: cpuz start: $($_.Exception.Message)") }
    }

    # ------------------------------------------------------------ общие помощники
    function Pp-Add($list, $k, $v) { if ($null -ne $v -and "$v".Trim() -ne '' -and "$v".Trim() -ne '—') { $list.Add([pscustomobject]@{ 'Параметр' = $k; 'Значение' = ("$v".Trim()) }) } }
    function Pp-Size($b) {
        $b = [double]$b
        if ($b -le 0) { return '' }
        if ($b -ge 1GB) { return ('{0:0.##} ГБ' -f ($b / 1GB)) }
        if ($b -ge 1MB) { return ('{0:0.##} МБ' -f ($b / 1MB)) }
        return ('{0:0} КБ' -f ($b / 1KB))
    }
    function Pp-RegStr($v) {
        if ($null -eq $v) { return '' }
        if ($v -is [byte[]]) { try { return ([Text.Encoding]::Unicode.GetString($v) -replace "`0", '').Trim() } catch { return '' } }
        if ($v -is [array]) { return (($v | ForEach-Object { "$_" }) -join ' ').Trim() }
        return ("$v" -replace "`0", '').Trim()
    }
    function Pp-Bad($t) { return ("$t" -match '(?i)^\s*$|default string|to be filled|o\.?e\.?m\.?|system serial|^none$|not specified|^0+$|^x\.x$|^n/?a$|^unknown$|^1234567890$') }
    function Pp-Transpose($cols, $params) {
        $rows = @()
        foreach ($p in $params) {
            $any = $false; $o = [ordered]@{ 'Параметр' = $p }
            foreach ($c in $cols) {
                $v = $c.D[$p]
                if ($null -ne $v -and "$v".Trim() -ne '') { $any = $true; $o[$c.L] = "$v".Trim() } else { $o[$c.L] = '—' }
            }
            if ($any) { $rows += [pscustomobject]$o }
        }
        return $rows
    }
    function Pp-Label($wanted, $used) {
        $l = "$wanted".Trim(); if (-not $l) { $l = 'устройство' }
        $l = $l.TrimStart('_')
        $base = $l; $n = 2
        while ($used.ContainsKey($l) -or $l -eq 'Параметр') { $l = '{0} #{1}' -f $base, $n; $n++ }
        $used[$l] = 1
        return $l
    }

    $pnpVendors = @{ SAM = 'Samsung'; GSM = 'LG'; DEL = 'Dell'; AUS = 'ASUS'; ACR = 'Acer'; AOC = 'AOC'; BNQ = 'BenQ'; PHL = 'Philips'; HPN = 'HP'; HWP = 'HP'; LEN = 'Lenovo'; MSI = 'MSI'; VSC = 'ViewSonic'; GBT = 'Gigabyte'; XMI = 'Xiaomi'; HKC = 'HKC'; KTC = 'KTC'; BOE = 'BOE'; AUO = 'AU Optronics'; CMN = 'Innolux (Chimei)'; CMO = 'Chimei'; LGD = 'LG Display'; SDC = 'Samsung Display'; SHP = 'Sharp'; IVO = 'InfoVision'; NEC = 'NEC'; SNY = 'Sony'; IIY = 'iiyama'; EIZ = 'EIZO'; ENC = 'EIZO'; FUS = 'Fujitsu'; MEI = 'Panasonic'; TSB = 'Toshiba'; HSD = 'HannStar'; HSL = 'Hansol'; CSO = 'CSOT'; TCL = 'TCL'; HIS = 'Hisense'; HIQ = 'Hyundai'; MED = 'Medion'; PNP = 'Microsoft'; MZI = 'Digital Vision'; AMR = 'AmazonBasics'; DXP = 'Dahua'; HKM = 'HKC'; GWD = 'Arzopa'; NOA = 'Nokia'; APP = 'Apple'; RHT = 'Red Hat (вирт.)'; VMW = 'VMware (вирт.)'; MSF = 'Microsoft'; STA = 'STAR/Самсунг-ОЕМ'; WAC = 'Wacom'; ZOW = 'BenQ Zowie'; PKB = 'Pixio'; AOP = 'AOpen'; INL = 'InnoLux'; BBY = 'Insignia'; ONN = 'onn'; TOS = 'Toshiba'; VIZ = 'Vizio'; SKG = 'Skyworth'; CHD = 'ChangHong'; MAX = 'Belinea'; PRI = 'Prism+'; TTE = 'TTE' }
    $subVendors = @{ '1043' = 'ASUS'; '1462' = 'MSI'; '1458' = 'Gigabyte'; '3842' = 'EVGA'; '19DA' = 'Zotac'; '1569' = 'Palit'; '10B0' = 'Gainward'; '7377' = 'Colorful'; '196E' = 'PNY'; '1682' = 'XFX'; '1DA2' = 'Sapphire'; '148C' = 'PowerColor'; '1849' = 'ASRock'; '17AA' = 'Lenovo'; '1028' = 'Dell'; '103C' = 'HP'; '1025' = 'Acer'; '10DE' = 'NVIDIA (референс)'; '1002' = 'AMD (референс)'; '8086' = 'Intel'; '1B4C' = 'KFA2/Galax'; '1ACC' = 'Point of View'; '1D05' = 'Tongfang'; '1D72' = 'Xiaomi'; '144D' = 'Samsung'; '1179' = 'Toshiba/Dynabook'; '104D' = 'Sony'; '1734' = 'Fujitsu'; '1558' = 'Clevo'; '1D17' = 'Zhaoxin'; '152D' = 'Quanta'; '1631' = 'Packard Bell'; '1509' = 'FIC'; '1642' = 'Bitland'; '174B' = 'Sapphire (PC Partner)'; '1787' = 'HIS'; '1092' = 'Diamond'; '107D' = 'Leadtek'; '1554' = 'Prolink'; '1B0A' = 'Pegatron'; '17C0' = 'Wistron'; '1E83' = 'Huawei'; '1414' = 'Microsoft'; '15AD' = 'VMware'; '1AF4' = 'Red Hat (вирт.)'; '80EE' = 'VirtualBox'; '1D49' = 'Lenovo'; '1E26' = 'Gigabyte'; '1D61' = 'Maxsun'; '1F0A' = 'Yeston'; '1048' = 'Elsa'; '1019' = 'ECS'; '1297' = 'Shuttle' }
    $pciVendors = @{ '10DE' = 'NVIDIA'; '1002' = 'AMD'; '1022' = 'AMD'; '8086' = 'Intel'; '10EC' = 'Realtek'; '14E4' = 'Broadcom'; '168C' = 'Qualcomm Atheros'; '17CB' = 'Qualcomm'; '1969' = 'Qualcomm Atheros (Killer)'; '14C3' = 'MediaTek'; '1D6A' = 'Marvell (Aquantia)'; '11AB' = 'Marvell'; '15B3' = 'Mellanox'; '1B21' = 'ASMedia'; '1106' = 'VIA'; '144D' = 'Samsung'; '15B7' = 'SanDisk/WD'; '1C5C' = 'SK hynix'; '1987' = 'Phison'; '126F' = 'Silicon Motion'; '1E0F' = 'Kioxia'; '1CC1' = 'ADATA'; '2646' = 'Kingston'; '1E4B' = 'Maxio'; '1D79' = 'Transcend'; '0BDA' = 'Realtek'; '0CF3' = 'Qualcomm Atheros'; '8087' = 'Intel'; '0A5C' = 'Broadcom'; '0E8D' = 'MediaTek'; '13D3' = 'IMC (AzureWave)'; '0489' = 'Foxconn'; '2357' = 'TP-Link'; '0B05' = 'ASUS'; '046D' = 'Logitech'; '1532' = 'Razer'; '045E' = 'Microsoft'; '1038' = 'SteelSeries'; '0951' = 'Kingston'; '0781' = 'SanDisk'; '1B1C' = 'Corsair'; '04F2' = 'Chicony'; '5986' = 'Bison/Acer'; '0C45' = 'Microdia'; '1BCF' = 'Sunplus'; '27C6' = 'Goodix'; '06CB' = 'Synaptics'; '138A' = 'Validity/Synaptics'; '1C7A' = 'LighTuning/EgisTec'; '04E8' = 'Samsung'; '05AC' = 'Apple'; '258A' = 'SinoWealth'; '24AE' = 'RAPOO'; '1A2C' = 'China Resource Semico'; '0D8C' = 'C-Media'; '1235' = 'Focusrite'; '1395' = 'Sennheiser/EPOS'; '0B0E' = 'Jabra'; '3434' = 'Keychron'; '0416' = 'Winbond'; '048D' = 'ITE'; '1A86' = 'QinHeng (CH340)'; '10C4' = 'Silicon Labs'; '0403' = 'FTDI'; '067B' = 'Prolific'; '2109' = 'VIA Labs'; '05E3' = 'Genesys Logic'; '0424' = 'Microchip (SMSC)'; '1A40' = 'Terminus'; '0BB4' = 'HTC'; '2717' = 'Xiaomi'; '18D1' = 'Google'; '054C' = 'Sony'; '057E' = 'Nintendo'; '28DE' = 'Valve'; '0E6F' = 'PDP'; '0738' = 'Mad Catz'; '1E7D' = 'ROCCAT'; '3842' = 'EVGA'; '1462' = 'MSI'; '0DB0' = 'MSI'; '1044' = 'Gigabyte'; '1A2B' = 'ADATA'; '152D' = 'JMicron'; '174C' = 'ASMedia'; '090C' = 'Silicon Motion'; '0930' = 'Toshiba'; '1058' = 'Western Digital'; '0BC2' = 'Seagate'; '04B4' = 'Cypress'; '2DC8' = '8BitDo'; '046A' = 'Cherry'; '04D9' = 'Holtek'; '1D57' = 'Xenta'; '2EA8' = 'Transcend' }
    $jedec = @{ '004E' = 'Samsung'; '002D' = 'SK hynix'; '002C' = 'Micron'; '0118' = 'Kingston'; '021E' = 'Corsair'; '044D' = 'G.Skill'; '044B' = 'ADATA'; '051B' = 'Crucial'; '046F' = 'Team Group'; '030B' = 'Nanya'; '017A' = 'Apacer'; '014F' = 'Transcend'; '0114' = 'Smart Modular'; '0025' = 'Kingmax'; '0034' = 'Super Talent'; '0045' = 'SanDisk'; '0105' = 'Elpida' }
    function Pp-Jedec($m) {
        $t = Clean $m
        if ((Pp-Bad $t) -or $t -match '(?i)^(undefined|manufacturer\d*|00000000|0000)$') { return '' }
        $h = $t -replace '^(?i)0x', ''
        $b = -1; $id = -1
        if ($h -match '^[0-9A-Fa-f]{4}$') { $b = [Convert]::ToInt32($h.Substring(0, 2), 16) -band 0x7F; $id = [Convert]::ToInt32($h.Substring(2, 2), 16) -band 0x7F }
        elseif ($h -match '^([0-9A-Fa-f]{2})0{2,}$') { $b = 0; $id = [Convert]::ToInt32($Matches[1], 16) -band 0x7F }
        else { return $t }
        $nm = $jedec[('{0:X2}{1:X2}' -f $b, $id)]
        if ($nm) { return $nm }
        return "код JEDEC $t"
    }
    $sigDrv = @{}
    foreach ($d in (CIM Win32_PnPSignedDriver)) { if ($d.DeviceID) { $sigDrv["$($d.DeviceID)"] = $d } }
    function Pp-Drv($id) { $d = $sigDrv["$id"]; if ($d) { return ('{0} от {1}' -f $d.DriverVersion, (DT $d.DriverDate)) }; return '' }
    $sens = @(Get-AllSensors)
    $key = Read-Key

    # ================================================================ ПРОЦЕССОР (данные Windows)
    $cpus = @(CIM Win32_Processor)
    $cpu = $cpus | Select-Object -First 1
    $vendorCpu = "$($cpu.Manufacturer)"
    $isIntel = $vendorCpu -match 'Intel'
    $topo = @(); if ($api) { try { $topo = @([PcDiagHw]::Topology()) } catch {} }
    $ucode = $null
    try {
        $b = (Get-ItemProperty 'HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0' -Name 'Update Revision' -ErrorAction Stop).'Update Revision'
        if ($b -and $b.Length -ge 8) { $ucode = [BitConverter]::ToUInt32([byte[]]$b, 4); if ($ucode -eq 0) { $ucode = [BitConverter]::ToUInt32([byte[]]$b, 0) } } elseif ($b -and $b.Length -ge 4) { $ucode = [BitConverter]::ToUInt32([byte[]]$b, 0) }
    } catch {}
    $sig = $null
    if ("$($cpu.ProcessorId)" -match '^[0-9A-Fa-f]{16}$') { $sig = [Convert]::ToUInt32("$($cpu.ProcessorId)".Substring(8, 8), 16) }

    # ================================================================ дожидаемся CPU-Z и разбираем отчёт
    $cz = $null
    if ($czProc) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while (-not $czProc.HasExited -and $sw.Elapsed.TotalSeconds -lt 90) {
            Start-Sleep -Milliseconds 500
            Write-Host -NoNewline ("`r    {0,4:N0} с | CPU-Z работает..." -f $sw.Elapsed.TotalSeconds)
        }
        Write-Host ''
        if (-not $czProc.HasExited) { try { $czProc.Kill() } catch {}; $G.Log.Add('passport: CPU-Z не завершился за 90 с — остановлен') }
        Start-Sleep -Milliseconds 500
        $txt = $null
        foreach ($cand in (Join-Path $czDir "$czName.txt"), (Join-Path $G.Temp "$czName.txt")) { if (Test-Path $cand) { $txt = $cand; break } }
        if (-not $txt) { $f = Get-ChildItem $czDir -Filter "$czName*.txt" -ErrorAction SilentlyContinue | Select-Object -First 1; if ($f) { $txt = $f.FullName } }
        if ($txt) {
            $dst = Join-Path $G.Temp 'cpuz_report.txt'
            try { Move-Item $txt $dst -Force -ErrorAction Stop; $txt = $dst } catch {}
            $G.Log.Add("passport: CPU-Z report: $txt")
            $lines = @()
            try { $lines = @([IO.File]::ReadAllLines($txt, [Text.Encoding]::Default)) } catch {}
            $recs = New-Object System.Collections.Generic.List[object]
            $sec = ''; $sub = ''; $blk = 0
            for ($i = 0; $i -lt $lines.Count; $i++) {
                $ln = "$($lines[$i])".TrimEnd()
                if ($ln.Trim() -and $ln -notmatch '^\s*-+\s*$' -and ($i + 1) -lt $lines.Count -and "$($lines[$i + 1])" -match '^\s*-{8,}\s*$') { $sec = $ln.Trim(); $sub = ''; $blk++; $i++; continue }
                $t = $ln.Trim()
                if (-not $t) { continue }
                $m = [regex]::Match($t, '^([^\t]+?)\t+(.*)$')
                if (-not $m.Success) { $m = [regex]::Match($t, '^(.+?)\s{2,}(.*)$') }
                if ($m.Success) { $k = $m.Groups[1].Value.Trim(); $v = $m.Groups[2].Value.Trim() } else { $k = $t; $v = '' }
                if ($k -match '^(DMI\s.+|Display adapter\s*\d+|Monitor\s*\d+|Socket\s*\d+|DIMM\s*#.*)$') { $sub = ($k + ' ' + $v).Trim(); $blk++ }
                $recs.Add([pscustomobject]@{ S = $sec; Sub = $sub; B = $blk; K = $k; V = $v })
            }
            if ($recs.Count -gt 20) { $cz = $recs } else { $G.Log.Add("passport: CPU-Z report too short ($($recs.Count) lines)") }
        } else { $G.Log.Add('passport: CPU-Z report file not found') }
    }
    function Cz($secRe, $keyRe, $subRe = $null) {
        if (-not $cz) { return '' }
        foreach ($r in $cz) {
            if ($r.S -match $secRe -and $r.K -match $keyRe -and ($null -eq $subRe -or $r.Sub -match $subRe)) { return $r.V }
        }
        return ''
    }
    function CzIn($list, $keyRe) { foreach ($r in $list) { if ($r.K -match $keyRe) { return $r.V } }; return '' }
    function Pp-NoId($v) { return (("$v" -replace '\s*\((ID\s*)?[0-9A-Fa-f]{6,}\)\s*$', '').Trim()) }

    $passport = @{}
    $s = New-Section 'Паспорт компьютера'
    Add-Row $s 'Источник данных' $(if ($cz) { 'Windows (WMI, реестр, драйверы) + CPU-Z 3.02 (SPD памяти, чипсет, подробности)' } elseif ($czExe) { 'Windows (WMI, реестр, драйверы); CPU-Z не отработал — детали SPD недоступны' } else { 'Windows (WMI, реестр, драйверы); CPU-Z не скачался — детали SPD недоступны' })

    # ================================================================ 1. ПРОЦЕССОР
    $cp = New-Object System.Collections.Generic.List[object]
    Pp-Add $cp 'Модель' (Clean $cpu.Name)
    if ($cpus.Count -gt 1) { Pp-Add $cp 'Процессоров (сокетов)' $cpus.Count }
    Pp-Add $cp 'Производитель' $(if ($isIntel) { 'Intel' } elseif ($vendorCpu -match 'AMD') { 'AMD' } else { $vendorCpu })
    $codename = Cz '^Processors Information' '^Codename$'
    Pp-Add $cp 'Кодовое имя (ядро)' $codename
    $pkg = Cz '^Processors Information' '^Package'
    Pp-Add $cp 'Корпус / сокет' $(if ($pkg) { $pkg } else { Clean $cpu.SocketDesignation })
    Pp-Add $cp 'Техпроцесс' (Cz '^Processors Information' '^Technology$')
    if ($null -ne $sig) {
        $stp = $sig -band 0xF; $mdl = ($sig -shr 4) -band 0xF; $fam = ($sig -shr 8) -band 0xF; $exm = ($sig -shr 16) -band 0xF; $exf = ($sig -shr 20) -band 0xFF
        $dFam = $fam; if ($fam -eq 0xF) { $dFam = $fam + $exf }
        $dMdl = $mdl; if ($fam -eq 6 -or $fam -eq 0xF) { $dMdl = ($exm -shl 4) + $mdl }
        Pp-Add $cp 'CPUID (семейство / модель / степпинг)' ('0x{0:X} / 0x{1:X} / {2}  (сигнатура 0x{3:X8}; база {4:X}.{5:X}.{2:X}, расш. семейство {6:X}, расш. модель {7:X})' -f $dFam, $dMdl, $stp, $sig, $fam, $mdl, $exf, $exm)
    } elseif ("$($cpu.Caption)" -match 'Family\s+(\d+)\s+Model\s+(\d+)\s+Stepping\s+(\d+)') { Pp-Add $cp 'CPUID (семейство / модель / степпинг)' ('{0} / {1} / {2}' -f $Matches[1], $Matches[2], $Matches[3]) }
    Pp-Add $cp 'Ревизия ядра (stepping)' (Cz '^Processors Information' '^(Core )?Stepping$')
    Pp-Add $cp 'Микрокод' $(if ($null -ne $ucode) { '0x{0:X}' -f $ucode } else { Cz '^Processors Information' '^Microcode' })
    # ядра / потоки, гибридная архитектура
    $cores = @($topo | Where-Object { $_ -like 'core|*' } | ForEach-Object { $p = $_ -split '\|'; [pscustomobject]@{ Eff = [int]$p[1]; Thr = [int]$p[2] } })
    $nCores = 0; $nThr = 0; foreach ($c in $cpus) { $nCores += [int]$c.NumberOfCores; $nThr += [int]$c.NumberOfLogicalProcessors }
    $coreTxt = '{0} ядер / {1} потоков' -f $nCores, $nThr
    $effGroups = @($cores | Group-Object Eff | Sort-Object { [int]$_.Name } -Descending)
    if ($effGroups.Count -gt 1) {
        $parts = @(); $gi = 0
        foreach ($grpItem in $effGroups) {
            $lbl = if ($gi -eq 0) { 'P' } elseif ($gi -eq $effGroups.Count - 1 -and $effGroups.Count -ge 3) { 'LP-E' } else { 'E' }
            $parts += '{0}-ядер: {1} ({2} потоков)' -f $lbl, $grpItem.Count, (($grpItem.Group | Measure-Object Thr -Sum).Sum)
            $gi++
        }
        $coreTxt += ' — гибридный: ' + ($parts -join ', ')
    }
    Pp-Add $cp 'Ядра / потоки' $coreTxt
    $czCores = Cz '^Processors Information' '(?i)core set|P-cores?|E-cores?'
    if ($czCores) { Pp-Add $cp 'Ядра (CPU-Z)' $czCores }
    Pp-Add $cp 'Базовая частота' ('{0:N2} ГГц' -f ([double]$cpu.MaxClockSpeed / 1000))
    $maxF = Cz '^Processors Information' '^Max frequency$'
    Pp-Add $cp 'Максимальная частота (турбо)' $maxF
    if ($key.CpuClock) { Pp-Add $cp 'Частота сейчас (среднее по ядрам)' ('{0:N0} МГц' -f $key.CpuClock) }
    Pp-Add $cp 'Множитель × шина (CPU-Z)' (Cz '^Processors Information' '^Multiplier x')
    if ($cpu.ExtClock) { Pp-Add $cp 'Внешняя шина (BCLK)' ('{0} МГц' -f $cpu.ExtClock) }
    # кэши
    $caches = @($topo | Where-Object { $_ -like 'cache|*' } | ForEach-Object { $p = $_ -split '\|'; [pscustomobject]@{ L = [int]$p[1]; T = [int]$p[2]; Sz = [double]$p[3]; A = [int]$p[4] } })
    foreach ($lv in @(@(1, 2, 'L1 данных', '^L1 Data'), @(1, 1, 'L1 инструкций', '^L1 Instruction'), @(2, 0, 'L2', '^L2 cache'), @(3, 0, 'L3', '^L3 cache'), @(4, 0, 'L4', '^L4 cache'))) {
        $grp = @($caches | Where-Object { $_.L -eq $lv[0] -and ($_.T -eq $lv[1] -or ($lv[1] -eq 0 -and $_.T -eq 0)) } | Group-Object Sz, A)
        $v = ''
        if ($grp.Count) { $v = (($grp | Sort-Object { $_.Group[0].Sz } -Descending | ForEach-Object { '{0} × {1}{2}' -f $_.Count, (Pp-Size $_.Group[0].Sz), $(if ($_.Group[0].A -gt 0 -and $_.Group[0].A -lt 255) { ' (' + $_.Group[0].A + '-way)' } else { '' }) }) -join ' + ') }
        if (-not $v) { $v = Cz '^Processors Information' $lv[3] }
        if (-not $v -and $lv[0] -eq 2 -and $cpu.L2CacheSize) { $v = Pp-Size ([double]$cpu.L2CacheSize * 1KB) }
        if (-not $v -and $lv[0] -eq 3 -and $cpu.L3CacheSize) { $v = Pp-Size ([double]$cpu.L3CacheSize * 1KB) }
        Pp-Add $cp ('Кэш ' + $lv[2]) $v
    }
    # наборы инструкций
    $isa = Cz '^Processors Information' '^Instructions? sets?$'
    if (-not $isa -and $api) {
        $fl = @()
        foreach ($f in @(@(6, 'SSE'), @(10, 'SSE2'), @(13, 'SSE3'), @(36, 'SSSE3'), @(37, 'SSE4.1'), @(38, 'SSE4.2'), @(39, 'AVX'), @(40, 'AVX2'), @(41, 'AVX-512F'), @(28, 'RDRAND'), @(12, 'NX'), @(20, 'SLAT'))) { if ([PcDiagHw]::Feature([uint32]$f[0])) { $fl += $f[1] } }
        if ($fl.Count) { $isa = ($fl -join ', ') + ' (по данным Windows)' }
    }
    Pp-Add $cp 'Наборы инструкций' $isa
    Pp-Add $cp 'Виртуализация' ('{0} — {1}' -f $(if ($isIntel) { 'VT-x' } else { 'AMD-V (SVM)' }), $(if ($cpu.VirtualizationFirmwareEnabled) { 'включена в BIOS' } elseif ((CIM Win32_ComputerSystem | Select-Object -First 1).HypervisorPresent) { 'занята гипервизором Windows (Hyper-V/VBS)' } else { 'выключена в BIOS' }))
    Pp-Add $cp 'TDP' (Cz '^Processors Information' '^(TDP|Max TDP)')
    $vc = $key.Vcore
    if ($null -eq $vc) { $vc = Pick $sens '^Cpu$' 'Voltage' '(?i)^(CPU )?(Core|VDDCR|Vcore)( \(SVI\d.*\))?$' }
    if ($null -eq $vc) { $vc = Pick $sens '^Cpu$' 'Voltage' '(?i)VID' -Max }
    if ($null -ne $vc -and $vc -gt 0.3 -and $vc -lt 2) { Pp-Add $cp 'Напряжение ядра (Vcore) сейчас' ('{0:N3} В' -f $vc) }
    Pp-Add $cp 'ID процессора (WMI ProcessorId)' "$($cpu.ProcessorId)"
    Add-Table $s 'Процессор' $cp
    $passport.cpu = Clean $cpu.Name
    $passport.cpu_code = $codename
    if ($null -ne $ucode) { $passport.cpu_ucode = '0x{0:X}' -f $ucode }

    # ================================================================ 2. ОПЕРАТИВНАЯ ПАМЯТЬ — каждый модуль
    $mods = @(CIM Win32_PhysicalMemory)
    $arr = @(CIM Win32_PhysicalMemoryArray | Where-Object { $_.Use -eq 3 })
    $typeMap = @{ 20 = 'DDR'; 21 = 'DDR2'; 24 = 'DDR3'; 26 = 'DDR4'; 27 = 'LPDDR'; 28 = 'LPDDR2'; 29 = 'LPDDR3'; 30 = 'LPDDR4'; 34 = 'DDR5'; 35 = 'LPDDR5' }
    $ffMap = @{ 8 = 'DIMM'; 12 = 'SO-DIMM'; 13 = 'SO-DIMM' }
    # SPD-блоки CPU-Z
    $spd = @()
    if ($cz) {
        foreach ($grpItem in @($cz | Where-Object { $_.S -match '^Memory SPD' -and $_.Sub -match '^DIMM' } | Group-Object B)) {
            $l = $grpItem.Group
            $o = @{ Sub = $l[0].Sub; Type = CzIn $l '^Memory type$'; Fmt = CzIn $l '^Module format$'; Mfr = Pp-NoId (CzIn $l '^(Module )?Manufacturer\s*\(ID\)$')
                Dram = Pp-NoId (CzIn $l '^(SDRAM|DRAM) Manufacturer'); Size = CzIn $l '^Size$'; Bw = CzIn $l '^Max bandwidth$'; Part = (CzIn $l '^Part number$').Trim(); Ser = (CzIn $l '^Serial number$').Trim()
                Date = CzIn $l '^Manufacturing date$'; Ranks = CzIn $l '^(Number of ranks|Ranks)$'; Banks = CzIn $l '^Number of banks$'; Volt = CzIn $l '^Nominal Voltage$'; Reg = CzIn $l '^(Registered|Buffered)$'; Ecc = CzIn $l '^(ECC|Correction)$'
                Prof = @(); Tim = @() }
            $cur = $null
            foreach ($r in $l) {
                if ($r.K -match '^(XMP|EXPO|EPP|AMP)\s*profile') { $cur = @{ Name = $r.V; Kind = $Matches[1].ToUpper(); Spec = ''; Volt = '' }; $o.Prof += $cur; continue }
                if ($cur -and $r.K -match '^Specification$' -and -not $cur.Spec) { $cur.Spec = $r.V }
                if ($cur -and $r.K -match '^Voltage level' -and -not $cur.Volt) { $cur.Volt = $r.V }
                if ($r.K -match '^(JEDEC|XMP|EXPO|EPP|AMP)\s*#\s*\d+' -and $r.V -match '^([\d.]+)-(\d+)-(\d+)-(\d+)(?:-(\d+))?(?:-([\w.]+))?\s*@\s*([\d.]+)\s*MHz(?:\s*\(([\d.]+)\s*Volts?\))?') {
                    $o.Tim += [pscustomobject]@{ Kind = $r.K -replace '\s*#.*$', ''; CL = [double]::Parse($Matches[1], $IC); RCD = [int]$Matches[2]; RP = [int]$Matches[3]; RAS = [int]$Matches[4]; RC = $Matches[5]; CR = $Matches[6]; F = [double]::Parse($Matches[7], $IC); V = $Matches[8] }
                }
            }
            $spd += $o
        }
    }
    function Pp-BestTim($tims, $kind) {
        $t = @($tims | Where-Object { $_.Kind -eq $kind })
        if (-not $t.Count) { return $null }
        $mx = ($t | Measure-Object F -Maximum).Maximum
        return ($t | Where-Object { $_.F -ge $mx - 0.5 } | Sort-Object CL | Select-Object -First 1)
    }
    function Pp-TimTxt($t) {
        if (-not $t) { return '' }
        $x = '{0}-{1}-{2}-{3}' -f [math]::Round($t.CL, 1), $t.RCD, $t.RP, $t.RAS
        if ($t.CR -and $t.CR -match '^\dT$') { $x += ' ' + $t.CR }
        $x = '{0} МТ/с: {1}' -f [math]::Round($t.F * 2), $x
        if ($t.V) { $x += ' @ {0} В' -f $t.V }
        return $x
    }
    $used = @{}; $cols = @(); $parts = @(); $ratedMax = 0; $confMin = 0; $jedecMax = 0; $xmpMax = 0
    $idx = 0
    foreach ($m in $mods) {
        $d = @{}
        $sn = Clean $m.SerialNumber; $pn = Clean $m.PartNumber
        # сопоставление с SPD CPU-Z: по серийному номеру, иначе по партномеру, иначе по порядку
        $sp = $null
        if ($spd.Count) {
            if ($sn -and -not (Pp-Bad $sn)) { $sp = $spd | Where-Object { $_.Ser -and ($_.Ser -replace '^0x', '') -eq ($sn -replace '^0x', '') } | Select-Object -First 1 }
            if (-not $sp -and $pn) { $sp = $spd | Where-Object { $_.Part -and $_.Part -eq $pn -and -not $_.Used } | Select-Object -First 1 }
            if (-not $sp -and $spd.Count -eq $mods.Count) { $sp = $spd[$idx] }
            if ($sp) { $sp.Used = $true }
        }
        $t = $typeMap[[int]$m.SMBIOSMemoryType]
        if (-not $t -and $sp) { $t = $sp.Type }
        $ff = $ffMap[[int]$m.FormFactor]
        $d['Банк / метка'] = Clean $m.BankLabel
        $d['Объём'] = GB $m.Capacity 0
        $d['Тип'] = (@($t, $ff, $(if ($sp -and $sp.Fmt) { '(' + $sp.Fmt + ')' } else { '' })) | Where-Object { $_ }) -join ' '
        $mfr = ''
        if ($sp -and $sp.Mfr) { $mfr = $sp.Mfr } else { $mfr = Pp-Jedec $m.Manufacturer }
        $d['Производитель модуля'] = $mfr
        if ($sp -and $sp.Dram) { $d['Производитель чипов (DRAM)'] = $sp.Dram }
        $d['Партномер (модель)'] = $(if ($pn) { $pn } elseif ($sp) { $sp.Part } else { '' })
        $d['Серийный номер'] = $(if ($sn -and -not (Pp-Bad $sn)) { $sn } elseif ($sp -and $sp.Ser) { $sp.Ser } else { '' })
        $rk = [int]$m.Attributes -band 0xF
        $d['Ранги'] = $(if ($rk -gt 0) { $(if ($rk -eq 1) { '1 (single rank)' } elseif ($rk -eq 2) { '2 (dual rank)' } else { "$rk" }) } elseif ($sp) { $sp.Ranks } else { '' })
        if ([int]$m.TotalWidth -gt [int]$m.DataWidth -and [int]$m.DataWidth -gt 0) { $d['ECC'] = 'есть (ширина {0}/{1} бит)' -f $m.TotalWidth, $m.DataWidth }
        if ($sp -and $sp.Reg -match '(?i)yes') { $d['ECC'] = (("$($d['ECC']) регистровая (RDIMM)").Trim()) }
        if ($m.Speed) { $d['Номинал по SMBIOS'] = '{0} МТ/с' -f $m.Speed }
        if ($m.ConfiguredClockSpeed) { $d['Работает сейчас'] = '{0} МТ/с' -f $m.ConfiguredClockSpeed }
        $vv = @()
        if ($m.ConfiguredVoltage) { $vv += ('{0:N2} В сейчас' -f ([double]$m.ConfiguredVoltage / 1000)) }
        if ($m.MinVoltage -and $m.MaxVoltage -and $m.MinVoltage -ne $m.MaxVoltage) { $vv += ('{0:N2}–{1:N2} В допустимо' -f ([double]$m.MinVoltage / 1000), ([double]$m.MaxVoltage / 1000)) }
        if ($sp -and $sp.Volt) { $vv += ('номинал SPD ' + ($sp.Volt -replace '(?i)\s*Volts?', ' В')) }
        $d['Напряжение'] = $vv -join ', '
        if ($sp) {
            if ($sp.Bw) { $d['Макс. полоса (SPD)'] = $sp.Bw }
            if ($sp.Date -match '(?i)Week\s*(\d+)\D+Year\s*(\d+)') {
                $wk = [int]$Matches[1]; $yr = [int]$Matches[2]; if ($yr -lt 100) { $yr += 2000 }
                if ($wk -ge 1 -and $wk -le 53 -and $yr -ge 1995 -and $yr -le ((Get-Date).Year + 1)) { $d['Дата выпуска'] = '{0} неделя {1} г.' -f $wk, $yr } else { $d['Дата выпуска'] = 'не записана в SPD (' + $sp.Date + ')' }
            }
            $j = Pp-BestTim $sp.Tim 'JEDEC'
            if ($j) { $d['Тайминги JEDEC (макс.)'] = Pp-TimTxt $j; if ($j.F * 2 -gt $jedecMax) { $jedecMax = $j.F * 2 } }
            foreach ($kind in 'XMP', 'EXPO', 'EPP', 'AMP') {
                $bt = Pp-BestTim $sp.Tim $kind
                $pr = @($sp.Prof | Where-Object { $_.Kind -eq $kind })
                $txt2 = ''
                if ($pr.Count) { $txt2 = (($pr | ForEach-Object { (@($_.Name, $_.Spec, $(if ($_.Volt) { $_.Volt -replace '(?i)\s*Volts?', ' В' } else { '' })) | Where-Object { $_ }) -join ', ' }) -join '; ') }
                if ($bt) { $txt2 = (@($txt2, (Pp-TimTxt $bt)) | Where-Object { $_ }) -join ' — '; if ($bt.F * 2 -gt $xmpMax) { $xmpMax = $bt.F * 2 } }
                if ($txt2) { $d[('Профиль ' + $kind)] = $txt2 }
            }
            if (-not (AsArr $sp.Prof).Count -and -not @($sp.Tim | Where-Object { $_.Kind -ne 'JEDEC' }).Count) { $d['Профили XMP/EXPO'] = 'нет' }
        }
        if ($m.Speed -gt $ratedMax) { $ratedMax = [int]$m.Speed }
        if ($m.ConfiguredClockSpeed -and ($confMin -eq 0 -or $m.ConfiguredClockSpeed -lt $confMin)) { $confMin = [int]$m.ConfiguredClockSpeed }
        $lbl = Clean $m.DeviceLocator; if (-not $lbl) { $lbl = 'Модуль {0}' -f ($idx + 1) }
        $cols += @{ L = (Pp-Label $lbl $used); D = $d; Part = $d['Партномер (модель)']; Spd = $m.Speed; Cap = $m.Capacity; Loc = (Clean $m.DeviceLocator) + ' ' + (Clean $m.BankLabel) }
        $parts += $d['Партномер (модель)']
        $idx++
    }
    $rp = New-Object System.Collections.Generic.List[object]
    $slots = ($arr | Measure-Object MemoryDevices -Sum).Sum
    Pp-Add $rp 'Модулей / слотов' ('{0} из {1}' -f $mods.Count, $(if ($slots) { $slots } else { '?' }))
    $maxKB = ($arr | Measure-Object MaxCapacityEx -Sum).Sum
    if ($maxKB) { Pp-Add $rp 'Максимум по данным платы' (GB ($maxKB * 1KB) 0) }
    # каналы: по CPU-Z, иначе по меткам слотов
    $chCz = Cz '^Chipset' '^Channels$'
    $chs = @($cols | ForEach-Object {
            $loc = "$($_.Loc)"
            # Intel: «Controller0-ChannelA-DIMM1» — канал определяется парой контроллер+канал
            if ($loc -match '(?i)controller\s*(\d+).*channel\s*([A-H])') { 'C' + $Matches[1] + $Matches[2].ToUpper() }
            elseif ($loc -match '(?i)channel\s*([A-H])') { $Matches[1].ToUpper() } elseif ($loc -match '(?i)\bCH(?:ANNEL)?[\s_-]*([A-H])\b') { $Matches[1].ToUpper() } elseif ($loc -match '(?i)DIMM[\s_-]*([A-H])\d') { $Matches[1].ToUpper() } elseif ($loc -match '(?i)\bCH(?:ANNEL)?[\s_-]*(\d)\b') { $Matches[1] }
        } | Select-Object -Unique)
    $chTxt = ''
    if ($chs.Count -ge 1) { $chTxt = switch ($chs.Count) { 1 { 'одноканальный' } 2 { 'двухканальный' } 4 { 'четырёхканальный' } default { "$($chs.Count) канала" } }; $chTxt += ' (по меткам слотов: каналы ' + ($chs -join ', ') + ')' }
    # CPU-Z для DDR5 пишет подканалы: «4 x 32-bit» = два 64-битных канала
    if ($chCz -match '(\d+)\s*x\s*32-bit') { $n64 = [int]$Matches[1] / 2; $chTxt = $(switch ($n64) { 1 { 'одноканальный' } 2 { 'двухканальный' } 4 { 'четырёхканальный' } default { "$n64 канала" } }) + " (DDR5: $chCz)" }
    elseif ($chCz) { $chTxt = (@("CPU-Z: $chCz", $chTxt) | Where-Object { $_ }) -join '; ' }
    if (-not $chTxt -and $mods.Count -eq 1) { $chTxt = 'одноканальный (один модуль)' }
    Pp-Add $rp 'Режим каналов' $chTxt
    Pp-Add $rp 'Контроллер памяти / северный мост (CPU-Z)' (Cz '^Chipset' '^Northbridge$')
    $mf = Cz '^Chipset' '^(DRAM|Memory) Frequency$'
    if ($mf -match '^([\d.]+)\s*MHz') { $mf = '{0} ({1:N0} МТ/с)' -f $mf, ([double]::Parse($Matches[1], $IC) * 2) }
    Pp-Add $rp 'Частота памяти (CPU-Z)' $mf
    $tm = @((Cz '^Chipset' '^CAS'), (Cz '^Chipset' '^RAS# to CAS'), (Cz '^Chipset' '^RAS# Precharge'), (Cz '^Chipset' '^Cycle Time'))
    if ($tm[0]) {
        $cr = Cz '^Chipset' '^Command Rate'
        $tt = (($tm | ForEach-Object { if ($_ -match '^([\d.]+)') { [math]::Round([double]::Parse($Matches[1], $IC), 1) } else { '?' } }) -join '-')
        $extra = @(); $rfc = Cz '^Chipset' '^Row Refresh'; $trc = Cz '^Chipset' '^Bank Cycle'
        if ($trc) { $extra += "tRC $trc" }; if ($rfc) { $extra += "tRFC $rfc" }
        Pp-Add $rp 'Текущие тайминги (CL-tRCD-tRP-tRAS)' ($tt + $(if ($cr) { ' ' + $cr } else { '' }) + $(if ($extra.Count) { ', ' + ($extra -join ', ') } else { '' }))
    }
    if (-not $cz) { Pp-Add $rp 'Тайминги, XMP/EXPO, дата выпуска, чипы' 'детали SPD недоступны (CPU-Z не отработал)' }
    Add-Table $s 'Оперативная память — общее' $rp
    if ($cols.Count) {
        $params = 'Банк / метка', 'Объём', 'Тип', 'Производитель модуля', 'Производитель чипов (DRAM)', 'Партномер (модель)', 'Серийный номер', 'Дата выпуска', 'Ранги', 'ECC', 'Номинал по SMBIOS', 'Макс. полоса (SPD)', 'Работает сейчас', 'Напряжение', 'Тайминги JEDEC (макс.)', 'Профиль XMP', 'Профиль EXPO', 'Профиль EPP', 'Профиль AMP', 'Профили XMP/EXPO'
        Add-Table $s 'Модули памяти (по слотам)' (Pp-Transpose $cols $params)
    }
    if ($spd.Count -and $spd.Count -ne $mods.Count) { $G.Log.Add(('passport: SPD blocks {0} vs WMI modules {1}' -f $spd.Count, $mods.Count)) }
    # разные модули (разный объём уже отмечается в шаге «Оперативная память»)
    $uParts = @($cols | ForEach-Object { "$($_.Part)" } | Where-Object { $_ } | Select-Object -Unique)
    $uCap = @($cols | ForEach-Object { $_.Cap } | Select-Object -Unique)
    $uSpd = @($cols | ForEach-Object { $_.Spd } | Where-Object { $_ } | Select-Object -Unique)
    if ($cols.Count -gt 1 -and $uCap.Count -le 1 -and ($uParts.Count -gt 1 -or $uSpd.Count -gt 1)) {
        Add-Issue 'info' 'Память' ('установлены разные модули памяти: {0}' -f $(if ($uParts.Count -gt 1) { $uParts -join ' / ' } else { ($uSpd | ForEach-Object { "$_ МТ/с" }) -join ' / ' })) 'Разные модели обычно работают, но по самому медленному модулю и иногда нестабильно с XMP/EXPO. Для надёжности — комплект из одинаковых модулей.'
    }
    # XMP/EXPO не включён (по SPD CPU-Z). Не дублируем шаг «Оперативная память», который ловит «работает < 90 % номинала SMBIOS».
    $bodyFlag = @($mods | Where-Object { $_.Speed -and $_.ConfiguredClockSpeed -and $_.ConfiguredClockSpeed -lt ($_.Speed * 0.9) }).Count -gt 0
    if (-not $G.IsLaptop -and -not $bodyFlag -and $xmpMax -gt 0 -and $confMin -gt 0 -and $xmpMax -gt $confMin * 1.08 -and ($jedecMax -eq 0 -or $confMin -le $jedecMax * 1.03)) {
        Add-Issue 'info' 'Память' ('память работает на {0} МТ/с (стандарт JEDEC), а модули рассчитаны на {1:N0} МТ/с с профилем XMP/EXPO' -f $confMin, $xmpMax) 'Включите профиль XMP (Intel) / EXPO или DOCP (AMD) в BIOS — прирост 5–20 % в играх и тяжёлых задачах. После включения проверьте стабильность тестом памяти.'
    }
    $passport.ram_parts = @($parts | Where-Object { $_ })
    if ($xmpMax) { $passport.ram_xmp = [int]$xmpMax }

    # ================================================================ 3. МАТЕРИНСКАЯ ПЛАТА, BIOS
    $bb = CIM Win32_BaseBoard | Select-Object -First 1
    $bios = CIM Win32_BIOS | Select-Object -First 1
    $csys = CIM Win32_ComputerSystem | Select-Object -First 1
    $csp = CIM Win32_ComputerSystemProduct | Select-Object -First 1
    $mb = New-Object System.Collections.Generic.List[object]
    Pp-Add $mb 'Производитель платы' (Clean $bb.Manufacturer)
    Pp-Add $mb 'Модель платы' (Clean $bb.Product)
    $rev = Clean $bb.Version; if (-not (Pp-Bad $rev)) { Pp-Add $mb 'Ревизия платы' $rev }
    $bsn = Clean $bb.SerialNumber; if (-not (Pp-Bad $bsn)) { Pp-Add $mb 'Серийный номер платы' $bsn }
    $sb2 = Cz '^Chipset' '^Southbridge$'
    $chip = $sb2
    if (-not $chip) {
        $lpc = Get-PnpDevice -PresentOnly -Class System -ErrorAction SilentlyContinue | Where-Object { $_.FriendlyName -match '(?i)LPC|eSPI' } | Select-Object -First 1
        if ($lpc) { $chip = Clean $lpc.FriendlyName }
    }
    Pp-Add $mb 'Чипсет (южный мост)' $chip
    $sysM = Clean $csys.Manufacturer; $sysP = Clean $csys.Model
    if (-not (Pp-Bad $sysM) -and -not (Pp-Bad $sysP) -and $sysP -ne (Clean $bb.Product)) { Pp-Add $mb 'Система (производитель / модель)' ('{0} {1}' -f $sysM, $sysP) }
    $ver2 = Clean $csp.Version; if ($ver2 -and -not (Pp-Bad $ver2) -and $ver2 -ne $sysP) { Pp-Add $mb 'Версия / серия системы' $ver2 }
    $sku = Clean $csys.SystemSKUNumber; if (-not (Pp-Bad $sku) -and $sku -ne 'SKU') { Pp-Add $mb 'SKU (точная комплектация)' $sku }
    $fam2 = Clean $csys.SystemFamily; if (-not (Pp-Bad $fam2)) { Pp-Add $mb 'Семейство' $fam2 }
    Pp-Add $mb 'BIOS: производитель' (Clean $bios.Manufacturer)
    Pp-Add $mb 'BIOS: версия' ((@((Clean $bios.SMBIOSBIOSVersion), $(if ($bios.BIOSVersion) { '(' + (((AsArr $bios.BIOSVersion) | ForEach-Object { (Clean $_) } | Where-Object { $_ }) -join '; ') + ')' } else { '' })) | Where-Object { $_ }) -join ' ')
    Pp-Add $mb 'BIOS: дата' (DT $bios.ReleaseDate)
    if ($null -ne $bios.SystemBiosMajorVersion -and $bios.SystemBiosMajorVersion -ne 255) { Pp-Add $mb 'BIOS: ревизия ядра' ('{0}.{1}' -f $bios.SystemBiosMajorVersion, $bios.SystemBiosMinorVersion) }
    if ($null -ne $bios.EmbeddedControllerMajorVersion -and $bios.EmbeddedControllerMajorVersion -ne 255) { Pp-Add $mb 'Прошивка EC (контроллер питания/клавиатуры)' ('{0}.{1}' -f $bios.EmbeddedControllerMajorVersion, $bios.EmbeddedControllerMinorVersion) }
    if ($bios.SMBIOSMajorVersion) { Pp-Add $mb 'Версия SMBIOS' ('{0}.{1}' -f $bios.SMBIOSMajorVersion, $bios.SMBIOSMinorVersion) }
    $fwt = 0; if ($api) { $fwt = [PcDiagHw]::FirmwareType() }
    Pp-Add $mb 'Режим прошивки' $(switch ($fwt) { 1 { 'Legacy BIOS (CSM)' } 2 { 'UEFI' } default { '' } })
    Pp-Add $mb 'BIOS ROM (CPU-Z)' (Cz '^DMI' '^ROM size' '^DMI BIOS')
    Add-Table $s 'Материнская плата и BIOS' $mb
    $passport.board = ('{0} {1}' -f (Clean $bb.Manufacturer), (Clean $bb.Product)).Trim()
    if ($chip) { $passport.chipset = $chip }
    $passport.bios = Clean $bios.SMBIOSBIOSVersion
    # слоты
    $wMap = @{ 5 = 'x1'; 6 = 'x2'; 7 = 'x4'; 8 = 'x8'; 9 = 'x12'; 10 = 'x16'; 11 = 'x32'; 0 = '8 бит'; 1 = '16 бит'; 2 = '32 бит'; 3 = '64 бит'; 4 = '128 бит' }
    $slt = @(CIM Win32_SystemSlot | ForEach-Object {
            [pscustomobject]@{
                'Слот'       = Clean $_.SlotDesignation
                'Ширина'     = $(if ($null -ne $_.MaxDataWidth) { $wMap[[int]$_.MaxDataWidth] } else { '' })
                'Занят'      = $(switch ([int]$_.CurrentUsage) { 3 { 'свободен' } 4 { 'занят' } default { 'неизвестно' } })
                'Примечание' = Clean $_.Description
            } })
    Add-Table $s 'Слоты расширения (по данным BIOS)' $slt -Collapsed
    $obd = @(CIM Win32_OnBoardDevice | Where-Object { $_.Description } | ForEach-Object {
            [pscustomobject]@{ 'Встроенное устройство' = Clean $_.Description; 'Тип' = $(switch ([int]$_.DeviceType) { 3 { 'видео' } 4 { 'SCSI/SATA' } 5 { 'Ethernet' } 7 { 'звук' } 8 { 'PATA' } 9 { 'SATA' } 10 { 'SAS' } default { 'прочее' } }); 'Включено' = $(if ($_.Enabled) { 'да' } else { 'нет' }) } })
    Add-Table $s 'Встроенные устройства платы (по данным BIOS)' $obd -Collapsed
    $ports = @(CIM Win32_PortConnector | ForEach-Object { [pscustomobject]@{ 'Внутренний' = Clean $_.InternalReferenceDesignator; 'Внешний' = Clean $_.ExternalReferenceDesignator } } | Where-Object { $_.'Внутренний' -or $_.'Внешний' })
    Add-Table $s 'Разъёмы платы (по данным BIOS)' $ports -Collapsed

    # ================================================================ 4. ВИДЕОКАРТЫ
    $smiRows = @()
    $smiExe = $null; if (Get-Command Get-SmiExe -ErrorAction SilentlyContinue) { $smiExe = Get-SmiExe }
    if ($smiExe) {
        try {
            $r = Run-Exe $smiExe '--query-gpu=name,vbios_version,memory.total,pci.bus_id --format=csv,noheader' 20
            foreach ($ln in ($r.Out -split "`r?`n")) { $p = $ln -split ',\s*'; if ($p.Count -ge 3 -and $p[0].Trim()) { $smiRows += [pscustomobject]@{ Name = $p[0].Trim(); Vbios = $p[1].Trim(); Mem = $p[2].Trim() } } }
        } catch {}
    }
    $czGpu = @(); if ($cz) { $czGpu = @($cz | Where-Object { $_.Sub -match '^Display adapter' } | Group-Object B | ForEach-Object { , $_.Group }) }
    $used = @{}; $gcols = @(); $gvend = @()
    foreach ($v in (CIM Win32_VideoController)) {
        $d = @{}
        $pid2 = "$($v.PNPDeviceID)"
        $d['Модель'] = Clean $v.Name
        $chipV = ''; $devId = ''; $subV = ''; $subD = ''
        if ($pid2 -match 'VEN_([0-9A-F]{4})&DEV_([0-9A-F]{4})') { $chipV = $Matches[1].ToUpper(); $devId = $Matches[2].ToUpper() }
        if ($pid2 -match 'SUBSYS_([0-9A-F]{4})([0-9A-F]{4})') { $subD = $Matches[1].ToUpper(); $subV = $Matches[2].ToUpper() }
        $cg = $null
        foreach ($grpItem in $czGpu) { $nm = CzIn $grpItem '^Name$'; if ($nm -and ((Clean $v.Name) -like "*$nm*" -or $nm -like ('*' + (Clean $v.Name) + '*'))) { $cg = $grpItem; break } }
        if (-not $cg -and $devId) { foreach ($grpItem in $czGpu) { if ((CzIn $grpItem '^Model ID$') -match ('(?i)0x' + $devId)) { $cg = $grpItem; break } } }
        $partner = ''
        if ($subV) { $partner = $subVendors[$subV]; if (-not $partner) { $partner = "код $subV" } }
        $czBoard = ''; if ($cg) { $czBoard = CzIn $cg '^Board Manufacturer$' }
        $d['Производитель карты (вендор)'] = (@($partner, $(if ($czBoard -and (-not $partner -or $czBoard -notmatch [regex]::Escape("$partner"))) { "CPU-Z: $czBoard" } else { '' })) | Where-Object { $_ }) -join '; '
        $d['Производитель чипа'] = $pciVendors[$chipV]
        if ($cg) { $d['Кодовое имя GPU'] = CzIn $cg '^Codename$'; $d['Техпроцесс'] = CzIn $cg '^Technology$'; $d['Шейдерных блоков'] = CzIn $cg '^(Cores|Shaders?)$' }
        # реестр драйвера: память, BIOS
        $reg = $null
        try {
            $drvKey = (Get-PnpDeviceProperty -InstanceId $pid2 -KeyName 'DEVPKEY_Device_Driver' -ErrorAction Stop).Data
            if ($drvKey) { $reg = Get-ItemProperty ('HKLM:\SYSTEM\CurrentControlSet\Control\Class\' + $drvKey) -ErrorAction Stop }
        } catch {}
        $mem = $null
        if ($reg) {
            $mem = $reg.'HardwareInformation.qwMemorySize'
            if (-not $mem) { $m2 = $reg.'HardwareInformation.MemorySize'; if ($m2 -is [byte[]] -and $m2.Length -ge 4) { $mem = [BitConverter]::ToUInt32($m2, 0) } elseif ($m2) { $mem = $m2 } }
        }
        if (-not $mem) { $mem = $v.AdapterRAM }
        $memTxt = ''; if ($mem) { $memTxt = Pp-Size ([double]$mem) }
        $czMem = ''; if ($cg) { $czMem = (@((CzIn $cg '^Memory type$'), (CzIn $cg '^Memory vendor$')) | Where-Object { $_ }) -join ', ' }
        $d['Видеопамять'] = (@($memTxt, $czMem) | Where-Object { $_ }) -join ', '
        if ($cg) { $d['Шина памяти (CPU-Z)'] = CzIn $cg '^Memory bus' }
        $vb = ''
        $sm = $smiRows | Where-Object { $_.Name -and (Clean $v.Name) -like ('*' + $_.Name + '*') } | Select-Object -First 1
        if (-not $sm -and $v.Name -match 'NVIDIA' -and $smiRows.Count -eq 1) { $sm = $smiRows[0] }
        if ($sm -and $sm.Vbios -and $sm.Vbios -notmatch 'N/A') { $vb = $sm.Vbios }
        if (-not $vb -and $reg) { $vb = Pp-RegStr $reg.'HardwareInformation.BiosString' }
        if (-not $vb -and $cg) { $vb = CzIn $cg '(?i)^BIOS' }
        $d['Версия VBIOS'] = $vb
        if ($reg) { $ct = Pp-RegStr $reg.'HardwareInformation.ChipType'; if ($ct -and $ct -ne (Clean $v.Name)) { $d['Тип чипа (драйвер)'] = $ct } }
        $d['Драйвер'] = '{0} от {1}' -f $v.DriverVersion, (DT $v.DriverDate)
        $d['PCI ID (чип / плата)'] = $(if ($chipV) { '{0}:{1} / {2}:{3}' -f $chipV, $devId, $subV, $subD } else { $pid2 })
        $gcols += @{ L = (Pp-Label (Clean $v.Name) $used); D = $d }
        if ($partner) { $gvend += $partner }
    }
    if ($gcols.Count) { Add-Table $s 'Видеокарты' (Pp-Transpose $gcols @('Модель', 'Производитель карты (вендор)', 'Производитель чипа', 'Кодовое имя GPU', 'Техпроцесс', 'Шейдерных блоков', 'Видеопамять', 'Шина памяти (CPU-Z)', 'Версия VBIOS', 'Тип чипа (драйвер)', 'Драйвер', 'PCI ID (чип / плата)')) }
    $passport.gpu_vendor = @($gvend | Select-Object -Unique)

    # ================================================================ 5. НАКОПИТЕЛИ
    $dd = @{}; foreach ($x in (CIM Win32_DiskDrive)) { $dd["$($x.Index)"] = $x }
    $srows = @()
    foreach ($pd in @(Get-PhysicalDisk -ErrorAction SilentlyContinue | Sort-Object { [int]$_.DeviceId })) {
        $w = $dd["$($pd.DeviceId)"]
        $media = "$($pd.MediaType)"; if ($media -eq 'Unspecified' -and "$($pd.BusType)" -eq 'NVMe') { $media = 'SSD' }
        $ps = ''; try { $ps = "$((Get-Disk -Number $pd.DeviceId -ErrorAction Stop).PartitionStyle)" } catch {}
        $sn = Clean $pd.SerialNumber; if (-not $sn -and $w) { $sn = Clean $w.SerialNumber }
        $srows += [pscustomobject]@{
            '№'        = $pd.DeviceId
            'Модель'   = Clean $pd.FriendlyName
            'Серийный' = $(if ($sn) { $sn.TrimEnd('.') } else { '—' })
            'Прошивка' = Clean $pd.FirmwareVersion
            'Тип'      = '{0}{1}' -f $media, $(if ($pd.SpindleSpeed -and $pd.SpindleSpeed -lt 100000 -and $media -eq 'HDD') { ', {0} об/мин' -f $pd.SpindleSpeed } else { '' })
            'Шина'     = "$($pd.BusType)"
            'Объём'    = '{0} ({1:N0} ГБ дес.)' -f (GB $pd.Size 0), ([double]$pd.Size / 1e9)
            'Разметка' = $(if ($ps -and $ps -ne 'RAW') { $ps } elseif ($ps) { 'не размечен' } else { '—' })
            'Сектор'   = $(if ($pd.PhysicalSectorSize) { '{0}/{1} Б' -f $pd.LogicalSectorSize, $pd.PhysicalSectorSize } else { '' })
        }
    }
    Add-Table $s 'Накопители' $srows

    # ================================================================ 6. МОНИТОРЫ
    $outMap = @{ '-1' = 'другое'; '0' = 'VGA (D-Sub)'; '1' = 'S-Video'; '2' = 'композитный'; '3' = 'компонентный'; '4' = 'DVI'; '5' = 'HDMI'; '6' = 'LVDS (встроенный)'; '8' = 'D-Jpn'; '9' = 'SDI'; '10' = 'DisplayPort'; '11' = 'eDP (встроенный)'; '12' = 'UDI'; '13' = 'UDI (встроенный)'; '14' = 'SDTV'; '15' = 'Miracast (беспроводной)'; '16' = 'проводной адаптер (USB/док)'; '17' = 'виртуальный'; '18' = 'DisplayPort через USB-C/Thunderbolt'; '2147483648' = 'встроенный дисплей'; '4294967295' = 'другое' }
    $basic = @(CIM WmiMonitorBasicDisplayParams 'root/wmi')
    $conn = @(CIM WmiMonitorConnectionParams 'root/wmi')
    $listed = @(CIM WmiMonitorListedSupportedSourceModes 'root/wmi')
    $disp = @(); if ($api) { try { $disp = @([PcDiagHw]::Displays()) } catch {} }
    $dmap = @{}
    foreach ($ln in $disp) {
        $p = $ln -split '\|'
        if ($p.Count -lt 9) { continue }
        foreach ($mid in ($p[8] -split ';')) {
            if ($mid -match '^\\\\\?\\(.+?)#\{') { $dmap[($Matches[1] -replace '#', '\').ToUpper()] = [pscustomobject]@{ Gpu = $p[1]; W = [int]$p[2]; H = [int]$p[3]; Hz = [int]$p[4]; MaxCur = [int]$p[5]; MaxAny = [int]$p[6]; Bpp = [int]$p[7] } }
        }
    }
    $czMon = @(); if ($cz) { $czMon = @($cz | Where-Object { $_.Sub -match '^Monitor' } | Group-Object B | ForEach-Object { , $_.Group }) }
    $used = @{}; $mcols = @(); $monSum = @()
    foreach ($m in (CIM WmiMonitorID 'root/wmi')) {
        $inst = "$($m.InstanceName)"
        $d = @{}
        $code = DecodeWmi $m.ManufacturerName
        $prod = DecodeWmi $m.ProductCodeID
        $nm = DecodeWmi $m.UserFriendlyName
        $vend = $pnpVendors[$code]
        $d['Производитель'] = $(if ($vend) { '{0} ({1})' -f $vend, $code } else { $code })
        $d['Модель'] = $(if ($nm) { $nm } else { 'без имени (встроенная панель?)' })
        $d['Код модели (EDID)'] = $(if ($code) { "$code$prod" } else { $prod })
        $ser = DecodeWmi $m.SerialNumberID; if ($ser -and -not (Pp-Bad $ser)) { $d['Серийный номер'] = $ser }
        $yr = [int]$m.YearOfManufacture; $wk = [int]$m.WeekOfManufacture
        if ($yr -gt 1990) { $d['Дата выпуска'] = $(if ($wk -eq 255) { "модельный год $yr" } elseif ($wk -ge 1 -and $wk -le 54) { '{0} неделя {1} г.' -f $wk, $yr } else { "$yr г." }) }
        $b = $basic | Where-Object { $_.InstanceName -eq $inst } | Select-Object -First 1
        if ($b -and $b.MaxHorizontalImageSize -gt 0) {
            $diag = [math]::Sqrt([math]::Pow([double]$b.MaxHorizontalImageSize, 2) + [math]::Pow([double]$b.MaxVerticalImageSize, 2)) / 2.54
            $d['Размер экрана'] = '{0:N1}" ({1}×{2} см)' -f $diag, $b.MaxHorizontalImageSize, $b.MaxVerticalImageSize
        }
        $c = $conn | Where-Object { $_.InstanceName -eq $inst } | Select-Object -First 1
        if ($c) { $ot = $outMap["$([int64]$c.VideoOutputTechnology)"]; $d['Подключение'] = $(if ($ot) { $ot } else { 'код ' + $c.VideoOutputTechnology }) }
        # родное разрешение и максимальная частота по EDID
        $lm = $listed | Where-Object { $_.InstanceName -eq $inst } | Select-Object -First 1
        $edidMax = 0
        if ($lm -and $lm.MonitorSourceModes) {
            $modes = (AsArr $lm.MonitorSourceModes)
            $pi = [int]$lm.PreferredMonitorSourceModeIndex
            if ($pi -ge 0 -and $pi -lt $modes.Count) { $d['Родное разрешение (EDID)'] = '{0}×{1}' -f $modes[$pi].HorizontalActivePixels, $modes[$pi].VerticalActivePixels }
            foreach ($md in $modes) { if ($md.VerticalRefreshRateDenominator -gt 0) { $hz = [double]$md.VerticalRefreshRateNumerator / $md.VerticalRefreshRateDenominator; if ($hz -gt $edidMax) { $edidMax = $hz } } }
            if ($edidMax -gt 0) { $d['Макс. частота по EDID'] = '{0:N0} Гц' -f $edidMax }
        }
        $cm = $null
        $did = ($inst -replace '_\d+$', '').ToUpper()
        if ($dmap.ContainsKey($did)) { $cm = $dmap[$did] }
        if ($cm) {
            $d['Текущий режим'] = '{0}×{1} @ {2} Гц, {3} бит (видеокарта: {4})' -f $cm.W, $cm.H, $cm.Hz, $cm.Bpp, $cm.Gpu
            if ($cm.MaxCur -gt 0) { $d['Макс. частота в этом разрешении (драйвер)'] = '{0} Гц' -f $cm.MaxCur }
        }
        $czm = $null
        foreach ($grpItem in $czMon) { if ($code -and (CzIn $grpItem '^ID$') -match ('^' + [regex]::Escape("$code$prod") + '$')) { $czm = $grpItem; break } }
        if ($czm) { $d['Диапазон частот (CPU-Z)'] = (@((CzIn $czm '^Vertical Freq'), (CzIn $czm '^Max Resolution')) | Where-Object { $_ }) -join '; ' }
        $lbl = Pp-Label $(if ($nm) { $nm } else { "$code$prod" }) $used
        $mcols += @{ L = $lbl; D = $d }
        $monSum += "$code$prod"
        # частота ниже возможной
        if ($cm -and $cm.Hz -gt 1) {
            if ($cm.MaxCur -ge 75 -and $cm.MaxCur -ge $cm.Hz + 10) {
                Add-Issue 'info' 'Видеокарта' ('монитор {0} работает на {1} Гц, а в этом разрешении поддерживает {2} Гц' -f $lbl, $cm.Hz, $cm.MaxCur) ('Включите {0} Гц: Параметры → Система → Дисплей → Расширенные параметры дисплея → Частота обновления (или в панели NVIDIA/AMD). Картинка станет заметно плавнее.' -f $cm.MaxCur)
            } elseif ($edidMax -ge 75 -and $edidMax -ge $cm.Hz + 10 -and $cm.MaxCur -lt $edidMax - 5) {
                Add-Issue 'info' 'Видеокарта' ('монитор {0} умеет {1:N0} Гц, но через текущее подключение доступно только {2} Гц' -f $lbl, $edidMax, [math]::Max($cm.MaxCur, $cm.Hz)) 'Обычно виноват кабель или порт: подключите через DisplayPort или HDMI 2.0/2.1 (кабель High Speed / Ultra High Speed) к порту видеокарты, а не материнской платы. Проверьте настройку частоты/версии DP в меню монитора.'
            }
        }
    }
    if ($mcols.Count) { Add-Table $s 'Мониторы' (Pp-Transpose $mcols @('Производитель', 'Модель', 'Код модели (EDID)', 'Серийный номер', 'Дата выпуска', 'Размер экрана', 'Родное разрешение (EDID)', 'Подключение', 'Текущий режим', 'Макс. частота в этом разрешении (драйвер)', 'Макс. частота по EDID', 'Диапазон частот (CPU-Z)')) }
    $passport.mon = @($monSum | Where-Object { $_ })

    # ================================================================ 7. СЕТЕВЫЕ АДАПТЕРЫ
    $wgen = ''
    $nets = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue)
    if (@($nets | Where-Object { "$($_.PhysicalMediaType)" -match '802\.11|Wireless' -or $_.InterfaceDescription -match '(?i)wi-?fi|wireless|802\.11|WLAN' }).Count) {
        $wd = (netsh wlan show drivers 2>$null) -join "`n"
        $sup = @([regex]::Matches($wd, '802\.11[a-z]{1,2}') | ForEach-Object { $_.Value } | Select-Object -Unique)
        if ($sup.Count) { $wgen = $(if ($sup -contains '802.11be') { 'Wi-Fi 7' } elseif ($sup -contains '802.11ax') { 'Wi-Fi 6/6E' } elseif ($sup -contains '802.11ac') { 'Wi-Fi 5' } elseif ($sup -contains '802.11n') { 'Wi-Fi 4' } else { 'Wi-Fi 3 и старше' }) + ' (' + ($sup -join ', ') + ')' }
    }
    $nrows = @($nets | ForEach-Object {
            $pnp = "$($_.PnPDeviceID)"; $vid = ''
            if ($pnp -match '(?:VEN|VID)_([0-9A-F]{4})') { $vid = $Matches[1].ToUpper() }
            $wifi = ("$($_.PhysicalMediaType)" -match '802\.11|Wireless') -or ($_.InterfaceDescription -match '(?i)wi-?fi|wireless|802\.11|WLAN')
            [pscustomobject]@{
                'Адаптер'       = Clean $_.InterfaceDescription
                'Производитель' = $(if ($pciVendors[$vid]) { $pciVendors[$vid] } elseif ($vid) { "код $vid" } else { '' })
                'Тип'           = $(if ($wifi) { 'Wi-Fi' + $(if ($wgen) { ': ' + $wgen } else { '' }) } elseif ($pnp -like 'USB\*') { 'USB-сеть' } else { 'Ethernet' })
                'MAC'           = $_.MacAddress
                'Скорость'      = $(if ($_.Status -eq 'Up') { $_.LinkSpeed } else { 'не подключён' })
                'Драйвер'       = '{0} от {1}' -f $_.DriverVersion, (DT $_.DriverDate)
            } })
    Add-Table $s 'Сетевые адаптеры' $nrows

    # ================================================================ 8. ЗВУК, USB, BLUETOOTH
    $arows = @(CIM Win32_SoundDevice | ForEach-Object {
            [pscustomobject]@{ 'Звуковое устройство' = Clean $_.Name; 'Производитель' = Clean $_.Manufacturer; 'Драйвер' = Pp-Drv $_.PNPDeviceID; 'Состояние' = $(if ("$($_.Status)" -eq 'OK') { 'OK' } else { "$($_.Status)" }) } })
    Add-Table $s 'Звук' $arows
    $pnpAll = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue)
    $bts = @($pnpAll | Where-Object { $_.Class -eq 'Bluetooth' -and $_.InstanceId -match '^(USB|PCI)\\' })
    $btRows = @($bts | ForEach-Object {
            $vid = ''; if ($_.InstanceId -match '(?:VID|VEN)_([0-9A-F]{4})') { $vid = $Matches[1].ToUpper() }
            [pscustomobject]@{ 'Bluetooth-адаптер' = Clean $_.FriendlyName; 'Производитель' = $pciVendors[$vid]; 'Драйвер' = Pp-Drv $_.InstanceId; 'Состояние' = $(if ("$($_.Status)" -eq 'OK') { 'OK' } else { "$($_.Status)" }) } })
    if ($btRows.Count) { Add-Table $s 'Bluetooth' $btRows } else { Add-Row $s 'Bluetooth' 'адаптер не обнаружен' }
    $usbc = @($pnpAll | Where-Object { $_.Class -eq 'USB' -and $_.FriendlyName -match '(?i)host controller|хост-контроллер|xhci|ehci|USB4|Thunderbolt' } | ForEach-Object {
            $vid = ''; if ($_.InstanceId -match 'VEN_([0-9A-F]{4})') { $vid = $Matches[1].ToUpper() }
            [pscustomobject]@{ 'USB-контроллер' = Clean $_.FriendlyName; 'Производитель' = $pciVendors[$vid]; 'Состояние' = $(if ("$($_.Status)" -eq 'OK') { 'OK' } else { "$($_.Status)" }) } })
    Add-Table $s 'USB-контроллеры' $usbc
    $usbDev = @($pnpAll | Where-Object { $_.InstanceId -match '^USB\\VID_[0-9A-F]{4}&PID_[0-9A-F]{4}' -and $_.InstanceId -notmatch '&MI_' -and $_.FriendlyName -notmatch '(?i)root hub|корневой|generic usb hub|универсальный usb-концентратор|usb hub$|концентратор' })
    $urows = @()
    foreach ($u in $usbDev) {
        $vid = ''; $prd = ''
        if ($u.InstanceId -match 'VID_([0-9A-F]{4})&PID_([0-9A-F]{4})') { $vid = $Matches[1].ToUpper(); $prd = $Matches[2].ToUpper() }
        $real = ''
        try { $real = "$((Get-PnpDeviceProperty -InstanceId $u.InstanceId -KeyName 'DEVPKEY_Device_BusReportedDeviceDesc' -ErrorAction Stop).Data)".Trim() } catch {}
        $nm = Clean $u.FriendlyName
        $urows += [pscustomobject]@{
            'USB-устройство' = $(if ($real -and $real -ne $nm) { '{0} ({1})' -f $real, $nm } else { $nm })
            'Производитель'  = $(if ($pciVendors[$vid]) { $pciVendors[$vid] } else { '' })
            'Класс'          = "$($u.Class)"
            'VID:PID'        = "$vid`:$prd"
            'Состояние'      = $(if ("$($u.Status)" -eq 'OK') { 'OK' } elseif ("$($u.Status)" -eq 'Error') { 'ОШИБКА' } else { "$($u.Status)" })
        }
    }
    Add-Table $s ('Подключённые USB-устройства ({0})' -f $urows.Count) ($urows | Sort-Object 'USB-устройство') -Collapsed

    # ================================================================ 9. БЛОК ПИТАНИЯ
    if (-not $G.IsLaptop) { Add-Row $s 'Блок питания' 'модель программно не определяется — запишите с наклейки на БП (модель, мощность, дата)' }
    else { Add-Row $s 'Зарядное устройство' 'модель программно не определяется — посмотрите мощность (Вт) на наклейке адаптера' }

    $G.Num.passport = $passport
    if ($passport.cpu_code) { Info ('процессор: {0} ({1})' -f $passport.cpu, $passport.cpu_code) }
    Info ('паспорт: модулей памяти {0}, видеокарт {1}, мониторов {2}, накопителей {3}, USB-устройств {4}' -f $mods.Count, $gcols.Count, $mcols.Count, $srows.Count, $urows.Count)
}
