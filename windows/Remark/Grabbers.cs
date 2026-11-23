using System;
using System.Collections.Specialized;
using System.Diagnostics;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Media.Imaging;

namespace Remark;

/// Which app and window the user was in when they pressed a shortcut.
internal sealed record ForegroundInfo(IntPtr Hwnd, string? App, string? Title, bool IsSelf)
{
    public static ForegroundInfo Capture()
    {
        var hwnd = Native.GetForegroundWindow();
        if (hwnd == IntPtr.Zero) return new ForegroundInfo(hwnd, null, null, false);
        Native.GetWindowThreadProcessId(hwnd, out uint pid);
        bool self = pid == (uint)Environment.ProcessId;
        string? app = null;
        try
        {
            using var p = Process.GetProcessById((int)pid);
            try { app = p.MainModule?.FileVersionInfo.FileDescription; } catch { }
            if (string.IsNullOrWhiteSpace(app)) app = p.ProcessName;
        }
        catch { }
        var title = Native.GetWindowTitle(hwnd);
        return new ForegroundInfo(hwnd, self ? null : app?.Trim(),
                                  self || string.IsNullOrWhiteSpace(title) ? null : title.Trim(), self);
    }

    public void Restore()
    {
        if (!IsSelf && Hwnd != IntPtr.Zero && Native.IsWindow(Hwnd))
            Native.SetForegroundWindow(Hwnd);
    }
}

/// Reads the text the user has selected in the frontmost app.
/// UI Automation first, then a Ctrl+C round-trip that puts the clipboard back afterwards.
internal static class TextGrabber
{
    public static async Task<string?> GrabSelectedTextAsync()
    {
        var viaUia = await Task.Run(TryUiAutomation);
        if (!string.IsNullOrWhiteSpace(viaUia)) return viaUia;
        return await CopyRoundTripAsync();
    }

    private static string? TryUiAutomation()
    {
        try
        {
            var el = AutomationElement.FocusedElement;
            if (el == null) return null;
            if (el.TryGetCurrentPattern(TextPattern.Pattern, out object pattern) && pattern is TextPattern tp)
            {
                var parts = tp.GetSelection()
                    .Select(r => r.GetText(-1))
                    .Where(t => !string.IsNullOrWhiteSpace(t));
                var text = string.Join("\n", parts);
                return string.IsNullOrWhiteSpace(text) ? null : text;
            }
        }
        catch { }
        return null;
    }

    private static async Task<string?> CopyRoundTripAsync()
    {
        // The user is probably still holding Ctrl+Alt from the shortcut; Ctrl+C would arrive as Ctrl+Alt+C.
        for (int i = 0; i < 40 && Native.AnyModifierDown(); i++) await Task.Delay(25);

        var snapshot = ClipboardSnapshot.Take();
        uint before = Native.GetClipboardSequenceNumber();
        Native.SendChord(Native.VK_CONTROL, 0x43 /* C */);

        bool changed = false;
        for (int i = 0; i < 15; i++)
        {
            await Task.Delay(30);
            if (Native.GetClipboardSequenceNumber() != before) { changed = true; break; }
        }
        if (!changed) return null;
        await Task.Delay(40);

        string? text = Retry(() => Clipboard.ContainsText() ? Clipboard.GetText() : null);
        snapshot.Restore();
        return text;
    }

    private static T? Retry<T>(Func<T?> f)
    {
        for (int i = 0; i < 5; i++)
        {
            try { return f(); }
            catch { System.Threading.Thread.Sleep(30); }
        }
        return default;
    }

    private sealed class ClipboardSnapshot
    {
        private string? _text;
        private BitmapSource? _image;
        private StringCollection? _files;

        public static ClipboardSnapshot Take()
        {
            var s = new ClipboardSnapshot();
            s._text = Retry(() => Clipboard.ContainsText() ? Clipboard.GetText() : null);
            s._image = Retry(() => Clipboard.ContainsImage() ? Clipboard.GetImage() : null);
            s._files = Retry(() => Clipboard.ContainsFileDropList() ? Clipboard.GetFileDropList() : null);
            return s;
        }

        public void Restore()
        {
            Retry<object>(() =>
            {
                if (_text == null && _image == null && _files == null)
                {
                    Clipboard.Clear();
                    return null;
                }
                var data = new DataObject();
                if (_text != null) data.SetText(_text);
                if (_image != null) data.SetImage(_image);
                if (_files != null) data.SetFileDropList(_files);
                Clipboard.SetDataObject(data, true);
                return null;
            });
        }
    }
}
