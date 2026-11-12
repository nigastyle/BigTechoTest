using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows.Forms;

namespace PCDiag
{
    // Thin launcher: unpacks the embedded PC-Diagnostika.cmd to a temp folder and runs it in a console.
    // DIAG_ROOT points the script at the folder next to the .exe (tools\, reports\).
    static class Program
    {
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

                var psi = new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, "cmd.exe"), "/c \"\"" + cmd + "\"\"");
                psi.UseShellExecute = false;           // inherit DIAG_ROOT
                psi.CreateNoWindow = false;            // the script needs its own console
                psi.WorkingDirectory = exeDir;
                using (Process p = Process.Start(psi))
                {
                    p.WaitForExit();
                    return p.ExitCode;
                }
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
