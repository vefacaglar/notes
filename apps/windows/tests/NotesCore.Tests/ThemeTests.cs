using System.Diagnostics;
using System.Text;
using NotesCore;

namespace NotesCore.Tests;

internal static class ThemeTestHelpers
{
    public static readonly string Head = "\"name\": \"A\", \"appearance\": \"light\"";

    public static ThemeError? Thrown(Action body)
    {
        try
        {
            body();
            return null;
        }
        catch (ThemeException e)
        {
            return e.Error;
        }
    }

    public static Theme Decode(string json) => Theme.Decode(Encoding.UTF8.GetBytes(json), "f");

    public static IEnumerable<ThemeColor> PaletteColors(Theme theme, bool includeControls)
    {
        var controls = new HashSet<string> { "Selection", "Cursor", "Accent" };
        foreach (var source in new object[] { theme.Colors, theme.Syntax })
            foreach (var property in source.GetType().GetProperties())
            {
                if (property.GetValue(source) is not ThemeColor color) continue;
                if (!includeControls && controls.Contains(property.Name)) continue;
                yield return color;
            }
    }
}

public class ThemeColorTests
{
    public static IEnumerable<object[]> ParseCases() =>
    [
        ["#FFFFFF", new ThemeColor(255, 255, 255), "#FFFFFF"],
        ["#1e1E1f", new ThemeColor(0x1E, 0x1E, 0x1F), "#1E1E1F"],
        ["#00000080", new ThemeColor(0, 0, 0, 0x80), "#00000080"],
        ["#123456FF", new ThemeColor(0x12, 0x34, 0x56), "#123456"],
    ];

    [Theory]
    [MemberData(nameof(ParseCases))]
    public void ParsesAndFormats(string input, ThemeColor color, string formatted)
    {
        var parsed = ThemeColor.Parse(input);
        Assert.Equal(color, parsed);
        Assert.Equal(formatted, parsed.Hex);
        Assert.Equal(parsed, ThemeColor.Parse(parsed.Hex));
    }

    [Theory]
    [InlineData("")]
    [InlineData("#")]
    [InlineData("FFFFFF")]
    [InlineData("#FFF")]
    [InlineData("#FFFFF")]
    [InlineData("#FFFFFFF")]
    [InlineData("#FFFFFFFFF")]
    [InlineData("#GGGGGG")]
    [InlineData(" #FFFFFF")]
    [InlineData("#FFFFFF ")]
    [InlineData("#ＦＦＦＦＦＦ")]
    [InlineData("##FFFFF")]
    [InlineData("#-1FFFF")]
    [InlineData("0xFFFFFF")]
    [InlineData("#ffffff\n")]
    [InlineData("#FFFFFF00FF")]
    public void RejectsMalformedHex(string input)
    {
        var error = Assert.Throws<ThemeException>(() => ThemeColor.Parse(input)).Error;
        Assert.Equal(ThemeError.InvalidColor(input), error);
        Assert.False(ThemeColor.TryParse(input, out _));
    }

    [Fact]
    public void ErrorMessageIsLocalized()
    {
        var message = ThemeError.InvalidColor("#12").Message;
        Assert.Contains("Invalid color", message);
        Assert.Contains("#12", message);
        using var _ = TestCulture.Use("tr");
        Assert.Equal("Geçersiz renk \"#12\": #RRGGBB ya da #RRGGBBAA biçiminde olmalı.", ThemeError.InvalidColor("#12").Message);
    }

    [Fact]
    public void ContrastRatioMatchesWCAG()
    {
        Assert.True(Math.Abs(ThemeColor.ContrastRatio(ThemeColor.Black, ThemeColor.White) - 21) < 0.001);
        Assert.Equal(1, ThemeColor.ContrastRatio(ThemeColor.White, ThemeColor.White));
        // #777777 on white is the textbook 4.48:1.
        var gray = new ThemeColor(0x77, 0x77, 0x77);
        Assert.True(Math.Abs(ThemeColor.ContrastRatio(gray, ThemeColor.White) - 4.48) < 0.01);
        Assert.Equal(ThemeColor.ContrastRatio(gray, ThemeColor.White), ThemeColor.ContrastRatio(ThemeColor.White, gray));
    }

    [Fact]
    public void TranslucentColorsAreComposited()
    {
        var halfBlack = new ThemeColor(0, 0, 0, 128);
        Assert.Equal(new ThemeColor(127, 127, 127), halfBlack.CompositedOver(ThemeColor.White));
        Assert.Equal(ThemeColor.ContrastRatio(new ThemeColor(127, 127, 127), ThemeColor.White),
            ThemeColor.ContrastRatio(halfBlack, ThemeColor.White));
        Assert.Equal(ThemeColor.White, new ThemeColor(0, 0, 0, 0).CompositedOver(ThemeColor.White));
    }

    [Fact]
    public void ComponentsAreFractions()
    {
        var color = new ThemeColor(255, 0, 51, 102);
        Assert.Equal(1, color.RedComponent);
        Assert.Equal(0, color.GreenComponent);
        Assert.Equal(0.2, color.BlueComponent, 6);
        Assert.Equal(0.4, color.AlphaComponent, 6);
    }
}

public class ThemeDecodingTests
{
    [Fact]
    public void MinimalThemeFallsBackToBase()
    {
        var theme = Theme.Decode("{\"id\": \"x\", \"name\": \"Benim\", \"appearance\": \"dark\"}");
        var resolved = new ThemeLibrary().Resolved(theme);
        var baseTheme = ThemeLibrary.BaseTheme(ThemeAppearance.Dark);
        Assert.Equal("x", resolved.Id);
        Assert.Equal("Benim", resolved.Name);
        Assert.Equal(baseTheme.Colors, resolved.Colors);
        Assert.Equal(baseTheme.Syntax, resolved.Syntax);
    }

