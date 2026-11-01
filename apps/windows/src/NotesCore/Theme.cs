using System.Globalization;
using System.Text;
using System.Text.Json;

namespace NotesCore;

// Themes (docs/themes.md): colors, errors, the theme model, JSON reading with the strict grammar, the library of
// built-in and user themes. Pure logic, no UI types; the same files work in the macOS app.

// MARK: Color

/// <summary>An sRGB color with 8-bit channels, written as <c>#RRGGBB</c> or <c>#RRGGBBAA</c> in theme files.</summary>
public readonly record struct ThemeColor(byte Red, byte Green, byte Blue, byte Alpha = 255)
{
    public static readonly ThemeColor White = new(255, 255, 255);
    public static readonly ThemeColor Black = new(0, 0, 0);

    /// <summary>Strict: <c>#</c> followed by exactly 6 or 8 hex digits (either case), nothing else.</summary>
    public static bool TryParse(string hex, out ThemeColor color)
    {
        color = default;
        if (hex.Length is not (7 or 9) || hex[0] != '#') return false;
        Span<byte> bytes = stackalloc byte[4];
        var count = 0;
        for (var i = 1; i < hex.Length; i += 2)
        {
            if (HexValue(hex[i]) is not { } high || HexValue(hex[i + 1]) is not { } low) return false;
            bytes[count++] = (byte)(high << 4 | low);
        }
        color = new ThemeColor(bytes[0], bytes[1], bytes[2], count == 4 ? bytes[3] : (byte)255);
        return true;
    }

    /// <summary>Like <see cref="TryParse"/>, throwing a <see cref="ThemeException"/> with <see cref="ThemeErrorKind.InvalidColor"/>.</summary>
    public static ThemeColor Parse(string hex) =>
        TryParse(hex, out var color) ? color : throw new ThemeException(ThemeError.InvalidColor(hex));

    private static int? HexValue(char c) => c switch
    {
        >= '0' and <= '9' => c - '0',
        >= 'a' and <= 'f' => c - 'a' + 10,
        >= 'A' and <= 'F' => c - 'A' + 10,
        _ => null,
    };

    /// <summary>Uppercase <c>#RRGGBB</c>, or <c>#RRGGBBAA</c> when not opaque.</summary>
    public string Hex => Alpha == 255 ? $"#{Red:X2}{Green:X2}{Blue:X2}" : $"#{Red:X2}{Green:X2}{Blue:X2}{Alpha:X2}";

    public override string ToString() => Hex;

    public double RedComponent => Red / 255.0;
    public double GreenComponent => Green / 255.0;
    public double BlueComponent => Blue / 255.0;
    public double AlphaComponent => Alpha / 255.0;

    /// <summary>This color blended over an opaque <paramref name="background"/> (source-over), as it appears on screen.</summary>
    public ThemeColor CompositedOver(ThemeColor background)
    {
        var a = AlphaComponent;
        static byte Mix(byte top, byte bottom, double a) => (byte)Math.Round(top * a + bottom * (1 - a), MidpointRounding.AwayFromZero);
        return new ThemeColor(Mix(Red, background.Red, a), Mix(Green, background.Green, a), Mix(Blue, background.Blue, a));
    }

    /// <summary>WCAG 2 relative luminance of the color's RGB channels (alpha ignored).</summary>
    public double RelativeLuminance
    {
        get
        {
            static double Linear(byte v)
            {
                var c = v / 255.0;
                return c <= 0.04045 ? c / 12.92 : Math.Pow((c + 0.055) / 1.055, 2.4);
            }
            return 0.2126 * Linear(Red) + 0.7152 * Linear(Green) + 0.0722 * Linear(Blue);
        }
    }

    public ThemeColor Opaque => new(Red, Green, Blue);

    /// <summary>
    /// WCAG 2 contrast ratio (1 to 21) of <paramref name="foreground"/> drawn on <paramref name="background"/>. A translucent
    /// foreground is composited over the background; the background's own alpha is ignored, so composite a translucent
    /// background over whatever lies beneath it first (<see cref="ResolvedTheme.ContrastRatio"/> does that with the theme background).
    /// </summary>
    public static double ContrastRatio(ThemeColor foreground, ThemeColor background)
    {
        var opaqueBackground = background.Opaque;
        var opaqueForeground = foreground.Alpha == 255 ? foreground : foreground.CompositedOver(opaqueBackground);
        double l1 = opaqueForeground.RelativeLuminance, l2 = opaqueBackground.RelativeLuminance;
        return (Math.Max(l1, l2) + 0.05) / (Math.Min(l1, l2) + 0.05);
    }
}

// MARK: Errors

public enum ThemeErrorKind
{
    InvalidColor,
    /// <summary>The file is valid JSON but not an object.</summary>
    InvalidJson,
    /// <summary>The file breaks the JSON grammar in docs/themes.md.</summary>
    MalformedJson,
    NotUtf8,
    MissingField,
    InvalidValue,
    FileTooLarge,
    TooManyFiles,
    Unreadable,
    DuplicateId,
}

/// <summary>A theme problem; compares by value. <see cref="Message"/> is in the UI language (reasons are localized when the error is made).</summary>
/// <param name="Text">The offending color, field, id or reason, depending on the kind.</param>
/// <param name="Reason">What is wrong with <see cref="ThemeErrorKind.InvalidValue"/> and <see cref="ThemeErrorKind.MalformedJson"/>.</param>
public readonly record struct ThemeError(ThemeErrorKind Kind, string Text = "", string Reason = "", int Line = 0)
{
    public static ThemeError InvalidColor(string value) => new(ThemeErrorKind.InvalidColor, value);
    public static ThemeError InvalidJson => new(ThemeErrorKind.InvalidJson);
    public static ThemeError MalformedJson(int line, string reason) => new(ThemeErrorKind.MalformedJson, Reason: reason, Line: line);
    public static ThemeError NotUtf8 => new(ThemeErrorKind.NotUtf8);
    public static ThemeError MissingField(string field) => new(ThemeErrorKind.MissingField, field);
    public static ThemeError InvalidValue(string field, string reason) => new(ThemeErrorKind.InvalidValue, field, reason);
    public static ThemeError FileTooLarge => new(ThemeErrorKind.FileTooLarge);
    public static ThemeError TooManyFiles => new(ThemeErrorKind.TooManyFiles);
    public static ThemeError Unreadable(string reason) => new(ThemeErrorKind.Unreadable, Reason: reason);
    public static ThemeError DuplicateId(string id) => new(ThemeErrorKind.DuplicateId, id);

    public string Message => Kind switch
    {
        ThemeErrorKind.InvalidColor => Strings.Format("ThemeInvalidColor", Text),
        ThemeErrorKind.InvalidJson => Strings.Get("ThemeInvalidJson"),
        ThemeErrorKind.MalformedJson => Strings.Format("ThemeMalformedJson", Line, Reason),
        ThemeErrorKind.NotUtf8 => Strings.Get("ThemeNotUtf8"),
        ThemeErrorKind.MissingField => Strings.Format("ThemeMissingField", Text),
        ThemeErrorKind.InvalidValue => Strings.Format("ThemeInvalidValue", Text, Reason),
        ThemeErrorKind.FileTooLarge => Strings.Get("ThemeFileTooLarge"),
        ThemeErrorKind.TooManyFiles => Strings.Format("ThemeTooManyFiles", ThemeLibrary.MaxFileCount),
        ThemeErrorKind.Unreadable => Strings.Format("ThemeUnreadable", Reason),
        _ => Strings.Format("ThemeDuplicateId", Text),
    };

    public override string ToString() => Message;
}

