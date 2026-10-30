using System.Globalization;
using System.Text;

namespace NotesCore;

public sealed class JsonFormatException(int line, int column, int offset, string detail) : Exception
{
    /// <summary>1-based line and column (in grapheme clusters) of the offending token.</summary>
    public int Line { get; } = line;
    public int Column { get; } = column;
    /// <summary>UTF-16 offset of the offending token, for selecting it in a text box.</summary>
    public int Offset { get; } = offset;
    /// <summary>The bare reason, without the position.</summary>
    public string Detail { get; } = detail;

    /// <summary>"Geçersiz JSON (line:column): detail".</summary>
    public override string Message => $"Geçersiz JSON ({Line}:{Column}): {Detail}";
}

/// <summary>Re-indents JSON without parsing values: keys keep their order, strings and numbers keep their exact spelling.</summary>
public static class JsonFormatter
{
    /// <summary>Deepest nesting of objects and arrays that is formatted.</summary>
    public const int MaxDepth = 1_000;

    public static string Format(string text, int indent = 2) => Rewrite(text, Math.Max(0, indent));

    public static string Minify(string text) => Rewrite(text, null);

    private static readonly UTF8Encoding StrictUtf8 = new(false, true);

    private static string Rewrite(string text, int? indent)
    {
        var writer = new Writer(StrictUtf8.GetBytes(text), indent);
        writer.Run();
        return StrictUtf8.GetString(writer.Output.GetBuffer(), 0, (int)writer.Output.Length);
    }
}

public static class CodeLanguageFormatting
{
    /// <summary>Whether "Biçimlendir" is available for this language.</summary>
    public static bool CanFormat(this CodeLanguage language) => language == CodeLanguage.Json;

    /// <summary>The formatted text; throws when the text is invalid or the language has no formatter.</summary>
    public static string Format(this CodeLanguage language, string text) => language switch
    {
        CodeLanguage.Json => JsonFormatter.Format(text),
        _ => throw new JsonFormatException(1, 1, 0, $"{language.DisplayName()} biçimlendirilemiyor"),
    };
}

internal sealed class Writer
{
    private readonly byte[] s;
    private readonly int n;
    private readonly int? indent;
    public readonly MemoryStream Output;
    private int i;
    /// <summary>Open containers: true for objects. Items counts the values written in each.</summary>
    private readonly List<bool> isObject = [];
    private readonly List<int> items = [];
    /// <summary>Set after an opening bracket or a comma: the next token must start an entry.</summary>
    private bool expectsItem;

    public Writer(byte[] bytes, int? indent)
    {
        s = bytes;
        n = bytes.Length;
        this.indent = indent;
        Output = new MemoryStream(bytes.Length + bytes.Length / 4);
        // A UTF-8 byte order mark is not JSON; drop it.
        if (n >= 3 && s[0] == 0xEF && s[1] == 0xBB && s[2] == 0xBF) i = 3;
    }

    private void Put(byte b) => Output.WriteByte(b);

    public void Run()
    {
        SkipWhitespace();
        if (i >= n) throw Error("boş belge");
        Value();
        // A loop rather than recursion, so deep nesting cannot overflow the stack.
        while (isObject.Count > 0)
        {
            SkipWhitespace();
            if (i >= n) throw Error("belge beklenmedik şekilde bitti");
            if (expectsItem)
            {
                expectsItem = false;
                Item();
                continue;
            }
            var top = isObject[^1];
            byte close = top ? (byte)'}' : (byte)']';
            if (s[i] == close)
            {
                CloseContainer();
            }
            else if (s[i] == (byte)',')
            {
                i++;
                Put((byte)',');
                SkipWhitespace();
                if (i >= n) throw Error("belge beklenmedik şekilde bitti");
                if (s[i] == close) throw Error("sondaki virgüle izin verilmez");
                expectsItem = true;
            }
            else
            {
                throw Error(top ? "',' veya '}' bekleniyordu" : "',' veya ']' bekleniyordu");
            }
        }
        SkipWhitespace();
        if (i != n) throw Error("değerden sonra fazladan içerik");
        if (indent != null) Put(10);
    }

    private void SkipWhitespace()
    {
        while (i < n && (s[i] == 32 || s[i] == 10 || s[i] == 13 || s[i] == 9)) i++;
    }

    private void Newline()
    {
        if (indent is not { } width) return;
        Put(10);
        for (var k = width * isObject.Count; k > 0; k--) Put(32);
    }

    /// <summary>A container entry: "key": value in objects, a value in arrays.</summary>
    private void Item()
    {
        items[^1]++;
        Newline();
        if (isObject[^1])
        {
            if (s[i] != 34)
                throw Error(s[i] == 39 || IsLetter(s[i]) ? "anahtar çift tırnak içinde olmalı" : "anahtar bekleniyordu");
            String();
            SkipWhitespace();
            if (i >= n) throw Error("belge beklenmedik şekilde bitti");
            if (s[i] != 58) throw Error("':' bekleniyordu");
            i++;
            Put(58);
            if (indent != null) Put(32);
            SkipWhitespace();
            if (i >= n) throw Error("belge beklenmedik şekilde bitti");
        }
        Value();
    }

