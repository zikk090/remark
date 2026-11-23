using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing.Imaging;
using System.IO;
using System.Reflection;
using System.Threading.Tasks;
using System.Windows;
using Forms = System.Windows.Forms;

namespace Remark;

/// The app's brain: tray icon + menu, hotkeys, capture flow, buddy, settings.
internal sealed class TrayController : IDisposable
{
    private readonly Prefs _prefs = Prefs.Load();
    private readonly SessionStore _store;
    private readonly HotKeyManager _hotkeys = new();
    private readonly BuddyWindow _buddy = new();
    private readonly Forms.NotifyIcon _tray = new();
    private HashSet<HotkeyAction> _unavailable = new();

    private NoteWindow? _note;
    private SettingsWindow? _settings;
    private bool _busy;
    private bool _recordingShortcut;

    public TrayController()
    {
        _store = new SessionStore(_prefs);
    }

    public void Start()
    {
        var iconStream = Application.GetResourceStream(new Uri("pack://application:,,,/Assets/Remark.ico"))?.Stream;
        _tray.Icon = iconStream != null ? new System.Drawing.Icon(iconStream) : System.Drawing.SystemIcons.Application;
        _tray.Text = "Remark";
        _tray.Visible = true;
        _tray.ContextMenuStrip = new Forms.ContextMenuStrip { ShowImageMargin = false, Font = new System.Drawing.Font("Segoe UI", 9.5f) };
        _tray.ContextMenuStrip.Opening += (_, _) => BuildMenu();
        _tray.MouseUp += (_, e) =>
        {
            if (e.Button == Forms.MouseButtons.Left)
            {
                // Show the same menu on left-click.
                typeof(Forms.NotifyIcon).GetMethod("ShowContextMenu", BindingFlags.Instance | BindingFlags.NonPublic)?.Invoke(_tray, null);
            }
        };

        _prefs.Changed = () =>
        {
            RefreshBuddy();
            if (!_recordingShortcut) RegisterHotkeys(); // picks up edited / reset shortcuts
        };
        _store.Changed += RefreshBuddy;
        RegisterHotkeys();
        _store.ResumeLast();
        RefreshBuddy();

        if (!_prefs.Welcomed)
        {
            var s = _prefs.ShortcutFor(HotkeyAction.Capture)?.Display ?? "the shortcut";
            _tray.ShowBalloonTip(5000, "Remark is running",
                $"It lives in the system tray. Press {s} to capture an area and add a note.", Forms.ToolTipIcon.None);
            _prefs.Welcomed = true;
            _prefs.Save();
        }
    }

    // ---------- hotkeys ----------

    private void RegisterHotkeys()
    {
        _hotkeys.UnregisterAll();
        var failed = new HashSet<HotkeyAction>();
        foreach (var action in Enum.GetValues<HotkeyAction>())
        {
            if (_prefs.ShortcutFor(action) is not { } s) continue;
            var a = action;
            if (!_hotkeys.Register(s, () => Perform(a))) failed.Add(action);
        }
        _unavailable = failed;
    }

    private void Perform(HotkeyAction action)
    {
        switch (action)
        {
            case HotkeyAction.Capture: _ = BeginCaptureAsync(); break;
            case HotkeyAction.CaptureText: _ = BeginTextNoteAsync(); break;
            case HotkeyAction.NewSession: PromptNewSession(); break;
            case HotkeyAction.ToggleBuddy:
                _prefs.BuddyEnabled = !_prefs.BuddyEnabled;
                _prefs.Save();
                break;
        }
    }

    // ---------- screenshot notes ----------

    private async Task BeginCaptureAsync()
    {
        if (_note != null) { _note.FocusNote(); return; }
        if (_busy) return;
        _busy = true;
        var fg = ForegroundInfo.Capture();
        _buddy.SetVisible(false);
        await Task.Delay(30); // let the buddy disappear before the screen is frozen

        CaptureResult? result;
        try { result = await RegionSelector.SelectAsync(); }
        finally { _busy = false; RefreshBuddy(); }

        if (result == null) { fg.Restore(); return; }

        string path;
        using (result)
        {
            path = _store.NextImagePath();
            result.Image.Save(path, ImageFormat.Png);
        }

        ShowNote(new NoteDraft
        {
            ImagePath = path,
            SourceApp = fg.App,
            WindowTitle = fg.Title,
            SessionTitle = _store.Session?.Title ?? "Review",
            Anchor = result.Bounds
        }, fg);
    }