public sealed class ThemeException(ThemeError error) : Exception
{
    public ThemeError Error { get; } = error;

    public override string Message => Error.Message;
}

// MARK: Theme

public enum ThemeAppearance
{
    Light,
    Dark,
}

public static class ThemeAppearanceExtensions
{
    public static string DisplayName(this ThemeAppearance appearance) =>
        Strings.Get(appearance == ThemeAppearance.Light ? "AppearanceLight" : "AppearanceDark");

    /// <summary>The raw value used in theme files and settings.</summary>
    public static string RawValue(this ThemeAppearance appearance) => appearance == ThemeAppearance.Light ? "light" : "dark";
}

/// <summary>The app-wide appearance setting.</summary>
public enum AppearanceMode
{
    System,
    Light,
    Dark,
}

public static class AppearanceModeExtensions
{
    public static string DisplayName(this AppearanceMode mode) => Strings.Get(mode switch
    {
        AppearanceMode.System => "AppearanceSystem",
        AppearanceMode.Light => "AppearanceLight",
        _ => "AppearanceDark",
    });

    /// <summary>The raw value used in settings (<c>system</c>, <c>light</c>, <c>dark</c>).</summary>
    public static string RawValue(this AppearanceMode mode) => mode switch
    {
        AppearanceMode.System => "system",
        AppearanceMode.Light => "light",
        _ => "dark",
    };

    /// <summary>The appearance to draw with, given what the system currently uses.</summary>
    public static ThemeAppearance EffectiveAppearance(this AppearanceMode mode, ThemeAppearance system) => mode switch
    {
        AppearanceMode.System => system,
        AppearanceMode.Light => ThemeAppearance.Light,
        _ => ThemeAppearance.Dark,
    };
}

/// <summary>What the user picked: the appearance mode plus one theme for each appearance.</summary>
public sealed record ThemePreferences
{
    public AppearanceMode Mode { get; init; } = AppearanceMode.System;
    public string LightThemeId { get; init; } = ThemeLibrary.DefaultLightId;
    public string DarkThemeId { get; init; } = ThemeLibrary.DefaultDarkId;

    public string ThemeId(ThemeAppearance appearance) => appearance == ThemeAppearance.Light ? LightThemeId : DarkThemeId;

    /// <summary>
    /// Lenient: a missing or malformed key falls back to its default without losing the others, and so does unreadable
    /// JSON as a whole. Unknown theme ids are kept; <see cref="ThemeLibrary"/> falls back when it resolves them.
    /// </summary>
    public static ThemePreferences FromJson(string json)
    {
        try
        {
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object) return new ThemePreferences();
            string? Text(string key) =>
                root.TryGetProperty(key, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;
            var mode = Text("mode");
            return new ThemePreferences
            {
                Mode = mode switch
                {
                    "light" => AppearanceMode.Light,
                    "dark" => AppearanceMode.Dark,
                    _ => AppearanceMode.System,
                },
                LightThemeId = Text("lightThemeID") ?? ThemeLibrary.DefaultLightId,
                DarkThemeId = Text("darkThemeID") ?? ThemeLibrary.DefaultDarkId,
            };
        }
        catch (JsonException)
        {
            return new ThemePreferences();
        }
    }

    /// <summary>The keys the macOS app uses: <c>mode</c>, <c>lightThemeID</c>, <c>darkThemeID</c>.</summary>
    public string ToJson() => new StringBuilder("{")
        .Append("\"darkThemeID\":").Append(ThemeJson.Quote(DarkThemeId))
        .Append(",\"lightThemeID\":").Append(ThemeJson.Quote(LightThemeId))
        .Append(",\"mode\":").Append(ThemeJson.Quote(Mode.RawValue()))
        .Append('}').ToString();
}

/// <summary>Editor colors of a theme; every one optional (missing values come from the base theme).</summary>
public sealed record ThemeColors
{
    /// <summary>Editor background.</summary>
    public ThemeColor? Background { get; init; }
    public ThemeColor? Text { get; init; }
    public ThemeColor? SecondaryText { get; init; }
    /// <summary>Dimmed Markdown syntax: <c>#</c>, <c>**</c>, backtick, <c>&gt;</c>, list and link punctuation.</summary>
    public ThemeColor? Marker { get; init; }
    public ThemeColor? Heading { get; init; }
    public ThemeColor? Link { get; init; }
    public ThemeColor? InlineCode { get; init; }
    public ThemeColor? InlineCodeBackground { get; init; }
    public ThemeColor? CodeBlockBackground { get; init; }
    public ThemeColor? Blockquote { get; init; }
    public ThemeColor? Selection { get; init; }
    public ThemeColor? Cursor { get; init; }
    public ThemeColor? Accent { get; init; }
    /// <summary>Band behind the line with the caret. Derived from <see cref="Text"/> when missing, see <see cref="ResolvedTheme.DerivedCurrentLine"/>.</summary>
    public ThemeColor? CurrentLine { get; init; }
}

/// <summary>One color per <see cref="CodeSpanKind"/>.</summary>
public sealed record ThemeSyntax
{
    public ThemeColor? Keyword { get; init; }
    public ThemeColor? String { get; init; }
    public ThemeColor? Number { get; init; }
    public ThemeColor? Comment { get; init; }
    public ThemeColor? Literal { get; init; }
    public ThemeColor? Type { get; init; }
    public ThemeColor? Property { get; init; }
    public ThemeColor? Tag { get; init; }
}

/// <summary>
/// A theme as written in a JSON file. Everything except <see cref="Name"/> and <see cref="Appearance"/> is optional;
/// missing values come from the default built-in theme of the same appearance (see docs/themes.md).
/// </summary>
public sealed record Theme
{
    public required string Id { get; init; }
    public required string Name { get; init; }
    public required ThemeAppearance Appearance { get; init; }
    public ThemeColors Colors { get; init; } = new();
    public ThemeSyntax Syntax { get; init; } = new();

