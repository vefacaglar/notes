using System.Globalization;

namespace NotesCore;

public enum CodeLanguage
{
    Json, Swift, JavaScript, Python, Shell, Yaml, Xml, Css, CFamily, Sql, Toml, Markdown, PlainText,
}

public static class CodeLanguages
{
    private static readonly Dictionary<string, CodeLanguage> ByExtension = BuildTable();

    private static Dictionary<string, CodeLanguage> BuildTable()
    {
        var table = new Dictionary<string, CodeLanguage>(StringComparer.Ordinal);
        (CodeLanguage, string[])[] groups =
        [
            (CodeLanguage.Json, ["json"]),
            (CodeLanguage.Swift, ["swift"]),
            (CodeLanguage.JavaScript, ["js", "mjs", "cjs", "jsx", "ts", "tsx", "mts", "cts"]),
            (CodeLanguage.Python, ["py"]),
            (CodeLanguage.Shell, ["sh", "bash", "zsh"]),
            (CodeLanguage.Yaml, ["yaml", "yml"]),
            (CodeLanguage.Xml, ["xml", "html", "htm", "plist", "svg"]),
            (CodeLanguage.Css, ["css"]),
            (CodeLanguage.CFamily, ["c", "h", "cc", "cpp", "hpp", "m", "mm", "java", "kt", "kts", "cs", "go", "rs"]),
            (CodeLanguage.Sql, ["sql"]),
            (CodeLanguage.Toml, ["toml", "ini"]),
            (CodeLanguage.Markdown, ["md", "markdown", "mdown", "mkd", "mdenc"]),
        ];
        foreach (var (language, extensions) in groups)
            foreach (var ext in extensions) table[ext] = language;
        return table;
    }

    /// <summary>Lowercased file extensions with a language of their own; anything else is <see cref="CodeLanguage.PlainText"/>.</summary>
    public static IReadOnlySet<string> FileExtensions { get; } = new HashSet<string>(ByExtension.Keys, StringComparer.Ordinal);

    public static CodeLanguage FromFileExtension(string fileExtension) =>
        ByExtension.TryGetValue(fileExtension.ToLowerInvariant(), out var language) ? language : CodeLanguage.PlainText;

    /// <summary>Language from the path's extension, split at '/' only (like NSString.pathExtension).</summary>
    public static CodeLanguage FromPath(string path)
    {
        var end = path.Length;
        while (end > 1 && path[end - 1] == '/') end--;
        var name = path[..end];
        var slash = name.LastIndexOf('/');
        if (slash >= 0) name = name[(slash + 1)..];
        var dot = name.LastIndexOf('.');
        return dot > 0 && dot < name.Length - 1 ? FromFileExtension(name[(dot + 1)..]) : CodeLanguage.PlainText;
    }

    public static string DisplayName(this CodeLanguage language) => language switch
    {
        CodeLanguage.Json => "JSON",
        CodeLanguage.Swift => "Swift",
        CodeLanguage.JavaScript => "JavaScript",
        CodeLanguage.Python => "Python",
        CodeLanguage.Shell => "Shell",
        CodeLanguage.Yaml => "YAML",
        CodeLanguage.Xml => "XML",
        CodeLanguage.Css => "CSS",
        CodeLanguage.CFamily => "C",
        CodeLanguage.Sql => "SQL",
        CodeLanguage.Toml => "TOML",
        CodeLanguage.Markdown => "Markdown",
        _ => Strings.Get("PlainText"),
    };

    /// <summary>What Tab inserts: a tab when the file already indents with tabs, otherwise its most common indent step.</summary>
    public static string IndentUnit(this CodeLanguage language, string text)
    {
        int tabLines = 0, spaceLines = 0, previous = 0, lines = 0;
        var steps = new int[9];
        int indent = 0;
        bool atLineStart = true, firstIsTab = false;
        foreach (var c in text)
        {
            if (c == '\n')
            {
                atLineStart = true; indent = 0;
                lines++;
                if (lines == 2_000) break;
                continue;
            }
            if (!atLineStart) continue;
            if (c == ' ' || c == '\t')
            {
                if (indent == 0) firstIsTab = c == '\t';
                indent++;
                continue;
            }
            atLineStart = false;
            if (indent > 0 && firstIsTab) { tabLines++; continue; }
            if (indent > 1) spaceLines++;
            var step = Math.Abs(indent - previous);
            if (step >= 2 && step <= 8) steps[step]++;
            previous = indent;
        }
        if (tabLines > spaceLines && language != CodeLanguage.Yaml) return "\t";
        var best = 0;
        for (var k = 1; k < steps.Length; k++) if (steps[k] > steps[best]) best = k;
        if (steps[best] > 0) return new string(' ', best);
        return language switch
        {
            CodeLanguage.Json or CodeLanguage.Yaml or CodeLanguage.JavaScript or CodeLanguage.Xml or CodeLanguage.Css
                or CodeLanguage.Toml or CodeLanguage.Markdown or CodeLanguage.Shell => "  ",
            _ => "    ",
        };
    }
}

