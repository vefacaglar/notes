using System.Runtime.InteropServices.WindowsRuntime;
using Microsoft.UI.Xaml;
using NotesCore;
using Windows.ApplicationModel.DataTransfer;
using Windows.Graphics.Imaging;
using Windows.Storage;
using Windows.Storage.Streams;

namespace Notes.Editor;

/// <summary>Pasting and dropping images: each one is saved into the note's <c>assets</c> folder and its Markdown reference inserted
/// (docs/format.md, "Images"). Refused for drafts (no folder yet) and encrypted notes (the file would be plain).</summary>
internal sealed partial class MarkdownEditor
{
    /// <summary>An image to add: a file on disk, or the pixels of a bitmap on the clipboard or in a drag.</summary>
    private abstract record ImageSource;

    private sealed record FileImage(StorageFile File) : ImageSource;

    private sealed record BitmapImageData(RandomAccessStreamReference Reference) : ImageSource;

    private void InitializeImageDrop()
    {
        // A picture or an image file dropped on the text is not something RichEdit can hold as plain text. While such a drag is
        // over the editor, the box leaves the drop to the host around it (which inserts the references).
        Host.AllowDrop = true;
        Box.AddHandler(UIElement.DragEnterEvent, new DragEventHandler((_, e) =>
        {
            if (CanDropImages(e.DataView)) Box.AllowDrop = false;
        }), true);
        Host.DragOver += (_, e) =>
        {
            e.AcceptedOperation = CanDropImages(e.DataView) ? DataPackageOperation.Copy : DataPackageOperation.None;
            e.Handled = true;
        };
        Host.DragLeave += (_, _) => Box.AllowDrop = true;
        Host.Drop += async (_, e) =>
        {
            Box.AllowDrop = true;
            if (!CanDropImages(e.DataView)) return;
            e.Handled = true;
            var deferral = e.GetDeferral();
            try
            {
                Sync();
                var point = e.GetPosition(Box);
                var index = Math.Clamp(Box.Document.GetRangeFromPoint(point, Microsoft.UI.Text.PointOptions.ClientCoordinates).StartPosition, 0, LastText.Length);
                if (await ImagesIn(e.DataView) is { Count: > 0 } sources) await InsertImagesAsync(sources, new MarkdownRange(index, 0));
            }
            finally
            {
                deferral.Complete();
            }
        };
    }

    /// <summary>Whether a drag may hold images (files that are not images are told apart on drop).</summary>
    private bool CanDropImages(DataPackageView view) =>
        !Box.IsReadOnly && !ShowsSource
        && (view.Contains(StandardDataFormats.StorageItems) || (view.Contains(StandardDataFormats.Bitmap) && !view.Contains(StandardDataFormats.Text)));

    /// <summary>What the package offers as images to add to the note, or null when it should be handled as text as before:
    /// image files (only when all items are images), or image data without any text.</summary>
    private static async Task<List<ImageSource>?> ImagesIn(DataPackageView view)
    {
        try
        {
            if (view.Contains(StandardDataFormats.StorageItems))
            {
                var items = await view.GetStorageItemsAsync();
                var files = items.OfType<StorageFile>().ToList();
                if (files.Count == 0 || files.Count != items.Count) return null;
                return files.All(f => f.ContentType.StartsWith("image/", StringComparison.OrdinalIgnoreCase))
                    ? [.. files.Select(f => (ImageSource)new FileImage(f))]
                    : null;
            }
            if (view.Contains(StandardDataFormats.Bitmap) && !view.Contains(StandardDataFormats.Text))
                return [new BitmapImageData(await view.GetBitmapAsync())];
        }
        catch (Exception e) when (e is System.Runtime.InteropServices.COMException or UnauthorizedAccessException or InvalidOperationException)
        {
        }
        return null;
    }

    public override void Paste()
    {
        if (Box.IsReadOnly || ShowsSource) { base.Paste(); return; }
        DataPackageView view;
        try { view = Clipboard.GetContent(); }
        catch (Exception e) when (e is System.Runtime.InteropServices.COMException or UnauthorizedAccessException)
        {
            base.Paste();
            return;
        }
        var mayHoldImages = view.Contains(StandardDataFormats.StorageItems)
            || (view.Contains(StandardDataFormats.Bitmap) && !view.Contains(StandardDataFormats.Text));
        if (!mayHoldImages)
        {
            base.Paste();
            return;
        }
        Sync();
        var selection = CurrentSelection();
        _ = PasteImagesAsync(view, selection);
    }