    /// <summary>The name to show: built-in themes are named in the UI language (their <see cref="Name"/> is data), others use <see cref="Name"/>.</summary>
    public string DisplayName => Id switch
    {
        "default-light" => Strings.Get("ThemeDefaultLight"),
        "sepia" => Strings.Get("ThemeSepia"),
        "paper" => Strings.Get("ThemePaper"),
        "default-dark" => Strings.Get("ThemeDefaultDark"),
        "midnight" => Strings.Get("ThemeMidnight"),
        "ocean" => Strings.Get("ThemeOcean"),
        _ => Name,
    };

    /// <summary>Applies the same normalization and validation as reading a file (trims, NFC); throws a <see cref="ThemeException"/>.</summary>
    public static Theme Create(string id, string name, ThemeAppearance appearance, ThemeColors? colors = null, ThemeSyntax? syntax = null) =>
        new Theme { Id = id, Name = name, Appearance = appearance, Colors = colors ?? new(), Syntax = syntax ?? new() }.Normalized();

    /// <summary>Trims <see cref="Id"/> and <see cref="Name"/>, normalizes them to NFC, then validates.</summary>
    public Theme Normalized()
    {
        static string Clean(string s) => s.Trim().Normalize(NormalizationForm.FormC);
        var theme = this with { Id = Clean(Id), Name = Clean(Name) };
        if (theme.Id.Length == 0) throw new ThemeException(ThemeError.InvalidValue("id", Strings.Get("ThemeMustNotBeEmpty")));
        if (theme.Name.Length == 0) throw new ThemeException(ThemeError.InvalidValue("name", Strings.Get("ThemeMustNotBeEmpty")));
        return theme;
    }

    /// <summary>
    /// Decodes a theme file. <paramref name="fallbackId"/> (usually the file name) is used when the JSON has no <c>id</c>.
    /// The bytes must follow the strict grammar in docs/themes.md (UTF-8, no comments, no trailing commas, no duplicate
    /// keys, depth at most 64). Errors are <see cref="ThemeException"/>s naming the offending field.
    /// </summary>
    public static Theme Decode(byte[] data, string? fallbackId = null)
    {
        var bytes = data.AsSpan();
        if (bytes.StartsWith(new byte[] { 0xEF, 0xBB, 0xBF })) bytes = bytes[3..];
        if (bytes.Contains((byte)0)) throw new ThemeException(ThemeError.NotUtf8);
        try { _ = new UTF8Encoding(false, throwOnInvalidBytes: true).GetCharCount(bytes); }
        catch (DecoderFallbackException) { throw new ThemeException(ThemeError.NotUtf8); }
        var array = bytes.ToArray();
        new StrictJsonValidator(array).Run();

        using var document = JsonDocument.Parse(array, new JsonDocumentOptions { MaxDepth = 64 });
        return ThemeJson.Read(document.RootElement, fallbackId);
    }

    public static Theme Decode(string json, string? fallbackId = null) => Decode(Encoding.UTF8.GetBytes(json), fallbackId);

    /// <summary>
    /// Pretty-printed JSON with only the fields that are set, ready to save as a user theme.
    /// Normalizes and validates first, like <see cref="Create"/>, so what it writes always reads back.
    /// </summary>
    public byte[] EncodedJson() => Encoding.UTF8.GetBytes(ThemeJson.Write(Normalized()));

    /// <summary>Fills every missing value from <paramref name="baseTheme"/>. The editor background is always opaque (its alpha is ignored).</summary>
    public ResolvedTheme ResolvedOver(ResolvedTheme baseTheme)
    {
        ThemeColors c = Colors;
        ResolvedColors b = baseTheme.Colors;
        ThemeSyntax s = Syntax;
        ResolvedSyntax bs = baseTheme.Syntax;
        var text = c.Text ?? b.Text;
        return new ResolvedTheme
        {
            Id = Id,
            Name = Name,
            Appearance = Appearance,
            Colors = new ResolvedColors
            {
                Background = (c.Background ?? b.Background).Opaque,
                Text = text,
                SecondaryText = c.SecondaryText ?? b.SecondaryText,
                Marker = c.Marker ?? b.Marker,
                Heading = c.Heading ?? b.Heading,
                Link = c.Link ?? b.Link,
                InlineCode = c.InlineCode ?? b.InlineCode,
                InlineCodeBackground = c.InlineCodeBackground ?? b.InlineCodeBackground,
                CodeBlockBackground = c.CodeBlockBackground ?? b.CodeBlockBackground,
                Blockquote = c.Blockquote ?? b.Blockquote,
                Selection = c.Selection ?? b.Selection,
                Cursor = c.Cursor ?? b.Cursor,
                Accent = c.Accent ?? b.Accent,
                CurrentLine = c.CurrentLine ?? ResolvedTheme.DerivedCurrentLine(text, Appearance),
            },
            Syntax = new ResolvedSyntax
            {
                Keyword = s.Keyword ?? bs.Keyword,
                String = s.String ?? bs.String,
                Number = s.Number ?? bs.Number,
                Comment = s.Comment ?? bs.Comment,
                Literal = s.Literal ?? bs.Literal,
                Type = s.Type ?? bs.Type,
                Property = s.Property ?? bs.Property,
                Tag = s.Tag ?? bs.Tag,
            },
        };
    }
}

/// <summary>Reading and writing a theme's JSON (the grammar is checked by <see cref="StrictJsonValidator"/> first).</summary>
internal static class ThemeJson
{
    private static ThemeException Invalid(string field, string reason) => new(ThemeError.InvalidValue(field, reason));

    private static string Expected(string what) => Strings.Format("ThemeExpected", Strings.Get(what));

    /// <summary>The property's value, or <c>null</c> when it is missing or JSON <c>null</c>.</summary>
    private static JsonElement? Optional(JsonElement obj, string name) =>
        obj.TryGetProperty(name, out var value) && value.ValueKind != JsonValueKind.Null ? value : null;

    private static string RequiredString(JsonElement obj, string name)
    {
        if (!obj.TryGetProperty(name, out var value)) throw new ThemeException(ThemeError.MissingField(name));
        if (value.ValueKind == JsonValueKind.Null) throw Invalid(name, Strings.Get("ThemeMustNotBeNull"));
        if (value.ValueKind != JsonValueKind.String) throw Invalid(name, Expected("ThemeExpectedString"));
        return value.GetString()!;
    }

