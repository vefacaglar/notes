# Notes folder format

The storage contract shared by the macOS and Windows apps. The folder on disk is the only source of truth; there is no database, index or app-specific metadata.

## Layout

- **Root**: a folder chosen by the user (macOS default: `~/Documents/Notes`, Windows default: `%USERPROFILE%\Documents\Notes`). Created if missing. An app may show several roots side by side (a workspace, like VS Code); each root follows this contract on its own, paths are relative to their root, and roots may not be nested inside one another. The list of roots is app preference, not stored in the folders.
- **Notes**: every regular file whose extension is `md` (case-insensitive) is a note. The note's display name is the file name without the extension. Only notes are created by New Note and named automatically.
- **Other text files**: regular files with one of these extensions (case-insensitive) are listed, searched and editable too, but are not notes: `json`, `swift`, `js` `mjs` `cjs` `jsx` `ts` `tsx` `mts` `cts`, `py`, `sh` `bash` `zsh`, `yaml` `yml`, `xml` `html` `htm` `plist` `svg`, `css`, `c` `h` `cc` `cpp` `hpp` `m` `mm` `java` `kt` `kts` `cs` `go` `rs`, `sql`, `toml` `ini`, `markdown` `mdown` `mkd`, `txt`, `log`, `csv`. They are shown with their full file name (extension included). Markdown files with the longer extensions open in the Markdown editor, the rest in a code editor with syntax highlighting; JSON can be reformatted ("Format"). They are never renamed automatically.
- **Large files**: files over 20 MB open read-only; files over 200 MB are not opened. Sizes are checked again when a file is reloaded after an external change: past 200 MB the last text read stays on screen, read-only. Styling is skipped for texts over 2,000,000 UTF-16 code units.
- **Read-only files**: a file the user may not write (permissions, locked item, a folder that refuses writes) opens read-only with a notice instead of failing every save. A symbolic link whose target is missing is not opened or written.
- **Folders**: every subdirectory is a folder, nested to any depth. Empty folders are kept and shown.
- **Ignored**: any file or folder whose name starts with `.` or that the OS marks hidden (macOS hidden flag, Windows Hidden attribute, e.g. `desktop.ini`), and everything below it (e.g. `.git/`), and every file without one of the extensions above (including files without an extension). Apps never list, modify or delete ignored entries.
- **No sidecar files**: apps write nothing but the files and folders themselves (and conflict copies, see *External changes*). Pinning, ordering, tags, timestamps etc. are not stored; modification time comes from the file system.

## Paths and names

- An item is identified by its path relative to the root, using `/` as the separator on every platform (e.g. `Work/Plans/2026.md`). Paths are split at the Unicode scalar U+002F, never at grapheme clusters (a `/` followed by a combining mark is still a separator).
- **Existing items** (anything found on disk) are opened, renamed and trashed whatever their names, so files made by other programs (`Why?.md`, `10:30.md`) keep working. A path is only rejected when a component is empty or starts with `.` (which covers `.`, `..` and hidden names), so it can never leave the root. On Windows a component containing `\ : * ? " < > |` or ending in `.` or a space is rejected too, and entries whose name ends in `.` or a space are not listed: Windows cannot create such names, and Win32 would resolve them to another item (`bar.`, `bar ` → `bar`), a stream or a wildcard.
- **Names the user types** (new folder, rename) and automatic names must follow the portable rules. A name must:
  - be non-empty,
  - not start with `.` (checked on the first Unicode scalar),
  - not end with `.` or a space (checked on the last Unicode scalar),
  - not contain `/ \ : * ? " < > |` or control characters (U+0000–U+001F, U+007F–U+009F), checked per Unicode scalar,
  - not be a Windows reserved device name: `CON`, `PRN`, `AUX`, `NUL`, `COM1`–`COM9`, `LPT1`–`LPT9`, compared case-insensitively on the part before the first `.` with trailing spaces ignored (`con.md`, `Nul.txt` and `LPT1 .md` are reserved; `CONSOLE`, `COM10`, `x.CON` are not).

  These are the Windows file name rules, enforced on both platforms so a folder stays portable. Leading/trailing whitespace is trimmed from user-entered names. A typed name that breaks them is rejected with an error.
