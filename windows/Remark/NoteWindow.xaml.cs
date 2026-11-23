using System;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace Remark;

/// What the note window was opened with.
internal sealed class NoteDraft
{
    public string? ImagePath { get; init; }
    public string Quote { get; set; } = "";
    public string? SourceApp { get; init; }
    public string? WindowTitle { get; init; }
    public string SessionTitle { get; init; } = "Review";
    /// Physical-pixel rectangle to sit beside (the selection, or a point for text notes).
    public System.Drawing.Rectangle Anchor { get; init; }

    public bool IsTextNote => ImagePath == null;
    public NoteKind Kind { get; set; } = NoteKind.Note;
    public string Text { get; set; } = "";
}

public partial class NoteWindow : Window
{
    private readonly NoteDraft _draft;
    private readonly bool _autoListen;
    private readonly bool _autoExtract;
    private readonly Dictation _dictation = new();
    private string _baseText = "";
    private bool _finished;
    private bool _extracting;

    /// true = saved, false = discarded.
    internal event Action<NoteDraft, bool>? Finished;
    internal event Action<bool>? ListeningChanged;

    internal NoteWindow(NoteDraft draft, bool autoListen, bool autoExtract)
    {
        InitializeComponent();
        _draft = draft;
        _autoListen = autoListen;
        _autoExtract = autoExtract;

        SessionTitle.Text = draft.SessionTitle;
        var ctx = string.Join(" — ", new[] { draft.SourceApp, draft.WindowTitle }.Where(s => !string.IsNullOrWhiteSpace(s)));
        ContextText.Text = ctx;
        ContextText.ToolTip = string.IsNullOrEmpty(ctx) ? null : ctx;

        if (draft.ImagePath != null)
        {
            var bmp = new BitmapImage();
            bmp.BeginInit();
            bmp.CacheOption = BitmapCacheOption.OnLoad; // don't keep the file locked
            bmp.UriSource = new Uri(draft.ImagePath);
            bmp.EndInit();
            Shot.Source = bmp;
            Hint.Text = "Ctrl+Enter save  ·  Ctrl+D talk  ·  Ctrl+E grab text  ·  Esc discard";
        }
        else
        {
            ImageFrame.Visibility = Visibility.Collapsed;
            OcrButton.Visibility = Visibility.Collapsed;
            HeaderIcon.Text = "";
            Hint.Text = "Ctrl+Enter save  ·  Ctrl+D talk  ·  Esc discard";
        }
        UpdateQuote();

        foreach (var kind in Enum.GetValues<NoteKind>())
        {
            var rb = new RadioButton
            {
                Content = kind.Label(),
                GroupName = "kind",
                Style = (Style)FindResource("SegmentRadio"),
                IsChecked = kind == draft.Kind,
                Tag = kind
            };
            rb.Checked += (_, _) => _draft.Kind = (NoteKind)rb.Tag;
            KindBar.Children.Add(rb);
        }

        Editor.TextChanged += (_, _) => Placeholder.Visibility = Editor.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        Header.MouseLeftButtonDown += (_, e) => { if (e.ButtonState == MouseButtonState.Pressed) DragMove(); };
        SaveButton.Click += (_, _) => Finish(true);
        DiscardButton.Click += (_, _) => Finish(false);
        TalkButton.Click += async (_, _) => await ToggleTalkAsync();
        OcrButton.Click += async (_, _) => await ExtractTextAsync();
        RemoveQuote.Click += (_, _) => { _draft.Quote = ""; UpdateQuote(); };
        PreviewKeyDown += OnKey;

        _dictation.TranscriptChanged += t => Dispatcher.BeginInvoke(() =>
        {
            Editor.Text = _baseText.Length == 0 ? t : _baseText + " " + t;
            Editor.CaretIndex = Editor.Text.Length;
        });
        _dictation.StateChanged += on => Dispatcher.BeginInvoke(() => SetListening(on));

        Loaded += OnLoaded;
        Deactivated += (_, _) => { /* stays open so you can click back into the app you're reviewing */ };
    }

    private async void OnLoaded(object sender, RoutedEventArgs e)
    {
        PositionNearAnchor();
        Opacity = 1;
        Activate();
        Editor.Focus();
        Keyboard.Focus(Editor);
        if (_autoListen) await ToggleTalkAsync();
        if (_autoExtract && !_draft.IsTextNote) await ExtractTextAsync();
    }