    [Fact]
    public void PartialThemeOverridesOnlyWhatItSets()
    {
        const string json = """
            {
              "name": "Yarım", "appearance": "light",
              "colors": { "background": "#FAF0E6", "selection": "#0000FF33", "accent": null },
              "syntax": { "comment": "#808080" },
              "fonts": { "body": { "family": "Georgia" }, "mono": { "size": 13 } },
              "gelecekteBirAlan": true
            }
            """;
        var theme = Theme.Decode(json, "yarim");
        var resolved = new ThemeLibrary().Resolved(theme);
        var baseTheme = ThemeLibrary.BaseTheme(ThemeAppearance.Light);
        Assert.Equal("yarim", resolved.Id);
        Assert.Equal(new ThemeColor(0xFA, 0xF0, 0xE6), resolved.Colors.Background);
        Assert.Equal(0x33, resolved.Colors.Selection.Alpha);
        Assert.Equal(baseTheme.Colors.Text, resolved.Colors.Text);
        Assert.Equal(baseTheme.Colors.Accent, resolved.Colors.Accent);
        Assert.Equal("#808080", resolved.Syntax.Comment.Hex);
        Assert.Equal(baseTheme.Syntax.Keyword, resolved.Syntax.Keyword);
    }

    [Fact]
    public void IdInFileWinsOverFallbackAndIsTrimmed()
    {
        var theme = Theme.Decode("{\"id\": \" gerçek \", \"name\": \" Ad \", \"appearance\": \"light\"}", "dosya");
        Assert.Equal("gerçek", theme.Id);
        Assert.Equal("Ad", theme.Name);
    }

    public static IEnumerable<object[]> InvalidThemes() =>
    [
        ["{", ThemeError.MalformedJson(1, "the file ended unexpectedly.")],
        ["[]", ThemeError.InvalidJson],
        ["\"tema\"", ThemeError.InvalidJson],
        ["{\"name\": \"A\"}", ThemeError.MissingField("appearance")],
        ["{\"appearance\": \"light\"}", ThemeError.MissingField("name")],
        ["{\"name\": \"A\", \"appearance\": \"sepia\"}", ThemeError.InvalidValue("appearance", "must be \"light\" or \"dark\".")],
        ["{\"name\": \"  \", \"appearance\": \"light\"}", ThemeError.InvalidValue("name", "must not be empty.")],
        ["{\"name\": \"A\", \"appearance\": \"light\", \"colors\": {\"text\": \"#12\"}}",
            ThemeError.InvalidValue("colors.text", "must be a color like #RRGGBB or #RRGGBBAA.")],
        ["{\"name\": \"A\", \"appearance\": \"light\", \"syntax\": {\"tag\": \"red\"}}",
            ThemeError.InvalidValue("syntax.tag", "must be a color like #RRGGBB or #RRGGBBAA.")],
        ["{\"name\": \"A\", \"appearance\": \"light\", \"colors\": {\"text\": 12}}",
            ThemeError.InvalidValue("colors.text", "Expected a string.")],
        ["{\"name\": null, \"appearance\": \"light\"}", ThemeError.InvalidValue("name", "must not be null.")],
        ["{\"name\": \"A\", \"appearance\": \"light\", \"colors\": []}", ThemeError.InvalidValue("colors", "Expected an object.")],
        ["{\"name\": 5, \"appearance\": \"light\"}", ThemeError.InvalidValue("name", "Expected a string.")],
    ];

    [Theory]
    [MemberData(nameof(InvalidThemes))]
    public void InvalidThemesReportTheField(string json, ThemeError error)
    {
        Assert.Equal(error, ThemeTestHelpers.Thrown(() => ThemeTestHelpers.Decode(json)));
    }

    [Fact]
    public void MissingIdWithoutFallbackIsAnError()
    {
        Assert.Equal(ThemeError.MissingField("id"),
            ThemeTestHelpers.Thrown(() => Theme.Decode("{\"name\": \"A\", \"appearance\": \"light\"}")));
    }

    [Fact]
    public void ErrorMessagesAreLocalized()
    {
        Assert.Equal("The field \"name\" is missing.", ThemeError.MissingField("name").Message);
        Assert.Equal("The file is not a valid JSON object.", ThemeError.InvalidJson.Message);
        Assert.Equal("The field \"a\" is invalid: b", ThemeError.InvalidValue("a", "b").Message);
        using var _ = TestCulture.Use("tr");
        Assert.Equal("\"name\" alanı eksik.", ThemeError.MissingField("name").Message);
        Assert.Equal("Dosya geçerli bir JSON nesnesi değil.", ThemeError.InvalidJson.Message);
        Assert.Equal("JSON hatası, satır 4: x", ThemeError.MalformedJson(4, "x").Message);
    }

    [Fact]
    public void EncodingRoundTripsAndOmitsUnsetFields()
    {
        var theme = Theme.Create("t", "Tema", ThemeAppearance.Dark, new ThemeColors { Background = ThemeColor.Black });
        var data = theme.EncodedJson();
        var text = Encoding.UTF8.GetString(data);
        Assert.Contains("\"background\" : \"#000000\"", text);
        Assert.DoesNotContain("\"text\"", text);
        Assert.DoesNotContain("fonts", text);
        Assert.Equal(theme, Theme.Decode(data));
    }

    [Fact]
    public void SyntaxCoversEveryCodeSpanKind()
    {
        var syntax = ThemeLibrary.BaseTheme(ThemeAppearance.Light).Syntax;
        CodeSpanKind[] kinds = [CodeSpanKind.Keyword, CodeSpanKind.String, CodeSpanKind.Number, CodeSpanKind.Comment,
            CodeSpanKind.Literal, CodeSpanKind.Type, CodeSpanKind.Property, CodeSpanKind.Tag];
        Assert.Equal([syntax.Keyword, syntax.String, syntax.Number, syntax.Comment, syntax.Literal, syntax.Type, syntax.Property, syntax.Tag],
            kinds.Select(kind => syntax[kind]));
    }

