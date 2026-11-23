using System;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Text;
using System.Text.Json;
using QuestPDF.Fluent;
using QuestPDF.Helpers;
using QuestPDF.Infrastructure;

namespace Remark;

public enum ExportFormat { Pdf, Html, Markdown, Json, Csv }

public static class ExportFormatInfo
{
    public static string Title(this ExportFormat f) => f switch
    {
        ExportFormat.Pdf => "PDF Document",
        ExportFormat.Html => "Web Page (single HTML file)",
        ExportFormat.Markdown => "Markdown + Images (.zip)",
        ExportFormat.Json => "JSON (raw data)",
        _ => "CSV (spreadsheet)"
    };

    public static string Summary(this ExportFormat f) => f switch
    {
        ExportFormat.Pdf => "Paginated report for clients and stakeholders.",
        ExportFormat.Html => "One file with images embedded. Opens in any browser.",
        ExportFormat.Markdown => "README.md plus a shots/ folder. Good for HackerOne, GitHub, Jira.",
        ExportFormat.Json => "Everything Remark knows, for scripts and integrations.",
        _ => "One row per note. Opens in Excel, Sheets, Numbers."
    };

    public static string Extension(this ExportFormat f) => f switch
    {
        ExportFormat.Pdf => "pdf",
        ExportFormat.Html => "html",
        ExportFormat.Markdown => "zip",
        ExportFormat.Json => "json",
        _ => "csv"
    };
}

internal static class Exporter
{
    public static void Export(ExportFormat format, SessionStore store, string path, PdfPageSize pageSize)
    {
        if (store.Session is not { } session || store.Folder is not { } folder)
            throw new InvalidOperationException("There's no active session to export.");
        if (File.Exists(path)) File.Delete(path);

        switch (format)
        {
            case ExportFormat.Pdf:
                PdfReport.Render(session, folder, path, pageSize);
                break;
            case ExportFormat.Html:
                File.WriteAllText(path, store.Html(embedImages: true), Encoding.UTF8);
                break;
            case ExportFormat.Json:
                File.WriteAllText(path, JsonSerializer.Serialize(session, Json.Options), Encoding.UTF8);
                break;
            case ExportFormat.Csv:
                File.WriteAllText(path, Csv(session), new UTF8Encoding(true)); // BOM so Excel reads UTF-8
                break;
            case ExportFormat.Markdown:
                MarkdownZip(store, session, folder, path);
                break;
        }
    }