    // ---------- text-selection notes ----------

    private async Task BeginTextNoteAsync()
    {
        if (_note != null) { _note.FocusNote(); return; }
        if (_busy) return;
        _busy = true;
        try
        {
            var fg = ForegroundInfo.Capture();
            Native.GetCursorPos(out var p);
            var text = (await TextGrabber.GrabSelectedTextAsync())?.Trim();
            if (string.IsNullOrEmpty(text))
            {
                var hint = _prefs.ShortcutFor(HotkeyAction.CaptureText)?.Display ?? "the shortcut";
                Toast.Show($"Highlight some text first, then press {hint}");
                return;
            }
            _store.EnsureSession();
            ShowNote(new NoteDraft
            {
                Quote = text,
                SourceApp = fg.App,
                WindowTitle = fg.Title,
                SessionTitle = _store.Session?.Title ?? "Review",
                Anchor = new System.Drawing.Rectangle(p.X, p.Y, 1, 1)
            }, fg);
        }
        finally { _busy = false; }
    }

    // ---------- note window ----------

    private void ShowNote(NoteDraft draft, ForegroundInfo previous)
    {
        var w = new NoteWindow(draft, _prefs.AutoListen, _prefs.AutoExtractText);
        w.ListeningChanged += on => _buddy.SetListening(on);
        w.Finished += (d, saved) =>
        {
            if (saved)
                _store.Add(d.Kind, d.Text, d.ImagePath, d.Quote, d.SourceApp, d.WindowTitle);
            else if (d.ImagePath != null)
                try { File.Delete(d.ImagePath); } catch { }
            _buddy.SetListening(false);
            _note = null;
            previous.Restore();
        };
        _note = w;
        w.Show();
    }

    // ---------- sessions ----------

    private void PromptNewSession()
    {
        if (_note != null || _busy) return;
        var dlg = new NewSessionDialog();
        if (dlg.ShowDialog() == true) _store.Start(dlg.SessionName);
    }

    private void RefreshBuddy()
    {
        _buddy.Update(_prefs.BuddyShape, _prefs.BuddySize, _prefs.BuddyShowCount, _store.Session?.Notes.Count ?? 0, false);
        if (!_busy) _buddy.SetVisible(_prefs.BuddyEnabled && _store.IsActive);
    }

    // ---------- export ----------

