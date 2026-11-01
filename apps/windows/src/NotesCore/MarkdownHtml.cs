using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace NotesCore;

/// <summary>
/// Markdown to HTML for export and printing. See docs/format.md, "HTML export". Supports headings (ATX and setext),
/// paragraphs, emphasis, strikethrough, code spans and fences, lists (nested, ordered, tasks), blockquotes, links,
/// images, thematic breaks and simple tables. Raw HTML in the source is escaped, never passed through.
/// </summary>
public static class MarkdownHtml
{
    /// <summary>The fonts the exported page uses; <c>null</c> families fall back to the system fonts.</summary>
    public sealed record Style(string? TextFontFamily = null, double TextFontSize = 15, string? CodeFontFamily = null, double CodeFontSize = 13);

    /// <summary>A complete HTML document for a Markdown note.</summary>
    public static string Document(string markdown, string title, Style? style = null) =>
        Page(title, style ?? new Style(), Body(markdown));

    /// <summary>A complete HTML document for a code or text file: the file as one <c>&lt;pre&gt;</c>.</summary>
    public static string DocumentForCode(string code, string title, Style? style = null)
    {
        var text = code.Replace("\r\n", "\n").Replace("\r", "\n");
        return Page(title, style ?? new Style(), $"<pre class=\"file\"><code>{Escape(text)}</code></pre>\n");
    }

    /// <summary>The HTML body for Markdown text.</summary>
    public static string Body(string markdown)
    {
        var text = markdown.StartsWith('﻿') ? markdown[1..] : markdown;
        text = text.Replace("\r\n", "\n").Replace("\r", "\n").Replace("\t", "    ");
        return Blocks(text.Split('\n'), tight: false);
    }

    /// <summary>Escapes <c>&amp;</c>, <c>&lt;</c>, <c>&gt;</c> and <c>"</c>.</summary>
    public static string Escape(string text)
    {
        var result = new StringBuilder(text.Length);
        foreach (var c in text)
        {
            switch (c)
            {
                case '&': result.Append("&amp;"); break;
                case '<': result.Append("&lt;"); break;
                case '>': result.Append("&gt;"); break;
                case '"': result.Append("&quot;"); break;
                default: result.Append(c); break;
            }
        }
        return result.ToString();
    }

    // MARK: Page

    private static string Page(string title, Style style, string body) =>
        string.Join("\n",
            "<!doctype html>",
            "<html>",
            "<head>",
            "<meta charset=\"utf-8\">",
            "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">",
            $"<title>{Escape(title)}</title>",
            "<style>",
            Css(style),
            "</style>",
            "</head>",
            "<body>",
            "<main>",
            $"{body}</main>",
            "</body>",
            "</html>",
            "");

