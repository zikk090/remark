using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Effects;
using System.Windows.Media.Imaging;

namespace Remark;

/// Settings: sidebar + panes, built in code so every piece stays in one place.
internal sealed class SettingsWindow : Window
{
    private readonly Prefs _prefs;
    private readonly Action _onBeginRecording;
    private readonly Action _onEndRecording;
    private readonly Func<HashSet<HotkeyAction>> _unavailable;

    private readonly ContentControl _content = new();
    private readonly StackPanel _nav = new();
    private string _pane = "General";
    private HotkeyAction? _recording;
    private string? _recordMessage;

    private static readonly string[] Panes = { "General", "Shortcuts", "Cursor", "Export", "Privacy", "About" };
    private static readonly Dictionary<string, string> PaneIcons = new()
    {
        ["General"] = "", ["Shortcuts"] = "", ["Cursor"] = "",
        ["Export"] = "", ["Privacy"] = "", ["About"] = ""
    };

    public static string Version =>
        Assembly.GetExecutingAssembly().GetName().Version is { } v ? $"{v.Major}.{v.Minor}.{v.Build}" : "dev";

    public SettingsWindow(Prefs prefs, Action onBeginRecording, Action onEndRecording, Func<HashSet<HotkeyAction>> unavailable)
    {
        _prefs = prefs;
        _onBeginRecording = onBeginRecording;
        _onEndRecording = onEndRecording;
        _unavailable = unavailable;

        Title = "Remark Settings";
        Width = 780;
        Height = 540;
        ResizeMode = ResizeMode.CanMinimize;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Background = Res<Brush>("WindowBrush");
        FontFamily = Res<FontFamily>("UiFont");
        Icon = new BitmapImage(new Uri("pack://application:,,,/Assets/Remark-256.png"));

        var root = new Grid();
        root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(210) });
        root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        var sidebar = new Border
        {
            Background = Res<Brush>("SidebarBrush"),
            BorderBrush = Res<Brush>("LineBrush"),
            BorderThickness = new Thickness(0, 0, 1, 0),
            Padding = new Thickness(12, 18, 12, 12),
            Child = BuildSidebar()
        };
        root.Children.Add(sidebar);

        var scroll = new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Content = _content, Padding = new Thickness(30, 24, 30, 28) };
        Grid.SetColumn(scroll, 1);
        root.Children.Add(scroll);
        Content = root;

        PreviewKeyDown += OnPreviewKeyDown;
        Closed += (_, _) => StopRecording();
        ShowPane("General");
    }

    private static T Res<T>(string key) => (T)Application.Current.Resources[key];

    // ---------- sidebar ----------

    private UIElement BuildSidebar()
    {
        var panel = new StackPanel();
        var header = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(4, 0, 0, 20) };
        header.Children.Add(new Image
        {
            Source = new BitmapImage(new Uri("pack://application:,,,/Assets/Remark-256.png")),
            Width = 36, Height = 36, Margin = new Thickness(0, 0, 10, 0)
        });
        var names = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        names.Children.Add(new TextBlock { Text = "Remark", FontSize = 16, FontWeight = FontWeights.Bold });
        names.Children.Add(new TextBlock { Text = "v" + Version, FontSize = 11.5, Foreground = Res<Brush>("MutedBrush") });
        header.Children.Add(names);
        panel.Children.Add(header);
        panel.Children.Add(_nav);
        return panel;
    }

    private void RebuildNav()
    {
        _nav.Children.Clear();
        foreach (var name in Panes)
        {
            bool selected = name == _pane;
            var icon = new Border
            {
                Width = 26, Height = 26, CornerRadius = new CornerRadius(7),
                Background = selected ? Res<Brush>("AccentGradient") : Res<Brush>("AccentSoftBrush"),
                Child = new TextBlock
                {
                    Text = PaneIcons[name], FontFamily = Res<FontFamily>("IconFont"), FontSize = 13,
                    Foreground = selected ? Brushes.White : Res<Brush>("AccentDeepBrush"),
                    HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center
                }
            };
            var row = new StackPanel { Orientation = Orientation.Horizontal };
            row.Children.Add(icon);
            row.Children.Add(new TextBlock
            {
                Text = name, FontSize = 13.5, Margin = new Thickness(10, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center,
                FontWeight = selected ? FontWeights.SemiBold : FontWeights.Normal
            });
            var item = new Border
            {
                Child = row, Padding = new Thickness(8, 6, 8, 6), Margin = new Thickness(0, 0, 0, 3),
                CornerRadius = new CornerRadius(9), Cursor = Cursors.Hand,
                Background = selected ? Res<Brush>("AccentSoftBrush") : Brushes.Transparent
            };
            var captured = name;
            item.MouseLeftButtonUp += (_, _) => ShowPane(captured);
            _nav.Children.Add(item);
        }
    }

    private void ShowPane(string pane)
    {
        StopRecording();
        _pane = pane;
        RebuildNav();
        Refresh();
    }

    private void Refresh()
    {
        var page = new StackPanel();
        page.Children.Add(new TextBlock { Text = _pane, FontSize = 24, FontWeight = FontWeights.Bold, Margin = new Thickness(0, 0, 0, 16) });
        switch (_pane)
        {
            case "General": BuildGeneral(page); break;
            case "Shortcuts": BuildShortcuts(page); break;
            case "Cursor": BuildCursor(page); break;
            case "Export": BuildExport(page); break;
            case "Privacy": BuildPrivacy(page); break;
            default: BuildAbout(page); break;
        }
        _content.Content = page;
    }

    // ---------- building blocks ----------

    private static Border Card(params UIElement[] rows)
    {
        var stack = new StackPanel();
        for (int i = 0; i < rows.Length; i++)
        {
            if (i > 0) stack.Children.Add(new Border { Height = 1, Background = Res<Brush>("LineBrush"), Margin = new Thickness(16, 0, 0, 0) });
            stack.Children.Add(rows[i]);
        }
        return new Border
        {
            Background = Res<Brush>("CardBrush"), BorderBrush = Res<Brush>("LineBrush"), BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(12), Margin = new Thickness(0, 0, 0, 18), Child = stack
        };
    }

    private static Grid Row(string title, string? subtitle, UIElement trailing)
    {
        var g = new Grid { Margin = new Thickness(16, 12, 16, 12) };
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 16, 0) };
        text.Children.Add(new TextBlock { Text = title, FontSize = 13.5, FontWeight = FontWeights.Medium });
        if (subtitle != null)
            text.Children.Add(new TextBlock { Text = subtitle, FontSize = 12, Foreground = Res<Brush>("MutedBrush"), TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 2, 0, 0) });
        g.Children.Add(text);
        if (trailing is FrameworkElement fe) fe.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(trailing, 1);
        g.Children.Add(trailing);
        return g;
    }

    private static TextBlock SectionLabel(string text) => new()
    {
        Text = text.ToUpperInvariant(), FontSize = 11, FontWeight = FontWeights.SemiBold,
        Foreground = Res<Brush>("MutedBrush"), Margin = new Thickness(4, 0, 0, 8)
    };

    private static TextBlock Lead(string text) => new()
    {
        Text = text, FontSize = 13, Foreground = Res<Brush>("MutedBrush"), TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 16)
    };

    private static CheckBox Switch(bool value, Action<bool> onChange)
    {
        var cb = new CheckBox { IsChecked = value, Style = Res<Style>("Switch") };
        cb.Click += (_, _) => onChange(cb.IsChecked == true);
        return cb;
    }

    private static Button LinkButton(string text, Action click, bool primary = false)
    {
        var b = new Button { Content = text, Style = Res<Style>(primary ? "PrimaryButton" : "BaseButton"), Padding = new Thickness(12, 5, 12, 5) };
        b.Click += (_, _) => click();
        return b;
    }

    private static Border Segmented<T>(IEnumerable<T> values, T current, Func<T, string> label, Action<T> onPick) where T : notnull
    {
        var bar = new StackPanel { Orientation = Orientation.Horizontal };
        string group = Guid.NewGuid().ToString();
        foreach (var v in values)
        {
            var rb = new RadioButton { Content = label(v), GroupName = group, IsChecked = v.Equals(current), Style = Res<Style>("SegmentRadio"), MinWidth = 64 };
            var captured = v;
            rb.Checked += (_, _) => onPick(captured);
            bar.Children.Add(rb);
        }
        return new Border { Background = new SolidColorBrush(Color.FromRgb(0xEF, 0xED, 0xF4)), CornerRadius = new CornerRadius(8), Padding = new Thickness(2), Child = bar };
    }

    private static void Open(string target)
    {
        try { Process.Start(new ProcessStartInfo(target) { UseShellExecute = true }); } catch { }
    }

    // ---------- panes ----------

    private void BuildGeneral(StackPanel page)
    {
        page.Children.Add(SectionLabel("Notes"));
        page.Children.Add(Card(
            Row("Start talking when a note opens", "Dictation starts right away; type to add to it.",
                Switch(_prefs.AutoListen, v => { _prefs.AutoListen = v; _prefs.Save(); })),
            Row("Pull text out of every screenshot", "Runs Windows' on-device OCR and attaches the text to the note.",
                Switch(_prefs.AutoExtractText, v => { _prefs.AutoExtractText = v; _prefs.Save(); }))));

        page.Children.Add(SectionLabel("App"));
        page.Children.Add(Card(
            Row("Open Remark when you sign in", null,
                Switch(_prefs.LaunchAtLogin, v => { _prefs.LaunchAtLogin = v; })),
            Row("Sessions folder", SessionStore.RootFolder,
                LinkButton("Open folder", () => { Directory.CreateDirectory(SessionStore.RootFolder); Open(SessionStore.RootFolder); }))));
    }

    private void BuildShortcuts(StackPanel page)
    {
        page.Children.Add(Lead("Click a shortcut, then press the keys you want. Esc cancels, Backspace clears."));
        var unavailable = _unavailable();
        var rows = new List<UIElement>();
        foreach (var action in Enum.GetValues<HotkeyAction>())
        {
            var captured = action;
            var button = new Button { Style = Res<Style>("GhostButton"), Padding = new Thickness(2), Content = KeyCaps(action), ToolTip = "Click to record a new shortcut" };
            button.Click += (_, _) => ToggleRecording(captured);
            rows.Add(Row(action.Title(), unavailable.Contains(action) ? "⚠ Another app is using this combo. Pick a different one." : null, button));
        }
        page.Children.Add(Card(rows.ToArray()));

        if (_recordMessage != null)
            page.Children.Add(new TextBlock { Text = _recordMessage, Foreground = Res<Brush>("AccentDeepBrush"), FontSize = 13, Margin = new Thickness(2, 0, 0, 12) });

        var reset = LinkButton("Restore defaults", () => { StopRecording(); _prefs.ResetShortcuts(); Refresh(); });
        reset.HorizontalAlignment = HorizontalAlignment.Right;
        page.Children.Add(reset);
    }

    private UIElement KeyCaps(HotkeyAction action)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal };
        if (_recording == action)
        {
            row.Children.Add(new Border
            {
                BorderBrush = Res<Brush>("AccentBrush"), BorderThickness = new Thickness(1.5), CornerRadius = new CornerRadius(7),
                Padding = new Thickness(10, 4, 10, 4),
                Child = new TextBlock { Text = "Type shortcut…", Foreground = Res<Brush>("AccentDeepBrush"), FontSize = 12.5, FontWeight = FontWeights.Medium }
            });
            return row;
        }
        var s = _prefs.ShortcutFor(action);
        if (s == null)
        {
            row.Children.Add(new TextBlock { Text = "Not set", Foreground = Res<Brush>("MutedBrush"), FontSize = 12.5, Margin = new Thickness(8, 4, 8, 4) });
            return row;
        }
        foreach (var part in s.Parts)
        {
            row.Children.Add(new Border
            {
                Background = Brushes.White, BorderBrush = Res<Brush>("LineBrush"), BorderThickness = new Thickness(1, 1, 1, 2),
                CornerRadius = new CornerRadius(6), Padding = new Thickness(8, 3, 8, 3), Margin = new Thickness(0, 0, 4, 0),
                Child = new TextBlock { Text = part, FontSize = 12, FontWeight = FontWeights.SemiBold }
            });
        }
        return row;
    }

    private void ToggleRecording(HotkeyAction action)
    {
        if (_recording == action) { StopRecording(); Refresh(); return; }
        StopRecording();
        _recording = action;
        _recordMessage = "Press the new shortcut. Use Ctrl, Alt or Win (or an F-key).";
        _onBeginRecording(); // pause global hotkeys so the combo reaches this window
        Refresh();
    }

    private void StopRecording()
    {
        if (_recording == null) return;
        _recording = null;
        _recordMessage = null;
        _onEndRecording();
    }

    private void OnPreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (_recording is not { } action) return;
        e.Handled = true;
        var key = e.Key == Key.System ? e.SystemKey : e.Key;
        if (key is Key.LeftCtrl or Key.RightCtrl or Key.LeftAlt or Key.RightAlt or Key.LeftShift or Key.RightShift or Key.LWin or Key.RWin)
            return; // wait for the actual key

        var mods = Keyboard.Modifiers;
        if (mods == ModifierKeys.None && key == Key.Escape) { StopRecording(); Refresh(); return; }
        if (mods == ModifierKeys.None && (key == Key.Back || key == Key.Delete))
        {
            _prefs.SetShortcut(action, null);
            StopRecording();
            Refresh();
            return;
        }

        uint m = 0;
        if (mods.HasFlag(ModifierKeys.Control)) m |= Native.MOD_CONTROL;
        if (mods.HasFlag(ModifierKeys.Alt)) m |= Native.MOD_ALT;
        if (mods.HasFlag(ModifierKeys.Shift)) m |= Native.MOD_SHIFT;
        if (mods.HasFlag(ModifierKeys.Windows)) m |= Native.MOD_WIN;

        bool isFKey = key >= Key.F1 && key <= Key.F24;
        bool strong = (m & (Native.MOD_CONTROL | Native.MOD_ALT | Native.MOD_WIN)) != 0;
        if (!strong && !isFKey)
        {
            _recordMessage = "Include Ctrl, Alt or Win (or use an F-key).";
            Refresh();
            return;
        }

        var shortcut = new Shortcut(m, (uint)KeyInterop.VirtualKeyFromKey(key), KeyName(key));
        if (_prefs.Conflict(shortcut, action) is { } other)
        {
            _recordMessage = $"{shortcut.Display} is already used for “{other.Title()}”.";
            Refresh();
            return;
        }
        _prefs.SetShortcut(action, shortcut);
        StopRecording();
        Refresh();
    }

    private static string KeyName(Key key)
    {
        if (key >= Key.D0 && key <= Key.D9) return ((int)(key - Key.D0)).ToString();
        if (key >= Key.NumPad0 && key <= Key.NumPad9) return "Num" + (int)(key - Key.NumPad0);
        return key switch
        {
            Key.Space => "Space", Key.Enter => "Enter", Key.Tab => "Tab", Key.Back => "Backspace",
            Key.Left => "←", Key.Right => "→", Key.Up => "↑", Key.Down => "↓",
            Key.OemComma => ",", Key.OemPeriod => ".", Key.OemMinus => "-", Key.OemPlus => "=",
            Key.Oem1 => ";", Key.Oem2 => "/", Key.Oem3 => "`", Key.Oem4 => "[", Key.Oem5 => "\\", Key.Oem6 => "]", Key.Oem7 => "'",
            Key.PrintScreen => "PrtSc", Key.Insert => "Ins", Key.Home => "Home", Key.End => "End",
            Key.PageUp => "PgUp", Key.PageDown => "PgDn",
            _ => key.ToString()
        };
    }

    private void BuildCursor(StackPanel page)
    {
        page.Children.Add(Lead("During a review session, a small purple marker sits beside your cursor and shows how many notes you've taken. It turns red while you're talking."));
        page.Children.Add(Card(Row("Show cursor buddy during a session", "Toggle it any time with your shortcut.",
            Switch(_prefs.BuddyEnabled, v => { _prefs.BuddyEnabled = v; _prefs.Save(); Refresh(); }))));

        page.Children.Add(SectionLabel("Shape"));
        var tiles = new UniformGrid { Rows = 1, Margin = new Thickness(0, 0, 0, 18), IsEnabled = _prefs.BuddyEnabled, Opacity = _prefs.BuddyEnabled ? 1 : 0.45 };
        foreach (var shape in Enum.GetValues<BuddyShape>())
            tiles.Children.Add(ShapeTile(shape));
        page.Children.Add(tiles);

        var card = Card(
            Row("Show note count", null, Switch(_prefs.BuddyShowCount, v => { _prefs.BuddyShowCount = v; _prefs.Save(); Refresh(); })),
            Row("Size", null, Segmented(Enum.GetValues<BuddySize>(), _prefs.BuddySize, s => s.ToString(),
                s => { _prefs.BuddySize = s; _prefs.Save(); Refresh(); })));
        card.IsEnabled = _prefs.BuddyEnabled;
        page.Children.Add(card);
    }

    private UIElement ShapeTile(BuddyShape shape)
    {
        bool selected = _prefs.BuddyShape == shape;
        var preview = new Grid { Width = 110, Height = 60 };
        var cursor = new TextBlock
        {
            Text = "", FontFamily = Res<FontFamily>("IconFont"), FontSize = 18,
            HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(18, 14, 0, 0)
        };
        var visualHost = new ContentControl
        {
            Content = BuddyVisual.Build(shape, _prefs.BuddySize.Scale() * 0.95, false, 7, _prefs.BuddyShowCount),
            HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(40, 8, 0, 0)
        };
        preview.Children.Add(cursor);
        preview.Children.Add(visualHost);

        var stack = new StackPanel();
        stack.Children.Add(preview);
        stack.Children.Add(new TextBlock
        {
            Text = shape.ToString(), HorizontalAlignment = HorizontalAlignment.Center, FontSize = 13,
            FontWeight = selected ? FontWeights.SemiBold : FontWeights.Normal, Margin = new Thickness(0, 6, 0, 0)
        });

        var tile = new Border
        {
            Child = stack, Margin = new Thickness(0, 0, 10, 0), Padding = new Thickness(8, 10, 8, 12), Cursor = Cursors.Hand,
            CornerRadius = new CornerRadius(12), Background = Res<Brush>("CardBrush"),
            BorderBrush = selected ? Res<Brush>("AccentBrush") : Res<Brush>("LineBrush"),
            BorderThickness = new Thickness(selected ? 2 : 1),
            ToolTip = "Hover to preview the talking state"
        };
        tile.MouseEnter += (_, _) => visualHost.Content = BuddyVisual.Build(shape, _prefs.BuddySize.Scale() * 0.95, true, 7, _prefs.BuddyShowCount);
        tile.MouseLeave += (_, _) => visualHost.Content = BuddyVisual.Build(shape, _prefs.BuddySize.Scale() * 0.95, false, 7, _prefs.BuddyShowCount);
        tile.MouseLeftButtonUp += (_, _) => { _prefs.BuddyShape = shape; _prefs.Save(); Refresh(); };
        return tile;
    }

    private void BuildExport(StackPanel page)
    {
        page.Children.Add(Lead("Export any session from the tray icon → Export."));
        page.Children.Add(SectionLabel("PDF"));
        page.Children.Add(Card(Row("Page size", null, Segmented(Enum.GetValues<PdfPageSize>(), _prefs.PageSize,
            p => p == PdfPageSize.A4 ? "A4" : "US Letter", p => { _prefs.PageSize = p; _prefs.Save(); }))));

        page.Children.Add(SectionLabel("Formats"));
        var rows = Enum.GetValues<ExportFormat>().Select(f => (UIElement)Row(f.Title(), f.Summary(), new Border
        {
            Background = Res<Brush>("AccentSoftBrush"), CornerRadius = new CornerRadius(10), Padding = new Thickness(8, 2, 8, 3),
            Child = new TextBlock { Text = "." + f.Extension(), FontFamily = new FontFamily("Consolas"), FontSize = 11.5, FontWeight = FontWeights.SemiBold, Foreground = Res<Brush>("AccentDeepBrush") }
        })).ToArray();
        page.Children.Add(Card(rows));
    }

    private void BuildPrivacy(StackPanel page)
    {
        page.Children.Add(Lead("Remark only uses these when you press a shortcut. Screenshots, notes and transcripts stay on this PC."));
        page.Children.Add(Card(
            Row("Microphone", "Needed for Talk. Turn on “Let desktop apps access your microphone”.",
                LinkButton("Open settings", () => Open("ms-settings:privacy-microphone"))),
            Row("Speech", "Talk uses Windows speech recognition. If it won't start, turn on Online speech recognition — or Remark falls back to Windows voice typing (Win+H).",
                LinkButton("Open settings", () => Open("ms-settings:privacy-speech"))),
            Row("Text recognition (OCR)", "Pulling text from screenshots uses your installed Windows display languages.",
                LinkButton("Languages", () => Open("ms-settings:regionlanguage")))));
    }

    private void BuildAbout(StackPanel page)
    {
        var top = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(18) };
        top.Children.Add(new Image { Source = new BitmapImage(new Uri("pack://application:,,,/Assets/Remark-256.png")), Width = 72, Height = 72, Margin = new Thickness(0, 0, 16, 0) });
        var info = new StackPanel { VerticalAlignment = VerticalAlignment.Center, MaxWidth = 380 };
        info.Children.Add(new TextBlock { Text = "Remark", FontSize = 20, FontWeight = FontWeights.Bold });
        info.Children.Add(new TextBlock { Text = "Version " + Version, Foreground = Res<Brush>("MutedBrush") });
        info.Children.Add(new TextBlock
        {
            Text = "Select anything on your screen, talk or type a note, and send a clean report. No shared docs or edit access needed.",
            TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 6, 0, 0), FontSize = 13
        });
        top.Children.Add(info);
        page.Children.Add(new Border
        {
            Background = Res<Brush>("CardBrush"), BorderBrush = Res<Brush>("LineBrush"), BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(12), Margin = new Thickness(0, 0, 0, 16), Child = top
        });

        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 14) };
        var gh = LinkButton("GitHub", () => Open("https://github.com/zikk090/remark"), primary: true);
        gh.Margin = new Thickness(0, 0, 8, 0);
        buttons.Children.Add(gh);
        buttons.Children.Add(LinkButton("Report an issue", () => Open("https://github.com/zikk090/remark/issues")));
        page.Children.Add(buttons);
        page.Children.Add(new TextBlock { Text = "Made by Ezinne Kalu.", FontSize = 12, Foreground = Res<Brush>("MutedBrush") });
    }
}