    public static Theme Read(JsonElement root, string? fallbackId)
    {
        string? id = null;
        if (Optional(root, "id") is { } idElement)
        {
            if (idElement.ValueKind != JsonValueKind.String) throw Invalid("id", Expected("ThemeExpectedString"));
            id = idElement.GetString();
        }
        id ??= fallbackId ?? throw new ThemeException(ThemeError.MissingField("id"));
        var name = RequiredString(root, "name");
        var appearance = RequiredString(root, "appearance") switch
        {
            "light" => ThemeAppearance.Light,
            "dark" => ThemeAppearance.Dark,
            _ => throw Invalid("appearance", Strings.Get("ThemeBadAppearance")),
        };
        var colors = new ThemeColors();
        if (Section(root, "colors") is { } c)
        {
            colors = new ThemeColors
            {
                Background = Color(c, "colors", "background"),
                Text = Color(c, "colors", "text"),
                SecondaryText = Color(c, "colors", "secondaryText"),
                Marker = Color(c, "colors", "marker"),
                Heading = Color(c, "colors", "heading"),
                Link = Color(c, "colors", "link"),
                InlineCode = Color(c, "colors", "inlineCode"),
                InlineCodeBackground = Color(c, "colors", "inlineCodeBackground"),
                CodeBlockBackground = Color(c, "colors", "codeBlockBackground"),
                Blockquote = Color(c, "colors", "blockquote"),
                Selection = Color(c, "colors", "selection"),
                Cursor = Color(c, "colors", "cursor"),
                Accent = Color(c, "colors", "accent"),
                CurrentLine = Color(c, "colors", "currentLine"),
            };
        }
        var syntax = new ThemeSyntax();
        if (Section(root, "syntax") is { } s)
        {
            syntax = new ThemeSyntax
            {
                Keyword = Color(s, "syntax", "keyword"),
                String = Color(s, "syntax", "string"),
                Number = Color(s, "syntax", "number"),
                Comment = Color(s, "syntax", "comment"),
                Literal = Color(s, "syntax", "literal"),
                Type = Color(s, "syntax", "type"),
                Property = Color(s, "syntax", "property"),
                Tag = Color(s, "syntax", "tag"),
            };
        }
        return new Theme { Id = id, Name = name, Appearance = appearance, Colors = colors, Syntax = syntax }.Normalized();
    }

    private static JsonElement? Section(JsonElement root, string name)
    {
        if (Optional(root, name) is not { } value) return null;
        return value.ValueKind == JsonValueKind.Object ? value : throw Invalid(name, Expected("ThemeExpectedObject"));
    }

    private static ThemeColor? Color(JsonElement section, string sectionName, string key)
    {
        if (Optional(section, key) is not { } value) return null;
        var field = $"{sectionName}.{key}";
        if (value.ValueKind != JsonValueKind.String) throw Invalid(field, Expected("ThemeExpectedString"));
        return ThemeColor.TryParse(value.GetString()!, out var color) ? color : throw Invalid(field, Strings.Get("ThemeBadColor"));
    }

    /// <summary>Pretty-printed with sorted keys, only the set fields (the layout Foundation's encoder gives on macOS).</summary>
    public static string Write(Theme theme)
    {
        var sb = new StringBuilder("{\n");
        sb.Append("  \"appearance\" : ").Append(Quote(theme.Appearance.RawValue())).Append(",\n");
        sb.Append("  \"colors\" : ");
        WriteObject(sb, [
            ("accent", theme.Colors.Accent), ("background", theme.Colors.Background), ("blockquote", theme.Colors.Blockquote),
            ("codeBlockBackground", theme.Colors.CodeBlockBackground), ("currentLine", theme.Colors.CurrentLine),
            ("cursor", theme.Colors.Cursor), ("heading", theme.Colors.Heading), ("inlineCode", theme.Colors.InlineCode),
            ("inlineCodeBackground", theme.Colors.InlineCodeBackground), ("link", theme.Colors.Link),
            ("marker", theme.Colors.Marker), ("secondaryText", theme.Colors.SecondaryText),
            ("selection", theme.Colors.Selection), ("text", theme.Colors.Text),
        ]);
        sb.Append(",\n  \"id\" : ").Append(Quote(theme.Id)).Append(",\n");
        sb.Append("  \"name\" : ").Append(Quote(theme.Name)).Append(",\n");
        sb.Append("  \"syntax\" : ");
        WriteObject(sb, [
            ("comment", theme.Syntax.Comment), ("keyword", theme.Syntax.Keyword), ("literal", theme.Syntax.Literal),
            ("number", theme.Syntax.Number), ("property", theme.Syntax.Property), ("string", theme.Syntax.String),
            ("tag", theme.Syntax.Tag), ("type", theme.Syntax.Type),
        ]);
        return sb.Append("\n}").ToString();
    }

    private static void WriteObject(StringBuilder sb, (string Key, ThemeColor? Value)[] entries)
    {
        var set = entries.Where(e => e.Value is not null).ToList();
        if (set.Count == 0)
        {
            sb.Append("{\n  }");
            return;
        }
        sb.Append("{\n");
        sb.Append(string.Join(",\n", set.Select(e => $"    {Quote(e.Key)} : {Quote(e.Value!.Value.Hex)}")));
        sb.Append("\n  }");
    }

    /// <summary>A JSON string literal: control characters, quotes and backslashes escaped, everything else (also non-ASCII and slashes) as it is.</summary>
    public static string Quote(string value)
    {
        var sb = new StringBuilder("\"");
        foreach (var c in value)
        {
            switch (c)
            {
                case '"': sb.Append("\\\""); break;
                case '\\': sb.Append("\\\\"); break;
                case '\n': sb.Append("\\n"); break;
                case '\r': sb.Append("\\r"); break;
                case '\t': sb.Append("\\t"); break;
                case '\b': sb.Append("\\b"); break;
                case '\f': sb.Append("\\f"); break;
                case < ' ': sb.Append("\\u").Append(((int)c).ToString("x4", CultureInfo.InvariantCulture)); break;
                default: sb.Append(c); break;
            }
        }
        return sb.Append('"').ToString();
    }
}

/// <summary>A theme with every value filled in, ready for the editor.</summary>
public sealed record ResolvedTheme
{
    public required string Id { get; init; }
    public required string Name { get; init; }
    public required ThemeAppearance Appearance { get; init; }
    public required ResolvedColors Colors { get; init; }
    public required ResolvedSyntax Syntax { get; init; }

    /// <summary>
    /// The current-line band of a theme that does not set one: the text colour at 6% (light) or 8% (dark) opacity,
    /// drawn over whatever lies beneath, so it is a neutral grey that follows the theme.
    /// </summary>
    public static ThemeColor DerivedCurrentLine(ThemeColor text, ThemeAppearance appearance) =>
        new(text.Red, text.Green, text.Blue, appearance == ThemeAppearance.Light ? (byte)0x0F : (byte)0x14);