public enum CodeSpanKind
{
    Keyword,
    String,
    Number,
    Comment,
    /// <summary>true, false, null, nil, None..., and entities like &amp;amp; in markup.</summary>
    Literal,
    /// <summary>Capitalized identifiers, CSS id/class selectors.</summary>
    Type,
    /// <summary>JSON/YAML/TOML keys, XML attribute names, CSS properties, shell variables.</summary>
    Property,
    /// <summary>Markup tags with their brackets, TOML/INI section headers.</summary>
    Tag,
}

/// <summary>A UTF-16 range (location, length), directly usable with a RichEditBox text range.</summary>
public readonly record struct CodeRange(int Location, int Length)
{
    public int End => Location + Length;
}

/// <param name="Location">UTF-16 start.</param>
/// <param name="Length">UTF-16 length.</param>
public readonly record struct CodeSpan(int Location, int Length, CodeSpanKind Kind)
{
    public int End => Location + Length;
    public CodeRange Range => new(Location, Length);
}

/// <summary>A single-pass tokenizer for syntax highlighting, configured per language. Not a parser:
/// it knows comments, strings, numbers, words and a few per-language rules (keys, tags, selectors).</summary>
public static class CodeHighlighter
{
    /// <summary>Non-overlapping spans sorted by location. Markdown is the exception: its spans may nest.</summary>
    public static List<CodeSpan> Spans(string text, CodeLanguage language)
    {
        switch (language)
        {
            case CodeLanguage.PlainText:
                return [];
            case CodeLanguage.Markdown:
                return MarkdownCodeSpans(text);
            case CodeLanguage.Xml:
            {
                var tokenizer = new MarkupTokenizer(text);
                tokenizer.Run();
                return tokenizer.Spans;
            }
            default:
            {
                var tokenizer = new Tokenizer(text, Syntax.Of(language));
                tokenizer.Run();
                return tokenizer.Spans;
            }
        }
    }

    private static List<CodeSpan> MarkdownCodeSpans(string text)
    {
        var result = new List<CodeSpan>();
        foreach (var span in MarkdownStyler.Spans(text))
        {
            CodeSpanKind? kind = span.Kind.Kind switch
            {
                MarkdownKind.Heading => CodeSpanKind.Keyword,
                MarkdownKind.InlineCode or MarkdownKind.CodeBlock => CodeSpanKind.String,
                MarkdownKind.Link => CodeSpanKind.Property,
                MarkdownKind.Blockquote => CodeSpanKind.Comment,
                MarkdownKind.ListMarker or MarkdownKind.TaskMarker => CodeSpanKind.Tag,
                _ => null,
            };
            if (kind is { } k) result.Add(new CodeSpan(span.Range.Location, span.Range.Length, k));
        }
        return result;
    }

    /// <summary>What an editor must restyle after one edit: the edited range plus every span that appeared,
    /// vanished or changed. Identical spans before the edit and identical shifted spans after it are skipped.
    /// <paramref name="editedRange"/> is in post-edit coordinates.</summary>
    public static CodeRange ChangedRange(
        IReadOnlyList<CodeSpan> old, IReadOnlyList<CodeSpan> @new, CodeRange editedRange, int changeInLength, int length)
    {
        var delta = changeInLength;
        var editStart = editedRange.Location;
        var editEnd = editedRange.End;
        var oldEditEnd = editEnd - delta;

        var head = 0;
        while (head < old.Count && head < @new.Count && old[head] == @new[head] && old[head].End <= editStart) head++;
        var tail = 0;
        while (tail < old.Count - head && tail < @new.Count - head)
        {
            var o = old[old.Count - 1 - tail];
            var m = @new[@new.Count - 1 - tail];
            if (o.Kind != m.Kind || o.Location < oldEditEnd || o.Length != m.Length || o.Location + delta != m.Location) break;
            tail++;
        }

        int Mapped(int x) => x <= editStart ? x : x >= oldEditEnd ? x + delta : editEnd;
        int lo = editStart, hi = editEnd;
        for (var k = head; k < @new.Count - tail; k++)
        {
            lo = Math.Min(lo, @new[k].Location);
            hi = Math.Max(hi, @new[k].End);
        }
        for (var k = head; k < old.Count - tail; k++)
        {
            lo = Math.Min(lo, Mapped(old[k].Location));
            hi = Math.Max(hi, Mapped(old[k].End));
        }
        hi = Math.Min(hi, length);
        lo = Math.Min(lo, hi);
        return new CodeRange(lo, hi - lo);
    }
}

// Language rules