    private static string Css(Style style)
    {
        var text = FontStack(style.TextFontFamily, "-apple-system, BlinkMacSystemFont, \"Segoe UI\", \"Helvetica Neue\", sans-serif");
        var code = FontStack(style.CodeFontFamily, "ui-monospace, \"SF Mono\", Menlo, Consolas, monospace");
        var size = style.TextFontSize.ToString("F1", CultureInfo.InvariantCulture);
        var codeSize = style.CodeFontSize.ToString("F1", CultureInfo.InvariantCulture);
        return string.Join("\n",
            ":root { color-scheme: light dark; --fg: #222; --bg: #fff; --muted: #6b6b6b; --line: #d9d9d9; --code-bg: #f3f3f3; }",
            "@media (prefers-color-scheme: dark) { :root { --fg: #e4e4e4; --bg: #1e1e1e; --muted: #9a9a9a; --line: #3d3d3d; --code-bg: #2a2a2a; } }",
            "@media print { :root { --fg: #222; --bg: #fff; --muted: #6b6b6b; --line: #d9d9d9; --code-bg: #f3f3f3; } }",
            "html { background: var(--bg); }",
            $"body {{ margin: 0; color: var(--fg); background: var(--bg); font: {size}px/1.6 {text}; }}",
            "main { max-width: 46em; margin: 0 auto; padding: 2em 1.5em; }",
            "h1, h2, h3, h4, h5, h6 { line-height: 1.25; margin: 1.4em 0 0.5em; }",
            "h1 { font-size: 1.8em; } h2 { font-size: 1.45em; } h3 { font-size: 1.2em; }",
            "h4, h5, h6 { font-size: 1em; } h6 { color: var(--muted); }",
            "main > :first-child { margin-top: 0; }",
            "p, ul, ol, blockquote, pre, table { margin: 0 0 1em; }",
            "ul, ol { padding-left: 1.6em; }",
            "li > ul, li > ol { margin: 0.2em 0; }",
            "li.task { list-style: none; margin-left: -1.4em; }",
            "li.task input { margin: 0 0.5em 0 0; vertical-align: middle; }",
            "a { color: inherit; text-decoration: underline; text-decoration-color: var(--muted); }",
            $"code, pre {{ font-family: {code}; font-size: {codeSize}px; }}",
            "code { background: var(--code-bg); padding: 0.1em 0.3em; border-radius: 3px; }",
            "pre { background: var(--code-bg); padding: 0.8em 1em; border-radius: 6px; overflow-x: auto; white-space: pre-wrap; word-wrap: break-word; }",
            "pre code { background: none; padding: 0; border-radius: 0; font-size: inherit; }",
            "blockquote { margin-left: 0; padding: 0 1em; color: var(--muted); border-left: 3px solid var(--line); }",
            "hr { border: 0; border-top: 1px solid var(--line); margin: 1.5em 0; }",
            "img { max-width: 100%; }",
            "table { border-collapse: collapse; }",
            "th, td { border: 1px solid var(--line); padding: 0.3em 0.7em; }",
            "th { background: var(--code-bg); }",
            "@media print { main { max-width: none; padding: 0; } pre, blockquote, img, tr { break-inside: avoid; } h1, h2, h3 { break-after: avoid; } }");
    }

    private static string FontStack(string? family, string fallback)
    {
        if (family is null || TrimSpaces(family).Length == 0) return fallback;
        var cleaned = new string(family.Where(c => c is not ('"' or '\\' or '<' or '>' or '\n')).ToArray());
        return $"\"{cleaned}\", {fallback}";
    }

    // MARK: Regex helpers

    // The patterns come from the macOS implementation (ICU): there `.` and `$` stop at every line terminator.
    private const string Dot = @"[^\n\u000B\u000C\r\u0085\u2028\u2029]";
    private const string Eol = @"(?=(?:\r\n|[\n\u000B\u000C\r\u0085\u2028\u2029])?\z)";

    private static Regex Rx(string pattern, bool dotAll = false) =>
        new(pattern.Replace("DOT", Dot).Replace("EOL", Eol), RegexOptions.CultureInvariant | (dotAll ? RegexOptions.Singleline : RegexOptions.None));

    private static string[] Groups(Match m) => m.Groups.Cast<Group>().Select(g => g.Success ? g.Value : "").ToArray();

    private static string[]? First(Regex regex, string text)
    {
        var m = regex.Match(text);
        return m.Success ? Groups(m) : null;
    }

    private static bool Matches(Regex regex, string text) => regex.IsMatch(text);

    private static string Replacing(Regex regex, string text, Func<string[], string> transform) =>
        regex.Replace(text, m => transform(Groups(m)));

    /// <summary>Swift's <c>.whitespaces</c>: space separators and tab.</summary>
    private static bool IsSpace(char c) => c == '\t' || CharUnicodeInfo.GetUnicodeCategory(c) == UnicodeCategory.SpaceSeparator;

    private static string TrimSpaces(string text)
    {
        var from = 0;
        var to = text.Length;
        while (from < to && IsSpace(text[from])) from++;
        while (to > from && IsSpace(text[to - 1])) to--;
        return text[from..to];
    }

    // MARK: Blocks

