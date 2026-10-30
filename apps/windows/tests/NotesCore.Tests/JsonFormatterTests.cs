using NotesCore;

namespace NotesCore.Tests;

public sealed class JsonFormatterTests
{
    [Fact]
    public void FormatsNestedAndKeepsKeyOrder()
    {
        var input = "{\"z\":1,\"a\":{\"y\":[1,2,{\"k\":\"v\"}],\"b\":{},\"c\":[]},\"m\":[[]],\"e\":\"son\"}";
        var expected = string.Join("\n",
            "{",
            "  \"z\": 1,",
            "  \"a\": {",
            "    \"y\": [",
            "      1,",
            "      2,",
            "      {",
            "        \"k\": \"v\"",
            "      }",
            "    ],",
            "    \"b\": {},",
            "    \"c\": []",
            "  },",
            "  \"m\": [",
            "    []",
            "  ],",
            "  \"e\": \"son\"",
            "}",
            "");
        Assert.Equal(expected, JsonFormatter.Format(input));
    }

    [Fact]
    public void NumbersAndStringsAreCopiedVerbatim()
    {
        var input = "[12345678901234567890, 1e-7, -0.0, 1.50, 2E+10, \"\\u00e7\\/\\n\", \"ğüşİ \U0001F600\", \"\\ud83d\\ude00\"]";
        Assert.Equal("[12345678901234567890,1e-7,-0.0,1.50,2E+10,\"\\u00e7\\/\\n\",\"ğüşİ \U0001F600\",\"\\ud83d\\ude00\"]", JsonFormatter.Minify(input));
        var formatted = JsonFormatter.Format(input, 4);
        Assert.StartsWith("[\n    12345678901234567890,\n    1e-7,\n    -0.0,\n    1.50,", formatted);
        Assert.Contains("    \"\\u00e7\\/\\n\",", formatted);
    }

    [Fact]
    public void FormattingIsIdempotentAndScalarsWork()
    {
        var once = JsonFormatter.Format(" {\r\n\t\"a\" : [ true , false , null ] } ");
        Assert.Equal(once, JsonFormatter.Format(once));
        Assert.Equal("\"tek\"\n", JsonFormatter.Format("  \"tek\" "));
        Assert.Equal("{}\n", JsonFormatter.Format("{ }"));
        Assert.Equal("{\"a\":[true,false,null]}", JsonFormatter.Minify(once));
    }

    [Fact]
    public void DeepNestingDoesNotRecurse()
    {
        const int depth = 100_000;
        var input = new string('[', depth) + new string(']', depth);
        Assert.Equal(input, JsonFormatter.Minify(input));
    }

    public static TheoryData<string, int, int, string> Invalid => new()
    {
        { "[1, 2,]", 1, 7, "trailing commas are not allowed" },
        { "{\"a\": 1,\n }", 2, 2, "trailing commas are not allowed" },
        { "{a: 1}", 1, 2, "keys must be in double quotes" },
        { "{'a': 1}", 1, 2, "keys must be in double quotes" },
        { "{\"a\": [1, 2", 1, 12, "unexpected end of document" },
        { "{\"çğ\": \"açık", 1, 8, "unterminated string" },
        { "", 1, 1, "empty document" },
        { "[01]", 1, 2, "invalid number" },
        { "[1.]", 1, 2, "invalid number" },
        { "[.5]", 1, 2, "unexpected character \".\"" },
        { "[NaN]", 1, 2, "unexpected character \"N\"" },
        { "[tru]", 1, 2, "unexpected character \"t\"" },
        { "{\"a\" 1}", 1, 6, "expected ':'" },
        { "[1 2]", 1, 4, "expected ',' or ']'" },
        { "{} []", 1, 4, "extra content after the value" },
        { "[\"a\tb\"]", 1, 4, "unescaped control character in string" },
        { "[\"\\x\"]", 1, 3, "invalid escape sequence" },
        { "[\"\\u12G4\"]", 1, 3, "invalid \\u escape" },
        { "// yorum\n{}", 1, 1, "unexpected character \"/\"" },
        { "[\"ş\", ü]", 1, 7, "unexpected character \"ü\"" },
    };

