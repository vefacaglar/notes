using System.Runtime.InteropServices.WindowsRuntime;
using Microsoft.UI.Xaml.Media.Imaging;
using NotesCore;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace Notes.Editor;

/// <summary>
/// Decoded, size-limited copies of the image files shown under <c>![](…)</c> lines (docs/format.md, "Images"). Files are read and
/// measured off the UI thread; the bitmap (at most 2400 px wide) is created on it. A file that changed on disk (checked at most
/// every 2 s per lookup, and whenever the window becomes active) is loaded again. UI thread only.
/// </summary>
internal sealed class InlineImageCache
{
    public static InlineImageCache Shared { get; } = new();

    private sealed class Entry
    {
        public BitmapImage? Image;
        /// <summary>Displayed size in layout pixels; kept when the bitmap is evicted so the room reserved for the line stays stable.</summary>
        public (double Width, double Height)? Size;
        public NoteFile.Stamp? Stamp;
        public DateTime Checked;
        public bool Loading;
        public int Used;
    }

    private const int Capacity = 48;
    private const long MaxFileSize = 64L * 1_048_576;
    private const int MaxPixelWidth = 2400;
    private static readonly TimeSpan RecheckInterval = TimeSpan.FromSeconds(2);

    private readonly Dictionary<string, Entry> entries = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, Dictionary<object, Action>> waiting = new(StringComparer.OrdinalIgnoreCase);
    private int pass;

    /// <summary>Starts a lookup pass: bitmaps looked up in it are never evicted by it.</summary>
    public void BeginPass() => pass++;

    /// <summary>
    /// The natural size of the image of <paramref name="path"/>; null while it loads for the first time or when the file is missing
    /// or not an image. <paramref name="onUpdate"/> runs when a (re)load of this file finishes; one callback per owner and file.
    /// </summary>
    public (double Width, double Height)? Size(string path, object owner, Action onUpdate)
    {
        var now = DateTime.UtcNow;
        if (!entries.TryGetValue(path, out var entry))
        {
            entries[path] = new Entry { Checked = now, Used = pass };
            Load(path, owner, onUpdate);
            return null;
        }
        entry.Used = pass;
        if (entry.Loading)
        {
            Wait(path, owner, onUpdate);
        }
        else if (entry.Size is not null && entry.Image is null)
        {
            Load(path, owner, onUpdate);
        }
        else if (now - entry.Checked > RecheckInterval)
        {
            entry.Checked = now;
            if (NoteFile.GetStamp(path) != entry.Stamp) Load(path, owner, onUpdate);
        }
        return entry.Size;
    }

    /// <summary>The bitmap already in the cache, without starting a load.</summary>
    public BitmapImage? CachedImage(string path) => entries.TryGetValue(path, out var entry) ? entry.Image : null;

    /// <summary>Makes the next lookup of every file compare its modification stamp.</summary>
    public void ExpireChecks()
    {
        foreach (var entry in entries.Values) entry.Checked = DateTime.MinValue;
    }

    private void Wait(string path, object owner, Action onUpdate)
    {
        if (!waiting.TryGetValue(path, out var owners)) waiting[path] = owners = [];
        owners[owner] = onUpdate;
    }

    private void Load(string path, object owner, Action onUpdate)
    {
        entries[path].Loading = true;
        Wait(path, owner, onUpdate);
        _ = LoadAsync(path);
    }

    private async Task LoadAsync(string path)
    {
        var stamp = NoteFile.GetStamp(path);
        BitmapImage? image = null;
        (double, double)? size = null;
        try
        {
            if (await Task.Run(() => ReadAsync(path)) is { } decoded)
            {
                image = new BitmapImage { DecodePixelWidth = Math.Min((int)decoded.Width, MaxPixelWidth) };
                using (var stream = new InMemoryRandomAccessStream())
                {
                    await stream.WriteAsync(decoded.Bytes.AsBuffer());
                    stream.Seek(0);
                    await image.SetSourceAsync(stream);
                }
                var density = InlineImageLayout.Density(decoded.Dpi);
                size = (decoded.Width / density, decoded.Height / density);
            }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or System.Runtime.InteropServices.COMException or ArgumentException)
        {
            image = null;
            size = null;
        }
        Finish(path, stamp, image, size);
    }

    private sealed record Decoded(byte[] Bytes, uint Width, uint Height, double Dpi);

    private static async Task<Decoded?> ReadAsync(string path)
    {
        try
        {
            byte[] bytes;
            await using (var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            {
                if (file.Length > MaxFileSize || file.Length == 0) return null;
                bytes = new byte[file.Length];
                await file.ReadExactlyAsync(bytes);
            }
            using var stream = new InMemoryRandomAccessStream();
            await stream.WriteAsync(bytes.AsBuffer());
            stream.Seek(0);
            var decoder = await BitmapDecoder.CreateAsync(stream);
            var frame = await decoder.GetFrameAsync(0);
            if (frame.PixelWidth == 0 || frame.PixelHeight == 0) return null;
            return new Decoded(bytes, frame.PixelWidth, frame.PixelHeight, frame.DpiX);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or System.Runtime.InteropServices.COMException
            or ArgumentException or NotSupportedException or InvalidOperationException)
        {
            return null;
        }
    }

    private void Finish(string path, NoteFile.Stamp? stamp, BitmapImage? image, (double, double)? size)
    {
        if (!entries.TryGetValue(path, out var entry))
        {
            waiting.Remove(path);
            return;
        }
        entry.Loading = false;
        entry.Stamp = stamp;
        entry.Checked = DateTime.UtcNow;
        entry.Image = image;
        entry.Size = size;
        Trim();
        if (!waiting.Remove(path, out var owners)) return;
        foreach (var callback in owners.Values) callback();
    }

    /// <summary>Drops the bitmaps that no current pass looked up, oldest first, while more than <see cref="Capacity"/> are held.</summary>
    private void Trim()
    {
        var held = entries.Where(e => e.Value.Image is not null).ToList();
        if (held.Count <= Capacity) return;
        foreach (var (_, entry) in held.Where(e => e.Value.Used < pass && !e.Value.Loading).OrderBy(e => e.Value.Used).Take(held.Count - Capacity))
            entry.Image = null;
    }
}