    private static readonly Regex FenceStart = Rx(@"^ {0,3}(`{3,}|~{3,})[ ]*([^`\s]*)");
    private static readonly Regex Heading = Rx(@"^ {0,3}(#{1,6})(?:[ ]+(DOT*?))?(?:[ ]+#+)?[ ]*EOL");
    private static readonly Regex Rule = Rx(@"^ {0,3}([-*_])(?: *\1){2,} *EOL");
    private static readonly Regex Quote = Rx(@"^ {0,3}> ?(DOT*)EOL");
    private static readonly Regex ListMarker = Rx(@"^( *)([-*+]|\d{1,9}[.)])( +|EOL)(DOT*)EOL");
    private static readonly Regex Setext = Rx(@"^ {0,3}(=+|-+) *EOL");
    private static readonly Regex TableSeparator = Rx(@"^ *\|? *:?-+:? *(?:\| *:?-+:? *)*\|? *EOL");
    private static readonly Regex Task = Rx(@"^\[([ xX])\](?: +(DOT*))?EOL");

    private static string Blocks(IReadOnlyList<string> lines, bool tight)
    {
        var output = new StringBuilder();
        var i = 0;
        while (i < lines.Count)
        {
            var line = lines[i];
            string[]? m;
            if (IsBlank(line))
            {
                i++;
            }
            else if ((m = First(FenceStart, line)) is not null)
            {
                var fence = m[1];
                var language = m[2];
                var code = new List<string>();
                i++;
                while (i < lines.Count && !Closes(lines[i], fence))
                {
                    code.Add(lines[i]);
                    i++;
                }
                i++;
                var cls = language.Length == 0 ? "" : $" class=\"language-{Escape(language)}\"";
                output.Append($"<pre><code{cls}>{Escape(string.Join("\n", code))}</code></pre>\n");
            }
            else if ((m = First(Heading, line)) is not null)
            {
                var level = m[1].Length;
                output.Append($"<h{level}>{Inline(TrimSpaces(m[2]))}</h{level}>\n");
                i++;
            }
            else if (Matches(Rule, line))
            {
                output.Append("<hr>\n");
                i++;
            }
            else if (Matches(Quote, line))
            {
                var inner = new List<string>();
                while (i < lines.Count && First(Quote, lines[i]) is { } q)
                {
                    inner.Add(q[1]);
                    i++;
                }
                output.Append($"<blockquote>\n{Blocks(inner, tight: false)}</blockquote>\n");
            }
            else if (Matches(ListMarker, line))
            {
                var (html, next) = List(lines, i);
                output.Append(html);
                i = next;
            }
            else if (line.Contains('|') && i + 1 < lines.Count && lines[i + 1].Contains('-')
                     && Matches(TableSeparator, lines[i + 1]) && Cells(lines[i + 1]).Count == Cells(line).Count)
            {
                var (html, next) = Table(lines, i);
                output.Append(html);
                i = next;
            }
            else
            {
                var paragraph = new List<string> { line };
                i++;
                var level = 0;
                while (i < lines.Count && !IsBlank(lines[i]))
                {
                    if (First(Setext, lines[i]) is { } s)
                    {
                        level = s[1].StartsWith('=') ? 1 : 2;
                        i++;
                        break;
                    }
                    if (StartsBlock(lines[i])) break;
                    paragraph.Add(lines[i]);
                    i++;
                }
                var text = string.Join("\n", paragraph.Select(p => p.TrimStart(' ')));
                var html = Inline(text.Trim());
                if (level > 0) output.Append($"<h{level}>{html}</h{level}>\n");
                else output.Append(tight ? $"{html}\n" : $"<p>{html}</p>\n");
            }
        }
        return output.ToString();
    }

    private static bool IsBlank(string line) => line.All(c => c is ' ' or '\t');

    private static bool Closes(string line, string fence)
    {
        var trimmed = TrimSpaces(line);
        return trimmed.Length >= fence.Length && trimmed.All(c => c == fence[0]);
    }

    /// <summary>Whether `line` interrupts a paragraph.</summary>
    private static bool StartsBlock(string line)
    {
        if (Matches(FenceStart, line) || Matches(Heading, line) || Matches(Rule, line) || Matches(Quote, line)) return true;
        if (First(ListMarker, line) is { } m && m[4].Length > 0)
            return !char.IsDigit(m[2][0]) || m[2].StartsWith('1');
        return false;
    }