    [Theory]
    [MemberData(nameof(Invalid))]
    public void RejectsInvalidJson(string input, int line, int column, string message)
    {
        var error = Assert.Throws<JsonFormatException>(() => JsonFormatter.Format(input));
        Assert.Equal(line, error.Line);
        Assert.Equal(column, error.Column);
        Assert.Equal(message, error.Detail);
        Assert.Equal($"Invalid JSON ({line}:{column}): {message}", error.Message);
    }

    [Fact]
    public void ErrorMessagesFollowTheUiLanguage()
    {
        using var _ = TestCulture.Use("tr");
        var error = Assert.Throws<JsonFormatException>(() => JsonFormatter.Format("[1, 2,]"));
        Assert.Equal("sondaki virgüle izin verilmez", error.Detail);
        Assert.Equal("Ge\u00e7ersiz JSON (1:7): sondaki virg\u00fcle izin verilmez", error.Message);
        Assert.Contains("iç içe geçme çok derin", Assert.Throws<JsonFormatException>(() =>
            JsonFormatter.Format("[" + new string('[', JsonFormatter.MaxDepth) + new string(']', JsonFormatter.MaxDepth) + "]")).Detail);
        Assert.Equal("beklenmeyen karakter \"ü\"", Assert.Throws<JsonFormatException>(() => JsonFormatter.Format("[\"ş\", ü]")).Detail);
        Assert.Equal("YAML biçimlendirilemiyor", Assert.Throws<JsonFormatException>(() => CodeLanguage.Yaml.Format("a: 1")).Detail);
    }

    [Fact]
    public void ErrorOffsetIsUtf16()
    {
        var error = Assert.Throws<JsonFormatException>(() => JsonFormatter.Format("{\"\U0001F600\": x}"));
        Assert.Equal(1, error.Line);
        Assert.Equal(7, error.Column);
        Assert.Equal(7, error.Offset);
        Assert.Equal("unexpected character \"x\"", error.Detail);
    }

    [Fact]
    public void LanguageFormatting()
    {
        Assert.True(CodeLanguage.Json.CanFormat());
        Assert.False(CodeLanguage.Yaml.CanFormat());
        Assert.Equal("[\n  1\n]\n", CodeLanguage.Json.Format("[1]"));
        Assert.Throws<JsonFormatException>(() => CodeLanguage.Swift.Format("x"));
    }

    [Fact]
    public void LargeDocumentIsFast()
    {
        const string item = "{\"ad\": \"Çağlar\", \"sayı\": -12.5e3, \"liste\": [1, 2, 3], \"ok\": true, \"x\": null}";
        var input = "[" + string.Join(",", Enumerable.Repeat(item, 20_000)) + "]";
        var watch = System.Diagnostics.Stopwatch.StartNew();
        var output = JsonFormatter.Format(input);
        watch.Stop();
        Assert.True(output.Length > input.Length);
        Assert.True(watch.Elapsed < TimeSpan.FromSeconds(2), watch.Elapsed.ToString());
    }

    [Fact]
    public void RefusesExtremeNesting()
    {
        var ok = new string('[', JsonFormatter.MaxDepth) + new string(']', JsonFormatter.MaxDepth);
        JsonFormatter.Format(ok);
        var deep = "[" + ok + "]";
        var error = Assert.Throws<JsonFormatException>(() => JsonFormatter.Format(deep));
        Assert.Equal(JsonFormatter.MaxDepth, error.Offset);
        Assert.Contains("too deep", error.Detail);
    }

    [Fact]
    public void LoneSurrogatesAreAnErrorNotAReplacementCharacter()
    {
        Assert.ThrowsAny<Exception>(() => JsonFormatter.Format("{\"a\": \"\uD800\"}"));
        Assert.ThrowsAny<Exception>(() => JsonFormatter.Minify("[\"\uDC00\"]"));
    }
}