    [Fact]
    public void QuotesAreEscapedWhenEncoding()
    {
        var theme = Theme.Create("a\"b\\c", "Ş/\n\u0001", ThemeAppearance.Light);
        var text = Encoding.UTF8.GetString(theme.EncodedJson());
        Assert.Contains("\"id\" : \"a\\\"b\\\\c\"", text);
        Assert.Contains("\"name\" : \"Ş/\\n\\u0001\"", text);
    }
}

public class BuiltInThemeTests
{
    public static IEnumerable<object[]> Ids() => ThemeLibrary.BuiltInThemes.Select(t => new object[] { t.Id });

    [Fact]
    public void NamesAndAppearances()
    {
        var themes = ThemeLibrary.BuiltInThemes;
        Assert.Equal(["Varsayılan Açık", "Sepya", "Kağıt", "Varsayılan Koyu", "Gece Mavisi", "Okyanus"], themes.Select(t => t.Name));
        Assert.Equal([ThemeAppearance.Light, ThemeAppearance.Light, ThemeAppearance.Light, ThemeAppearance.Dark, ThemeAppearance.Dark, ThemeAppearance.Dark],
            themes.Select(t => t.Appearance));
        Assert.Equal(themes.Count, themes.Select(t => t.Id).Distinct().Count());
        Assert.Equal(ThemeLibrary.DefaultLightId, ThemeLibrary.BaseTheme(ThemeAppearance.Light).Id);
        Assert.Equal(ThemeLibrary.DefaultDarkId, ThemeLibrary.BaseTheme(ThemeAppearance.Dark).Id);
        Assert.True(ThemeLibrary.IsBuiltIn("ocean"));
        Assert.False(ThemeLibrary.IsBuiltIn("benim"));
    }

    [Fact]
    public void DisplayNamesFollowTheUILanguage()
    {
        var sepia = ThemeLibrary.BuiltInThemes.First(t => t.Id == "sepia");
        Assert.Equal("Sepia", sepia.DisplayName);
        Assert.Equal("Default Light", ThemeLibrary.BuiltInThemes[0].DisplayName);
        Assert.Equal("Benim", Theme.Create("benim", "Benim", ThemeAppearance.Dark).DisplayName);
        using var _ = TestCulture.Use("tr");
        Assert.Equal("Sepya", sepia.DisplayName);
        Assert.Equal("Varsayılan Koyu", ThemeLibrary.BuiltInThemes[3].DisplayName);
        Assert.Equal("Benim", Theme.Create("benim", "Benim", ThemeAppearance.Dark).DisplayName);
    }

    [Fact]
    public void EveryBuiltInSetsEveryColor()
    {
        foreach (var theme in ThemeLibrary.BuiltInThemes)
        {
            // CurrentLine is optional everywhere: built-ins leave it to the derivation.
            Assert.Null(theme.Colors.CurrentLine);
            var colors = ThemeTestHelpers.PaletteColors(theme, includeControls: true).ToList();
            Assert.Equal(21, colors.Count);
        }
    }

    /// <summary>The shared muted palette: headings and inline code are the body colour, markers and comments are one dimmed grey, and no colour is saturated.</summary>
    [Fact]
    public void BuiltInPalettesAreMuted()
    {
        foreach (var theme in ThemeLibrary.BuiltInThemes)
        {
            var c = theme.Colors;
            var s = theme.Syntax;
            Assert.True(c.Heading == c.Text, $"{theme.Id}: heading is not the text color");
            Assert.True(c.InlineCode == c.Text, $"{theme.Id}: inline code is not the text color");
            Assert.True(c.Marker == s.Comment, $"{theme.Id}: markers and comments differ");
            // Selection, cursor and accent are control colors (the system accent blue), not palette colors.
            foreach (var color in ThemeTestHelpers.PaletteColors(theme, includeControls: false))
            {
                var high = Math.Max(color.Red, Math.Max(color.Green, color.Blue));
                var low = Math.Min(color.Red, Math.Min(color.Green, color.Blue));
                Assert.True(high - low <= 120, $"{theme.Id}: {color} is too saturated");
            }
        }
    }

    [Fact]
    public void CurrentLineIsOptionalAndDerivedFromText()
    {
        var library = new ThemeLibrary();
        var light = library.Resolved(Theme.Decode("{\"name\": \"A\", \"appearance\": \"light\", \"colors\": {\"text\": \"#102030\"}}", "a"));
        Assert.Equal(new ThemeColor(0x10, 0x20, 0x30, 0x0F), light.Colors.CurrentLine);
        var dark = library.Resolved(Theme.Decode("{\"name\": \"B\", \"appearance\": \"dark\", \"colors\": {\"text\": \"#E0E0E0\", \"currentLine\": null}}", "b"));
        Assert.Equal(new ThemeColor(0xE0, 0xE0, 0xE0, 0x14), dark.Colors.CurrentLine);
        foreach (var appearance in new[] { ThemeAppearance.Light, ThemeAppearance.Dark })
        {
            var baseTheme = ThemeLibrary.BaseTheme(appearance);
            Assert.Equal(ResolvedTheme.DerivedCurrentLine(baseTheme.Colors.Text, appearance), baseTheme.Colors.CurrentLine);
        }
    }

    [Fact]
    public void ExplicitCurrentLineWinsAndRoundTrips()
    {
        const string json = "{\"name\": \"C\", \"appearance\": \"light\", \"colors\": {\"currentLine\": \"#00000014\", \"codeBlockBackground\": \"#EEEEEE\"}}";
        var theme = Theme.Decode(json, "c");
        Assert.Equal(new ThemeColor(0, 0, 0, 0x14), theme.Colors.CurrentLine);
        Assert.Equal(theme.Colors.CurrentLine, new ThemeLibrary().Resolved(theme).Colors.CurrentLine);
        Assert.Equal(theme, Theme.Decode(theme.EncodedJson()));
    }

