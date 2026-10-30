# Notes folder format

The storage contract shared by the macOS and Windows apps. The folder on disk is the only source of truth; there is no database, index or app-specific metadata.

## Layout

- **Root**: one folder chosen by the user (macOS default: `~/Documents/Notes`). Created if missing.
- **Notes**: every regular file whose extension is `md` (case-insensitive) is a note. The note's display name is the file name without the extension. Only notes are created by New Note and named automatically.
- **Other text files**: regular files with one of these extensions (case-insensitive) are listed, searched and editable too, but are not notes: `json`, `swift`, `js` `mjs` `cjs` `jsx` `ts` `tsx` `mts` `cts`, `py`, `sh` `bash` `zsh`, `yaml` `yml`, `xml` `html` `htm` `plist` `svg`, `css`, `c` `h` `cc` `cpp` `hpp` `m` `mm` `java` `kt` `kts` `cs` `go` `rs`, `sql`, `toml` `ini`, `markdown`, `txt`, `log`, `csv`. They are shown with their full file name (extension included) and opened in a code editor with syntax highlighting; JSON can be reformatted ("Biçimlendir"). They are never renamed automatically.
- **Folders**: every subdirectory is a folder, nested to any depth. Empty folders are kept and shown.
- **Ignored**: any file or folder whose name starts with `.` (and everything below it, e.g. `.git/`), and every file without one of the extensions above (including files without an extension). Apps never list, modify or delete ignored entries.
- **No sidecar files**: apps write nothing but the files and folders themselves (and conflict copies, see *External changes*). Pinning, ordering, tags, timestamps etc. are not stored; modification time comes from the file system.

## Paths and names

- An item is identified by its path relative to the root, using `/` as the separator on every platform (e.g. `Work/Plans/2026.md`). Paths are split at the Unicode scalar U+002F, never at grapheme clusters (a `/` followed by a combining mark is still a separator).
- **Existing items** (anything found on disk) are opened, renamed and trashed whatever their names, so files made by other programs (`Why?.md`, `10:30.md`) keep working. A path is only rejected when a component is empty or starts with `.` (which covers `.`, `..` and hidden names), so it can never leave the root.
- **Names the user types** (new folder, rename) and automatic names must follow the portable rules. A name must:
  - be non-empty,
  - not start with `.` (checked on the first Unicode scalar),
  - not end with `.` or a space (checked on the last Unicode scalar),
  - not contain `/ \ : * ? " < > |` or control characters (U+0000–U+001F, U+007F–U+009F), checked per Unicode scalar,
  - not be a Windows reserved device name: `CON`, `PRN`, `AUX`, `NUL`, `COM1`–`COM9`, `LPT1`–`LPT9`, compared case-insensitively on the part before the first `.` with trailing spaces ignored (`con.md`, `Nul.txt` and `LPT1 .md` are reserved; `CONSOLE`, `COM10`, `x.CON` are not).

  These are the Windows file name rules, enforced on both platforms so a folder stays portable. Leading/trailing whitespace is trimmed from user-entered names. A typed name that breaks them is rejected with an error.
- Creating a note appends `.md` if the name lacks it. Renaming keeps the parent folder (a rename never moves an item to another folder). A note keeps its `.md` extension; another file keeps its extension when the new name has none (`config.json` → `ayarlar` gives `ayarlar.json`, `ayarlar.yaml` changes it).
- Two names the file system treats as the same file (case-insensitive volumes, Unicode case folding) are the same item; renaming an item to such a spelling of its own name is allowed and goes through a temporary name. If the second step fails, the item is moved back to its old name.

## Automatic naming (Otomatik adlandırma)

Notes are named after their first line, like Apple Notes. Nothing is stored to remember this; it is derived from the name and the content. Only notes (`.md`) inside the notes folder are named automatically; other text files and Markdown files opened from elsewhere keep their names.

Definitions used below:

- A **line** runs up to (not including) LF (U+000A); a CR (U+000D) right before the LF is ignored. A lone CR, U+2028 etc. are not line breaks.
- **Whitespace** is the Unicode `White_Space` property. A line is **blank** when it has only whitespace.
- Steps work on **Unicode scalars**; "characters" in the length cap are **grapheme clusters** (extended).
- A **number suffix** is a space followed by ASCII digits without a leading zero, with value ≥ 2 (` 2`, ` 12`; not ` 1`, ` 02`, ` 2a`).

Rules:

- **New note**: created at once, without asking for a name, as `Adsız.md`; if the file system already has an item by that name in the folder (in its own case/Unicode folding), `Adsız 2.md`, `Adsız 3.md`, … New folders still ask for a name.
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
- **Auto-named**: a note is auto-named when its name (without `.md`), or that name without a number suffix, is `Adsız` or equals the title of its content. Names compare after NFC normalization, case-sensitively (`alışveriş` is not `Alışveriş`). This is decided when the note is opened (or reloaded after an external change) and holds while it stays open. Any other note was named by hand and is never renamed automatically.
- **Sync**: after each save of an auto-named note, if its first line (not the first non-blank one) is not blank and has a title that differs from both the current name and the name without its number suffix, the file is renamed to that title, made unique in its folder with ` 2`, ` 3`, … (a name is taken when the file system already has an item by that name other than the note's own file, so a case-only change is allowed). If the first line is blank or yields no title, the name is kept. If the rename fails, the note keeps its name and the rename is tried again after the next save.

## File contents

- Encoding: **UTF-8**. Apps write UTF-8 **without a BOM**; on read a leading BOM is tolerated and ignored.
- Line endings: apps write **LF** (`\n`). On read, CRLF (`\r\n`) is tolerated and treated as a line break; a file is converted to LF the next time it is saved.
- Files are written atomically (write to a temporary file, then replace).
- Markdown flavour: **CommonMark** plus the GitHub Flavored Markdown extensions **strikethrough** (`~~text~~`) and **task list items** (`- [ ]` / `- [x]`). Other syntax is kept verbatim as plain text.

## Display order

Within a folder: subfolders first, then files (notes and other text files together, by display name); each group in localized natural order (case-insensitive, numbers compared by value: `2` before `10`), as by Finder / Explorer (`localizedStandardCompare` on macOS, `StrCmpLogicalW` on Windows).

## Deleting

Deleting a note or folder moves it to the OS trash (macOS Trash / Windows Recycle Bin) so it can be restored. Apps never delete permanently.

## External changes

Other programs (editors, sync clients, git) may change the folder at any time. Apps re-read the tree when they regain focus or when the file system reports a change, and reload an open file that changed on disk unless it has unsaved local edits; the cursor and scroll position are kept.

- **Conflicts**: before saving, an app checks whether the file changed on disk since it was loaded or last saved (modification time, then content). If it did and the content differs, the app does not overwrite it: it writes the local text to a new file next to it, `<name> (çakışma).<ext>` (then `(çakışma 2)`, `(çakışma 3)`, … if taken), opens the disk version and tells the user. Nothing is lost and no choice is forced in the middle of an autosave or quit.
- **Failed saves** keep the edits in memory and are reported. Switching to another note, renaming or trashing the open note, changing the notes folder, closing its window or quitting does not drop them: the action is cancelled, or the user explicitly chooses to discard the edits.
- **Deleted files**: an open file that disappears is closed only if it is still missing a moment later (some programs save by deleting and recreating) and has no unsaved edits; with unsaved edits the next save recreates it.
- A file opened in two windows is one document: both show the same text.
