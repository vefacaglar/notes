namespace NotesCore;

public static class MarkdownCodeBlock
{
    /// <summary>
    /// The code of a fenced block (<c>block</c> is the styler's code block range): its lines without the opening fence
    /// and, if the block is closed, without the closing fence; no break after the last line, <c>\n</c> between lines.
    /// </summary>
    public static string Code(string text, MarkdownRange block)
    {
        if (block.Location < 0 || block.End > text.Length) return "";
        var lines = text.Substring(block.Location, block.Length).Split('\n')
            .Select(l => l.EndsWith('\r') ? l[..^1] : l).ToList();
        if (Fence(lines[0]) is not { } open) return "";
        lines.RemoveAt(0);
        if (lines.Count > 0 && Fence(lines[^1]) is { } close && close.Char == open.Char && close.Count >= open.Count
            && IsBlank(lines[^1].TrimStart(' ', '\t')[close.Count..]))
            lines.RemoveAt(lines.Count - 1);
        else if (lines.Count > 0 && lines[^1].Length == 0)
            lines.RemoveAt(lines.Count - 1);
        return string.Join('\n', lines);
    }

    private static bool IsBlank(string s) => s.All(c => c == ' ' || c == '\t');

    private static (char Char, int Count)? Fence(string line)
    {
        var body = line.TrimStart(' ', '\t');
        if (line.Length - body.Length > 3 || body.Length == 0 || body[0] is not ('`' or '~')) return null;
        var ch = body[0];
        var count = 0;
        while (count < body.Length && body[count] == ch) count++;
        return count >= 3 ? (ch, count) : null;
    }
}
