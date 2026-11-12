# OCR экрана встроенным движком Windows (Windows.Media.Ocr) -> %LOCALAPPDATA%\BTT\ocr.txt и screen.png
Add-Type -AssemblyName System.Windows.Forms, System.Drawing, System.Runtime.WindowsRuntime
Add-Type 'using System;using System.Runtime.InteropServices;public class DpiB{[DllImport("user32.dll")]public static extern bool SetProcessDPIAware();}'
[void][DpiB]::SetProcessDPIAware()
$dir = Join-Path $env:LOCALAPPDATA 'BTT'; New-Item -ItemType Directory -Force $dir | Out-Null
$png = Join-Path $dir 'screen.png'; $txt = Join-Path $dir 'ocr.txt'
$b = [System.Windows.Forms.SystemInformation]::VirtualScreen
$bmp = New-Object System.Drawing.Bitmap($b.Width, $b.Height)
([System.Drawing.Graphics]::FromImage($bmp)).CopyFromScreen($b.Left, $b.Top, 0, 0, $bmp.Size); $bmp.Save($png)
$asTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
function Await($op, $t) { $tk = $asTask.MakeGenericMethod($t).Invoke($null, @($op)); $tk.Wait(-1) | Out-Null; $tk.Result }
[void][Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
[void][Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]
[void][Windows.Graphics.Imaging.BitmapDecoder, Windows.Graphics, ContentType = WindowsRuntime]
$f = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($png)) ([Windows.Storage.StorageFile])
$s = Await ($f.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
$dec = Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($s)) ([Windows.Graphics.Imaging.BitmapDecoder])
$sb = Await ($dec.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
$eng = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
$res = Await ($eng.RecognizeAsync($sb)) ([Windows.Media.Ocr.OcrResult])
($res.Lines | ForEach-Object { $_.Text }) -join "`r`n" | Set-Content $txt -Encoding UTF8
"lang=$($eng.RecognizerLanguage.LanguageTag) lines=$(@($res.Lines).Count)" | Add-Content $txt