    /// Places the window beside the selection using physical pixels (works across mixed-DPI monitors).
    private void PositionNearAnchor()
    {
        var hwnd = new WindowInteropHelper(this).Handle;
        if (!Native.GetWindowRect(hwnd, out var r)) return;
        int w = r.Right - r.Left, h = r.Bottom - r.Top;
        var a = _draft.Anchor;
        var screen = System.Windows.Forms.Screen.FromRectangle(a);
        var work = screen.WorkingArea;
        double s = Native.ScaleAt(a.X, a.Y);
        int gap = (int)(4 * s);

        int x = a.Right + gap;
        if (x + w > work.Right) x = a.Left - gap - w;
        if (x < work.Left) x = work.Right - w - (int)(16 * s);
        int y = a.Top - (int)(14 * s);
        y = Math.Min(Math.Max(y, work.Top), work.Bottom - h);
        Native.SetWindowPos(hwnd, Native.HWND_TOPMOST, x, y, 0, 0, Native.SWP_NOSIZE);
    }

    private void OnKey(object sender, KeyEventArgs e)
    {
        bool ctrl = (Keyboard.Modifiers & ModifierKeys.Control) != 0;
        if (e.Key == Key.Escape) { Finish(false); e.Handled = true; }
        else if (ctrl && e.Key == Key.Enter) { Finish(true); e.Handled = true; }
        else if (ctrl && e.Key == Key.D) { _ = ToggleTalkAsync(); e.Handled = true; }
        else if (ctrl && e.Key == Key.E && !_draft.IsTextNote) { _ = ExtractTextAsync(); e.Handled = true; }
    }

    private void UpdateQuote()
    {
        bool has = !string.IsNullOrWhiteSpace(_draft.Quote);
        QuotePanel.Visibility = has ? Visibility.Visible : Visibility.Collapsed;
        QuoteText.Text = _draft.Quote;
        QuoteLabel.Text = _draft.IsTextNote ? "Selected text" : "Text in screenshot";
        RemoveQuote.Visibility = _draft.IsTextNote ? Visibility.Collapsed : Visibility.Visible;
    }

    private void ShowMessage(string? text)
    {
        Message.Text = text ?? "";
        Message.Visibility = string.IsNullOrEmpty(text) ? Visibility.Collapsed : Visibility.Visible;
    }

    private async Task ExtractTextAsync()
    {
        if (_extracting || _draft.ImagePath == null) return;
        _extracting = true;
        OcrLabel.Text = "Reading…";
        OcrButton.IsEnabled = false;
        ShowMessage(null);
        try
        {
            var text = (await OcrService.RecognizeAsync(_draft.ImagePath)).Trim();
            if (text.Length == 0) ShowMessage("No text found in this capture.");
            else { _draft.Quote = text; UpdateQuote(); }
        }
        catch (Exception ex)
        {
            ShowMessage(ex.Message);
        }
        finally
        {
            _extracting = false;
            OcrLabel.Text = "Text";
            OcrButton.IsEnabled = true;
        }
    }

    private async Task ToggleTalkAsync()
    {
        if (_finished) return;
        if (_dictation.IsRunning)
        {
            await _dictation.StopAsync();
            return;
        }
        ShowMessage(null);
        _baseText = Editor.Text.Trim();
        try
        {
            await _dictation.StartAsync();
        }
        catch (DictationException ex)
        {
            ShowMessage(ex.Message + (ex.OfferVoiceTyping ? " Starting Windows voice typing instead…" : ""));
            if (ex.OfferVoiceTyping) StartVoiceTyping();
        }
    }

    /// Fallback: Windows' own voice typing (Win+H) types straight into the note box.
    private void StartVoiceTyping()
    {
        Editor.Focus();
        Editor.CaretIndex = Editor.Text.Length;
        Dispatcher.BeginInvoke(async () =>
        {
            await Task.Delay(150);
            Native.SendChord(Native.VK_LWIN, 0x48 /* H */);
        });
    }

    private void SetListening(bool on)
    {
        TalkLabel.Text = on ? "Stop" : "Talk";
        TalkIcon.Text = on ? "" : "";
        var red = new SolidColorBrush(Color.FromRgb(0xEF, 0x44, 0x54));
        TalkIcon.Foreground = on ? red : (Brush)FindResource("AccentDeepBrush");
        Editor.BorderBrush = on ? red : (Brush)FindResource("LineBrush");
        Editor.BorderThickness = new Thickness(on ? 2 : 1);
        Placeholder.Text = on ? "Listening… just talk" : "Type a note, or hit Talk and speak";
        ListeningChanged?.Invoke(on);
    }

    private async void Finish(bool saved)
    {
        if (_finished) return;
        _finished = true;
        _draft.Text = Editor.Text;
        if (_dictation.IsRunning) await _dictation.StopAsync();
        _dictation.Dispose();
        Close();
        Finished?.Invoke(_draft, saved);
    }

    protected override void OnClosing(System.ComponentModel.CancelEventArgs e)
    {
        base.OnClosing(e);
        if (!_finished)
        {
            _finished = true;
            _draft.Text = Editor.Text;
            _dictation.Dispose();
            Finished?.Invoke(_draft, false);
        }
    }

    public void FocusNote()
    {
        Activate();
        Editor.Focus();
    }
}