    /// <summary>
    /// Contrast of <paramref name="foreground"/> on <paramref name="background"/> (default: the editor background) as drawn
    /// by this theme: a translucent background is composited over the editor background, then a translucent foreground over that.
    /// </summary>
    public double ContrastRatio(ThemeColor foreground, ThemeColor? background = null)
    {
        var canvas = (background ?? Colors.Background).CompositedOver(Colors.Background);
        return ThemeColor.ContrastRatio(foreground, canvas);
    }
}

public sealed record ResolvedColors
{
    public required ThemeColor Background { get; init; }
    public required ThemeColor Text { get; init; }
    public required ThemeColor SecondaryText { get; init; }
    public required ThemeColor Marker { get; init; }
    public required ThemeColor Heading { get; init; }
    public required ThemeColor Link { get; init; }
    public required ThemeColor InlineCode { get; init; }
    public required ThemeColor InlineCodeBackground { get; init; }
    public required ThemeColor CodeBlockBackground { get; init; }
    public required ThemeColor Blockquote { get; init; }
    public required ThemeColor Selection { get; init; }
    public required ThemeColor Cursor { get; init; }
    public required ThemeColor Accent { get; init; }
    public required ThemeColor CurrentLine { get; init; }
}

public sealed record ResolvedSyntax
{
    public required ThemeColor Keyword { get; init; }
    public required ThemeColor String { get; init; }
    public required ThemeColor Number { get; init; }
    public required ThemeColor Comment { get; init; }
    public required ThemeColor Literal { get; init; }
    public required ThemeColor Type { get; init; }
    public required ThemeColor Property { get; init; }
    public required ThemeColor Tag { get; init; }

    public ThemeColor this[CodeSpanKind kind] => kind switch
    {
        CodeSpanKind.Keyword => Keyword,
        CodeSpanKind.String => String,
        CodeSpanKind.Number => Number,
        CodeSpanKind.Comment => Comment,
        CodeSpanKind.Literal => Literal,
        CodeSpanKind.Type => Type,
        CodeSpanKind.Property => Property,
        _ => Tag,
    };
}

// MARK: Library

/// <summary>Built-in themes plus the user's themes loaded from a directory of <c>.json</c> files.</summary>
public sealed class ThemeLibrary
{
    /// <summary>A file that was skipped.</summary>
    public readonly record struct Issue(string File, ThemeError Error)
    {
        public override string ToString() => $"{Path.GetFileName(File)}: {Error.Message}";
    }

    public const string DefaultLightId = "default-light";
    public const string DefaultDarkId = "default-dark";
    public const int MaxFileSize = 1_000_000;
    /// <summary>More <c>.json</c> files than this (in file-name order) are reported as <see cref="ThemeErrorKind.TooManyFiles"/> and not read.</summary>
    public const int MaxFileCount = 500;

    public static IReadOnlyList<Theme> BuiltInThemes { get; } = BuiltInThemeJson.Json.Select(json =>
    {
        try { return Theme.Decode(json); }
        catch (ThemeException e) { throw new InvalidOperationException($"Built-in theme does not decode: {e.Message}", e); }
    }).ToList();

    public static bool IsBuiltIn(string id) => BuiltInThemes.Any(theme => theme.Id == id);

    private static readonly ResolvedTheme BaseLight = Complete(DefaultLightId);
    private static readonly ResolvedTheme BaseDark = Complete(DefaultDarkId);

    /// <summary>The complete built-in theme every theme of <paramref name="appearance"/> falls back to.</summary>
    public static ResolvedTheme BaseTheme(ThemeAppearance appearance) => appearance == ThemeAppearance.Light ? BaseLight : BaseDark;

    private static ResolvedTheme Complete(string id)
    {
        var theme = BuiltInThemes.First(t => t.Id == id);
        ThemeColors c = theme.Colors;
        ThemeSyntax s = theme.Syntax;
        ThemeColor V(ThemeColor? color) => color ?? throw new InvalidOperationException($"Base theme {id} must set every color");
        return new ResolvedTheme
        {
            Id = theme.Id,
            Name = theme.Name,
            Appearance = theme.Appearance,
            Colors = new ResolvedColors
            {
                Background = V(c.Background), Text = V(c.Text), SecondaryText = V(c.SecondaryText), Marker = V(c.Marker),
                Heading = V(c.Heading), Link = V(c.Link), InlineCode = V(c.InlineCode),
                InlineCodeBackground = V(c.InlineCodeBackground), CodeBlockBackground = V(c.CodeBlockBackground),
                Blockquote = V(c.Blockquote), Selection = V(c.Selection), Cursor = V(c.Cursor), Accent = V(c.Accent),
                CurrentLine = c.CurrentLine ?? ResolvedTheme.DerivedCurrentLine(V(c.Text), theme.Appearance),
            },
            Syntax = new ResolvedSyntax
            {
                Keyword = V(s.Keyword), String = V(s.String), Number = V(s.Number), Comment = V(s.Comment),
                Literal = V(s.Literal), Type = V(s.Type), Property = V(s.Property), Tag = V(s.Tag),
            },
        };
    }

    /// <summary>Like Finder's name order: case, accents and width ignored, digit runs by value.</summary>
    private const CompareOptions StandardCompare = CompareOptions.IgnoreCase | CompareOptions.IgnoreNonSpace
        | CompareOptions.IgnoreKanaType | CompareOptions.IgnoreWidth | CompareOptions.NumericOrdering;

    private readonly List<Theme> userThemes = [];
    private readonly List<Issue> issues = [];
    private readonly Dictionary<string, string> userFiles = new(StringComparer.Ordinal);

    /// <summary>User themes sorted by name, then id.</summary>
    public IReadOnlyList<Theme> UserThemes => userThemes;

    /// <summary>Files that were skipped, in file-name order.</summary>
    public IReadOnlyList<Issue> Issues => issues;

