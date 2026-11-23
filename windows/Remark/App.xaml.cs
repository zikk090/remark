using System;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;
using System.Windows;
using System.Windows.Threading;

namespace Remark;

public partial class App : Application
{
    private Mutex? _singleInstance;
    private TrayController? _controller;

    /// Set by the CI end-to-end test so errors are logged instead of shown in a blocking dialog.
    private static bool IsCi => Environment.GetEnvironmentVariable("REMARK_CI") == "1";

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        QuestPDF.Settings.License = QuestPDF.Infrastructure.LicenseType.Community;

        // Headless self-tests used by CI (no tray, no single-instance lock).
        if (e.Args.Length >= 3 && e.Args[0] == "--selftest-export") { SelfTestExport(e.Args[1], e.Args[2]); return; }
        if (e.Args.Length >= 3 && e.Args[0] == "--selftest-ocr") { SelfTestOcr(e.Args[1], e.Args[2]); return; }

        _singleInstance = new Mutex(true, @"Local\Remark.SingleInstance", out bool isFirst);
        if (!isFirst)
        {
            MessageBox.Show("Remark is already running. Look for its icon in the system tray (you may need to click the ^ arrow).",
                            "Remark", MessageBoxButton.OK, MessageBoxImage.Information);
            Shutdown();
            return;
        }

        DispatcherUnhandledException += OnUnhandled;
        // Lets the WinForms selection overlay receive keyboard input (Esc/Enter) inside a WPF app.
        System.Windows.Forms.Integration.WindowsFormsHost.EnableWindowsFormsInterop();

        _controller = new TrayController();
        _controller.Start();
        if (e.Args.Contains("--show-settings")) _controller.ShowSettings();
    }

    private void SelfTestExport(string sessionFolder, string outDir)
    {
        var log = new StringBuilder();
        int failures = 0;
        try
        {
            Directory.CreateDirectory(outDir);
            var store = new SessionStore(new Prefs());
            if (!store.Open(sessionFolder)) throw new InvalidOperationException("could not open session " + sessionFolder);
            log.AppendLine($"session: {store.Session!.Title} ({store.Session.Notes.Count} notes)");
            foreach (var f in Enum.GetValues<ExportFormat>())
            {
                var path = Path.Combine(outDir, "export." + f.Extension());
                try
                {
                    Exporter.Export(f, store, path, PdfPageSize.A4);
                    var size = new FileInfo(path).Length;
                    log.AppendLine($"PASS {f} {size} bytes");
                    if (size == 0) failures++;
                }
                catch (Exception ex)
                {
                    failures++;
                    log.AppendLine($"FAIL {f} {ex}");
                }
            }
        }
        catch (Exception ex)
        {
            failures++;
            log.AppendLine("FAIL setup " + ex);
        }
        File.WriteAllText(Path.Combine(outDir, "selftest-export.txt"), log.ToString());
        Shutdown(failures == 0 ? 0 : 1);
    }

    private async void SelfTestOcr(string png, string outFile)
    {
        try
        {
            var text = await OcrService.RecognizeAsync(png);
            File.WriteAllText(outFile, "PASS\n" + text);
            Shutdown(0);
        }
        catch (Exception ex)
        {
            File.WriteAllText(outFile, "FAIL\n" + ex);
            Shutdown(1);
        }
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _controller?.Dispose();
        _singleInstance?.Dispose();
        base.OnExit(e);
    }

    private void OnUnhandled(object sender, DispatcherUnhandledExceptionEventArgs e)
    {
        try
        {
            var dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Remark");
            Directory.CreateDirectory(dir);
            File.AppendAllText(Path.Combine(dir, "error.log"), $"[{DateTime.Now:u}] {e.Exception}\n\n");
        }
        catch { }
        if (IsCi) { e.Handled = true; return; }
        MessageBox.Show($"Something went wrong:\n\n{e.Exception.Message}\n\nDetails were saved to %APPDATA%\\Remark\\error.log.",
                        "Remark", MessageBoxButton.OK, MessageBoxImage.Warning);
        e.Handled = true;
    }
}
