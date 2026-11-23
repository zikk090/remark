using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Effects;
using System.Windows.Shapes;
using System.Windows.Threading;

namespace Remark;

/// Builds the bubble / dot / diamond visuals (used by the live buddy and the Settings previews).
internal static class BuddyVisual
{
    private static readonly Color Light = Color.FromRgb(0xB3, 0x94, 0xFF);
    private static readonly Color Deep = Color.FromRgb(0x6D, 0x28, 0xD9);
    private static readonly Color RedLight = Color.FromRgb(0xFF, 0x73, 0x80);
    private static readonly Color RedDeep = Color.FromRgb(0xEF, 0x44, 0x54);

    public static FrameworkElement Build(BuddyShape shape, double scale, bool listening, int count, bool showCount)
    {
        var top = listening ? RedLight : Light;
        var bottom = listening ? RedDeep : Deep;
        var fill = new LinearGradientBrush(top, bottom, new Point(0, 0), new Point(1, 1));
        var shadow = new DropShadowEffect { Color = bottom, BlurRadius = 8 * scale, ShadowDepth = 1, Opacity = 0.55, Direction = 270 };

        if (shape == BuddyShape.Bubble)
        {
            if (!showCount && !listening) return Dot(fill, shadow, scale);
            return new Border
            {
                Background = fill,
                BorderBrush = Brushes.White,
                BorderThickness = new Thickness(2 * scale),
                CornerRadius = new CornerRadius(12 * scale),
                MinWidth = 24 * scale,
                Height = 24 * scale,
                Padding = new Thickness(5 * scale, 0, 5 * scale, 0),
                Effect = shadow,
                Child = Label(scale, listening, count),
                HorizontalAlignment = HorizontalAlignment.Left,
                VerticalAlignment = VerticalAlignment.Top
            };
        }

        var row = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top };
        row.Children.Add(shape == BuddyShape.Diamond ? Diamond(fill, shadow, scale) : Dot(fill, shadow, scale));
        if (showCount || listening)
        {
            var pill = new Border
            {
                Background = new LinearGradientBrush(top, bottom, 90),
                BorderBrush = new SolidColorBrush(Color.FromArgb(230, 255, 255, 255)),
                BorderThickness = new Thickness(1.2 * scale),
                CornerRadius = new CornerRadius(9 * scale),
                MinWidth = 20 * scale,
                Height = 18 * scale,
                Padding = new Thickness(6 * scale, 0, 6 * scale, 0),
                Margin = new Thickness(4 * scale, 6 * scale, 0, 0),
                Effect = new DropShadowEffect { Color = bottom, BlurRadius = 6 * scale, ShadowDepth = 1, Opacity = 0.45, Direction = 270 },
                Child = Label(scale * 0.9, listening, count),
                VerticalAlignment = VerticalAlignment.Top
            };
            row.Children.Add(pill);
        }
        return row;
    }

    private static FrameworkElement Label(double scale, bool listening, int count) => new TextBlock
    {
        Text = listening ? "" : count.ToString(),
        FontFamily = listening ? (FontFamily)Application.Current.Resources["IconFont"] : new FontFamily("Segoe UI"),
        FontSize = (listening ? 10 : 12) * scale,
        FontWeight = FontWeights.Bold,
        Foreground = Brushes.White,
        HorizontalAlignment = HorizontalAlignment.Center,
        VerticalAlignment = VerticalAlignment.Center
    };

    private static FrameworkElement Dot(Brush fill, Effect shadow, double scale) => new Ellipse
    {
        Width = 13 * scale,
        Height = 13 * scale,
        Fill = fill,
        Stroke = Brushes.White,
        StrokeThickness = 2 * scale,
        Effect = shadow,
        VerticalAlignment = VerticalAlignment.Top
    };

    private static FrameworkElement Diamond(Brush fill, Effect shadow, double scale)
    {
        var rect = new Rectangle
        {
            Width = 11 * scale,
            Height = 11 * scale,
            RadiusX = 2.5 * scale,
            RadiusY = 2.5 * scale,
            Fill = fill,
            Stroke = Brushes.White,
            StrokeThickness = 2 * scale,
            Effect = shadow,
            RenderTransformOrigin = new Point(0.5, 0.5),
            RenderTransform = new RotateTransform(45)
        };
        return new Grid { Width = 16 * scale, Height = 16 * scale, Children = { rect }, VerticalAlignment = VerticalAlignment.Top };
    }
}

/// Click-through, never-focused window that trails the cursor during a review session.
internal sealed class BuddyWindow : Window
{
    private readonly DispatcherTimer _timer;
    private IntPtr _hwnd;
    private double _x = double.NaN, _y = double.NaN;

    private BuddyShape _shape = BuddyShape.Bubble;
    private double _scale = 1;
    private bool _listening;
    private int _count;
    private bool _showCount = true;

    // Offset of the buddy from the cursor hotspot, in DIPs (right of the arrow, level with its top half).
    private const double OffsetX = 22, OffsetY = -6, Pad = 8;