    // MARK: Lists

    private static (string Html, int Next) List(IReadOnlyList<string> lines, int start)
    {
        var first = First(ListMarker, lines[start])!;
        var baseIndent = first[1].Length;
        var ordered = char.IsDigit(first[2][0]);
        var startNumber = 1;
        if (ordered && !int.TryParse(first[2][..^1], NumberStyles.None, CultureInfo.InvariantCulture, out startNumber)) startNumber = 1;

        var items = new List<List<string>>();
        var loose = false;
        var i = start;
        while (i < lines.Count && First(ListMarker, lines[i]) is { } m && m[1].Length < baseIndent + 2 && char.IsDigit(m[2][0]) == ordered)
        {
            var spaces = m[3].Length > 4 || m[4].Length == 0 ? 1 : m[3].Length;
            var contentIndent = m[1].Length + m[2].Length + spaces;
            var item = new List<string> { m[4] };
            i++;
            while (i < lines.Count)
            {
                var line = lines[i];
                if (IsBlank(line))
                {
                    var j = i;
                    while (j < lines.Count && IsBlank(lines[j])) j++;
                    if (j >= lines.Count)
                    {
                        i = j;
                        break;
                    }
                    if (Indent(lines[j]) >= contentIndent)
                    {
                        item.AddRange(Enumerable.Repeat("", j - i));
                        loose = true;
                        i = j;
                    }
                    else
                    {
                        if (First(ListMarker, lines[j]) is { } next && next[1].Length < baseIndent + 2 && char.IsDigit(next[2][0]) == ordered)
                            loose = true;
                        i = j;
                        break;
                    }
                }
                else if (Indent(line) >= contentIndent)
                {
                    item.Add(line[contentIndent..]);
                    i++;
                }
                else if (!StartsBlock(line) && !Matches(ListMarker, line) && item.Count > 0 && item[^1].Length > 0)
                {
                    item.Add(TrimSpaces(line));
                    i++;
                }
                else
                {
                    break;
                }
            }
            items.Add(item);
            if (i < lines.Count && IsBlank(lines[i])) i++;
        }

        var html = new StringBuilder(ordered ? (startNumber == 1 ? "<ol>\n" : $"<ol start=\"{startNumber}\">\n") : "<ul>\n");
        foreach (var item in items)
        {
            var itemLines = new List<string>(item);
            var prefix = "";
            var cls = "";
            if (First(Task, itemLines[0]) is { } t)
            {
                prefix = $"<input type=\"checkbox\" disabled{(t[1] == " " ? "" : " checked")}> ";
                cls = " class=\"task\"";
                itemLines[0] = t[2];
            }
            html.Append($"<li{cls}>{prefix}{Blocks(itemLines, tight: !loose)}</li>\n");
        }
        html.Append(ordered ? "</ol>\n" : "</ul>\n");
        return (html.ToString(), i);
    }

    private static int Indent(string line)
    {
        var count = 0;
        while (count < line.Length && line[count] == ' ') count++;
        return count;
    }

    // MARK: Tables

    private static List<string> Cells(string line)
    {
        var trimmed = TrimSpaces(line);
        if (trimmed.StartsWith('|')) trimmed = trimmed[1..];
        if (trimmed.EndsWith('|') && !trimmed.EndsWith("\\|", StringComparison.Ordinal)) trimmed = trimmed[..^1];
        var result = new List<string>();
        var current = new StringBuilder();
        var escaped = false;
        foreach (var c in trimmed)
        {
            if (escaped)
            {
                current.Append(c);
                escaped = false;
            }
            else if (c == '\\')
            {
                escaped = true;
                current.Append(c);
            }
            else if (c == '|')
            {
                result.Add(TrimSpaces(current.ToString()));
                current.Clear();
            }
            else
            {
                current.Append(c);
            }
        }
        result.Add(TrimSpaces(current.ToString()));
        return result;
    }