    [Fact]
    public void InvalidCurrentLineIsRejected()
    {
        const string json = "{\"name\": \"D\", \"appearance\": \"light\", \"colors\": {\"currentLine\": \"gray\"}}";
        Assert.Equal(ThemeError.InvalidValue("colors.currentLine", "must be a color like #RRGGBB or #RRGGBBAA."),
            ThemeTestHelpers.Thrown(() => Theme.Decode(json, "d")));
    }

    [Fact]
    public void BuiltInJsonRoundTrips()
    {
        foreach (var theme in ThemeLibrary.BuiltInThemes) Assert.Equal(theme, Theme.Decode(theme.EncodedJson()));
    }

    [Theory]
    [MemberData(nameof(Ids))]
    public void Contrast(string id)
    {
        var library = new ThemeLibrary();
        var theme = library.Resolved(library.Find(id)!);
        var c = theme.Colors;
        var s = theme.Syntax;
        var codeBlock = c.CodeBlockBackground;

        void Check(string name, ThemeColor fg, ThemeColor bg, double minimum)
        {
            var ratio = theme.ContrastRatio(fg, bg);
            Assert.True(ratio >= minimum, $"{id}: {name} {fg} on {bg} is {ratio}");
        }

        foreach (var (name, color) in new[] { ("text", c.Text), ("heading", c.Heading), ("link", c.Link), ("blockquote", c.Blockquote) })
            Check(name, color, c.Background, 4.5);
        Check("text on selection", c.Text, c.Selection, 4.5);
        Check("inline code", c.InlineCode, c.InlineCodeBackground, 4.5);
        Check("text in code block", c.Text, codeBlock, 4.5);
        Check("text on current line", c.Text, c.CurrentLine, 4.5);
        Check("text on current line in code block", c.Text, c.CurrentLine.CompositedOver(codeBlock), 4.5);
        foreach (var (name, color) in new[] { ("secondaryText", c.SecondaryText), ("marker", c.Marker), ("cursor", c.Cursor), ("accent", c.Accent) })
            Check(name, color, c.Background, 3);
        foreach (var (name, color) in new[] { ("keyword", s.Keyword), ("string", s.String), ("number", s.Number), ("literal", s.Literal),
                     ("type", s.Type), ("property", s.Property), ("tag", s.Tag) })
        {
            Check(name, color, c.Background, 4.5);
            Check(name, color, codeBlock, 4.5);
        }
        Check("comment", s.Comment, c.Background, 3);
        Check("comment", s.Comment, codeBlock, 3);
    }

    [Fact]
    public void AppearanceMatchesBackgroundLuminance()
    {
        var library = new ThemeLibrary();
        foreach (var theme in ThemeLibrary.BuiltInThemes)
        {
            var luminance = library.Resolved(theme).Colors.Background.RelativeLuminance;
            Assert.True(theme.Appearance == ThemeAppearance.Light ? luminance > 0.5 : luminance < 0.1, theme.Id);
        }
    }
}

public sealed class ThemeLibraryTests : IDisposable
{
    private readonly List<NotesTempFolder> folders = [];

    public void Dispose()
    {
        foreach (var folder in folders) folder.Dispose();
    }

    private string MakeDirectory(Dictionary<string, string>? files = null)
    {
        var folder = new NotesTempFolder();
        folders.Add(folder);
        foreach (var (name, content) in files ?? [])
            File.WriteAllBytes(Path.Combine(folder.Path, name), new UTF8Encoding(false).GetBytes(content));
        return folder.Path;
    }

    private static string ThemeFile(string? id = null, string name = "T") =>
        (id is null ? "{" : $"{{\"id\": \"{id}\", ") + $"\"name\": \"{name}\", \"appearance\": \"light\"}}";

    private static bool TryMakeDirectoryLink(string link, string target)
    {
        try
        {
            Directory.CreateSymbolicLink(link, target);
            return true;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            // No symlink privilege: a junction needs none.
            using var process = Process.Start(new ProcessStartInfo("cmd.exe", $"/c mklink /J \"{link}\" \"{target}\"")
            {
                CreateNoWindow = true,
                UseShellExecute = false,
                RedirectStandardOutput = true,
            })!;
            process.StandardOutput.ReadToEnd();
            process.WaitForExit();
            return process.ExitCode == 0;
        }
    }

    [Fact]
    public void MissingDirectoryMeansOnlyBuiltIns()
    {
        var library = new ThemeLibrary(Path.Combine(Path.GetTempPath(), "nonexistent-" + Guid.NewGuid().ToString("N")));
        Assert.Empty(library.UserThemes);
        Assert.Empty(library.Issues);
        Assert.Equal(ThemeLibrary.BuiltInThemes.Count, library.Themes.Count);
        Assert.Equal(6, new ThemeLibrary(null).Themes.Count);
    }