    /// <summary>
    /// Loads every <c>*.json</c> file directly inside <paramref name="userDirectory"/> (hidden files and subfolders are
    /// ignored; links are followed). A missing directory simply means no user themes. Nothing here throws.
    /// Does synchronous file IO (up to <see cref="MaxFileCount"/> files of <see cref="MaxFileSize"/> bytes): build it off the UI thread.
    /// </summary>
    public ThemeLibrary(string? userDirectory = null)
    {
        if (userDirectory is null) return;
        List<FileSystemInfo> entries;
        try
        {
            entries = new DirectoryInfo(userDirectory).EnumerateFileSystemInfos().ToList();
        }
        catch (DirectoryNotFoundException) when (!File.Exists(userDirectory))
        {
            return;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            issues.Add(new Issue(userDirectory, ThemeError.Unreadable(e.Message)));
            return;
        }
        var seen = new HashSet<string>(BuiltInThemes.Select(t => t.Id), StringComparer.Ordinal);
        var loaded = 0;
        var files = entries
            .Where(e => !e.Name.StartsWith('.') && !e.Attributes.HasFlag(FileAttributes.Hidden)
                        && e.Name.EndsWith(".json", StringComparison.OrdinalIgnoreCase)
                        && !e.Attributes.HasFlag(FileAttributes.Directory))
            .Select(e => (Name: e.Name.Normalize(NormalizationForm.FormC), Path: e.FullName))
            // Ordinal by Unicode scalar value of the NFC name (= UTF-8 byte order), see docs/themes.md.
            .OrderBy(f => f.Name, Utf8Order.Instance)
            .ToList();
        foreach (var (name, file) in files)
        {
            try
            {
                var target = ResolveFile(file);
                if (target is null) continue; // a link to a directory
                loaded++;
                if (loaded > MaxFileCount) throw new ThemeException(ThemeError.TooManyFiles);
                var theme = Load(target, name[..^5]);
                if (!seen.Add(theme.Id)) throw new ThemeException(ThemeError.DuplicateId(theme.Id));
                userThemes.Add(theme);
                userFiles[theme.Id] = file;
            }
            catch (ThemeException e)
            {
                issues.Add(new Issue(file, e.Error));
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                issues.Add(new Issue(file, ThemeError.Unreadable(e.Message)));
            }
        }
        userThemes.Sort((a, b) =>
        {
            var byName = string.Compare(a.Name, b.Name, CultureInfo.InvariantCulture, StandardCompare);
            return byName != 0 ? byName : string.CompareOrdinal(a.Id, b.Id);
        });
    }

    /// <summary>The file a link points to; <c>null</c> when it is a directory (ignored like one).</summary>
    private static string? ResolveFile(string file)
    {
        var info = Native.Query(file);
        if (info is null)
        {
            // A broken link or a file that can't be opened: let the open attempt name the problem.
            using (new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete)) { }
            throw new ThemeException(ThemeError.Unreadable(Strings.Get("ThemeNotRegularFile")));
        }
        return info.Value.IsDirectory ? null : info.Value.FinalPath;
    }

    private static Theme Load(string file, string fallbackId)
    {
        var info = Native.Query(file);
        if (info is null || ((int)File.GetAttributes(file) & 0x40) != 0) // FILE_ATTRIBUTE_DEVICE
            throw new ThemeException(ThemeError.Unreadable(Strings.Get("ThemeNotRegularFile")));
        if (info.Value.Size > MaxFileSize) throw new ThemeException(ThemeError.FileTooLarge);
        byte[] data;
        using (var stream = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
        {
            data = new byte[MaxFileSize + 1];
            var total = 0;
            int count;
            while (total < data.Length && (count = stream.Read(data, total, data.Length - total)) > 0) total += count;
            if (total > MaxFileSize) throw new ThemeException(ThemeError.FileTooLarge);
            Array.Resize(ref data, total);
        }
        return Theme.Decode(data, fallbackId);
    }

    /// <summary>Built-ins first (in their fixed order), then user themes.</summary>
    public IReadOnlyList<Theme> Themes => [.. BuiltInThemes, .. userThemes];

    public IReadOnlyList<Theme> ThemesFor(ThemeAppearance appearance) => Themes.Where(t => t.Appearance == appearance).ToList();

    /// <summary>The theme with this id; ids compare exactly (ordinal) after NFC, so a decomposed spelling finds the same theme.</summary>
    public Theme? Find(string id)
    {
        id = id.Normalize(NormalizationForm.FormC);
        return Themes.FirstOrDefault(t => t.Id == id);
    }

    /// <summary>The JSON file a user theme came from; <c>null</c> for built-ins.</summary>
    public string? FileForThemeId(string id) => userFiles.GetValueOrDefault(id);

    public ResolvedTheme Resolved(Theme theme) => theme.ResolvedOver(BaseTheme(theme.Appearance));

    /// <summary>The theme to draw with. An unknown id, or a theme of the other appearance, falls back to the default for <paramref name="appearance"/>.</summary>
    public ResolvedTheme ThemeFor(string id, ThemeAppearance appearance) =>
        Find(id) is { } theme && theme.Appearance == appearance ? Resolved(theme) : BaseTheme(appearance);

    public ResolvedTheme ThemeFor(ThemePreferences preferences, ThemeAppearance systemAppearance)
    {
        var appearance = preferences.Mode.EffectiveAppearance(systemAppearance);
        return ThemeFor(preferences.ThemeId(appearance), appearance);
    }

    /// <summary>Compares strings by their UTF-8 bytes (= by Unicode scalar value), not by UTF-16 code units.</summary>
    private sealed class Utf8Order : IComparer<string>
    {
        public static readonly Utf8Order Instance = new();

        public int Compare(string? x, string? y) =>
            Encoding.UTF8.GetBytes(x ?? "").AsSpan().SequenceCompareTo(Encoding.UTF8.GetBytes(y ?? ""));
    }
}

// MARK: Built-in themes

/// <summary>Stored as the same JSON a user would write (see docs/themes.md).</summary>
internal static class BuiltInThemeJson
{
    public static readonly string[] Json = [DefaultLight, Sepia, Paper, DefaultDark, Midnight, Ocean];

    private const string DefaultLight = """
        {
          "id": "default-light",
          "name": "Varsayılan Açık",
          "appearance": "light",
          "colors": {
            "background": "#FAFAFA",
            "text": "#1B1B1B",
            "secondaryText": "#5F5F5F",
            "marker": "#767676",
            "heading": "#1B1B1B",
            "link": "#2F6396",
            "inlineCode": "#1B1B1B",
            "inlineCodeBackground": "#F1F1F1",
            "codeBlockBackground": "#F1F1F1",
            "blockquote": "#5F5F5F",
            "selection": "#B3D7FF",
            "cursor": "#007AFF",
            "accent": "#007AFF"
          },
          "syntax": {
            "keyword": "#8C4A6B",
            "string": "#8A5A3C",
            "number": "#3F6A95",
            "comment": "#767676",
            "literal": "#8C4A6B",
            "type": "#2F7771",
            "property": "#6E5A94",
            "tag": "#3F6A95"
          }
        }
        """;