internal static class U
{
    public const char Tab = '\t', Newline = '\n', Cr = '\r', Space = ' ';
    public const char Quote = '"', Hash = '#', Dollar = '$', Amp = '&', Apostrophe = '\'';
    public const char Plus = '+', Dash = '-', Dot = '.', Slash = '/', Colon = ':';
    public const char Lt = '<', EqualsSign = '=', Gt = '>', Question = '?', At = '@';
    public const char LBracket = '[', Backslash = '\\', RBracket = ']', Underscore = '_';
    public const char Backtick = '`', LBrace = '{', RBrace = '}', Bang = '!', Semicolon = ';';

    public static bool IsSpace(char c) => c == Space || c == Tab;
    public static bool IsWhitespace(char c) => c == Space || c == Tab || c == Newline || c == Cr;
    public static bool IsDigit(char c) => c >= '0' && c <= '9';
    public static bool IsUpper(char c) => c >= 'A' && c <= 'Z';
    public static bool IsLower(char c) => c >= 'a' && c <= 'z';
    public static bool IsLetter(char c) => IsUpper(c) || IsLower(c);
    public static bool IsAlphanumeric(char c) => IsLetter(c) || IsDigit(c);
    public static bool IsHighSurrogate(char c) => c >= 0xD800 && c <= 0xDBFF;
}

/// <summary>An ASCII word of up to 18 characters packed into 7 bits per character, so keyword lookups never allocate.</summary>
internal readonly record struct Word(ulong A, ulong B)
{
    public static Word? Make(string s, int start, int end, bool foldCase)
    {
        if (end - start > 18) return null;
        ulong a = 0, b = 0;
        for (var i = start; i < end; i++)
        {
            var u = s[i];
            if (u >= 128) return null;
            if (foldCase && U.IsUpper(u)) u = (char)(u + 32);
            if (i - start < 9) a = a << 7 | u; else b = b << 7 | u;
        }
        return new Word(a, b);
    }

    public static HashSet<Word> Set(string words, bool foldCase = false)
    {
        var set = new HashSet<Word>();
        foreach (var word in words.Split(' ', StringSplitOptions.RemoveEmptyEntries))
            if (Make(word, 0, word.Length, foldCase) is { } w) set.Add(w);
        return set;
    }
}

internal sealed class StringRule(string open, string? close = null, bool escapes = true, bool multiline = false)
{
    public readonly string Open = open;
    public readonly string Close = close ?? open;
    public readonly bool Escapes = escapes;
    public readonly bool Multiline = multiline;
}

internal sealed class BlockComment(string open, string close, bool nests)
{
    public readonly string Open = open;
    public readonly string Close = close;
    public readonly bool Nests = nests;
}

internal sealed class Syntax
{
    public HashSet<Word> Keywords = [];
    public HashSet<Word> Literals = [];
    public bool FoldCase;
    public string[] LineComments = [];
    /// <summary>'#' starts a comment only at line start or after whitespace (shell, YAML, INI).</summary>
    public bool CommentNeedsSpace;
    public BlockComment? BlockComment;
    public StringRule[] Strings = [];
    /// <summary>Quotes open a string only at a value boundary, so it's in a plain YAML value stays plain.</summary>
    public bool StringsNeedBoundary;
    /// <summary>'a', '\n': single quotes as character literals only, so Rust lifetimes stay plain.</summary>
    public bool CharLiterals;
    public bool Types;
    public bool IdentifierDash;
    public bool IdentifierDollar;
    /// <summary>@attribute, #directive.</summary>
    public char[] DirectivePrefixes = [];
    /// <summary>$name, ${name}, $1.</summary>
    public bool Variables;
    /// <summary>A string followed by this character is a key.</summary>
    public char? KeySeparator;
    /// <summary>Bare keys at line start followed by this character.</summary>
    public char? LineKeySeparator;
    public bool SignedNumbers;
    public bool Sections;
    public bool YamlBlockScalars;
    public bool Css;

    private static readonly Dictionary<CodeLanguage, Syntax> Cache = [];

    public static Syntax Of(CodeLanguage language)
    {
        lock (Cache)
        {
            if (!Cache.TryGetValue(language, out var syntax)) Cache[language] = syntax = Build(language);
            return syntax;
        }
    }

    private static BlockComment SlashComments => new("/*", "*/", false);