    [Fact]
    public void LoadsValidThemesAndReportsTheRest()
    {
        var dir = MakeDirectory(new()
        {
            ["Orman Yeşili.json"] = "{\"name\": \"Orman\", \"appearance\": \"dark\", \"colors\": {\"background\": \"#0B1F14\"}}",
            ["b.json"] = "{\"id\": \"kum\", \"name\": \"Kum\", \"appearance\": \"light\"}",
            ["c.JSON"] = "{\"id\": \"ay\", \"name\": \"Ay ışığı\", \"appearance\": \"dark\"}",
            ["bozuk.json"] = "{ not json",
            ["renk.json"] = "{\"name\": \"R\", \"appearance\": \"light\", \"colors\": {\"link\": \"mavi\"}}",
            ["sepya-kopya.json"] = "{\"id\": \"sepia\", \"name\": \"Sepya 2\", \"appearance\": \"light\"}",
            ["z-kum.json"] = "{\"id\": \"kum\", \"name\": \"Kum 2\", \"appearance\": \"light\"}",
            ["notlar.txt"] = "ignored",
            [".gizli.json"] = "{",
        });
        Directory.CreateDirectory(Path.Combine(dir, "alt.json"));

        var library = new ThemeLibrary(dir);
        Assert.Equal(["ay", "kum", "Orman Yeşili"], library.UserThemes.Select(t => t.Id));
        Assert.Equal(["Ay ışığı", "Orman"], library.ThemesFor(ThemeAppearance.Dark).Select(t => t.Name).TakeLast(2));
        Assert.Equal("b.json", Path.GetFileName(library.FileForThemeId("kum")));
        Assert.Null(library.FileForThemeId("sepia"));
        Assert.Equal("Sepya", library.Find("sepia")!.Name);

        var issues = library.Issues.ToDictionary(i => Path.GetFileName(i.File), i => i.Error);
        Assert.Equal(4, issues.Count);
        Assert.Equal(ThemeError.MalformedJson(1, "a key in quotes was expected."), issues["bozuk.json"]);
        Assert.Equal(ThemeError.InvalidValue("colors.link", "must be a color like #RRGGBB or #RRGGBBAA."), issues["renk.json"]);
        Assert.Equal(ThemeError.DuplicateId("sepia"), issues["sepya-kopya.json"]);
        Assert.Equal(ThemeError.DuplicateId("kum"), issues["z-kum.json"]);
        Assert.StartsWith("z-kum.json: The id \"kum\" is already", library.Issues.First(i => Path.GetFileName(i.File) == "z-kum.json").ToString());
    }

    [Fact]
    public void FileNameIdIsNFC()
    {
        var dir = MakeDirectory(new() { ["Gu\u0308ne\u015F.json"] = "{\"name\": \"Güneş\", \"appearance\": \"light\"}" });
        var library = new ThemeLibrary(dir);
        Assert.Equal("Güneş".Normalize(System.Text.NormalizationForm.FormC), library.UserThemes[0].Id);
        Assert.Equal(5, library.UserThemes[0].Id.EnumerateRunes().Count());
    }

    [Fact]
    public void OversizedFileIsReported()
    {
        var big = "{\"name\": \"B\", \"appearance\": \"light\", \"x\": \"" + new string('a', ThemeLibrary.MaxFileSize) + "\"}";
        var dir = MakeDirectory(new() { ["buyuk.json"] = big });
        var library = new ThemeLibrary(dir);
        Assert.Empty(library.UserThemes);
        Assert.Equal([ThemeError.FileTooLarge], library.Issues.Select(i => i.Error));
    }

    [Fact]
    public void DirectoryThatIsAFileIsReported()
    {
        var dir = MakeDirectory(new() { ["dosya"] = "x" });
        var library = new ThemeLibrary(Path.Combine(dir, "dosya"));
        Assert.Empty(library.UserThemes);
        Assert.Single(library.Issues);
        Assert.Equal(ThemeErrorKind.Unreadable, library.Issues[0].Error.Kind);
    }

    [Fact]
    public void PreferencesPickThemePerAppearance()
    {
        var dir = MakeDirectory(new() { ["mine.json"] = "{\"id\": \"mine\", \"name\": \"Benim\", \"appearance\": \"dark\"}" });
        var library = new ThemeLibrary(dir);
        var prefs = new ThemePreferences { Mode = AppearanceMode.System, LightThemeId = "sepia", DarkThemeId = "mine" };

        Assert.Equal("sepia", library.ThemeFor(prefs, ThemeAppearance.Light).Id);
        Assert.Equal("mine", library.ThemeFor(prefs, ThemeAppearance.Dark).Id);
        prefs = prefs with { Mode = AppearanceMode.Light };
        Assert.Equal("sepia", library.ThemeFor(prefs, ThemeAppearance.Dark).Id);
        prefs = prefs with { Mode = AppearanceMode.Dark };
        Assert.Equal("mine", library.ThemeFor(prefs, ThemeAppearance.Light).Id);

        // Deleted theme or wrong appearance falls back to the default of that appearance.
        prefs = prefs with { DarkThemeId = "silinmiş" };
        Assert.Equal(ThemeLibrary.DefaultDarkId, library.ThemeFor(prefs, ThemeAppearance.Light).Id);
        prefs = prefs with { DarkThemeId = "paper" };
        Assert.Equal(ThemeLibrary.DefaultDarkId, library.ThemeFor(prefs, ThemeAppearance.Light).Id);
    }

    [Fact]
    public void PreferencesHaveDefaultsAndDisplayNames()
    {
        var prefs = new ThemePreferences();
        Assert.Equal(AppearanceMode.System, prefs.Mode);
        Assert.Equal("default-light", prefs.LightThemeId);
        Assert.Equal("default-dark", prefs.DarkThemeId);
        Assert.Equal(prefs, ThemePreferences.FromJson(prefs.ToJson()));
        var custom = new ThemePreferences { Mode = AppearanceMode.Dark, LightThemeId = "paper", DarkThemeId = "gece \"x\"" };
        Assert.Equal(custom, ThemePreferences.FromJson(custom.ToJson()));
        Assert.Equal(["System", "Light", "Dark"], Enum.GetValues<AppearanceMode>().Select(m => m.DisplayName()));
        Assert.Equal(["Light", "Dark"], Enum.GetValues<ThemeAppearance>().Select(a => a.DisplayName()));
    }

