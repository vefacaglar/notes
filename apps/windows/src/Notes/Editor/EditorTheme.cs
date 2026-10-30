using Microsoft.UI;
using Microsoft.UI.Xaml;
using NotesCore;
using Windows.UI;

namespace Notes.Editor;

/// <summary>Editor colours per theme (RichEdit takes fixed colours, so they are re-applied when the theme changes) and fonts.</summary>
internal sealed record EditorPalette(
    Color Text, Color Secondary, Color Tertiary, Color Link, Color CodeBackground,
    Color Pink, Color Red, Color Blue, Color Teal, Color Purple)
{
    // The macOS system colours the Mac app uses, in their light and dark variants.
    public static readonly EditorPalette Light = new(
        Hex(0x1B1B1B), Hex(0x5F5F5F), Hex(0x8B8B8B), Hex(0x005FB8), Hex(0xEBEBEB),
        Hex(0xFF2D55), Hex(0xFF3B30), Hex(0x007AFF), Hex(0x30B0C7), Hex(0xAF52DE));

    public static readonly EditorPalette Dark = new(
        Hex(0xFFFFFF), Hex(0xC5C5C5), Hex(0x8F8F8F), Hex(0x60CDFF), Hex(0x3A3A3A),
        Hex(0xFF375F), Hex(0xFF453A), Hex(0x0A84FF), Hex(0x40C8E0), Hex(0xBF5AF2));

    public static EditorPalette For(ElementTheme theme) => theme == ElementTheme.Dark ? Dark : Light;

    private static Color Hex(int rgb) => ColorHelper.FromArgb(0xFF, (byte)(rgb >> 16), (byte)(rgb >> 8), (byte)rgb);

    /// <summary>Colour (and whether semibold) of a code token kind.</summary>
    public (Color Color, bool Semibold) Code(CodeSpanKind kind) => kind switch
    {
        CodeSpanKind.Keyword => (Pink, true),
        CodeSpanKind.Literal => (Pink, false),
        CodeSpanKind.String => (Red, false),
        CodeSpanKind.Number => (Blue, false),
        CodeSpanKind.Comment => (Secondary, false),
        CodeSpanKind.Type => (Teal, false),
        CodeSpanKind.Property => (Purple, false),
        _ => (Blue, false),
    };
}

internal static class EditorFonts
{
    private static string FontsFolder => Environment.GetFolderPath(Environment.SpecialFolder.Fonts);

    public static readonly string Text = File.Exists(Path.Combine(FontsFolder, "SegUIVar.ttf")) ? "Segoe UI Variable Text" : "Segoe UI";
    public static readonly string Mono = File.Exists(Path.Combine(FontsFolder, "CascadiaMono.ttf")) ? "Cascadia Mono" : "Consolas";

    /// <summary>RichEdit sizes are points; the layout uses device-independent pixels.</summary>
    public static float Points(double pixels) => (float)(pixels * 0.75);
}