    private static Syntax Build(CodeLanguage language)
    {
        var x = new Syntax();
        switch (language)
        {
            case CodeLanguage.Json:
                x.Literals = Word.Set("true false null");
                x.Strings = [new StringRule("\"")];
                x.KeySeparator = U.Colon;
                x.SignedNumbers = true;
                // JSONC (settings files) comments come free.
                x.LineComments = ["//"];
                x.BlockComment = SlashComments;
                break;
            case CodeLanguage.Swift:
                x.Keywords = Word.Set(
                    "associatedtype class deinit enum extension fileprivate func import init inout internal let open operator " +
                    "private precedencegroup protocol public rethrows static struct subscript typealias var break case catch " +
                    "continue default defer do else fallthrough for guard if in repeat return throw switch where while as is " +
                    "try await async throws actor any some Self self super get set willSet didSet lazy weak unowned mutating " +
                    "nonmutating override final required convenience dynamic indirect nonisolated isolated consuming borrowing " +
                    "macro");
                x.Literals = Word.Set("true false nil");
                x.LineComments = ["//"];
                x.BlockComment = new BlockComment("/*", "*/", true);
                x.Strings = [new StringRule("\"\"\"", multiline: true), new StringRule("\"")];
                x.Types = true;
                x.DirectivePrefixes = [U.At, U.Hash];
                break;
            case CodeLanguage.JavaScript:
                x.Keywords = Word.Set(
                    "break case catch class const continue debugger default delete do else export extends finally for function " +
                    "if import in instanceof new return super switch this throw try typeof var void while with yield let static " +
                    "async await enum implements interface package private protected public namespace declare abstract " +
                    "readonly as from keyof satisfies override");
                x.Literals = Word.Set("true false null undefined NaN Infinity");
                x.LineComments = ["//"];
                x.BlockComment = SlashComments;
                x.Strings = [new StringRule("`", multiline: true), new StringRule("\""), new StringRule("'")];
                x.Types = true;
                x.IdentifierDollar = true;
                x.DirectivePrefixes = [U.At];
                break;
            case CodeLanguage.Python:
                x.Keywords = Word.Set(
                    "and as assert async await break class continue def del elif else except finally for from global if " +
                    "import in is lambda nonlocal not or pass raise return try while with yield self");
                x.Literals = Word.Set("True False None");
                x.LineComments = ["#"];
                x.Strings =
                [
                    new StringRule("\"\"\"", multiline: true), new StringRule("'''", multiline: true),
                    new StringRule("\""), new StringRule("'"),
                ];
                x.Types = true;
                x.DirectivePrefixes = [U.At];
                break;
            case CodeLanguage.Shell:
                x.Keywords = Word.Set(
                    "if then else elif fi for while until do done case esac in function select return local export readonly " +
                    "declare typeset unset shift break continue exit source alias trap eval exec");
                x.Literals = Word.Set("true false");
                x.LineComments = ["#"];
                x.CommentNeedsSpace = true;
                x.Strings =
                [
                    new StringRule("\"", multiline: true), new StringRule("'", escapes: false, multiline: true),
                    new StringRule("`", multiline: true),
                ];
                x.IdentifierDash = true;
                x.Variables = true;
                break;
            case CodeLanguage.Yaml:
                x.Literals = Word.Set("true false null yes no", foldCase: true);
                x.FoldCase = true;
                x.LineComments = ["#"];
                x.CommentNeedsSpace = true;
                x.Strings = [new StringRule("\""), new StringRule("'", escapes: false)];
                x.StringsNeedBoundary = true;
                x.KeySeparator = U.Colon;
                x.LineKeySeparator = U.Colon;
                x.IdentifierDash = true;
                x.SignedNumbers = true;
                x.YamlBlockScalars = true;
                break;
            case CodeLanguage.Css:
                x.Keywords = Word.Set("important");
                x.Literals = Word.Set("none auto inherit initial unset transparent");
                x.BlockComment = SlashComments;
                x.Strings = [new StringRule("\""), new StringRule("'")];
                x.IdentifierDash = true;
                x.DirectivePrefixes = [U.At];
                x.Css = true;
                break;
            case CodeLanguage.CFamily:
                x.Keywords = Word.Set(
                    "auto break case char const continue default do double else enum extern float for goto if inline int long " +
                    "register restrict return short signed sizeof static struct switch typedef union unsigned void volatile " +
                    "while bool class namespace template typename public private protected virtual override final new delete " +
                    "this throw throws try catch using operator friend explicit constexpr noexcept decltype mutable " +
                    "static_cast dynamic_cast reinterpret_cast const_cast concept requires self super instancetype " +
                    "abstract assert boolean byte extends finally implements import instanceof interface native package " +
                    "synchronized transient var sealed permits yield fun val when companion is in lateinit internal suspend " +
                    "reified typealias readonly ref string decimal async await foreach partial unsafe where func go defer " +
                    "chan fallthrough as crate dyn fn impl let loop match mod mut pub trait use Self");
                x.Literals = Word.Set("true false null nullptr nil NULL YES NO");
                x.LineComments = ["//"];
                x.BlockComment = SlashComments;
                x.Strings =
                [
                    new StringRule("\"\"\"", multiline: true), new StringRule("\""),
                    new StringRule("`", escapes: false, multiline: true),
                ];
                x.CharLiterals = true;
                x.Types = true;
                x.DirectivePrefixes = [U.At, U.Hash];
                break;
            case CodeLanguage.Sql:
                x.Keywords = Word.Set(
                    "select from where insert into values update set delete create table drop alter add column index primary " +
                    "key foreign references join inner left right outer full cross on as and or not in is like between exists " +
                    "group by order having limit offset union all distinct case when then else end begin commit rollback " +
                    "transaction view trigger default unique check constraint if with returning desc asc cascade database " +
                    "schema replace", foldCase: true);
                x.Literals = Word.Set("null true false", foldCase: true);
                x.FoldCase = true;
                x.LineComments = ["--"];
                x.BlockComment = SlashComments;
                x.Strings = [new StringRule("'", escapes: false, multiline: true), new StringRule("\"")];
                break;
            case CodeLanguage.Toml:
                x.Literals = Word.Set("true false");
                x.LineComments = ["#", ";"];
                x.CommentNeedsSpace = true;
                x.Strings =
                [
                    new StringRule("\"\"\"", multiline: true), new StringRule("'''", escapes: false, multiline: true),
                    new StringRule("\""), new StringRule("'", escapes: false),
                ];
                x.KeySeparator = U.EqualsSign;
                x.LineKeySeparator = U.EqualsSign;
                x.SignedNumbers = true;
                x.Sections = true;
                break;
        }
        return x;
    }
}

