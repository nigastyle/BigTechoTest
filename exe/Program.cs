using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace PCDiag
{
    // Thin launcher: unpacks the embedded PC-Diagnostika.cmd to a temp folder and runs it.
    // The console of cmd/PowerShell is created HIDDEN: the program talks to the user only through its windows
    // (chooser, live window, dialogs). DIAG_GUI=1 tells the script about it; DIAG_ROOT points it at the folder
    // next to the .exe (tools\, reports\).
    static class Program
    {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct STARTUPINFO
        {
            public int cb; public string lpReserved, lpDesktop, lpTitle;
            public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
            public short wShowWindow, cbReserved2; public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
        }
        [StructLayout(LayoutKind.Sequential)]
        struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool CreateProcess(string app, System.Text.StringBuilder cmdLine, IntPtr pa, IntPtr ta, bool inherit,
            int flags, IntPtr env, string dir, ref STARTUPINFO si, out PROCESS_INFORMATION pi);
        [DllImport("kernel32.dll", SetLastError = true)] static extern int WaitForSingleObject(IntPtr h, int ms);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetExitCodeProcess(IntPtr h, out int code);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool CloseHandle(IntPtr h);

        const int STARTF_USESHOWWINDOW = 0x1, SW_HIDE = 0, CREATE_NEW_CONSOLE = 0x10, CREATE_UNICODE_ENVIRONMENT = 0x400;

        [STAThread]
        static int Main()
        {
            string tmp = Path.Combine(Path.GetTempPath(), "pcdiag_" + Guid.NewGuid().ToString("N").Substring(0, 8));
            try
            {
                Directory.CreateDirectory(tmp);
                string cmd = Path.Combine(tmp, "PC-Diagnostika.cmd");
                using (Stream s = Assembly.GetExecutingAssembly().GetManifestResourceStream("payload.cmd"))
                using (FileStream f = File.Create(cmd)) { s.CopyTo(f); }

                string exeDir = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
                Environment.SetEnvironmentVariable("DIAG_ROOT", exeDir);
                Environment.SetEnvironmentVariable("DIAG_GUI", "1");

                // own console, created hidden (STARTF_USESHOWWINDOW + SW_HIDE); the environment is inherited
                string cmdExe = Path.Combine(Environment.SystemDirectory, "cmd.exe");
                var line = new System.Text.StringBuilder("\"" + cmdExe + "\" /c \"\"" + cmd + "\"\"");
                var si = new STARTUPINFO();
                si.cb = Marshal.SizeOf(typeof(STARTUPINFO));
                si.dwFlags = STARTF_USESHOWWINDOW;
                si.wShowWindow = SW_HIDE;
                PROCESS_INFORMATION pi;
                if (!CreateProcess(cmdExe, line, IntPtr.Zero, IntPtr.Zero, false, CREATE_NEW_CONSOLE | CREATE_UNICODE_ENVIRONMENT,
                        IntPtr.Zero, exeDir, ref si, out pi))
                    throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
                try
                {
                    WaitForSingleObject(pi.hProcess, -1);
                    int code;
                    GetExitCodeProcess(pi.hProcess, out code);
                    return code;
                }
                finally { CloseHandle(pi.hThread); CloseHandle(pi.hProcess); }
            }
            catch (Exception ex)
            {
                MessageBox.Show("Не удалось запустить диагностику:\n" + ex.Message, "Диагностика ПК", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return 1;
            }
            finally
            {
                try { Directory.Delete(tmp, true); } catch { }
            }
        }
    }
}