- Creating a note appends `.md` if the name lacks it. Renaming keeps the parent folder (a rename never moves an item to another folder). A note keeps its `.md` extension. Another file keeps its extension unless the new name ends in one of the listed extensions: `config.json` → `ayarlar` gives `ayarlar.json`, `ayarlar.yaml` changes it, and `Toplantı 3.5` gives `Toplantı 3.5.json` (`5` is not a listed extension).
- Two names the file system treats as the same file (case-insensitive volumes, Unicode case folding) are the same item; renaming an item to such a spelling of its own name is allowed and goes through a temporary name. If the second step fails, the item is moved back to its old name.

## Automatic naming

Notes are named after their first line, like Apple Notes. Nothing is stored to remember this; it is derived from the name and the content. Only notes (`.md`) inside a root are named automatically, and only while the app's automatic naming setting is on; other text files and Markdown files opened from elsewhere keep their names.

Definitions used below:

- A **line** runs up to (not including) LF (U+000A); a CR (U+000D) right before the LF is ignored. A lone CR, U+2028 etc. are not line breaks.
- **Whitespace** is the Unicode `White_Space` property. A line is **blank** when it has only whitespace.
- Steps work on **Unicode scalars**; "characters" in the length cap are **grapheme clusters** (extended).
- A **number suffix** is a space followed by ASCII digits without a leading zero, with value ≥ 2 (` 2`, ` 12`; not ` 1`, ` 02`, ` 2a`).

Rules:

- **Localized names**: the names apps write follow the app's UI language (the language the app itself is shown in, not the system's preferred-language list; a language the app has no translation for falls back to English): the untitled name is `Untitled` in English and `Adsız` in Turkish; the conflict marker is `conflict` in English and `çakışma` in Turkish. Reading never depends on the language: both untitled names are recognized everywhere.
- **New note**: created at once, without asking for a name, as `<untitled>.md` (`Untitled.md` / `Adsız.md`); if the file system already has an item by that name in the folder (in its own case/Unicode folding), `<untitled> 2.md`, `<untitled> 3.md`, … New folders still ask for a name.
- **Title** of a note's content:
  1. Take the first line that is not blank (leading blank lines are skipped; only as much of the note as needed is read). If it is a thematic break (`---`, `***`) or a code fence, there is no title.
  2. Remove Markdown syntax: heading `#`s (and a closing `#` run), `>` quote markers, list markers (`-`, `*`, `+`, `1.`, `1)`), task boxes (`[ ]`, `[x]`), matched emphasis/strikethrough/code delimiters, link and image syntax (`[text](url)` and `![text](src)` → `text`) and the backslash of backslash escapes. Then trim leftover `*`, `_`, `~`, `` ` `` and whitespace from both ends. Everything else stays text and goes through step 3, for example:
     - autolinks and bare URLs: `<https://a.com>` → `https---a.com`, `https://ex.com/yol` → `https---ex.com-yol`;
     - inline HTML and comments: `Merhaba <b>dünya</b>` → `Merhaba -b-dünya--b-`;
     - entities are not decoded: `Tom &amp; Jerry` → `Tom &amp; Jerry`;
     - escapes: `a\_b` → `a_b`, `\# değil` → `# değil`, `a\\b` → `a-b`; a trailing backslash is kept: `Satır sonu \` → `Satır sonu -`;
     - link reference definitions and tables are plain text: `[x]: https://a` → `[x]- https---a`, `| a | b |` → `- a - b -`.
  3. Make it a valid name, per Unicode scalar: drop `?` and `*`; `"` becomes `'`; `\ / : < > |` become `-`; control characters and whitespace become spaces, and runs of them collapse to one space (none at the start). Then drop leading grapheme clusters whose first scalar is `.` or a space. Then normalize to Unicode NFC.
  4. Cap the length: if it has more than 60 grapheme clusters, take the first 61; if the last space among them has at least 30 clusters before it, cut there, otherwise keep the first 60. Then remove clusters from the end while it is over 200 UTF-8 bytes. Then strip trailing `.` and spaces.
  5. If nothing is left, or only `-` and spaces, there is no title.
  6. If the result is a reserved device name (see *Paths and names*), insert `_` after the part before the first `.` with its trailing spaces: `CON` → `CON_`, `nul.txt` → `nul_.txt`.