// Tokenizer

internal sealed class Tokenizer
{
    private readonly string s;
    private readonly int n;
    private readonly Syntax x;
    public readonly List<CodeSpan> Spans = [];
    /// <summary>Inside a CSS declaration value, between prop: and ; or }.</summary>
    private bool cssInValue;
    /// <summary>Column of the YAML key whose | or > block scalar is open.</summary>
    private int? blockScalarColumn;

    private const string NoKeyStart = "#;\"'[{\n\r&*!|>";
    private const string ValueBoundaryPunct = ":[{,-?";
    private const string VariableSpecials = "@*#?$!-";

    public Tokenizer(string text, Syntax syntax)
    {
        s = text;
        n = text.Length;
        x = syntax;
    }

    private void Add(int start, int end, CodeSpanKind kind)
    {
        end = Math.Min(end, n);
        if (end <= start) return;
        Spans.Add(new CodeSpan(start, end - start, kind));
    }

    private bool Matches(string token, int i) => i + token.Length <= n && string.CompareOrdinal(s, i, token, 0, token.Length) == 0;

    private int LineEnd(int i)
    {
        var j = i;
        while (j < n && s[j] != U.Newline) j++;
        return j;
    }

    private int SkipSpaces(int i)
    {
        var j = i;
        while (j < n && U.IsSpace(s[j])) j++;
        return j;
    }

    private bool IsIdentifierStart(char u) =>
        U.IsLetter(u) || u == U.Underscore || u >= 0x80 || (x.IdentifierDollar && u == U.Dollar);

    private bool IsIdentifierPart(char u) =>
        U.IsAlphanumeric(u) || u == U.Underscore || u >= 0x80
        || (x.IdentifierDollar && u == U.Dollar) || (x.IdentifierDash && u == U.Dash);

    public void Run()
    {
        var i = 0;
        var lineStart = 0;
        var atLineStart = true;
        while (i < n)
        {
            var c = s[i];
            if (c == U.Newline)
            {
                i++;
                lineStart = i;
                atLineStart = true;
                continue;
            }
            if (atLineStart)
            {
                if (U.IsSpace(c) || c == U.Cr) { i++; continue; }
                atLineStart = false;
                if (LineStartRules(i, i - lineStart) is { } next) { i = next; continue; }
            }
            i = Token(i);
        }
    }

    /// <summary>YAML block scalars, line keys and section headers. Returns where to continue, or null to tokenize normally.</summary>
    private int? LineStartRules(int i, int column)
    {
        if (blockScalarColumn is { } open)
        {
            if (column > open)
            {
                var end = LineEnd(i);
                Add(i, end, CodeSpanKind.String);
                return end;
            }
            blockScalarColumn = null;
        }
        if (x.Sections && s[i] == U.LBracket)
        {
            var end = LineEnd(i);
            var close = end;
            while (close > i && s[close - 1] != U.RBracket) close--;
            if (close <= i) return null;
            Add(i, close, CodeSpanKind.Tag);
            return close;
        }
        if (x.LineKeySeparator is not { } separator) return null;
        var k = i;
        if (separator == U.Colon)
        {
            while (k < n && s[k] == U.Dash && (k + 1 == n || U.IsWhitespace(s[k + 1]))) k = SkipSpaces(k + 1);
        }
        if (k >= n || NoKeyStart.Contains(s[k])) return null;
        var j = k;
        while (j < n && s[j] != U.Newline)
        {
            if (s[j] == separator && (separator != U.Colon || j + 1 == n || U.IsWhitespace(s[j + 1]))) break;
            if (s[j] == U.Hash && j > k && U.IsSpace(s[j - 1])) return null;
            if (separator == U.EqualsSign && (s[j] == U.Quote || s[j] == U.Apostrophe)) return null;
            j++;
        }
        if (j >= n || s[j] != separator) return null;
        var keyEnd = j;
        while (keyEnd > k && U.IsSpace(s[keyEnd - 1])) keyEnd--;
        Add(k, keyEnd, CodeSpanKind.Property);
        if (x.YamlBlockScalars) CheckBlockScalar(j + 1, k - (i - column));
        return j + 1;
    }

