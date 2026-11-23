using System;
using System.Linq;
using System.Threading.Tasks;
using Windows.Graphics.Imaging;
using Windows.Media.Ocr;
using Windows.Media.SpeechRecognition;
using Windows.Storage;
using Windows.Storage.Streams;

namespace Remark;

/// On-device text recognition (Windows.Media.Ocr).
internal static class OcrService
{
    public static async Task<string> RecognizeAsync(string path)
    {
        var engine = OcrEngine.TryCreateFromUserProfileLanguages()
                     ?? OcrEngine.TryCreateFromLanguage(new Windows.Globalization.Language("en-US"));
        if (engine == null)
            throw new InvalidOperationException("No OCR language is installed. Add one in Settings → Time & language → Language & region.");

        var file = await StorageFile.GetFileFromPathAsync(path);
        using IRandomAccessStream stream = await file.OpenAsync(FileAccessMode.Read);
        var decoder = await BitmapDecoder.CreateAsync(stream);

        uint max = OcrEngine.MaxImageDimension;
        SoftwareBitmap bitmap;
        if (decoder.PixelWidth > max || decoder.PixelHeight > max)
        {
            double scale = Math.Min((double)max / decoder.PixelWidth, (double)max / decoder.PixelHeight);
            var transform = new BitmapTransform
            {
                ScaledWidth = (uint)(decoder.PixelWidth * scale),
                ScaledHeight = (uint)(decoder.PixelHeight * scale),
                InterpolationMode = BitmapInterpolationMode.Fant
            };
            bitmap = await decoder.GetSoftwareBitmapAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied,
                transform, ExifOrientationMode.IgnoreExifOrientation, ColorManagementMode.DoNotColorManage);
        }
        else
        {
            bitmap = await decoder.GetSoftwareBitmapAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied);
        }

        using (bitmap)
        {
            var result = await engine.RecognizeAsync(bitmap);
            return string.Join("\n", result.Lines.Select(l => l.Text));
        }
    }
}

internal sealed class DictationException : Exception
{
    public bool OfferVoiceTyping { get; }
    public DictationException(string message, bool offerVoiceTyping) : base(message) { OfferVoiceTyping = offerVoiceTyping; }
}

/// Push-to-talk dictation (Windows.Media.SpeechRecognition, continuous dictation).
internal sealed class Dictation : IDisposable
{
    private SpeechRecognizer? _recognizer;
    private string _final = "";
    private string _hypothesis = "";

    public bool IsRunning { get; private set; }

    /// Raised (on a background thread) with everything heard so far this session.
    public event Action<string>? TranscriptChanged;
    /// Raised (on a background thread) when listening starts/stops.
    public event Action<bool>? StateChanged;

    private const int SpeechPrivacyNotAccepted = unchecked((int)0x80045509);

    public async Task StartAsync()
    {
        if (IsRunning) return;
        _final = "";
        _hypothesis = "";
        try
        {
            _recognizer = new SpeechRecognizer();
            _recognizer.Constraints.Add(new SpeechRecognitionTopicConstraint(SpeechRecognitionScenario.Dictation, "dictation"));
            var compiled = await _recognizer.CompileConstraintsAsync();
            if (compiled.Status != SpeechRecognitionResultStatus.Success)
                throw new DictationException($"Speech recognition isn't available ({compiled.Status}).", true);

            _recognizer.HypothesisGenerated += (_, e) =>
            {
                _hypothesis = e.Hypothesis.Text;
                Raise();
            };
            _recognizer.ContinuousRecognitionSession.ResultGenerated += (_, e) =>
            {
                if (!string.IsNullOrWhiteSpace(e.Result.Text))
                    _final = (_final + " " + e.Result.Text).Trim();
                _hypothesis = "";
                Raise();
            };
            _recognizer.ContinuousRecognitionSession.Completed += (_, _) => Cleanup();
            _recognizer.ContinuousRecognitionSession.AutoStopSilenceTimeout = TimeSpan.FromSeconds(20);

            await _recognizer.ContinuousRecognitionSession.StartAsync();
            IsRunning = true;
            StateChanged?.Invoke(true);
        }
        catch (DictationException)
        {
            Cleanup();
            throw;
        }
        catch (Exception ex) when (ex.HResult == SpeechPrivacyNotAccepted)
        {
            Cleanup();
            throw new DictationException(
                "Turn on Online speech recognition in Windows Settings → Privacy & security → Speech, or use Windows voice typing.", true);
        }
        catch (Exception ex)
        {
            Cleanup();
            throw new DictationException(
                $"Couldn't start dictation: {ex.Message}. Check microphone access in Settings → Privacy & security → Microphone (\"Let desktop apps access your microphone\").", true);
        }
    }

    public async Task StopAsync()
    {
        if (_recognizer == null) return;
        try { await _recognizer.ContinuousRecognitionSession.StopAsync(); } catch { }
        Cleanup();
    }

    private void Raise()
    {
        var text = string.IsNullOrEmpty(_hypothesis) ? _final : (_final + " " + _hypothesis).Trim();
        TranscriptChanged?.Invoke(text);
    }

    private void Cleanup()
    {
        bool wasRunning = IsRunning;
        IsRunning = false;
        _recognizer?.Dispose();
        _recognizer = null;
        if (wasRunning) StateChanged?.Invoke(false);
    }

    public void Dispose() => Cleanup();
}