    [Fact]
    public void DocsExampleDecodes()
    {
        // Keep in sync with the full example in docs/themes.md.
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null && !File.Exists(Path.Combine(dir.FullName, "docs", "themes.md"))) dir = dir.Parent;
        Assert.NotNull(dir);
        var text = File.ReadAllText(Path.Combine(dir.FullName, "docs", "themes.md"), Encoding.UTF8).Replace("\r\n", "\n");
        var blocks = text.Split("```json\n").Skip(1).Select(b => b.Split("\n```")[0]).ToList();
        Assert.True(blocks.Count >= 2);
        foreach (var block in blocks)
            Assert.False(string.IsNullOrEmpty(Theme.Decode(block, "docs").Name));
    }

    [Fact]
    public void LinkedFoldersAreFollowed()
    {
        var real = MakeDirectory(new() { ["a.json"] = ThemeFile("a") });
        var outer = MakeDirectory();
        var link = Path.Combine(outer, "Themes");
        if (!TryMakeDirectoryLink(link, real)) return;
        var library = new ThemeLibrary(link);
        Assert.Empty(library.Issues);
        Assert.Equal(["a"], library.UserThemes.Select(t => t.Id));
    }

    [Fact]
    public void LinkedFilesAreFollowedButOnlyToRegularFiles()
    {
        var elsewhere = MakeDirectory(new() { ["real.json"] = ThemeFile(null, "Bağlı") });
        var dir = MakeDirectory();
        Directory.CreateDirectory(Path.Combine(elsewhere, "klasor"));
        try
        {
            File.CreateSymbolicLink(Path.Combine(dir, "bagli.json"), Path.Combine(elsewhere, "real.json"));
            File.CreateSymbolicLink(Path.Combine(dir, "kirik.json"), Path.Combine(elsewhere, "yok.json"));
            File.CreateSymbolicLink(Path.Combine(dir, "klasor.json"), Path.Combine(elsewhere, "klasor"));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return; } // no symlink privilege
        Directory.CreateDirectory(Path.Combine(dir, "alt.json"));

        var library = new ThemeLibrary(dir);
        // The id comes from the link's name, not the target's.
        Assert.Equal(["bagli"], library.UserThemes.Select(t => t.Id));
        Assert.Equal("bagli.json", Path.GetFileName(library.FileForThemeId("bagli")));
        var issues = library.Issues.ToDictionary(i => Path.GetFileName(i.File), i => i.Error);
        Assert.Equal(["kirik.json"], issues.Keys.OrderBy(k => k, StringComparer.Ordinal));
        Assert.Equal(ThemeErrorKind.Unreadable, issues["kirik.json"].Kind);
    }

    [Fact]
    public void HiddenFilesAreSkipped()
    {
        var dir = MakeDirectory(new() { ["gizli.json"] = "{", ["acik.json"] = ThemeFile("acik") });
        File.SetAttributes(Path.Combine(dir, "gizli.json"), FileAttributes.Hidden);
        var library = new ThemeLibrary(dir);
        Assert.Empty(library.Issues);
        Assert.Equal(["acik"], library.UserThemes.Select(t => t.Id));
    }

    [Fact]
    public void DuplicateIdsResolveByOrdinalScalarOrderOfNFCFileNames()
    {
        var dir = MakeDirectory(new()
        {
            ["a.json"] = ThemeFile("x", "küçük a"),
            ["B.json"] = ThemeFile("x", "büyük B"),
            ["\uFFFD.json"] = ThemeFile("y", "FFFD"),
            ["😀.json"] = ThemeFile("y", "emoji"),
            ["e\u0301.json"] = ThemeFile("z", "é"),
            ["f.json"] = ThemeFile("z", "f"),
        });
        var library = new ThemeLibrary(dir);
        Assert.Equal(new HashSet<string> { "büyük B", "FFFD", "f" }, library.UserThemes.Select(t => t.Name).ToHashSet());
        // Issues are listed in that same order.
        Assert.Equal(["a.json", "é.json", "😀.json"],
            library.Issues.Select(i => Path.GetFileName(i.File).Normalize(NormalizationForm.FormC)));
    }

    [Fact]
    public void IdsCompareExactlyAfterNFC()
    {
        var dir = MakeDirectory(new()
        {
            ["1.json"] = ThemeFile("caf\\u00e9"),
            ["2.json"] = ThemeFile("cafe\\u0301"),
            ["3.json"] = ThemeFile("Kum"),
            ["4.json"] = ThemeFile("kum"),
        });
        var library = new ThemeLibrary(dir);
        Assert.Equal(3, library.UserThemes.Count);
        Assert.Equal(["2.json"], library.Issues.Select(i => Path.GetFileName(i.File)));
        Assert.NotNull(library.Find("cafe\u0301"));
    }

    [Fact]
    public void FileCountIsCapped()
    {
        var files = new Dictionary<string, string>();
        for (var n = 0; n <= ThemeLibrary.MaxFileCount; n++) files[$"t{n:D4}.json"] = ThemeFile();
        var dir = MakeDirectory(files);
        Directory.CreateDirectory(Path.Combine(dir, "a-klasor.json"));

        var library = new ThemeLibrary(dir);
        Assert.Equal(ThemeLibrary.MaxFileCount, library.UserThemes.Count);
        Assert.Equal([$"t{ThemeLibrary.MaxFileCount:D4}.json"], library.Issues.Select(i => Path.GetFileName(i.File)));
        Assert.Equal(ThemeError.TooManyFiles, library.Issues[0].Error);
        Assert.Contains("500", ThemeError.TooManyFiles.Message);
    }

    [Fact]
    public void NaturalNameOrderForUserThemes()
    {
        var dir = MakeDirectory(new()
        {
            ["a.json"] = ThemeFile("a", "Tema 10"),
            ["b.json"] = ThemeFile("b", "tema 9"),
            ["c.json"] = ThemeFile("c", "Tema 9"),
        });
        var library = new ThemeLibrary(dir);
        Assert.Equal(["b", "c", "a"], library.UserThemes.Select(t => t.Id));
    }
}

public class ThemeJsonGrammarTests
{
    private static string Head => ThemeTestHelpers.Head;