    /// <summary>"key: |" or "key: >-" opens a block scalar: following lines indented deeper than the key are text.</summary>
    private void CheckBlockScalar(int i, int column)
    {
        var j = SkipSpaces(i);
        if (j >= n || (s[j] != '|' && s[j] != U.Gt)) return;
        j++;
        while (j < n && (s[j] == U.Dash || s[j] == U.Plus || U.IsDigit(s[j]))) j++;
        j = SkipSpaces(j);
        if (j == n || s[j] == U.Newline || s[j] == U.Cr || s[j] == U.Hash) blockScalarColumn = column;
    }

    private int Token(int i)
    {
        var c = s[i];
        if (x.BlockComment is { } block && Matches(block.Open, i)) return BlockCommentAt(i, block);
        foreach (var prefix in x.LineComments)
        {
            if (!Matches(prefix, i)) continue;
            if (x.CommentNeedsSpace && i > 0 && !U.IsWhitespace(s[i - 1])) continue;
            var end = LineEnd(i);
            Add(i, end, CodeSpanKind.Comment);
            return end;
        }
        if (c == U.Quote || c == U.Apostrophe || c == U.Backtick)
        {
            foreach (var rule in x.Strings)
            {
                if (!Matches(rule.Open, i)) continue;
                if (x.StringsNeedBoundary && i > 0 && !IsValueBoundary(s[i - 1])) break;
                return StringAt(i, rule);
            }
            if (x.CharLiterals && c == U.Apostrophe && CharLiteral(i) is { } end)
            {
                Add(i, end, CodeSpanKind.String);
                return end;
            }
            return i + 1;
        }
        var previousIsWord = i > 0 && IsIdentifierPart(s[i - 1]);
        if (!previousIsWord)
        {
            if (U.IsDigit(c)
                || (c == U.Dot && i + 1 < n && U.IsDigit(s[i + 1]) && (i == 0 || s[i - 1] != U.Dot))
                || (x.SignedNumbers && c == U.Dash && i + 1 < n && U.IsDigit(s[i + 1])))
                return Number(i);
        }
        if (IsIdentifierStart(c) || (x.Css && c == U.Dash && i + 1 < n && (U.IsLetter(s[i + 1]) || s[i + 1] == U.Dash)))
            return Word(i);
        if (Array.IndexOf(x.DirectivePrefixes, c) >= 0 && i + 1 < n && IsIdentifierStart(s[i + 1]))
        {
            var end = IdentifierEnd(i + 1);
            Add(i, end, CodeSpanKind.Keyword);
            return end;
        }
        if (x.Variables && c == U.Dollar) return Variable(i);
        if (x.Css) return CssPunctuation(i);
        return i + 1;
    }

    private static bool IsValueBoundary(char u) => U.IsWhitespace(u) || ValueBoundaryPunct.Contains(u);

    private int IdentifierEnd(int i)
    {
        var j = i;
        while (j < n && IsIdentifierPart(s[j])) j++;
        return j;
    }

    private int BlockCommentAt(int i, BlockComment block)
    {
        var depth = 1;
        var j = i + block.Open.Length;
        while (j < n)
        {
            if (Matches(block.Close, j))
            {
                j += block.Close.Length;
                depth--;
                if (depth == 0) break;
            }
            else if (block.Nests && Matches(block.Open, j))
            {
                j += block.Open.Length;
                depth++;
            }
            else
            {
                j++;
            }
        }
        Add(i, j, CodeSpanKind.Comment);
        return Math.Min(j, n);
    }

    /// <summary>Unterminated strings end at the line end, or at the end of the text when they may span lines.</summary>
    private int StringAt(int i, StringRule rule)
    {
        var j = i + rule.Open.Length;
        var closed = false;
        while (j < n)
        {
            var u = s[j];
            if (rule.Escapes && u == U.Backslash) { j += 2; continue; }
            if (u == U.Newline && !rule.Multiline) break;
            if (u == rule.Close[0] && Matches(rule.Close, j)) { j += rule.Close.Length; closed = true; break; }
            j++;
        }
        j = Math.Min(j, n);
        if (closed && x.KeySeparator is { } separator)
        {
            var k = SkipSpaces(j);
            if (k < n && s[k] == separator)
            {
                Add(i, j, CodeSpanKind.Property);
                return j;
            }
        }
        Add(i, j, CodeSpanKind.String);
        return j;
    }