    private async Task PasteImagesAsync(DataPackageView view, MarkdownRange selection)
    {
        if (await ImagesIn(view) is { Count: > 0 } sources) await InsertImagesAsync(sources, selection);
        else base.Paste();
    }

    /// <summary>PNG, JPEG and GIF files keep their bytes; everything else (BMP, TIFF, screenshots on the clipboard…) becomes PNG.</summary>
    private static async Task<(byte[] Data, string Extension)?> ImageFileAsync(ImageSource source)
    {
        try
        {
            switch (source)
            {
                case FileImage { File: var file }:
                    var extension = file.FileType.TrimStart('.').ToLowerInvariant();
                    if (extension is "png" or "jpg" or "jpeg" or "gif")
                        return ((await FileIO.ReadBufferAsync(file)).ToArray(), extension == "jpeg" ? "jpg" : extension);
                    using (var stream = await file.OpenReadAsync())
                        return await ToPngAsync(stream) is { } png ? (png, "png") : null;
                case BitmapImageData { Reference: var reference }:
                    using (var stream = await reference.OpenReadAsync())
                        return await ToPngAsync(stream) is { } data ? (data, "png") : null;
            }
        }
        catch (Exception e) when (e is System.Runtime.InteropServices.COMException or IOException or UnauthorizedAccessException
            or ArgumentException or InvalidOperationException)
        {
        }
        return null;
    }

    private static async Task<byte[]?> ToPngAsync(IRandomAccessStream source)
    {
        try
        {
            var decoder = await BitmapDecoder.CreateAsync(source);
            using var bitmap = await decoder.GetSoftwareBitmapAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied);
            using var output = new InMemoryRandomAccessStream();
            var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, output);
            encoder.SetSoftwareBitmap(bitmap);
            await encoder.FlushAsync();
            var bytes = new byte[output.Size];
            output.Seek(0);
            await output.ReadAsync(bytes.AsBuffer(), (uint)output.Size, InputStreamOptions.None);
            return bytes;
        }
        catch (Exception e) when (e is System.Runtime.InteropServices.COMException or ArgumentException or InvalidOperationException)
        {
            return null;
        }
    }

    /// <summary>Saves each image into the note's `assets` folder and inserts `![](assets/…)` for them at `range`, one per line,
    /// as a single undo step. A draft has no folder yet and an encrypted note would leak: nothing is saved and a neutral message says so.</summary>
    private async Task InsertImagesAsync(List<ImageSource> sources, MarkdownRange range)
    {
        if (Note.FileName.EndsWith(".mdenc", StringComparison.OrdinalIgnoreCase))
        {
            await ShowImageMessageAsync(Loc.Get("ImageEncrypted"));
            return;
        }
        if (Note.IsDraft)
        {
            await ShowImageMessageAsync(Loc.Get("ImageNeedsFile"));
            return;
        }
        var path = Note.Path;
        Sync();
        var snapshot = LastText;
        var lines = new List<string>();
        string? failure = null;
        foreach (var source in sources)
        {
            if (await ImageFileAsync(source) is not { } file)
            {
                failure = Loc.Get("ImageUnreadable");
                continue;
            }
            try
            {
                lines.Add($"![]({await Task.Run(() => NoteAssets.Save(file.Data, path, file.Extension))})");
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                failure = e.Message;
            }
        }
        if (lines.Count > 0)
        {
            if (Detached) return;
            Sync();
            var length = LastText.Length;
            // Text typed or reloaded meanwhile moved the target: insert at the caret instead of replacing what is there now.
            if (!string.Equals(LastText, snapshot, StringComparison.Ordinal)) range = new MarkdownRange(CurrentSelection().End, 0);
            var at = new MarkdownRange(Math.Min(range.Location, length), Math.Min(range.Length, Math.Max(0, length - Math.Min(range.Location, length))));
            var text = string.Join('\n', lines);
            // At the very end the last image line gets a break too, so the line below can be typed on.
            if (at.End == length) text += "\n";
            var end = at.Location + text.Length;
            ApplyEdit(new TextEdit(at, text, new MarkdownRange(end, 0)));
            Focus();
        }
        if (failure is not null) await ShowImageMessageAsync(failure);
    }

    private async Task ShowImageMessageAsync(string message)
    {
        if (Box.XamlRoot is { } root) await Dialogs.MessageAsync(root, Loc.Get("ImageFailedTitle"), message);
    }
}