    public static IEnumerable<object[]> Malformed() =>
        new[]
        {
            $"{{{Head},}}",
            $"{{{Head}, \"x\": [1, 2,]}}",
            $"{{{Head}, // yorum\n}}",
            $"/* yorum */ {{{Head}}}",
            $"{{{Head}, /* yorum */ \"x\": 1}}",
            $"{{{Head}, \"x\": 'a'}}",
            $"{{{Head}, \"x\": 01}}",
            $"{{{Head}, \"x\": +1}}",
            $"{{{Head}, \"x\": .5}}",
            $"{{{Head}, \"x\": 1.}}",
            $"{{{Head}, \"x\": 1e}}",
            $"{{{Head}, \"x\": NaN}}",
            $"{{{Head}, \"x\": Infinity}}",
            $"{{{Head}, \"x\": tru}}",
            "{\"name\": \"A\", \"appearance\": \"light\", \"x\": \"\\x\"}",
            "{\"name\": \"A\", \"appearance\": \"light\", \"x\": \"\\u12\"}",
            "{\"name\": \"A\", \"appearance\": \"light\", \"x\": \"\\uD800\"}",
            "{\"name\": \"A\", \"appearance\": \"light\", \"x\": \"\\uD800A\"}",
            "{\"name\": \"A\", \"appearance\": \"light\", \"x\": \"\\uDC00\"}",
            $"{{{Head}, \"x\": \"a\tb\"}}",
            $"{{{Head}, \"x\": \"a\nb\"}}",
            $"{{{Head}}} {{}}",
            $"{{{Head}",
            $"{{{Head}, \"x\": \"açık",
            "{name: \"A\"}",
            $"{{{Head} \"x\": 1}}",
            $"{{{Head}, \"x\" 1}}",
            $"{{{Head},\u00A0\"x\": 1}}",
        }.Select(json => new object[] { json });

    [Theory]
    [MemberData(nameof(Malformed))]
    public void RejectsMalformedJson(string json)
    {
        var error = ThemeTestHelpers.Thrown(() => ThemeTestHelpers.Decode(json));
        Assert.True(error is { Kind: ThemeErrorKind.MalformedJson }, $"accepted or wrong error ({error?.Kind}): {json}");
    }

    [Fact]
    public void MalformedJsonNamesTheLine()
    {
        Assert.Equal(ThemeError.MalformedJson(4, "a trailing comma is not allowed."),
            ThemeTestHelpers.Thrown(() => ThemeTestHelpers.Decode("{\n  \"name\": \"A\",\n  \"appearance\": \"light\",\n}")));
        Assert.Equal(ThemeError.MalformedJson(2, "comments are not allowed."),
            ThemeTestHelpers.Thrown(() => ThemeTestHelpers.Decode("{\r\n\"name\": \"A\", // not\r\n}")));
        Assert.Equal("JSON error, line 4: x", ThemeError.MalformedJson(4, "x").Message);
    }

    [Theory]
    [InlineData("null")]
    [InlineData("[]")]
    [InlineData("1")]
    [InlineData("\"tema\"")]
    [InlineData("true")]
    [InlineData("   ")]
    public void NonObjectTopLevelIsInvalidJson(string json)
    {
        Assert.Equal(ThemeError.InvalidJson, ThemeTestHelpers.Thrown(() => ThemeTestHelpers.Decode(json)));
    }

    [Fact]
    public void DuplicateKeysAreErrors()
    {
        const string reason = "the same key appears more than once.";
        Assert.Equal(ThemeError.InvalidValue("name", reason),
            ThemeTestHelpers.Thrown(() => ThemeTestHelpers.Decode("{\"name\": \"A\", \"name\": \"B\", \"appearance\": \"light\"}")));
        Assert.Equal(ThemeError.InvalidValue("colors.text", reason),
            ThemeTestHelpers.Thrown(() => ThemeTestHelpers.Decode($"{{{Head}, \"colors\": {{\"text\": \"#000000\", \"text\": \"#111111\"}}}}")));
        Assert.Equal(ThemeError.InvalidValue("x.0.a", reason),
            ThemeTestHelpers.Thrown(() => ThemeTestHelpers.Decode($"{{{Head}, \"x\": [{{\"a\": 1, \"a\": 1}}]}}")));
        // Same key in different objects is fine; keys compare ordinally, so NFC/NFD spellings differ.
        ThemeTestHelpers.Decode($"{{{Head}, \"x\": {{\"a\": 1}}, \"y\": {{\"a\": 1}}, \"caf\\u00e9\": 1, \"cafe\\u0301\": 2}}");
    }

    [Fact]
    public void NestingDepthIsLimitedTo64()
    {
        static string Nested(int arrays) => $"{{{Head}, \"x\": " + new string('[', arrays) + new string(']', arrays) + "}";
        ThemeTestHelpers.Decode(Nested(63));
        Assert.Equal(ThemeErrorKind.MalformedJson, ThemeTestHelpers.Thrown(() => ThemeTestHelpers.Decode(Nested(64)))?.Kind);
        Assert.Equal(ThemeErrorKind.MalformedJson, ThemeTestHelpers.Thrown(() => ThemeTestHelpers.Decode(Nested(100_000)))?.Kind);
    }

    [Fact]
    public void ValidEscapesAndNumbersAreAccepted()
    {
        var theme = ThemeTestHelpers.Decode("{\"name\": \"Çınar 🌳 \\\"t\\\" \\/ \\\\\", \"appearance\": \"light\", \"x\": [-0.5e+3, 0, 1E-2, true, false, null, {}, []]}");
        Assert.Equal("Çınar 🌳 \"t\" / \\", theme.Name);
        ThemeTestHelpers.Decode($"\r\n\t{{{Head}}}\n");
        Assert.Equal("😀", ThemeTestHelpers.Decode("{\"name\": \"\\uD83D\\uDE00\", \"appearance\": \"light\"}").Name);
    }

    [Fact]
    public void OutOfRangeNumbersNameTheField()
    {
        Assert.Equal(ThemeError.InvalidValue("fonts.body.size", "the number is too large."),
            ThemeTestHelpers.Thrown(() => ThemeTestHelpers.Decode($"{{{Head}, \"fonts\": {{\"body\": {{\"size\": 1e400}}}}}}")));
        Assert.Equal(ThemeError.InvalidValue("x.1", "the number is too large."),
            ThemeTestHelpers.Thrown(() => ThemeTestHelpers.Decode($"{{{Head}, \"x\": [0, -1e309]}}")));
    }