    private int? CharLiteral(int i)
    {
        if (i + 2 >= n) return null;
        if (s[i + 1] == U.Backslash)
        {
            var j = i + 2;
            while (j < n && j < i + 12 && s[j] != U.Newline)
            {
                if (s[j] == U.Apostrophe && j > i + 2) return j + 1;
                j++;
            }
            return null;
        }
        var close = i + 1 + (U.IsHighSurrogate(s[i + 1]) ? 2 : 1);
        return close < n && s[close] == U.Apostrophe && s[i + 1] != U.Newline ? close + 1 : null;
    }

    private int Number(int i)
    {
        var j = i + 1;
        var hex = s[i] == '0' && j < n && (s[j] == 'x' || s[j] == 'X');
        while (j < n)
        {
            var u = s[j];
            if (U.IsAlphanumeric(u) || u == U.Underscore) j++;
            else if (u == U.Dot && j + 1 < n && U.IsDigit(s[j + 1])) j++;
            else if ((u == U.Plus || u == U.Dash) && !hex && (s[j - 1] == 'e' || s[j - 1] == 'E')) j++;
            else break;
        }
        Add(i, j, CodeSpanKind.Number);
        return j;
    }

    private int Word(int i)
    {
        var end = IdentifierEnd(i + 1);
        if (NotesCore.Word.Make(s, i, end, x.FoldCase) is { } word)
        {
            if (x.Keywords.Contains(word)) { Add(i, end, CodeSpanKind.Keyword); return end; }
            if (x.Literals.Contains(word)) { Add(i, end, CodeSpanKind.Literal); return end; }
        }
        if (x.Css)
        {
            if (!cssInValue && IsDeclaration(end))
            {
                Add(i, end, CodeSpanKind.Property);
                cssInValue = true;
            }
        }
        else if (x.Types && U.IsUpper(s[i]) && HasLower(i + 1, end))
        {
            Add(i, end, CodeSpanKind.Type);
        }
        return end;
    }

    private bool HasLower(int from, int to)
    {
        for (var k = from; k < to; k++) if (U.IsLower(s[k])) return true;
        return false;
    }

    private int Variable(int i)
    {
        if (i + 1 >= n) return i + 1;
        var u = s[i + 1];
        if (u == U.LBrace)
        {
            var j = i + 2;
            while (j < n && s[j] != U.RBrace && s[j] != U.Newline) j++;
            var end = j < n && s[j] == U.RBrace ? j + 1 : j;
            Add(i, end, CodeSpanKind.Property);
            return end;
        }
        if (U.IsAlphanumeric(u) || u == U.Underscore)
        {
            var j = i + 2;
            while (j < n && (U.IsAlphanumeric(s[j]) || s[j] == U.Underscore)) j++;
            Add(i, j, CodeSpanKind.Property);
            return j;
        }
        if (VariableSpecials.Contains(u))
        {
            Add(i, i + 2, CodeSpanKind.Property);
            return i + 2;
        }
        return i + 1;
    }

    /// <summary>"name:" followed by ; or } before any {, so a:hover { stays a selector.</summary>
    private bool IsDeclaration(int end)
    {
        var k = SkipSpaces(end);
        if (k >= n || s[k] != U.Colon) return false;
        while (k < n)
        {
            switch (s[k])
            {
                case U.LBrace: return false;
                case U.Semicolon or U.RBrace: return true;
                default: k++; break;
            }
        }
        return true;
    }

    /// <summary>#id and .class are selectors, #fff in a value is a color.</summary>
    private int CssPunctuation(int i)
    {
        var c = s[i];
        if (c is U.LBrace or U.RBrace or U.Semicolon)
        {
            cssInValue = false;
        }
        else if (c == U.Hash && i + 1 < n && IsIdentifierPart(s[i + 1]))
        {
            var end = IdentifierEnd(i + 1);
            Add(i, end, cssInValue ? CodeSpanKind.Number : CodeSpanKind.Type);
            return end;
        }
        else if (c == U.Dot && !cssInValue && i + 1 < n && IsIdentifierStart(s[i + 1]))
        {
            var end = IdentifierEnd(i + 1);
            Add(i, end, CodeSpanKind.Type);
            return end;
        }
        return i + 1;
    }
}

// Markup

internal sealed class MarkupTokenizer
{
    private readonly string s;
    private readonly int n;
    public readonly List<CodeSpan> Spans = [];

    private const string CommentOpen = "<!--", CommentClose = "-->";
    private const string CdataOpen = "<![CDATA[", CdataClose = "]]>";
    private static readonly string[] RawTextElements = ["script", "style"];

    public MarkupTokenizer(string text)
    {
        s = text;
        n = text.Length;
    }

    private void Add(int start, int end, CodeSpanKind kind)
    {
        end = Math.Min(end, n);
        if (end <= start) return;
        Spans.Add(new CodeSpan(start, end - start, kind));
    }

    private bool Matches(string token, int i) => i + token.Length <= n && string.CompareOrdinal(s, i, token, 0, token.Length) == 0;