    private const string Sepia = """
        {
          "id": "sepia",
          "name": "Sepya",
          "appearance": "light",
          "colors": {
            "background": "#F4ECD8",
            "text": "#3B2F23",
            "secondaryText": "#6F5F4B",
            "marker": "#8F7C66",
            "heading": "#3B2F23",
            "link": "#3F6280",
            "inlineCode": "#3B2F23",
            "inlineCodeBackground": "#EADFC6",
            "codeBlockBackground": "#EEE4CE",
            "blockquote": "#6F5F4B",
            "selection": "#DCC79A",
            "cursor": "#6F5F4B",
            "accent": "#6B543C"
          },
          "syntax": {
            "keyword": "#7C4A61",
            "string": "#7A5836",
            "number": "#45688C",
            "comment": "#8F7C66",
            "literal": "#7C4A61",
            "type": "#47655B",
            "property": "#6B4E80",
            "tag": "#45688C"
          }
        }
        """;

    private const string Paper = """
        {
          "id": "paper",
          "name": "Kağıt",
          "appearance": "light",
          "colors": {
            "background": "#FAFAF7",
            "text": "#2B2B2B",
            "secondaryText": "#6B6B66",
            "marker": "#7C7C76",
            "heading": "#2B2B2B",
            "link": "#2F5D8C",
            "inlineCode": "#2B2B2B",
            "inlineCodeBackground": "#EFEFEA",
            "codeBlockBackground": "#F2F2EE",
            "blockquote": "#6B6B66",
            "selection": "#D8E2EC",
            "cursor": "#2B2B2B",
            "accent": "#2F5D8C"
          },
          "syntax": {
            "keyword": "#7A4F66",
            "string": "#7A5A3E",
            "number": "#3F6A95",
            "comment": "#7C7C76",
            "literal": "#7A4F66",
            "type": "#4F6F6B",
            "property": "#6A5A86",
            "tag": "#3F6A95"
          }
        }
        """;

    private const string DefaultDark = """
        {
          "id": "default-dark",
          "name": "Varsayılan Koyu",
          "appearance": "dark",
          "colors": {
            "background": "#272727",
            "text": "#E3E3E3",
            "secondaryText": "#C5C5C5",
            "marker": "#8A8A8A",
            "heading": "#E3E3E3",
            "link": "#8DB4DE",
            "inlineCode": "#E3E3E3",
            "inlineCodeBackground": "#313131",
            "codeBlockBackground": "#313131",
            "blockquote": "#C5C5C5",
            "selection": "#3F638B",
            "cursor": "#0A84FF",
            "accent": "#0A84FF"
          },
          "syntax": {
            "keyword": "#D18AA8",
            "string": "#C9A27F",
            "number": "#86A9D1",
            "comment": "#8A8A8A",
            "literal": "#D18AA8",
            "type": "#7FBAB3",
            "property": "#A99BD0",
            "tag": "#86A9D1"
          }
        }
        """;

    private const string Midnight = """
        {
          "id": "midnight",
          "name": "Gece Mavisi",
          "appearance": "dark",
          "colors": {
            "background": "#141B2D",
            "text": "#D8DEE9",
            "secondaryText": "#A4AEC2",
            "marker": "#7C88A3",
            "heading": "#D8DEE9",
            "link": "#8DB4DE",
            "inlineCode": "#D8DEE9",
            "inlineCodeBackground": "#1E2740",
            "codeBlockBackground": "#19213A",
            "blockquote": "#A4AEC2",
            "selection": "#2E4373",
            "cursor": "#7AB8FF",
            "accent": "#6E9BD6"
          },
          "syntax": {
            "keyword": "#C79BB8",
            "string": "#C4A385",
            "number": "#8FAAD0",
            "comment": "#7C88A3",
            "literal": "#C79BB8",
            "type": "#82B8B0",
            "property": "#A79BCB",
            "tag": "#8FAAD0"
          }
        }
        """;

    private const string Ocean = """
        {
          "id": "ocean",
          "name": "Okyanus",
          "appearance": "dark",
          "colors": {
            "background": "#0F2229",
            "text": "#D4E6E8",
            "secondaryText": "#A6BEC2",
            "marker": "#7D9CA3",
            "heading": "#D4E6E8",
            "link": "#8DB4DE",
            "inlineCode": "#D4E6E8",
            "inlineCodeBackground": "#173039",
            "codeBlockBackground": "#132A32",
            "blockquote": "#A6BEC2",
            "selection": "#1F4D5A",
            "cursor": "#5CD0E6",
            "accent": "#6FAEB8"
          },
          "syntax": {
            "keyword": "#C79BB8",
            "string": "#C4A385",
            "number": "#8FAAC4",
            "comment": "#7D9CA3",
            "literal": "#C79BB8",
            "type": "#82B8B0",
            "property": "#A79BCB",
            "tag": "#8FAAC4"
          }
        }
        """;
}

// MARK: Strict JSON

/// <summary>
/// Checks the theme-file JSON grammar (RFC 8259 plus the limits in docs/themes.md) before <c>System.Text.Json</c> sees the
/// bytes, so both platforms agree on every file: duplicate keys, comments, trailing commas and depth are checked here.
/// Expects valid UTF-8 without a BOM.
/// </summary>
internal sealed class StrictJsonValidator(byte[] bytes)
{
    public const int MaxDepth = 64;

    private readonly byte[] s = bytes;
    private int i;
    private int line = 1;
    private readonly List<string> path = [];

    public void Run()
    {
        SkipWhitespace();
        if (Peek != (byte)'{')
        {
            if (Peek == (byte)'/') throw Fail(Strings.Get("ThemeNoComments"));
            throw new ThemeException(ThemeError.InvalidJson);
        }
        Value(1);
        SkipWhitespace();
        if (i != s.Length) throw Unexpected(Strings.Get("ThemeExtraContent"));
    }

    private int Peek => i < s.Length ? s[i] : -1;

    private ThemeException Fail(string reason) => new(ThemeError.MalformedJson(line, reason));

    private ThemeException Unexpected(string reason) => Peek switch
    {
        -1 => Fail(Strings.Get("ThemeFileEnded")),
        '/' => Fail(Strings.Get("ThemeNoComments")),
        _ => Fail(reason),
    };

    private void SkipWhitespace()
    {
        while (Peek is var c and >= 0)
        {
            switch (c)
            {
                case 0x20 or 0x09 or 0x0D: i++; break;
                case 0x0A: i++; line++; break;
                default: return;
            }
        }
    }

