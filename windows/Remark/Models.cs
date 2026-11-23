using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Remark;

public enum NoteKind { Note, Bug, Ux, Question, Idea }

public static class NoteKindExtensions
{
    public static string Label(this NoteKind k) => k switch
    {
        NoteKind.Note => "Note",
        NoteKind.Bug => "Bug",
        NoteKind.Ux => "UX",
        NoteKind.Question => "Question",
        NoteKind.Idea => "Idea",
        _ => k.ToString()
    };

    public static string ColorHex(this NoteKind k) => k switch
    {
        NoteKind.Note => "#6B7280",
        NoteKind.Bug => "#DC2626",
        NoteKind.Ux => "#EA580C",
        NoteKind.Question => "#2563EB",
        NoteKind.Idea => "#059669",
        _ => "#6B7280"
    };
}

/// Same shape as the macOS app's session.json, so sessions move between Mac and Windows.
public sealed class ReviewNote
{
    public string Id { get; set; } = Guid.NewGuid().ToString().ToUpperInvariant();
    public int Number { get; set; }
    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.UtcNow;
    public NoteKind Kind { get; set; } = NoteKind.Note;
    public string Text { get; set; } = "";
    public string? ImageFile { get; set; }   // relative to the session folder; null for text notes
    public string? SourceApp { get; set; }
    public string? Quote { get; set; }       // selected text, or text pulled from the screenshot
    public string? WindowTitle { get; set; }

    [JsonIgnore]
    public string? Context
    {
        get
        {
            var parts = new[] { SourceApp, WindowTitle }.Where(s => !string.IsNullOrWhiteSpace(s)).ToArray();
            return parts.Length == 0 ? null : string.Join(" — ", parts);
        }
    }
}

public sealed class ReviewSession
{
    public string Id { get; set; } = Guid.NewGuid().ToString().ToUpperInvariant();
    public string Title { get; set; } = "";
    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.UtcNow;
    public string Reviewer { get; set; } = "";
    public List<ReviewNote> Notes { get; set; } = new();
}

/// ISO-8601 without fractional seconds ("2026-11-12T10:00:00Z") — what Swift's .iso8601 expects.
public sealed class IsoDateConverter : JsonConverter<DateTimeOffset>
{
    public override DateTimeOffset Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        var s = reader.GetString();
        return DateTimeOffset.TryParse(s, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var d)
            ? d : DateTimeOffset.UtcNow;
    }

    public override void Write(Utf8JsonWriter writer, DateTimeOffset value, JsonSerializerOptions options) =>
        writer.WriteStringValue(value.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture));
}

public static class Json
{
    public static readonly JsonSerializerOptions Options = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        WriteIndented = true,
        PropertyNameCaseInsensitive = true,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase), new IsoDateConverter() }
    };
}