    private static bool IsNameStart(char u) => U.IsLetter(u) || u == U.Underscore || u == U.Colon || u >= 0x80;
    private static bool IsNamePart(char u) => IsNameStart(u) || U.IsDigit(u) || u == U.Dash || u == U.Dot;

    /// <summary>Index just past <paramref name="close"/>, or the end of the text when it never comes.</summary>
    private int Find(string close, int from)
    {
        var j = from;
        while (j < n)
        {
            if (s[j] == close[0] && Matches(close, j)) return j + close.Length;
            j++;
        }
        return n;
    }

    public void Run()
    {
        var i = 0;
        while (i < n)
        {
            switch (s[i])
            {
                case U.Lt:
                    if (Matches(CommentOpen, i))
                    {
                        var end = Find(CommentClose, i + 4);
                        Add(i, end, CodeSpanKind.Comment);
                        i = end;
                    }
                    else if (Matches(CdataOpen, i))
                    {
                        var end = Find(CdataClose, i + 9);
                        Add(i, end, CodeSpanKind.String);
                        i = end;
                    }
                    else if (i + 1 < n && s[i + 1] == U.Bang)
                    {
                        var end = Find(">", i + 2);
                        Add(i, end, CodeSpanKind.Keyword);
                        i = end;
                    }
                    else if (i + 1 < n && (s[i + 1] == U.Slash || s[i + 1] == U.Question || IsNameStart(s[i + 1])))
                    {
                        i = Tag(i);
                    }
                    else
                    {
                        i++;
                    }
                    break;
                case U.Amp:
                    i = Entity(i);
                    break;
                default:
                    i++;
                    break;
            }
        }
    }

    private int Tag(int i)
    {
        var closing = s[i + 1] == U.Slash;
        var j = i + 1;
        if (closing || s[j] == U.Question) j++;
        var nameStart = j;
        while (j < n && IsNamePart(s[j])) j++;
        Add(i, j, CodeSpanKind.Tag);
        var name = j - nameStart is >= 5 and <= 6 ? AsciiLower(s[nameStart..j]) : "";

        var afterEquals = false;
        while (j < n)
        {
            var u = s[j];
            if (U.IsWhitespace(u)) { j++; continue; }
            if (u == U.Gt)
            {
                Add(j, j + 1, CodeSpanKind.Tag);
                return !closing && Array.IndexOf(RawTextElements, name) >= 0 ? RawText(j + 1, name) : j + 1;
            }
            if ((u == U.Slash || u == U.Question) && j + 1 < n && s[j + 1] == U.Gt)
            {
                Add(j, j + 2, CodeSpanKind.Tag);
                return j + 2;
            }
            if (u == U.Lt) return j;
            if (u == U.EqualsSign) { afterEquals = true; j++; continue; }
            var k = j;
            if (u == U.Quote || u == U.Apostrophe)
            {
                k = j + 1;
                while (k < n && s[k] != u) k++;
                k = Math.Min(k + 1, n);
                Add(j, k, CodeSpanKind.String);
            }
            else
            {
                while (k < n && !U.IsWhitespace(s[k]) && s[k] != U.EqualsSign && s[k] != U.Gt && s[k] != U.Lt
                       && s[k] != U.Quote && s[k] != U.Apostrophe
                       && !((s[k] == U.Slash || s[k] == U.Question) && k + 1 < n && s[k + 1] == U.Gt)) k++;
                if (k == j) k++; else Add(j, k, afterEquals ? CodeSpanKind.String : CodeSpanKind.Property);
            }
            afterEquals = false;
            j = k;
        }
        return j;
    }

    /// <summary>ASCII-only case folding; non-ASCII letters stay as they are and never match a tag name.</summary>
    private static string AsciiLower(string text) =>
        string.Create(text.Length, text, static (span, source) =>
        {
            for (var k = 0; k < span.Length; k++) span[k] = source[k] is >= 'A' and <= 'Z' ? (char)(source[k] + 32) : source[k];
        });

    /// <summary>script and style content is not markup; skip to the closing tag.</summary>
    private int RawText(int i, string name)
    {
        var close = "</" + name;
        var j = i;
        while (j < n)
        {
            if (s[j] == U.Lt && j + close.Length <= n)
            {
                var all = true;
                for (var k = 0; k < close.Length; k++)
                {
                    var c = s[j + k];
                    if (!(c == close[k] || (U.IsUpper(c) && c + 32 == close[k]))) { all = false; break; }
                }
                if (all) return j;
            }
            j++;
        }
        return n;
    }

    private int Entity(int i)
    {
        var j = i + 1;
        if (j < n && s[j] == U.Hash) j++;
        while (j < n && j < i + 32 && U.IsAlphanumeric(s[j])) j++;
        if (j >= n || s[j] != U.Semicolon || j <= i + 1) return i + 1;
        Add(i, j + 1, CodeSpanKind.Literal);
        return j + 1;
    }
}