    private static (string Html, int Next) Table(IReadOnlyList<string> lines, int start)
    {
        var header = Cells(lines[start]);
        var aligns = Cells(lines[start + 1]).Select(cell => (cell.StartsWith(':'), cell.EndsWith(':')) switch
        {
            (true, true) => " style=\"text-align: center\"",
            (false, true) => " style=\"text-align: right\"",
            (true, false) => " style=\"text-align: left\"",
            _ => "",
        }).ToList();

        string Row(List<string> values, string tag)
        {
            var tds = header.Select((_, column) => $"<{tag}{aligns[column]}>{Inline(column < values.Count ? values[column] : "")}</{tag}>");
            return $"<tr>{string.Concat(tds)}</tr>\n";
        }

        var html = new StringBuilder($"<table>\n<thead>\n{Row(header, "th")}</thead>\n<tbody>\n");
        var i = start + 2;
        while (i < lines.Count && !IsBlank(lines[i]) && lines[i].Contains('|'))
        {
            html.Append(Row(Cells(lines[i]), "td"));
            i++;
        }
        return (html + "</tbody>\n</table>\n", i);
    }

    // MARK: Inline

    private const char HoldOpen = '';
    private const char HoldClose = '';

    private static readonly Regex BackslashEscape = Rx(@"\\([\\`*_{}\[\]()#+\-.!|~<>""&])");
    private static readonly Regex CodeSpan = Rx(@"(?<!`)(`+)(?!`)(.+?)(?<!`)\1(?!`)", dotAll: true);
    private static readonly Regex Autolink = Rx(@"<((?:https?://|mailto:)[^\s<>]+)>");
    private static readonly Regex Image = Rx(@"!\[([^\]]*)\]\(\s*([^\s)]+)(?:\s+&quot;(DOT*?)&quot;)?\s*\)");
    private static readonly Regex Link = Rx(@"\[([^\]]+)\]\(\s*([^\s)]+)(?:\s+&quot;(DOT*?)&quot;)?\s*\)");
    private static readonly Regex BareUrl = Rx(@"(?<![\w""=/])https?://[^\s<]*[^\s<.,;:!?)\]']");
    private static readonly Regex BoldItalic = Rx(@"\*\*\*(?=\S)(.+?)(?<=\S)\*\*\*", dotAll: true);
    private static readonly Regex Strike = Rx(@"~~(?=\S)(.+?)(?<=\S)~~", dotAll: true);
    private static readonly Regex BoldStar = Rx(@"\*\*(?=\S)(.+?)(?<=\S)\*\*", dotAll: true);
    private static readonly Regex BoldUnderscore = Rx(@"(?<!\w)__(?=\S)(.+?)(?<=\S)__(?!\w)", dotAll: true);
    private static readonly Regex ItalicStar = Rx(@"\*(?=[^\s*])(.+?)(?<=[^\s*])\*", dotAll: true);
    private static readonly Regex ItalicUnderscore = Rx(@"(?<!\w)_(?=[^\s_])(.+?)(?<=[^\s_])_(?!\w)", dotAll: true);
    private static readonly Regex HardBreak = Rx(@"(?: {2,}|\\)\n");
    private static readonly Regex Placeholder = Rx("(\\d+)");

