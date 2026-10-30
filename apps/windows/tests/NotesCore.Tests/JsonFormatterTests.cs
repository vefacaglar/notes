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
        { "[1, 2,]", 1, 7, "sondaki virgüle izin verilmez" },
        { "{\"a\": 1,\n }", 2, 2, "sondaki virgüle izin verilmez" },
        { "{a: 1}", 1, 2, "anahtar çift tırnak içinde olmalı" },
        { "{'a': 1}", 1, 2, "anahtar çift tırnak içinde olmalı" },
        { "{\"a\": [1, 2", 1, 12, "belge beklenmedik şekilde bitti" },
        { "{\"çğ\": \"açık", 1, 8, "kapanmamış dizge" },
        { "", 1, 1, "boş belge" },
        { "[01]", 1, 2, "geçersiz sayı" },
        { "[1.]", 1, 2, "geçersiz sayı" },
        { "[.5]", 1, 2, "beklenmeyen karakter \".\"" },
        { "[NaN]", 1, 2, "beklenmeyen karakter \"N\"" },
        { "[tru]", 1, 2, "beklenmeyen karakter \"t\"" },
        { "{\"a\" 1}", 1, 6, "':' bekleniyordu" },
        { "[1 2]", 1, 4, "',' veya ']' bekleniyordu" },
        { "{} []", 1, 4, "değerden sonra fazladan içerik" },
        { "[\"a\tb\"]", 1, 4, "dizgede kaçışsız kontrol karakteri" },
        { "[\"\\x\"]", 1, 3, "geçersiz kaçış dizisi" },
        { "[\"\\u12G4\"]", 1, 3, "geçersiz \\u kaçışı" },
        { "// yorum\n{}", 1, 1, "beklenmeyen karakter \"/\"" },
        { "[\"ş\", ü]", 1, 7, "beklenmeyen karakter \"ü\"" },
    };

    [Theory]
    [MemberData(nameof(Invalid))]
    public void RejectsInvalidJson(string input, int line, int column, string message)
    {
        var error = Assert.Throws<JsonFormatException>(() => JsonFormatter.Format(input));
        Assert.Equal(line, error.Line);
        Assert.Equal(column, error.Column);
        Assert.Equal(message, error.Detail);
        Assert.Equal($"Geçersiz JSON ({line}:{column}): {message}", error.Message);
    }

    [Fact]
    public void ErrorOffsetIsUtf16()
    {
        var error = Assert.Throws<JsonFormatException>(() => JsonFormatter.Format("{\"\U0001F600\": x}"));
        Assert.Equal(1, error.Line);
        Assert.Equal(7, error.Column);
        Assert.Equal(7, error.Offset);
        Assert.Equal("beklenmeyen karakter \"x\"", error.Detail);
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
        Assert.Contains("çok derin", error.Detail);
    }

    [Fact]
    public void LoneSurrogatesAreAnErrorNotAReplacementCharacter()
    {
        Assert.ThrowsAny<Exception>(() => JsonFormatter.Format("{\"a\": \"\uD800\"}"));
        Assert.ThrowsAny<Exception>(() => JsonFormatter.Minify("[\"\uDC00\"]"));
    }
}
