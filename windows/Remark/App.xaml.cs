using System;
using System.IO;
using System.Threading;
using System.Windows;
using System.Windows.Threading;

namespace Remark;

public partial class App : Application
{
    private Mutex? _singleInstance;
    private TrayController? _controller;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

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

        QuestPDF.Settings.License = QuestPDF.Infrastructure.LicenseType.Community;

        _controller = new TrayController();
        _controller.Start();
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
        MessageBox.Show($"Something went wrong:\n\n{e.Exception.Message}\n\nDetails were saved to %APPDATA%\\Remark\\error.log.",
                        "Remark", MessageBoxButton.OK, MessageBoxImage.Warning);
        e.Handled = true;
    }
}
