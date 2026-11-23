using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Linq;
using System.Threading.Tasks;
using WinForms = System.Windows.Forms;

namespace Remark;

internal sealed class CaptureResult : IDisposable
{
    public Rectangle Bounds { get; init; }   // physical pixels, virtual-screen coordinates
    public Bitmap Image { get; init; } = null!;
    public void Dispose() => Image.Dispose();
}

/// Freezes every display, lets the user drag a rectangle (click or Enter = whole display,
/// Esc = cancel) and returns the selected pixels. Because the screen is frozen first,
/// the overlay itself never ends up in the capture.
internal static class RegionSelector
{
    public static Task<CaptureResult?> SelectAsync()
    {
        var tcs = new TaskCompletionSource<CaptureResult?>();
        var forms = new List<OverlayForm>();

        void Finish(CaptureResult? result)
        {
            if (tcs.Task.IsCompleted) return;
            foreach (var f in forms) f.Close();
            tcs.TrySetResult(result);
        }

        foreach (var screen in WinForms.Screen.AllScreens)
        {
            var b = screen.Bounds;
            var frozen = new Bitmap(b.Width, b.Height, PixelFormat.Format32bppArgb);
            using (var g = Graphics.FromImage(frozen))
                g.CopyFromScreen(b.Location, Point.Empty, b.Size, CopyPixelOperation.SourceCopy);
            forms.Add(new OverlayForm(b, frozen, Finish));
        }

        foreach (var f in forms) f.Show();

        var cursor = WinForms.Cursor.Position;
        var active = forms.FirstOrDefault(f => f.ScreenBounds.Contains(cursor)) ?? forms[0];
        active.Activate();
        active.Focus();
        return tcs.Task;
    }

    private sealed class OverlayForm : WinForms.Form
    {
        public Rectangle ScreenBounds { get; }
        private readonly Bitmap _frozen;
        private readonly Action<CaptureResult?> _finish;
        private Point? _start;
        private Point? _current;

        private static readonly Color Accent = Color.FromArgb(0x8B, 0x5C, 0xF6);

        public OverlayForm(Rectangle bounds, Bitmap frozen, Action<CaptureResult?> finish)
        {
            ScreenBounds = bounds;
            _frozen = frozen;
            _finish = finish;

            FormBorderStyle = WinForms.FormBorderStyle.None;
            StartPosition = WinForms.FormStartPosition.Manual;
            AutoScaleMode = WinForms.AutoScaleMode.None;
            ShowInTaskbar = false;
            TopMost = true;
            KeyPreview = true;
            DoubleBuffered = true;
            Cursor = WinForms.Cursors.Cross;
            BackColor = Color.Black;
            Bounds = bounds;
        }

        protected override void OnShown(EventArgs e)
        {
            base.OnShown(e);
            Bounds = ScreenBounds; // re-apply in case DPI scaling nudged it
        }

        protected override void OnFormClosed(WinForms.FormClosedEventArgs e)
        {
            base.OnFormClosed(e);
            _frozen.Dispose();
        }

        private Rectangle? Selection
        {
            get
            {
                if (_start is not { } s || _current is not { } c) return null;
                return Rectangle.FromLTRB(Math.Min(s.X, c.X), Math.Min(s.Y, c.Y), Math.Max(s.X, c.X), Math.Max(s.Y, c.Y));
            }
        }

        protected override void OnMouseDown(WinForms.MouseEventArgs e)
        {
            if (e.Button != WinForms.MouseButtons.Left) { _finish(null); return; }
            _start = e.Location;
            _current = e.Location;
            Invalidate();
        }

        protected override void OnMouseMove(WinForms.MouseEventArgs e)
        {
            if (_start == null) return;
            _current = e.Location;
            Invalidate();
        }

        protected override void OnMouseUp(WinForms.MouseEventArgs e)
        {
            if (_start == null) return;
            _current = e.Location;
            var sel = Selection ?? ClientRectangle;
            if (sel.Width < 6 || sel.Height < 6) sel = ClientRectangle; // a click = whole display
            Complete(sel);
        }

        protected override void OnKeyDown(WinForms.KeyEventArgs e)
        {
            if (e.KeyCode == WinForms.Keys.Escape) _finish(null);
            else if (e.KeyCode == WinForms.Keys.Enter) Complete(ClientRectangle);
        }

        private void Complete(Rectangle sel)
        {
            sel.Intersect(new Rectangle(0, 0, _frozen.Width, _frozen.Height));
            if (sel.Width <= 0 || sel.Height <= 0) { _finish(null); return; }
            var crop = new Bitmap(sel.Width, sel.Height, PixelFormat.Format32bppArgb);
            using (var g = Graphics.FromImage(crop))
                g.DrawImage(_frozen, new Rectangle(0, 0, sel.Width, sel.Height), sel, GraphicsUnit.Pixel);
            var global = new Rectangle(sel.X + ScreenBounds.X, sel.Y + ScreenBounds.Y, sel.Width, sel.Height);
            _finish(new CaptureResult { Bounds = global, Image = crop });
        }

        protected override void OnPaintBackground(WinForms.PaintEventArgs e) { /* painted in OnPaint */ }

        protected override void OnPaint(WinForms.PaintEventArgs e)
        {
            var g = e.Graphics;
            g.DrawImageUnscaled(_frozen, 0, 0);

            using var dim = new SolidBrush(Color.FromArgb(90, 0, 0, 0));
            if (Selection is { Width: > 0, Height: > 0 } sel)
            {
                using (var region = new Region(ClientRectangle))
                {
                    region.Exclude(sel);
                    g.FillRegion(dim, region);
                }
                using (var pen = new Pen(Accent, 2f * DeviceDpi / 96f))
                    g.DrawRectangle(pen, sel);
                DrawPill(g, $"{sel.Width} × {sel.Height}", new Point(sel.Left, Math.Max(sel.Top - Px(30), Px(4))));
            }
            else
            {
                g.FillRectangle(dim, ClientRectangle);
                const string hint = "Drag to select  ·  Click or Enter for the whole screen  ·  Esc to cancel";
                var size = PillSize(g, hint);
                DrawPill(g, hint, new Point((ClientSize.Width - size.Width) / 2, Px(90)));
            }
        }

        private int Px(int v) => (int)(v * DeviceDpi / 96f);

        private Font PillFont => new("Segoe UI", 10f, FontStyle.Regular);

        private Size PillSize(Graphics g, string text)
        {
            using var f = PillFont;
            var s = g.MeasureString(text, f);
            return new Size((int)s.Width + Px(22), (int)s.Height + Px(10));
        }

        private void DrawPill(Graphics g, string text, Point at)
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            var size = PillSize(g, text);
            var rect = new Rectangle(at, size);
            int r = size.Height;
            using (var path = new GraphicsPath())
            {
                path.AddArc(rect.X, rect.Y, r, r, 90, 180);
                path.AddArc(rect.Right - r, rect.Y, r, r, 270, 180);
                path.CloseFigure();
                using var bg = new SolidBrush(Color.FromArgb(200, 20, 16, 30));
                g.FillPath(bg, path);
            }
            using var f = PillFont;
            using var fg = new SolidBrush(Color.White);
            g.DrawString(text, f, fg, rect.X + Px(11), rect.Y + Px(5));
        }
    }
}