    private static string Inline(string source)
    {
        var held = new List<string>();
        var plain = new HashSet<int>();

        string Hold(string html, bool plainText = false)
        {
            held.Add(html);
            if (plainText) plain.Add(held.Count - 1);
            return $"{HoldOpen}{held.Count - 1}{HoldClose}";
        }

        // An attribute value from a destination or title: placeholders for escaped text expand to that text; any other
        // placeholder (an autolink or code span, which holds markup) makes the value unusable.
        string? Attribute(string value)
        {
            if (value.IndexOf(HoldOpen) < 0 && value.IndexOf(HoldClose) < 0) return value;
            var usable = true;
            var expanded = Replacing(Placeholder, value, g =>
            {
                if (!int.TryParse(g[1], NumberStyles.None, CultureInfo.InvariantCulture, out var index) || !plain.Contains(index))
                {
                    usable = false;
                    return "";
                }
                return held[index];
            });
            return usable && expanded.IndexOf(HoldOpen) < 0 && expanded.IndexOf(HoldClose) < 0 ? expanded : null;
        }

        var s = new string(source.Where(c => c != HoldOpen && c != HoldClose).ToArray());
        s = Replacing(BackslashEscape, s, g => Hold(Escape(g[1]), plainText: true));
        s = Replacing(CodeSpan, s, g =>
        {
            var code = g[2].Replace("\n", " ");
            if (new StringInfo(code).LengthInTextElements > 2 && code.StartsWith(' ') && code.EndsWith(' ') && !code.All(c => c == ' '))
                code = code[1..^1];
            return Hold($"<code>{Escape(code)}</code>");
        });
        s = Replacing(Autolink, s, g => Hold($"<a href=\"{Escape(g[1])}\">{Escape(g[1])}</a>"));
        s = Escape(s);
        s = Replacing(Image, s, g =>
        {
            if (Attribute(g[2]) is not { } destination || Attribute(g[3]) is not { } title) return g[0];
            var alt = Replacing(Placeholder, g[1], _ => "");
            var titleAttribute = title.Length == 0 ? "" : $" title=\"{title}\"";
            return Hold($"<img src=\"{SafeUrl(destination)}\" alt=\"{alt}\"{titleAttribute}>");
        });
        s = Replacing(Link, s, g =>
        {
            if (Attribute(g[2]) is not { } destination || Attribute(g[3]) is not { } title) return g[0];
            var titleAttribute = title.Length == 0 ? "" : $" title=\"{title}\"";
            return Hold($"<a href=\"{SafeUrl(destination)}\"{titleAttribute}>") + g[1] + Hold("</a>");
        });
        s = Replacing(BareUrl, s, g => Hold($"<a href=\"{g[0]}\">{g[0]}</a>"));
        s = Replacing(BoldItalic, s, g => $"<strong><em>{g[1]}</em></strong>");
        s = Replacing(Strike, s, g => $"<del>{g[1]}</del>");
        s = Replacing(BoldStar, s, g => $"<strong>{g[1]}</strong>");
        s = Replacing(BoldUnderscore, s, g => $"<strong>{g[1]}</strong>");
        s = Replacing(ItalicStar, s, g => $"<em>{g[1]}</em>");
        s = Replacing(ItalicUnderscore, s, g => $"<em>{g[1]}</em>");
        s = Replacing(HardBreak, s, _ => "<br>\n");
        for (var round = 0; round < 4 && s.IndexOf(HoldOpen) >= 0; round++)
            s = Replacing(Placeholder, s, g => held[int.TryParse(g[1], NumberStyles.None, CultureInfo.InvariantCulture, out var index) ? index : 0]);
        return s;
    }

    /// <summary>
    /// Only <c>http</c>, <c>https</c>, <c>mailto</c> and scheme-less (relative) targets survive; anything else becomes <c>#</c>.
    /// Like a browser, leading and trailing C0 controls and spaces are ignored and TAB, LF and CR inside are removed before
    /// the scheme is read. The URL is already HTML-escaped; the returned value is the cleaned one.
    /// </summary>
    internal static string SafeUrl(string url)
    {
        var chars = url.Where(c => c is not ('\t' or '\n' or '\r')).ToArray();
        var from = 0;
        var to = chars.Length;
        while (from < to && chars[from] <= ' ') from++;
        while (to > from && chars[to - 1] <= ' ') to--;
        var cleaned = new string(chars, from, to - from);
        var colon = cleaned.IndexOf(':');
        if (colon < 0) return cleaned;
        var scheme = cleaned[..colon];
        // Anything else before the first colon (a "/", "?" or "#", say) makes the whole target relative.
        if (scheme.Length == 0 || !char.IsAsciiLetter(scheme[0]) || !scheme.All(c => char.IsAsciiLetterOrDigit(c) || c is '+' or '-' or '.')) return cleaned;
        return scheme.ToLowerInvariant() is "http" or "https" or "mailto" ? cleaned : "#";
    }
}