    private void Value()
    {
        var b = s[i];
        switch (b)
        {
            case 123 or 91:
            {
                var obj = b == 123;
                // Indented output grows with the square of the depth; real files never come close. Minifying is linear.
                if (indent != null && isObject.Count >= JsonFormatter.MaxDepth)
                    throw Error($"iç içe geçme çok derin (en fazla {JsonFormatter.MaxDepth} düzey)");
                Put(b);
                i++;
                isObject.Add(obj);
                items.Add(0);
                SkipWhitespace();
                if (i >= n) throw Error("belge beklenmedik şekilde bitti");
                if (s[i] == (obj ? 125 : 93)) CloseContainer(); else expectsItem = true;
                break;
            }
            case 34:
                String();
                break;
            case 45 or (>= 48 and <= 57):
                Number();
                break;
            case 116: Literal("true"u8); break;
            case 102: Literal("false"u8); break;
            case 110: Literal("null"u8); break;
            case 39:
                throw Error("dizgeler çift tırnak kullanmalı");
            default:
                throw Unexpected();
        }
    }

    private void CloseContainer()
    {
        var wasObject = isObject[^1];
        var count = items[^1];
        isObject.RemoveAt(isObject.Count - 1);
        items.RemoveAt(items.Count - 1);
        if (count > 0) Newline();
        Put(wasObject ? (byte)'}' : (byte)']');
        i++;
    }

    private void String()
    {
        var start = i;
        i++;
        while (i < n)
        {
            var b = s[i];
            if (b == 34)
            {
                i++;
                Output.Write(s, start, i - start);
                return;
            }
            if (b < 0x20) throw Error("dizgede kaçışsız kontrol karakteri");
            if (b == 92)
            {
                if (i + 1 >= n) break;
                switch (s[i + 1])
                {
                    case 34 or 92 or 47 or 98 or 102 or 110 or 114 or 116:
                        i += 2;
                        break;
                    case 117:
                        if (!(i + 5 < n && IsHexDigit(s[i + 2]) && IsHexDigit(s[i + 3]) && IsHexDigit(s[i + 4]) && IsHexDigit(s[i + 5])))
                            throw Error("geçersiz \\u kaçışı");
                        i += 6;
                        break;
                    default:
                        throw Error("geçersiz kaçış dizisi");
                }
                continue;
            }
            i++;
        }
        i = start;
        throw Error("kapanmamış dizge");
    }

    private void Number()
    {
        var start = i;
        if (s[i] == 45) i++;
        if (i >= n || !IsDigit(s[i])) { i = start; throw Error("geçersiz sayı"); }
        if (s[i] == 48) i++;
        else while (i < n && IsDigit(s[i])) i++;
        if (i < n && s[i] == 46)
        {
            i++;
            if (i >= n || !IsDigit(s[i])) { i = start; throw Error("geçersiz sayı"); }
            while (i < n && IsDigit(s[i])) i++;
        }
        if (i < n && (s[i] == 101 || s[i] == 69))
        {
            i++;
            if (i < n && (s[i] == 43 || s[i] == 45)) i++;
            if (i >= n || !IsDigit(s[i])) { i = start; throw Error("geçersiz sayı"); }
            while (i < n && IsDigit(s[i])) i++;
        }
        if (i < n && (IsLetter(s[i]) || IsDigit(s[i]) || s[i] == 46)) { i = start; throw Error("geçersiz sayı"); }
        Output.Write(s, start, i - start);
    }

    private void Literal(ReadOnlySpan<byte> word)
    {
        if (i + word.Length > n || !s.AsSpan(i, word.Length).SequenceEqual(word)) throw Unexpected();
        Output.Write(word);
        i += word.Length;
    }

    private static bool IsDigit(byte b) => b >= 48 && b <= 57;
    private static bool IsLetter(byte b) => (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || b == 95;
    private static bool IsHexDigit(byte b) => IsDigit(b) || (b >= 65 && b <= 70) || (b >= 97 && b <= 102);

    private JsonFormatException Unexpected()
    {
        // Show the whole character, not one byte of it.
        var end = i + 1;
        while (end < n && (s[end] & 0xC0) == 0x80) end++;
        return Error($"beklenmeyen karakter \"{Encoding.UTF8.GetString(s, i, end - i)}\"");
    }

    private JsonFormatException Error(string message)
    {
        var at = Math.Min(i, n);
        var lineStart = 0;
        var line = 1;
        for (var k = 0; k < at; k++)
        {
            if (s[k] != 10) continue;
            line++;
            lineStart = k + 1;
        }
        var column = new StringInfo(Encoding.UTF8.GetString(s, lineStart, at - lineStart)).LengthInTextElements + 1;
        var offset = Encoding.UTF8.GetString(s, 0, at).Length;
        return new JsonFormatException(line, column, offset, message);
    }
}