    public BuddyWindow()
    {
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        Topmost = true;
        ShowInTaskbar = false;
        ShowActivated = false;
        Focusable = false;
        IsHitTestVisible = false;
        ResizeMode = ResizeMode.NoResize;
        Width = 160;
        Height = 80;
        Left = -10000;
        Top = -10000;

        _timer = new DispatcherTimer(DispatcherPriority.Render) { Interval = TimeSpan.FromMilliseconds(15) };
        _timer.Tick += (_, _) => Follow();
        Rebuild();
    }

    protected override void OnSourceInitialized(EventArgs e)
    {
        base.OnSourceInitialized(e);
        _hwnd = new WindowInteropHelper(this).Handle;
        Native.AddExStyle(_hwnd, Native.WS_EX_TRANSPARENT | Native.WS_EX_LAYERED | Native.WS_EX_TOOLWINDOW | Native.WS_EX_NOACTIVATE);
    }

    public void Update(BuddyShape shape, BuddySize size, bool showCount, int count, bool listening)
    {
        bool changed = shape != _shape || size.Scale() != _scale || showCount != _showCount || count != _count || listening != _listening;
        _shape = shape; _scale = size.Scale(); _showCount = showCount; _count = count; _listening = listening;
        if (changed) Rebuild();
    }

    public void SetListening(bool on)
    {
        if (on == _listening) return;
        _listening = on;
        Rebuild();
    }

    private void Rebuild()
    {
        var visual = BuddyVisual.Build(_shape, _scale, _listening, _count, _showCount);
        visual.Margin = new Thickness(Pad);
        Content = new Grid { Children = { visual }, IsHitTestVisible = false };
    }

    public void SetVisible(bool visible)
    {
        if (visible)
        {
            if (!IsVisible) Show();
            _x = double.NaN; // snap on (re)appear
            Follow();
            _timer.Start();
        }
        else
        {
            _timer.Stop();
            if (IsVisible) Hide();
        }
    }

    private void Follow()
    {
        if (_hwnd == IntPtr.Zero || !Native.GetCursorPos(out var p)) return;
        double s = Native.ScaleAt(p.X, p.Y);
        double tx = p.X + (OffsetX - Pad) * s;
        double ty = p.Y + (OffsetY - Pad) * s;

        if (double.IsNaN(_x) || Math.Abs(tx - _x) > 600 || Math.Abs(ty - _y) > 600)
        {
            _x = tx; _y = ty;
        }
        else
        {
            double dx = tx - _x, dy = ty - _y;
            if (Math.Abs(dx) < 0.3 && Math.Abs(dy) < 0.3) return;
            _x += dx * 0.32; // ease toward the cursor so it trails slightly
            _y += dy * 0.32;
        }
        Native.SetWindowPos(_hwnd, Native.HWND_TOPMOST, (int)Math.Round(_x), (int)Math.Round(_y), 0, 0,
            Native.SWP_NOSIZE | Native.SWP_NOACTIVATE);
    }
}

/// Small message that appears by the cursor and fades.
internal static class Toast
{
    private static Window? _current;

    public static void Show(string message)
    {
        _current?.Close();
        var w = new Window
        {
            WindowStyle = WindowStyle.None,
            AllowsTransparency = true,
            Background = Brushes.Transparent,
            Topmost = true,
            ShowInTaskbar = false,
            ShowActivated = false,
            SizeToContent = SizeToContent.WidthAndHeight,
            Left = -10000,
            Top = -10000,
            Content = new Border
            {
                Margin = new Thickness(8),
                Background = new SolidColorBrush(Color.FromArgb(225, 24, 20, 34)),
                CornerRadius = new CornerRadius(14),
                Padding = new Thickness(14, 8, 14, 8),
                Effect = new DropShadowEffect { BlurRadius = 10, ShadowDepth = 2, Opacity = 0.3 },
                Child = new TextBlock { Text = message, Foreground = Brushes.White, FontSize = 12.5, FontWeight = FontWeights.Medium }
            }
        };
        w.SourceInitialized += (_, _) =>
        {
            var h = new WindowInteropHelper(w).Handle;
            Native.AddExStyle(h, Native.WS_EX_TRANSPARENT | Native.WS_EX_TOOLWINDOW | Native.WS_EX_NOACTIVATE);
        };
        w.ContentRendered += (_, _) =>
        {
            var h = new WindowInteropHelper(w).Handle;
            if (Native.GetCursorPos(out var p))
            {
                double s = Native.ScaleAt(p.X, p.Y);
                Native.SetWindowPos(h, Native.HWND_TOPMOST, p.X + (int)(14 * s), p.Y + (int)(20 * s), 0, 0,
                    Native.SWP_NOSIZE | Native.SWP_NOACTIVATE);
            }
        };
        _current = w;
        w.Show();
        var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(2.2) };
        timer.Tick += (_, _) =>
        {
            timer.Stop();
            w.Close();
            if (_current == w) _current = null;
        };
        timer.Start();
    }
}
