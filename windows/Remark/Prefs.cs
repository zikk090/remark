using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.Win32;

namespace Remark;

public enum HotkeyAction { Capture, CaptureText, NewSession, ToggleBuddy }
public enum BuddyShape { Bubble, Dot, Diamond }
public enum BuddySize { Small, Medium, Large }
public enum PdfPageSize { A4, Letter }

public static class EnumText
{
    public static string Title(this HotkeyAction a) => a switch
    {
        HotkeyAction.Capture => "Capture area & note",
        HotkeyAction.CaptureText => "Note on selected text",
        HotkeyAction.NewSession => "New review session",
        HotkeyAction.ToggleBuddy => "Show / hide cursor buddy",
        _ => a.ToString()
    };

    public static double Scale(this BuddySize s) => s switch
    {
        BuddySize.Small => 0.85,
        BuddySize.Large => 1.25,
        _ => 1.0
    };
}

/// A global shortcut: Win32 MOD_* flags + virtual-key code.
public sealed record Shortcut(uint Modifiers, uint Key, string KeyName)
{
    [JsonIgnore]
    public string Display => string.Join("+", Parts);

    [JsonIgnore]
    public IEnumerable<string> Parts
    {
        get
        {
            if ((Modifiers & Native.MOD_CONTROL) != 0) yield return "Ctrl";
            if ((Modifiers & Native.MOD_ALT) != 0) yield return "Alt";
            if ((Modifiers & Native.MOD_SHIFT) != 0) yield return "Shift";
            if ((Modifiers & Native.MOD_WIN) != 0) yield return "Win";
            yield return KeyName;
        }
    }

    public static Shortcut CtrlAlt(char letter) =>
        new(Native.MOD_CONTROL | Native.MOD_ALT, letter, letter.ToString());

    public static Shortcut Default(HotkeyAction a) => a switch
    {
        HotkeyAction.Capture => CtrlAlt('R'),
        HotkeyAction.CaptureText => CtrlAlt('T'),
        HotkeyAction.NewSession => CtrlAlt('N'),
        _ => CtrlAlt('B')
    };
}

/// User settings, stored as JSON in %APPDATA%\Remark\settings.json.
public sealed class Prefs
{
    private static readonly string Dir =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Remark");
    private static string FilePath => Path.Combine(Dir, "settings.json");

    public bool BuddyEnabled { get; set; } = true;
    public BuddyShape BuddyShape { get; set; } = BuddyShape.Bubble;
    public BuddySize BuddySize { get; set; } = BuddySize.Medium;
    public bool BuddyShowCount { get; set; } = true;
    public bool AutoListen { get; set; }
    public bool AutoExtractText { get; set; }
    public PdfPageSize PageSize { get; set; } = PdfPageSize.A4;
    public string? LastSessionFolder { get; set; }
    public bool Welcomed { get; set; }

    /// Missing key = default shortcut; null value = disabled.
    public Dictionary<HotkeyAction, Shortcut?> Shortcuts { get; set; } = new();

    [JsonIgnore] public Action? Changed { get; set; }

    public Shortcut? ShortcutFor(HotkeyAction a) =>
        Shortcuts.TryGetValue(a, out var s) ? s : Shortcut.Default(a);

    public void SetShortcut(HotkeyAction a, Shortcut? s)
    {
        Shortcuts[a] = s;
        Save();
    }

    public void ResetShortcuts()
    {
        Shortcuts.Clear();
        Save();
    }

    public HotkeyAction? Conflict(Shortcut s, HotkeyAction except)
    {
        foreach (var a in Enum.GetValues<HotkeyAction>())
        {
            if (a == except) continue;
            var other = ShortcutFor(a);
            if (other != null && other.Key == s.Key && other.Modifiers == s.Modifiers) return a;
        }
        return null;
    }

    public void Save()
    {
        try
        {
            Directory.CreateDirectory(Dir);
            File.WriteAllText(FilePath, JsonSerializer.Serialize(this, Json.Options));
        }
        catch { }
        Changed?.Invoke();
    }

    public static Prefs Load()
    {
        try
        {
            if (File.Exists(FilePath))
                return JsonSerializer.Deserialize<Prefs>(File.ReadAllText(FilePath), Json.Options) ?? new Prefs();
        }
        catch { }
        return new Prefs();
    }

    // ---- Launch at login (HKCU Run key) ----
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";

    [JsonIgnore]
    public bool LaunchAtLogin
    {
        get
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey);
            return key?.GetValue("Remark") != null;
        }
        set
        {
            using var key = Registry.CurrentUser.CreateSubKey(RunKey);
            if (value && Environment.ProcessPath is { } exe)
                key.SetValue("Remark", $"\"{exe}\"");
            else
                key.DeleteValue("Remark", throwOnMissingValue: false);
        }
    }
}
