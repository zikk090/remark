using System;
using System.Collections.Generic;
using System.Windows.Interop;
using System.Windows.Threading;

namespace Remark;

/// Global hotkeys via RegisterHotKey on a hidden message-only window.
internal sealed class HotKeyManager : IDisposable
{
    private readonly HwndSource _source;
    private readonly Dictionary<int, Action> _handlers = new();
    private int _nextId = 1;

    public HotKeyManager()
    {
        var p = new HwndSourceParameters("RemarkHotkeys")
        {
            ParentWindow = new IntPtr(-3), // HWND_MESSAGE
            Width = 0,
            Height = 0,
            WindowStyle = 0
        };
        _source = new HwndSource(p);
        _source.AddHook(Hook);
    }

    /// Returns false when Windows refuses the combo (usually because another app owns it).
    public bool Register(Shortcut s, Action action)
    {
        int id = _nextId++;
        if (!Native.RegisterHotKey(_source.Handle, id, s.Modifiers | Native.MOD_NOREPEAT, s.Key))
            return false;
        _handlers[id] = action;
        return true;
    }

    public void UnregisterAll()
    {
        foreach (var id in _handlers.Keys)
            Native.UnregisterHotKey(_source.Handle, id);
        _handlers.Clear();
    }

    private IntPtr Hook(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg == Native.WM_HOTKEY && _handlers.TryGetValue(wParam.ToInt32(), out var action))
        {
            handled = true;
            // Run after the message returns so dialogs opened by the action don't nest inside the hook.
            Dispatcher.CurrentDispatcher.BeginInvoke(action, DispatcherPriority.Normal);
        }
        return IntPtr.Zero;
    }

    public void Dispose()
    {
        UnregisterAll();
        _source.RemoveHook(Hook);
        _source.Dispose();
    }
}