    private void Export(ExportFormat format)
    {
        if (_store.Session is not { } session) return;
        var dlg = new Microsoft.Win32.SaveFileDialog
        {
            Title = $"Export “{session.Title}”",
            FileName = $"{SessionStore.Slug(session.Title)}.{format.Extension()}",
            DefaultExt = format.Extension(),
            Filter = $"{format.Title()}|*.{format.Extension()}",
            InitialDirectory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads"),
            OverwritePrompt = true
        };
        if (dlg.ShowDialog() != true) return;
        try
        {
            Exporter.Export(format, _store, dlg.FileName, _prefs.PageSize);
            Process.Start("explorer.exe", $"/select,\"{dlg.FileName}\"");
        }
        catch (Exception ex)
        {
            MessageBox.Show("Export failed: " + ex.Message, "Remark", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    // ---------- menu ----------

    private void BuildMenu()
    {
        var menu = _tray.ContextMenuStrip!;
        menu.Items.Clear();

        var header = _store.Session is { } s
            ? $"{s.Title}  ·  {s.Notes.Count} note{(s.Notes.Count == 1 ? "" : "s")}"
            : "No active session";
        menu.Items.Add(new Forms.ToolStripMenuItem(header) { Enabled = false });
        menu.Items.Add(new Forms.ToolStripSeparator());

        Add(menu.Items, "Capture area && note", () => _ = BeginCaptureAsync(), HotkeyAction.Capture);
        Add(menu.Items, "Note on selected text", () => _ = BeginTextNoteAsync(), HotkeyAction.CaptureText);
        Add(menu.Items, "New review session…", PromptNewSession, HotkeyAction.NewSession);
        menu.Items.Add(new Forms.ToolStripSeparator());

        bool active = _store.IsActive;
        Add(menu.Items, "Open report", () => { _store.Save(); if (_store.ReportHtmlPath is { } p) Open(p); }, enabled: active);
        Add(menu.Items, "Open session folder", () => { if (_store.Folder is { } f) Open(f); }, enabled: active);
        Add(menu.Items, "Copy report as Markdown", () =>
        {
            try { Clipboard.SetText(_store.Markdown()); Toast.Show("Report copied as Markdown"); } catch { }
        }, enabled: active);

        var export = new Forms.ToolStripMenuItem("Export") { Enabled = active };
        foreach (var f in Enum.GetValues<ExportFormat>())
        {
            var fmt = f;
            Add(export.DropDownItems, f.Title() + "…", () => Export(fmt));
        }
        menu.Items.Add(export);

        var recent = new Forms.ToolStripMenuItem("Recent sessions");
        var recents = SessionStore.RecentSessions();
        if (recents.Count == 0) recent.DropDownItems.Add(new Forms.ToolStripMenuItem("None yet") { Enabled = false });
        foreach (var r in recents)
        {
            var folder = r.Folder;
            var item = Add(recent.DropDownItems, $"{r.Title}  ({r.Count})", () =>
            {
                if (!_store.Open(folder)) MessageBox.Show("Couldn't open that session.", "Remark");
            });
            item.Checked = string.Equals(folder, _store.Folder, StringComparison.OrdinalIgnoreCase);
        }
        menu.Items.Add(recent);
        Add(menu.Items, "End session", () => _store.End(), enabled: active);

        menu.Items.Add(new Forms.ToolStripSeparator());
        var buddy = Add(menu.Items, "Show cursor buddy", () => { _prefs.BuddyEnabled = !_prefs.BuddyEnabled; _prefs.Save(); }, HotkeyAction.ToggleBuddy);
        buddy.Checked = _prefs.BuddyEnabled;
        Add(menu.Items, "Settings…", ShowSettings);
        menu.Items.Add(new Forms.ToolStripSeparator());
        Add(menu.Items, "Quit Remark", () => Application.Current.Shutdown());
    }

    private Forms.ToolStripMenuItem Add(Forms.ToolStripItemCollection items, string text, Action click,
                                        HotkeyAction? shortcut = null, bool enabled = true)
    {
        var item = new Forms.ToolStripMenuItem(text) { Enabled = enabled };
        if (shortcut is { } a && _prefs.ShortcutFor(a) is { } s) item.ShortcutKeyDisplayString = s.Display;
        // Run after the menu closes so focus returns to the app being reviewed.
        item.Click += (_, _) => Application.Current.Dispatcher.BeginInvoke(async () =>
        {
            await Task.Delay(120);
            click();
        });
        items.Add(item);
        return item;
    }

    public void ShowSettings()
    {
        if (_settings != null) { _settings.Activate(); return; }
        _settings = new SettingsWindow(_prefs,
            onBeginRecording: () => { _recordingShortcut = true; _hotkeys.UnregisterAll(); },
            onEndRecording: () => { _recordingShortcut = false; RegisterHotkeys(); },
            unavailable: () => _unavailable);
        _settings.Closed += (_, _) => { _settings = null; RegisterHotkeys(); };
        _settings.Show();
        _settings.Activate();
    }

    private static void Open(string target)
    {
        try { Process.Start(new ProcessStartInfo(target) { UseShellExecute = true }); } catch { }
    }

    public void Dispose()
    {
        _tray.Visible = false;
        _tray.Dispose();
        _hotkeys.Dispose();
        _buddy.Close();
    }
}
