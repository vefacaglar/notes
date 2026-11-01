using System.Globalization;
using System.Text;

namespace NotesCore;

/// <summary>
/// Subsequence matching for Quick Open: the query's characters must appear in order, case, diacritics and the Turkish
/// dotless ı ignored. Consecutive matches, matches at word starts and early matches score higher.
/// </summary>
public static class FuzzyMatch
{
    /// <summary>An item to match: its name, and its path for queries that name a folder too. Folded once, up front.</summary>
    public sealed class Candidate
    {
        internal int[] Name { get; }
        internal int[] Path { get; }

        public Candidate(string name, string path)
        {
            Name = Fold(name);
            Path = Fold(path);
        }
    }

    /// <summary>`text` lowercased, without diacritics and with ı/İ as i, as Unicode scalars.</summary>
    internal static int[] Fold(string text)
    {
        var decomposed = text.Replace('ı', 'i').Replace('İ', 'i').Normalize(NormalizationForm.FormD);
        var folded = new StringBuilder(decomposed.Length);
        foreach (var c in decomposed)
            if (CharUnicodeInfo.GetUnicodeCategory(c) != UnicodeCategory.NonSpacingMark) folded.Append(c);
        return folded.ToString().ToLowerInvariant().EnumerateRunes().Select(r => r.Value).ToArray();
    }

    /// <summary>The score of `query` in `text` (both folded), <c>null</c> when it is not a subsequence. Higher is better.</summary>
    internal static int? Score(int[] query, int[] text)
    {
        if (query.Length == 0) return 0;
        if (query.Length > text.Length) return null;
        // Forward pass finds the earliest end; the backward pass then shrinks the match to the tightest window.
        var matched = 0;
        var end = -1;
        for (var index = 0; index < text.Length; index++)
        {
            if (text[index] != query[matched]) continue;
            matched++;
            if (matched == query.Length)
            {
                end = index;
                break;
            }
        }
        if (end < 0) return null;
        var positions = new int[query.Length];
        var at = end;
        for (var q = query.Length - 1; q >= 0; q--)
        {
            while (text[at] != query[q]) at--;
            positions[q] = at;
            at--;
        }

        var score = 0;
        for (var q = 0; q < positions.Length; q++)
        {
            var position = positions[q];
            score += 10;
            if (q > 0 && position == positions[q - 1] + 1) score += 15;
            if (position == 0 || !IsWordCharacter(text[position - 1])) score += 12;
        }
        var span = end - positions[0] + 1;
        score -= span - query.Length;
        score -= Math.Min(positions[0], 20);
        if (positions[0] == 0) score += 20;
        if (span == text.Length) score += 30;
        return score;
    }

    private static bool IsWordCharacter(int scalar)
    {
        var rune = new Rune(scalar);
        return Rune.IsLetter(rune) || Rune.IsNumber(rune)
            || Rune.GetUnicodeCategory(rune) is UnicodeCategory.SpacingCombiningMark or UnicodeCategory.EnclosingMark;
    }

    /// <summary>
    /// The indexes of `candidates` that match `query`, best first (ties keep the given order); a match in the name beats
    /// one that needs the folder path. An empty query matches everything in the given order. At most `limit` indexes.
    /// </summary>
    public static List<int> Rank(string query, IReadOnlyList<Candidate> candidates, int limit = 100)
    {
        var folded = Fold(query.Trim());
        if (folded.Length == 0) return Enumerable.Range(0, candidates.Count).Take(limit).ToList();
        var scored = new List<(int Index, int Score)>();
        for (var index = 0; index < candidates.Count; index++)
        {
            if (Score(folded, candidates[index].Name) is { } nameScore) scored.Add((index, nameScore + 100));
            else if (Score(folded, candidates[index].Path) is { } pathScore) scored.Add((index, pathScore));
        }
        return scored.OrderByDescending(s => s.Score).ThenBy(s => s.Index).Take(limit).Select(s => s.Index).ToList();
    }
}
