using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;

namespace Remark;

public sealed record RecentSession(string Title, string Folder, int Count, DateTimeOffset Date);

/// Each review session is a folder in Documents\Remark:
///   session.json, shots\*.png, report.html, report.md
public sealed class SessionStore
{
    public static string RootFolder { get; } =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), "Remark");

    private readonly Prefs _prefs;

    public ReviewSession? Session { get; private set; }
    public string? Folder { get; private set; }
    public event Action? Changed;

    public SessionStore(Prefs prefs) { _prefs = prefs; }

    public bool IsActive => Session != null;
    public string? ReportHtmlPath => Folder == null ? null : Path.Combine(Folder, "report.html");

    // ---------- lifecycle ----------

    public void Start(string title)
    {
        var clean = (title ?? "").Trim();
        var now = DateTimeOffset.Now;
        var finalTitle = clean.Length == 0 ? $"Review {now:MMM d, yyyy h:mm tt}" : clean;
        var folder = Path.Combine(RootFolder, $"{now:yyyy-MM-dd_HHmm}-{Slug(finalTitle)}");
        Directory.CreateDirectory(Path.Combine(folder, "shots"));

        Session = new ReviewSession { Title = finalTitle, CreatedAt = now, Reviewer = ReviewerName() };
        Folder = folder;
        _prefs.LastSessionFolder = folder;
        _prefs.Save();
        Save();
    }

    public void EnsureSession()
    {
        if (Session == null) Start("");
    }

    public bool Open(string folder)
    {
        try
        {
            var json = File.ReadAllText(Path.Combine(folder, "session.json"));
            var s = JsonSerializer.Deserialize<ReviewSession>(json, Json.Options);
            if (s == null) return false;
            Session = s;
            Folder = folder;
            _prefs.LastSessionFolder = folder;
            _prefs.Save();
            Changed?.Invoke();
            return true;
        }
        catch
        {
            return false;
        }
    }

    public void ResumeLast()
    {
        if (!string.IsNullOrEmpty(_prefs.LastSessionFolder) && Directory.Exists(_prefs.LastSessionFolder))
            Open(_prefs.LastSessionFolder!);
    }

    public void End()
    {
        Session = null;
        Folder = null;
        _prefs.LastSessionFolder = null;
        _prefs.Save();
        Changed?.Invoke();
    }

    // ---------- notes ----------

    public string NextImagePath()
    {
        EnsureSession();
        int n = (Session!.Notes.Count == 0 ? 0 : Session.Notes.Max(x => x.Number)) + 1;
        var name = $"shot-{n:000}-{Guid.NewGuid().ToString("N")[..4]}.png";
        var dir = Path.Combine(Folder!, "shots");
        Directory.CreateDirectory(dir);
        return Path.Combine(dir, name);
    }

    public void Add(NoteKind kind, string text, string? imagePath, string? quote, string? sourceApp, string? windowTitle)
    {
        if (Session == null) return;
        int n = (Session.Notes.Count == 0 ? 0 : Session.Notes.Max(x => x.Number)) + 1;
        var q = quote?.Trim();
        Session.Notes.Add(new ReviewNote
        {
            Number = n,
            CreatedAt = DateTimeOffset.Now,
            Kind = kind,
            Text = (text ?? "").Trim(),
            ImageFile = imagePath == null ? null : "shots/" + Path.GetFileName(imagePath),
            SourceApp = sourceApp,
            Quote = string.IsNullOrEmpty(q) ? null : q,
            WindowTitle = windowTitle
        });
        Save();
    }

    public void Save()
    {
        if (Session == null || Folder == null) return;
        Directory.CreateDirectory(Folder);
        File.WriteAllText(Path.Combine(Folder, "session.json"), JsonSerializer.Serialize(Session, Json.Options));
        File.WriteAllText(Path.Combine(Folder, "report.md"), Markdown());
        File.WriteAllText(Path.Combine(Folder, "report.html"), Html(embedImages: false));
        Changed?.Invoke();
    }

    public static List<RecentSession> RecentSessions(int limit = 10)
    {
        var list = new List<RecentSession>();
        if (!Directory.Exists(RootFolder)) return list;
        foreach (var dir in Directory.GetDirectories(RootFolder))
        {
            try
            {
                var file = Path.Combine(dir, "session.json");
                if (!File.Exists(file)) continue;
                var s = JsonSerializer.Deserialize<ReviewSession>(File.ReadAllText(file), Json.Options);
                if (s != null) list.Add(new RecentSession(s.Title, dir, s.Notes.Count, s.CreatedAt));
            }
            catch { }
        }
        return list.OrderByDescending(r => r.Date).Take(limit).ToList();
    }

    // ---------- reports ----------

    public string Markdown()
    {
        if (Session == null) return "";
        var s = Session;
        var sb = new StringBuilder();
        sb.Append($"# {s.Title}\n\n");
        sb.Append($"_Reviewed by {s.Reviewer} · {s.CreatedAt.ToLocalTime():MMM d, yyyy h:mm tt} · {s.Notes.Count} note{(s.Notes.Count == 1 ? "" : "s")}_\n\n");
        foreach (var n in s.Notes)
        {
            sb.Append($"## {n.Number}. [{n.Kind.Label()}]{(n.Context is { } c ? " — " + c : "")}\n\n");
            if (n.Quote is { } q)
                sb.Append(string.Join("\n", q.Split('\n').Select(l => "> " + l))).Append("\n\n");
            if (n.ImageFile is { } img)
                sb.Append($"![Note {n.Number}]({img})\n\n");
            sb.Append(n.Text.Length == 0 ? "_(no note)_" : n.Text).Append("\n\n");
            sb.Append($"<sub>{n.CreatedAt.ToLocalTime():h:mm tt}</sub>\n\n---\n\n");
        }
        return sb.ToString();
    }

    public string Html(bool embedImages)
    {
        if (Session == null || Folder == null) return "";
        var s = Session;

        var counts = s.Notes.GroupBy(n => n.Kind).ToDictionary(g => g.Key, g => g.Count());
        var chips = string.Concat(Enum.GetValues<NoteKind>()
            .Where(k => counts.ContainsKey(k))
            .Select(k => $"<span class=\"chip\" style=\"--c:{k.ColorHex()}\">{k.Label()} · {counts[k]}</span>"));

        var cards = new StringBuilder();
        foreach (var n in s.Notes)
        {
            var imageHtml = "";
            if (n.ImageFile is { } file)
            {
                var src = Esc(file);
                if (embedImages)
                {
                    var p = Path.Combine(Folder, file.Replace('/', Path.DirectorySeparatorChar));
                    if (File.Exists(p)) src = "data:image/png;base64," + Convert.ToBase64String(File.ReadAllBytes(p));
                }
                imageHtml = $"<a href=\"{src}\" target=\"_blank\"><img src=\"{src}\" alt=\"Screenshot for note {n.Number}\"></a>";
            }
            var quoteHtml = n.Quote is { } q ? $"<blockquote>{Esc(q)}</blockquote>" : "";
            var body = n.Text.Length == 0 ? "<div class=\"text empty\">(no note)</div>" : $"<div class=\"text\">{Esc(n.Text)}</div>";
            var ctx = n.Context is { } c ? " · " + Esc(c) : "";
            cards.Append($"""
            <article class="card" id="note-{n.Number}">
              <header>
                <span class="num">#{n.Number}</span>
                <span class="chip" style="--c:{n.Kind.ColorHex()}">{n.Kind.Label()}</span>
                <span class="meta">{n.CreatedAt.ToLocalTime():h:mm tt}{ctx}</span>
              </header>
              {quoteHtml}
              {body}
              {imageHtml}
            </article>

            """);
        }

        var noteWord = s.Notes.Count == 1 ? "note" : "notes";
        var cardsHtml = cards.Length == 0 ? "<p class=\"sub\">No notes yet.</p>" : cards.ToString();

        return $$"""
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>{{Esc(s.Title)}} — Review</title>
        <style>
          :root { --bg:#faf9f7; --fg:#1c1917; --muted:#78716c; --card:#fff; --line:#e7e5e4; --accent:#8B5CF6; }
          @media (prefers-color-scheme: dark) { :root { --bg:#171513; --fg:#f5f5f4; --muted:#a8a29e; --card:#211e1b; --line:#3a3532; --accent:#A78BFA; } }
          * { box-sizing: border-box; }
          body { margin:0; background:var(--bg); color:var(--fg); font:15px/1.55 -apple-system, BlinkMacSystemFont, "Segoe UI", Inter, sans-serif; }
          main { max-width: 880px; margin: 0 auto; padding: 48px 24px 80px; }
          h1 { font-size: 30px; margin: 0 0 6px; letter-spacing: -0.02em; }
          .sub { color: var(--muted); margin-bottom: 14px; }
          .chips { display:flex; gap:8px; flex-wrap:wrap; margin-bottom: 32px; }
          .chip { --c:#6b7280; display:inline-block; font-size:12px; font-weight:600; padding:2px 10px; border-radius:999px;
                  color:var(--c); background: color-mix(in srgb, var(--c) 14%, transparent); }
          .card { background:var(--card); border:1px solid var(--line); border-radius:14px; padding:18px 20px 20px; margin-bottom:22px; }
          .card header { display:flex; align-items:center; gap:10px; margin-bottom:10px; }
          .num { font-weight:700; color:var(--accent); }
          .meta { margin-left:auto; color:var(--muted); font-size:13px; text-align:right; }
          blockquote { margin:0 0 12px; padding:8px 14px; border-left:3px solid var(--accent); white-space:pre-wrap;
                       background: color-mix(in srgb, var(--accent) 8%, transparent); border-radius:0 8px 8px 0; font-size:14px; }
          .text { white-space: pre-wrap; margin: 0 0 14px; font-size: 15.5px; }
          .text.empty { color: var(--muted); font-style: italic; }
          img { display:block; max-width:100%; max-height:560px; margin:0 auto; border-radius:8px; border:1px solid var(--line); }
          footer { color:var(--muted); font-size:12px; text-align:center; margin-top:40px; }
          @media print { body { background:#fff; color:#000; } .card { break-inside: avoid; } }
        </style>
        </head>
        <body>
        <main>
          <h1>{{Esc(s.Title)}}</h1>
          <div class="sub">Reviewed by {{Esc(s.Reviewer)}} · {{s.CreatedAt.ToLocalTime():MMM d, yyyy h:mm tt}} · {{s.Notes.Count}} {{noteWord}}</div>
          <div class="chips">{{chips}}</div>
          {{cardsHtml}}
          <footer>Made with Remark</footer>
        </main>
        </body>
        </html>
        """;
    }

    // ---------- helpers ----------

    public static string Esc(string s) => s
        .Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;").Replace("\"", "&quot;");

    public static string Slug(string s)
    {
        var chars = s.ToLowerInvariant().Select(ch => char.IsLetterOrDigit(ch) && ch < 128 ? ch : '-').ToArray();
        var collapsed = string.Join("-", new string(chars).Split('-', StringSplitOptions.RemoveEmptyEntries));
        if (collapsed.Length == 0) return "review";
        return collapsed.Length > 40 ? collapsed[..40] : collapsed;
    }

    private static string ReviewerName()
    {
        var name = Environment.UserName;
        return string.IsNullOrWhiteSpace(name) ? "Reviewer" : name;
    }
}