    [Fact]
    public void Encodings()
    {
        var json = $"{{{Head}}}";
        byte[] bom = [0xEF, 0xBB, 0xBF];
        Assert.Equal("A", Theme.Decode([.. bom, .. Encoding.UTF8.GetBytes(json)], "f").Name);
        Assert.Equal(ThemeError.NotUtf8, ThemeTestHelpers.Thrown(() => Theme.Decode([0xFF, 0xFE, .. Encoding.Unicode.GetBytes(json)], "f")));
        Assert.Equal(ThemeError.NotUtf8, ThemeTestHelpers.Thrown(() => Theme.Decode(Encoding.BigEndianUnicode.GetBytes(json), "f")));
        Assert.Equal(ThemeError.NotUtf8, ThemeTestHelpers.Thrown(() =>
            Theme.Decode([.. "{\"name\": \""u8, 0xC3, 0x28, .. "\", \"appearance\": \"light\"}"u8], "f")));
        Assert.NotNull(ThemeTestHelpers.Thrown(() => Theme.Decode([.. bom, .. bom, .. Encoding.UTF8.GetBytes(json)], "f")));
        Assert.Equal(ThemeError.NotUtf8, ThemeTestHelpers.Thrown(() => Theme.Decode("{\"name\": \"a\0b\", \"appearance\": \"light\"}"u8.ToArray(), "f")));
    }

    [Fact]
    public void IdsFromJsonAreNFC()
    {
        var theme = ThemeTestHelpers.Decode("{\"id\": \" Güneş \", \"name\": \"Gün\", \"appearance\": \"light\"}");
        Assert.Equal(5, theme.Id.EnumerateRunes().Count());
        Assert.Equal("Güneş".Normalize(NormalizationForm.FormC), theme.Id);
        Assert.Equal(3, theme.Name.EnumerateRunes().Count());
    }

    /// <summary>Fonts left the theme format (they are app settings now); old files that still have them load unchanged, even with values that used to be errors.</summary>
    [Fact]
    public void LegacyFontsAreIgnored()
    {
        var theme = ThemeTestHelpers.Decode(
            $"{{{Head}, \"fonts\": {{\"body\": {{\"family\": \"\", \"size\": 200}}, \"mono\": {{\"family\": \"Menlo\", \"size\": \"12\"}}}}, \"colors\": {{\"text\": \"#123456\"}}}}");
        Assert.Equal("#123456", theme.Colors.Text?.Hex);
        Assert.DoesNotContain("fonts", Encoding.UTF8.GetString(theme.EncodedJson()));
    }

    [Fact]
    public void CreateAndEncodingValidateLikeDecoding()
    {
        Assert.Equal(ThemeError.InvalidValue("id", "must not be empty."),
            ThemeTestHelpers.Thrown(() => Theme.Create(" ", "A", ThemeAppearance.Light)));
        var theme = Theme.Create(" Gu\u0308l ", " Gül ", ThemeAppearance.Light);
        Assert.Equal("Gül", theme.Id);
        Assert.Equal(3, theme.Id.EnumerateRunes().Count());
        Assert.Equal("Gül", theme.Name);
        var blank = theme with { Name = "\n" };
        Assert.Equal(ThemeError.InvalidValue("name", "must not be empty."), ThemeTestHelpers.Thrown(() => blank.EncodedJson()));
    }
}

public class ThemeAlphaTests
{
    [Fact]
    public void BackgroundAlphaIsIgnored()
    {
        var theme = ThemeTestHelpers.Decode($"{{{ThemeTestHelpers.Head}, \"colors\": {{\"background\": \"#F0F0F080\"}}}}");
        Assert.Equal(new ThemeColor(0xF0, 0xF0, 0xF0), new ThemeLibrary().Resolved(theme).Colors.Background);
    }

    [Fact]
    public void TranslucentBackgroundsCompositeOverTheThemeBackground()
    {
        var theme = Theme.Decode("{\"id\": \"d\", \"name\": \"D\", \"appearance\": \"dark\", \"colors\": {\"selection\": \"#FFFFFF33\"}}");
        var resolved = new ThemeLibrary().Resolved(theme);
        var c = resolved.Colors;
        var expected = ThemeColor.ContrastRatio(c.Text, c.Selection.CompositedOver(c.Background));
        Assert.Equal(expected, resolved.ContrastRatio(c.Text, c.Selection));
        Assert.NotEqual(ThemeColor.ContrastRatio(c.Text, c.Selection.CompositedOver(ThemeColor.White)), resolved.ContrastRatio(c.Text, c.Selection));
        Assert.Equal(ThemeColor.ContrastRatio(c.Text, c.Background), resolved.ContrastRatio(c.Text));
        // The static helper treats the background as opaque.
        Assert.Equal(ThemeColor.ContrastRatio(ThemeColor.Black, ThemeColor.White),
            ThemeColor.ContrastRatio(ThemeColor.Black, new ThemeColor(255, 255, 255, 0)));
    }
}

public class ThemePreferencesDecodingTests
{
    [Fact]
    public void OneBadKeyKeepsTheOthers()
    {
        Assert.Equal(new ThemePreferences { Mode = AppearanceMode.System, LightThemeId = "default-light", DarkThemeId = "silinmiş" },
            ThemePreferences.FromJson("{\"mode\": \"sepya\", \"lightThemeID\": 5, \"darkThemeID\": \"silinmiş\"}"));
        Assert.Equal(new ThemePreferences { Mode = AppearanceMode.Dark, LightThemeId = "paper", DarkThemeId = "default-dark" },
            ThemePreferences.FromJson("{\"mode\": \"dark\", \"lightThemeID\": \"paper\", \"darkThemeID\": null}"));
        Assert.Equal(new ThemePreferences(), ThemePreferences.FromJson("{}"));
        Assert.Equal(new ThemePreferences(), ThemePreferences.FromJson("not json"));
        Assert.Equal(new ThemePreferences(), ThemePreferences.FromJson("[1]"));
    }
}
