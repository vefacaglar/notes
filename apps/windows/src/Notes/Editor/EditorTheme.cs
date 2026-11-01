using Microsoft.UI;
using Microsoft.UI.Xaml;
using NotesCore;
using Windows.UI;

namespace Notes.Editor;

/// <summary>Editor colours per theme (RichEdit takes fixed colours, so they are re-applied when the theme changes) and fonts.</summary>
internal sealed record EditorPalette(
    Color Text, Color Secondary, Color Tertiary, Color Link, Color CodeBackground,
    Color Pink, Color Red, Color Blue, Color Teal, Color Purple, Color CurrentLine, Color Dim)
{
    // Muted, low-saturation tokens that sit close to the text in lightness. Contrast against the editor layer
    // (light about #FAFAFA, dark about #272727): tokens 5.0-6.9:1, secondary 6.1/8.7:1, comments and markers 4.4/4.3:1.
    public static readonly EditorPalette Light = new(
        Hex(0x1B1B1B), Hex(0x5F5F5F), Hex(0x767676), Hex(0x2F6396), Hex(0xF1F1F1),
        Hex(0x8C4A6B), Hex(0x8A5A3C), Hex(0x3F6A95), Hex(0x2F7771), Hex(0x6E5A94),
        Hex(0xEFEFEF), Hex(0xB7B7B7));

    public static readonly EditorPalette Dark = new(
        Hex(0xFFFFFF), Hex(0xC5C5C5), Hex(0x8A8A8A), Hex(0x8DB4DE), Hex(0x313131),
        Hex(0xD18AA8), Hex(0xC9A27F), Hex(0x86A9D1), Hex(0x7FBAB3), Hex(0xA99BD0),
        Hex(0x313131), Hex(0x686868));

    public static EditorPalette For(ElementTheme theme) => theme == ElementTheme.Dark ? Dark : Light;

    private static Color Hex(int rgb) => ColorHelper.FromArgb(0xFF, (byte)(rgb >> 16), (byte)(rgb >> 8), (byte)rgb);

    // CurrentLine: a neutral band a step off the editor layer. Dim: the text colour at 30% over the layer, for focus mode.

    /// <summary>Colour (and whether semibold) of a code token kind.</summary>
    public (Color Color, bool Semibold) Code(CodeSpanKind kind) => kind switch
    {
        CodeSpanKind.Keyword => (Pink, true),
        CodeSpanKind.Literal => (Pink, false),
        CodeSpanKind.String => (Red, false),
        CodeSpanKind.Number => (Blue, false),
        CodeSpanKind.Comment => (Tertiary, false),
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

    /// <summary>The text size in pixels at the current zoom.</summary>
    public static double Scaled(double pixels) => pixels * AppSettings.Zoom;
}