    private void Value(int depth)
    {
        switch (Peek)
        {
            case -1: throw Unexpected(Strings.Get("ThemeValueExpected"));
            case '{': Object(depth); break;
            case '[': Array(depth); break;
            case '"': _ = String(); break;
            case 't': Word("true"); break;
            case 'f': Word("false"); break;
            case 'n': Word("null"); break;
            case '-' or (>= '0' and <= '9'): Number(); break;
            default: throw Unexpected(Strings.Get("ThemeValueExpected"));
        }
    }

    private void CheckDepth(int depth)
    {
        if (depth > MaxDepth) throw Fail(Strings.Format("ThemeTooDeep", MaxDepth));
    }

    private void Object(int depth)
    {
        CheckDepth(depth);
        i++;
        SkipWhitespace();
        if (Peek == '}') { i++; return; }
        var keys = new HashSet<string>(StringComparer.Ordinal);
        while (true)
        {
            SkipWhitespace();
            if (Peek != '"')
                throw Unexpected(Peek == '}' ? Strings.Get("ThemeTrailingComma") : Strings.Get("ThemeKeyExpected"));
            var key = String();
            if (!keys.Add(key))
                throw new ThemeException(ThemeError.InvalidValue(string.Join('.', path.Append(key)), Strings.Get("ThemeDuplicateKey")));
            SkipWhitespace();
            if (Peek != ':') throw Unexpected(Strings.Get("ThemeColonExpected"));
            i++;
            SkipWhitespace();
            path.Add(key);
            Value(depth + 1);
            path.RemoveAt(path.Count - 1);
            SkipWhitespace();
            switch (Peek)
            {
                case ',': i++; break;
                case '}': i++; return;
                default: throw Unexpected(Strings.Get("ThemeCommaOrBrace"));
            }
        }
    }

    private void Array(int depth)
    {
        CheckDepth(depth);
        i++;
        SkipWhitespace();
        if (Peek == ']') { i++; return; }
        var index = 0;
        while (true)
        {
            SkipWhitespace();
            if (Peek == ']') throw Fail(Strings.Get("ThemeTrailingComma"));
            path.Add(index.ToString(CultureInfo.InvariantCulture));
            Value(depth + 1);
            path.RemoveAt(path.Count - 1);
            index++;
            SkipWhitespace();
            switch (Peek)
            {
                case ',': i++; break;
                case ']': i++; return;
                default: throw Unexpected(Strings.Get("ThemeCommaOrBracket"));
            }
        }
    }

    private void Word(string literal)
    {
        if (s.Length - i < literal.Length) throw Fail(Strings.Get("ThemeInvalidValueWord"));
        for (var k = 0; k < literal.Length; k++)
            if (s[i + k] != literal[k]) throw Fail(Strings.Get("ThemeInvalidValueWord"));
        i += literal.Length;
    }

    private int Digits()
    {
        var from = i;
        while (Peek is >= '0' and <= '9') i++;
        return i - from;
    }

    private void Number()
    {
        var start = i;
        if (Peek == '-') i++;
        if (Peek == '0') i++;
        else if (Digits() == 0) throw Fail(Strings.Get("ThemeBadNumber"));
        if (Peek == '.')
        {
            i++;
            if (Digits() == 0) throw Fail(Strings.Get("ThemeBadNumber"));
        }
        if (Peek is 'e' or 'E')
        {
            i++;
            if (Peek is '+' or '-') i++;
            if (Digits() == 0) throw Fail(Strings.Get("ThemeBadNumber"));
        }
        var text = Encoding.ASCII.GetString(s, start, i - start);
        if (!double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out var number) || !double.IsFinite(number))
            throw new ThemeException(ThemeError.InvalidValue(string.Join('.', path), Strings.Get("ThemeNumberTooLarge")));
    }

    /// <summary>Returns the decoded string. <c>i</c> is at the opening quote.</summary>
    private string String()
    {
        i++;
        var sb = new StringBuilder();
        while (true)
        {
            if (Peek == -1) throw Fail(Strings.Get("ThemeUnterminatedString"));
            var c = s[i];
            if (c == '"')
            {
                i++;
                return sb.ToString();
            }
            if (c < 0x20) throw Fail(Strings.Get("ThemeControlChar"));
            if (c == '\\')
            {
                i++;
                if (Peek == -1) throw Fail(Strings.Get("ThemeUnterminatedString"));
                var e = s[i++];
                switch (e)
                {
                    case (byte)'"': sb.Append('"'); break;
                    case (byte)'\\': sb.Append('\\'); break;
                    case (byte)'/': sb.Append('/'); break;
                    case (byte)'b': sb.Append('\b'); break;
                    case (byte)'f': sb.Append('\f'); break;
                    case (byte)'n': sb.Append('\n'); break;
                    case (byte)'r': sb.Append('\r'); break;
                    case (byte)'t': sb.Append('\t'); break;
                    case (byte)'u': sb.Append(UnicodeEscape()); break;
                    default: throw Fail(Strings.Get("ThemeBadEscape"));
                }
                continue;
            }
            // Already validated as UTF-8: decode one scalar.
            var length = c < 0x80 ? 1 : c < 0xE0 ? 2 : c < 0xF0 ? 3 : 4;
            var value = length == 1 ? c : c & (0xFF >> (length + 1));
            for (var k = 1; k < length; k++) value = value << 6 | (s[i + k] & 0x3F);
            i += length;
            sb.Append(char.ConvertFromUtf32(value));
        }
    }

    private int Hex4()
    {
        if (s.Length - i < 4) throw Fail(Strings.Get("ThemeBadUnicodeEscape"));
        var value = 0;
        for (var k = 0; k < 4; k++)
        {
            var c = (char)s[i];
            var digit = c switch
            {
                >= '0' and <= '9' => c - '0',
                >= 'a' and <= 'f' => c - 'a' + 10,
                >= 'A' and <= 'F' => c - 'A' + 10,
                _ => throw Fail(Strings.Get("ThemeBadUnicodeEscape")),
            };
            value = value << 4 | digit;
            i++;
        }
        return value;
    }

    /// <summary><c>i</c> is after <c>\u</c>. Surrogates must come as a valid pair.</summary>
    private string UnicodeEscape()
    {
        var first = Hex4();
        if (first is >= 0xDC00 and <= 0xDFFF) throw Fail(Strings.Get("ThemeUnpairedSurrogate"));
        if (first is not (>= 0xD800 and <= 0xDBFF)) return ((char)first).ToString();
        if (s.Length - i < 2 || s[i] != '\\' || s[i + 1] != 'u') throw Fail(Strings.Get("ThemeUnpairedSurrogate"));
        i += 2;
        var second = Hex4();
        if (second is not (>= 0xDC00 and <= 0xDFFF)) throw Fail(Strings.Get("ThemeUnpairedSurrogate"));
        return char.ConvertFromUtf32(0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00));
    }
}