    private static string Csv(ReviewSession s)
    {
        static string Cell(string? v) => "\"" + (v ?? "").Replace("\"", "\"\"") + "\"";
        var sb = new StringBuilder("number,kind,note,quoted_text,app,window,created_at,image\r\n");
        foreach (var n in s.Notes)
        {
            sb.Append(string.Join(",", n.Number, n.Kind.Label(), Cell(n.Text), Cell(n.Quote), Cell(n.SourceApp),
                Cell(n.WindowTitle), n.CreatedAt.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'"), Cell(n.ImageFile)));
            sb.Append("\r\n");
        }
        return sb.ToString();
    }

    private static void MarkdownZip(SessionStore store, ReviewSession session, string folder, string zipPath)
    {
        var staging = Path.Combine(Path.GetTempPath(), "remark-" + Guid.NewGuid().ToString("N"));
        var bundle = Path.Combine(staging, SessionStore.Slug(session.Title));
        try
        {
            Directory.CreateDirectory(Path.Combine(bundle, "shots"));
            File.WriteAllText(Path.Combine(bundle, "README.md"), store.Markdown(), Encoding.UTF8);
            foreach (var file in session.Notes.Select(n => n.ImageFile).OfType<string>())
            {
                var src = Path.Combine(folder, file.Replace('/', Path.DirectorySeparatorChar));
                if (File.Exists(src))
                    File.Copy(src, Path.Combine(bundle, file.Replace('/', Path.DirectorySeparatorChar)), true);
            }
            ZipFile.CreateFromDirectory(bundle, zipPath, CompressionLevel.Optimal, includeBaseDirectory: true);
        }
        finally
        {
            try { Directory.Delete(staging, true); } catch { }
        }
    }
}

/// Paginated PDF report (QuestPDF, community license).
internal static class PdfReport
{
    private const string Accent = "#8B5CF6";
    private const string Muted = "#78716C";
    private const string Line = "#E7E5E4";

    public static void Render(ReviewSession s, string folder, string path, PdfPageSize size)
    {
        var counts = s.Notes.GroupBy(n => n.Kind).ToDictionary(g => g.Key, g => g.Count());

        Document.Create(doc =>
        {
            doc.Page(page =>
            {
                page.Size(size == PdfPageSize.A4 ? PageSizes.A4 : PageSizes.Letter);
                page.Margin(40);
                page.DefaultTextStyle(t => t.FontSize(11).FontColor("#1C1917"));

                page.Footer().Text(t =>
                {
                    t.Span(s.Title + "  ·  ").FontSize(8.5f).FontColor(Muted);
                    t.CurrentPageNumber().FontSize(8.5f).FontColor(Muted);
                });

                page.Content().Column(col =>
                {
                    col.Spacing(6);
                    col.Item().Text(s.Title).FontSize(22).Bold();
                    var noteWord = s.Notes.Count == 1 ? "note" : "notes";
                    col.Item().Text($"Reviewed by {s.Reviewer}  ·  {s.CreatedAt.ToLocalTime():MMM d, yyyy h:mm tt}  ·  {s.Notes.Count} {noteWord}")
                        .FontSize(10).FontColor(Muted);

                    if (counts.Count > 0)
                    {
                        col.Item().PaddingTop(2).Text(t =>
                        {
                            foreach (var kind in Enum.GetValues<NoteKind>())
                                if (counts.TryGetValue(kind, out var c))
                                    t.Span($"{kind.Label()} {c}     ").FontSize(10).SemiBold().FontColor(kind.ColorHex());
                        });
                    }

                    col.Item().PaddingTop(10).PaddingBottom(14).LineHorizontal(1).LineColor(Line);

                    foreach (var n in s.Notes)
                    {
                        col.Item().EnsureSpace(90).Column(note =>
                        {
                            note.Spacing(6);
                            note.Item().Text(t =>
                            {
                                t.Span($"#{n.Number}  ").FontSize(13).Bold().FontColor(Accent);
                                t.Span(n.Kind.Label().ToUpperInvariant()).FontSize(10).Bold().FontColor(n.Kind.ColorHex());
                                var meta = "   ·   " + n.CreatedAt.ToLocalTime().ToString("h:mm tt");
                                if (n.Context is { } ctx) meta += "   ·   " + ctx;
                                t.Span(meta).FontSize(9.5f).FontColor(Muted);
                            });

                            if (n.Quote is { } q)
                            {
                                note.Item().BorderLeft(2.5f).BorderColor(Accent).Background("#F5F1FE")
                                    .PaddingVertical(4).PaddingHorizontal(10)
                                    .Text(q).FontSize(10.5f).FontColor("#3F3A46");
                            }

                            if (n.Text.Length == 0)
                                note.Item().Text("(no note)").Italic().FontColor(Muted);
                            else
                                note.Item().Text(n.Text).FontSize(11.5f);

                            if (n.ImageFile is { } file)
                            {
                                var p = Path.Combine(folder, file.Replace('/', Path.DirectorySeparatorChar));
                                if (File.Exists(p))
                                {
                                    note.Item().PaddingTop(4).AlignCenter().MaxHeight(430)
                                        .Border(0.75f).BorderColor(Line)
                                        .Image(p).FitArea();
                                }
                            }
                        });
                        col.Item().PaddingVertical(12).LineHorizontal(0.75f).LineColor(Line);
                    }

                    if (s.Notes.Count == 0)
                        col.Item().Text("No notes yet.").FontColor(Muted);
                });
            });
        })
        .WithMetadata(new DocumentMetadata { Title = s.Title, Author = s.Reviewer, Creator = "Remark" })
        .GeneratePdf(path);
    }
}
