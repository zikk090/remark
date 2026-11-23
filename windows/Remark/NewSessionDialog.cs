using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Effects;

namespace Remark;

/// "What are you reviewing?" prompt.
internal sealed class NewSessionDialog : Window
{
    private readonly TextBox _input;
    public string SessionName => _input.Text;

    public NewSessionDialog()
    {
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        ResizeMode = ResizeMode.NoResize;
        SizeToContent = SizeToContent.WidthAndHeight;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Topmost = true;
        ShowInTaskbar = false;
        Title = "New review session";
        FontFamily = (FontFamily)Application.Current.Resources["UiFont"];

        _input = new TextBox { FontSize = 14, Padding = new Thickness(8, 6, 8, 6), Width = 340, Margin = new Thickness(0, 14, 0, 16) };

        var start = new Button { Content = "Start session", Style = (Style)Application.Current.Resources["PrimaryButton"], IsDefault = true, Margin = new Thickness(8, 0, 0, 0) };
        var cancel = new Button { Content = "Cancel", Style = (Style)Application.Current.Resources["GhostButton"], IsCancel = true };
        start.Click += (_, _) => { DialogResult = true; };

        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        buttons.Children.Add(cancel);
        buttons.Children.Add(start);

        var body = new StackPanel { Margin = new Thickness(22, 18, 22, 18) };
        body.Children.Add(new TextBlock { Text = "New review session", FontSize = 17, FontWeight = FontWeights.Bold });
        body.Children.Add(new TextBlock
        {
            Text = "What are you reviewing? e.g. “Ada’s app — onboarding” or “Acme web app — auth flows”.",
            FontSize = 12.5, Foreground = (Brush)Application.Current.Resources["MutedBrush"], TextWrapping = TextWrapping.Wrap,
            MaxWidth = 340, Margin = new Thickness(0, 4, 0, 0)
        });
        body.Children.Add(_input);
        body.Children.Add(buttons);

        var card = new Border
        {
            Margin = new Thickness(16),
            CornerRadius = new CornerRadius(14),
            Background = Brushes.White,
            BorderBrush = (Brush)Application.Current.Resources["LineBrush"],
            BorderThickness = new Thickness(1),
            Effect = new DropShadowEffect { BlurRadius = 24, ShadowDepth = 4, Opacity = 0.25, Direction = 270 },
            Child = body
        };
        card.MouseLeftButtonDown += (_, e) => { if (e.ButtonState == MouseButtonState.Pressed && e.OriginalSource is not TextBox) DragMove(); };
        Content = card;

        Loaded += (_, _) => { Activate(); _input.Focus(); Keyboard.Focus(_input); };
    }
}