- **Auto-named**: a note is auto-named when its name (without `.md`), or that name without a number suffix, is one of the untitled names (`Untitled`, `Adsız`) or equals the title of its content. Names compare after NFC normalization, case-sensitively (`alışveriş` is not `Alışveriş`). This is decided when the note is opened, reloaded after an external change, or renamed by the user (renaming its folder does not count), and holds in between. Any other note was named by hand and is never renamed automatically.
- **Sync**: after each save of an auto-named note, if its first line (not the first non-blank one) is not blank and has a title that differs from both the current name and the name without its number suffix, the file is renamed to that title, made unique in its folder with ` 2`, ` 3`, … (a name is taken when the file system already has an item by that name other than the note's own file, so a case-only change is allowed). If the first line is blank or yields no title, the name is kept. If the rename fails, the note keeps its name and the rename is tried again after the next save.

## Drafts (app state, outside the notes folders)

A new tab opens a draft: an unsaved note that lives only in the app until the user saves it. Drafts are app state, not part of any notes folder.

- Store: one UTF-8 file per draft, named `<32 lowercase hex>.md`, in the app's own folder (Windows: `%LOCALAPPDATA%\Notes\Drafts\`, macOS: `~/Library/Application Support/Notes/Drafts/`), plus `order.txt` listing the draft file names in tab order. Written atomically like notes. Apps never put drafts or anything else into a notes folder before the user saves.
- One app process owns the store at a time, holding an exclusive lock on `.lock` in it (released by the OS when the process ends; macOS uses `flock`). A process that can't get it keeps its drafts in a pending store of its own (Windows: `%LOCALAPPDATA%\Notes\PendingDrafts\<guid>\`, macOS: `~/Library/Application Support/Notes/PendingDrafts/<uuid>/`, locked the same way), says so once, asks before closing a window with non-empty drafts, and on exit moves them into the real store if the lock has become free. Moved drafts get new draft names and are appended to `order.txt`. A pending store that could not be moved stays on disk, and the next process that owns the real store adopts every pending store whose lock it can take, the same way, before restoring. Restore ignores `.lock`, `order.txt` and any name that isn't a draft name.
- A draft whose file changed on disk since it was last read or written here (another writer) is not overwritten: the local text goes to a new draft file and the tab follows it; the old file stays and is restored last.
- Drafts survive closing the app, quitting and logging off without a prompt, and come back as tabs in their order. Empty draft files are deleted at startup. Closing a non-empty draft tab asks Save / Don't Save / Cancel.
- Saving a draft writes `<title>.md` (the title as in *Automatic naming*, else the untitled name, made unique) into the folder selected in the sidebar, else the first root, then deletes the draft file; from then on it is an ordinary auto-named note. Saving an empty draft does nothing. Save As writes anywhere the user picks.

## File contents

- Encoding: **UTF-8**. Apps write UTF-8 **without a BOM**; on read a leading BOM is tolerated and ignored.
- Line endings: apps write **LF** (`\n`). On read, CRLF (`\r\n`) is tolerated and treated as a line break; a file is converted to LF the next time it is saved. A lone CR is ordinary text and is kept. Text entering an editor (typed, pasted) is converted the same way (a leading BOM dropped, CRLF to LF), so the text an app holds always equals what it writes and reads back, and a save is never mistaken for an outside change.
- Files are written atomically: write to a temporary file on the same volume, then replace the original in a way that keeps its metadata (`ReplaceFile` on Windows). On macOS permissions, Finder tags, most extended attributes and the hidden flag are kept; the resource fork (`com.apple.ResourceFork`), the quarantine attribute and hard links are not (the file gets a new inode). Where the private temporary folder can't be used (some network shares), the temporary file is a hidden `.<uuid>.tmp` next to the original. Symbolic links are followed: the link stays and its target is replaced; a link to a missing file is never written.
- Markdown flavour: **CommonMark** plus the GitHub Flavored Markdown extensions **strikethrough** (`~~text~~`) and **task list items** (`- [ ]` / `- [x]`). Other syntax is kept verbatim as plain text.

## Display order

Within a folder: subfolders first, then files (notes and other text files together, by display name); each group in localized natural order (case-insensitive, numbers compared by value: `2` before `10`), as by Finder / Explorer (`localizedStandardCompare` on macOS, `StrCmpLogicalW` on Windows).

Apps may offer two display preferences, which change nothing on disk: sorting by last modified (folders still first and by name, then files newest first, ties by name) and showing only Markdown files (`md`, `markdown`, `mdown`, `mkd`; folders are always shown), which hides the other files from the tree and from search.

## Links

Links in Markdown files are followed from the editor with a plain click or a ⌘-click (Ctrl-click on Windows); a click that only places the caret or ends a drag-selection does nothing. Arrow keys still move through link text, so it stays editable.

- **Web addresses**: any destination with a scheme of two or more letters (`https:`, `http:`, `mailto:`, `file:`…), also bare URLs and `<autolinks>`, opens in the system's default app. A single letter before `:` (`C:\x.md`) is a path, not a scheme.
- **File links** `[text](path)`: a relative path, percent-decoded, without `#fragment` and `?query`, resolved against the folder of the note that holds the link, with `.` and `..` resolved. The target must be inside the same root (`..` above the root resolves to nothing). Matching ignores case and Unicode normalization; a path without extension also tries `.md`. A target that is not among the listed files, or a note outside the roots, is looked up on disk relative to the note's folder; a listed text file opens in a tab, any other file in its default app. Absolute paths (`/…`) are looked up on disk.
- **Wiki links** `[[Note name]]`, `[[Note name|shown text]]` and `[[Note name#heading]]`: only the part before `|` and `#`, trimmed, names the target. The name is compared with every listed file of every root: its display name (file name without `.md`), its full file name (`config.json`), or its path without `.md` (`Work/Plan`, matching from any folder boundary). Comparison folds case with NFC + lowercase, plus Turkish `ı` and `İ` to `i`, so `ÇALIŞMA` finds `çalışma`. Several matches: same folder as the linking note, then same root, then `.md` notes before other files, then fewer path components, then path order.
- A target that does not exist is reported with a neutral message ("There is no note named …"); nothing is created. An opened target goes to a tab: an already open tab is focused, otherwise a new tab opens next to the current one.
- `[[…]]` is styled like a link (brackets as dimmed markers, name as link text). Inside code spans and fenced code it is plain text. Brackets inside the name, or an empty name, make it plain text.

## Editing helpers (Markdown editor)

Each is one undo step. Ranges are UTF-16 offsets; text in the editor has LF line breaks.

- **Return in a list or quote** continues it with the same indentation: `-`, `*`, `+` keep their character, numbered items count up (`9.` → `10.`, `)` kept), task items continue as `- [ ] `, quotes repeat their `>` markers (`> - a` continues as `> - `). The text after the caret moves to the new item. Return on an empty item (marker only, or marker and box) removes the marker and indentation (inside a quote only the quote prefix stays), ending the list. Nothing is continued when a selection exists, the caret is before the text of the item, a marker has no space after it (`-`, `2025.`), the line is a thematic break (`---`, `- - -`), or the line is inside a fenced code block. Following numbers are not renumbered.
- **Tab / Shift-Tab** on a list item line, or on a selection whose lines are all list items, adds or removes one level at the start of the line's indentation (after any quote prefix): 2 spaces for bullets and tasks, the width of the marker plus its space for numbered items (`1. ` = 3, `10. ` = 4). Shift-Tab removes one tab or up to one level of spaces. Anywhere else Tab inserts a tab as before.
- **⌘K (Ctrl+K)** turns the selection into `[selection](|)` with the caret in the parentheses; an empty selection gives `[|]()`; a selected `http(s)` address becomes `[|](address)`.
- **Clicking a task box** `[ ]` / `[x]` (`[X]` counts as checked) flips it to `[x]` / `[ ]` when the file is editable; the caret does not move. Boxes in fenced code are not task items.

## Deleting

Deleting a note or folder moves it to the OS trash (macOS Trash / Windows Recycle Bin) so it can be restored. Apps never delete permanently on their own; where the volume has no trash (e.g. some network shares on Windows), the OS asks the user before deleting permanently, and declining cancels the delete.

## External changes

Other programs (editors, sync clients, git) may change the folder at any time. Apps re-read the tree when they regain focus or when the file system reports a change, and reload an open file that changed on disk unless it has unsaved local edits; the cursor and scroll position are kept.

- **Conflicts**: before saving, an app checks whether the file changed on disk since it was loaded or last saved here: its modification time, size or file identity (inode / file ID) differ from what was recorded after the last load or save. Since some file systems keep modification times to a second or two (HFS+, FAT), the macOS app also compares the disk text with the last saved text when the stamp is unchanged, for files up to 1 MB, and for bigger files only when their modification time is a whole second (a coarse-timestamp volume) and less than two seconds old, so saving a large file on APFS never reads it back. Both texts are compared in their on-disk form (see *File contents*). If it changed and the content differs, the app does not overwrite it: it writes the local text to a new file next to it, `<name> (<conflict>).<ext>` (`(conflict)` / `(çakışma)`, then `(conflict 2)`, `(conflict 3)`, … if taken), opens the disk version and tells the user. If the changed file can't be read (no longer UTF-8, no permission), the local text goes to the conflict copy the same way and editing continues in that copy; the original is left alone. Nothing is lost and no choice is forced in the middle of an autosave or quit.
- **Failed saves** keep the edits in memory and are reported. Switching to another note, renaming or trashing the open note, changing the notes folder, closing its window or quitting does not drop them: the action is cancelled, or the user explicitly chooses to discard the edits.
- **Deleted files**: an open file that disappears is closed only if it is still missing a moment later (some programs save by deleting and recreating) and has no unsaved edits; with unsaved edits the next save recreates it.
- A file opened in two windows is one document: both show the same text.

## Files opened from outside the roots (macOS)

A file that is not inside any root of the main window (opened from Finder, "Open With", the command line) opens in a window of its own, rooted at the file's folder, with the sidebar closed until the user shows it; further files from that folder join that window as tabs. Such a window follows this contract for its folder, with two differences: notes there are never named automatically (the file keeps its name), and ⌘T followed by Save writes the draft into that window's folder (as `<title>.md`, made unique) because it has no selection elsewhere. When a window of this kind is rooted at the home folder or one of its parents, the sidebar lists only a few levels deep. Closing the window moves its drafts, and any file whose last save failed, to the main window; saved files simply close.

## App state (not part of the format)

Besides drafts, apps keep their own state outside the notes folders; none of it is shared or needed to read a folder. The macOS app keeps the list of roots of the main window in its preferences (a root that can't be opened, e.g. an unmounted volume, stays in the list and is shown as unavailable; only the default `~/Documents/Notes` is created when missing, and only on the first run) and the open windows in `~/Library/Application Support/Notes/session.json` (written atomically, only by the process that owns the draft store): per window its outside folder (the main window has none, its roots live in the preferences), the open files by absolute path and drafts by draft file name, the active tab, the source-view toggle, the selection (UTF-16 offsets) and scroll position of each tab, and whether the sidebar is shown. Files and folders that are gone are skipped silently on restore.
