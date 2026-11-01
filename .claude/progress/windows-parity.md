# Windows parity plan (2026-11-01)

User asked: bring every macOS feature to Windows. Core port first (3 parallel worktree agents), then UI batches.

## User decisions

- Ctrl+F = find in note; Ctrl+Shift+F = sidebar search (like macOS ⌘F / ⇧⌘F).
- Ctrl+B = bold (as docs/format.md says); sidebar toggle moves to Ctrl+Shift+B (Ctrl+\ needs AltGr on a Turkish keyboard).
- One window with tabs stays: outside files open as tabs. Port the other window behaviours (last tab, size/position memory).

## Core port (NotesCore, C#)

- A: MarkdownEditing, MarkdownFormatting, MarkdownTable, MarkdownCodeBlock, MarkdownOutline, TextStatistics.
- B: MarkdownHtml, NoteLinks, NoteAssets, NotePreview, PathList, FuzzyMatch, NoteOperations.
- C: NoteCrypto, Theme, MarkdownStyler/CodeHighlighter catch-up (hidden markers, fences, tags, render ranges), NoteFile parity fixes, Strings.resx owner.

## UI batches (app, sequential where files overlap)

1. Commands and windows: shortcut remap; a command surface (title-bar menu) with File/Edit/Format/View items; tab context menu, middle-click close, Ctrl+1…9, Ctrl+Shift+[ ], tab reorder; window size/position; session.json restore (tabs, active, cursor, scroll, reading/source, sidebar, folder state); read-only banner with reason; unavailable roots greyed with Retry/Remove; neutral InfoBar (no Error severity); last tab closes behaviour.
2. Editor commands: full Format set + formatting bar + table picker/menu; list/quote continuation, indent, table Tab nav, task click; links (relative, wiki, program reveal, missing note msg), Ctrl+K; find bar; status bar; outline; zoom; focus mode; reading mode; show source; spell/caret-line/line width/spacing settings. Editor must pass new Ctrl combos (EditorSupport.cs swallows unknown ones).
3. Editor rendering: hidden markers except at caret (+ Ctrl+Shift+M toggle), bullets •, quote bars, rules, rendered tables, code band + language + copy button, inline images, paste/drop to assets/, code line numbers + wrap toggle.
4. Sidebar: pins, recents (Open Recent), duplicate, drag-drop move, copy in from Explorer, sort by name/date, show other files, previews, quick open Ctrl+P, empty-workspace state.
5. Settings window (Ctrl+,): General, Appearance (themes/fonts from Theme core), Editor, Sidebar; language moves there.
6. Export HTML/PDF/print (Ctrl+Shift+P), protected PDF, encryption UI (.mdenc lock/unlock, new/encrypt/remove, lock all, auto-lock on lock/sleep/idle), About.

## Batch 2 status (editor commands, 2026-11-01)

Done in code, build and tests green, not yet seen in the running app: Format commands (menu, right-click, bar, shortcuts: Ctrl+Shift where macOS has ⌥⌘/⌃⌘), formatting bar above the editor with active states, Return/Tab/table Tab/task click, links (click or Ctrl+click, Open Link, wiki, programs revealed), find/replace panel, status bar, outline flyout (Ctrl+Shift+D), zoom (keys and Ctrl+wheel), focus mode (colour dim + centring), reading mode (outside files open in it) and Show Source, editor settings persisted in settings.json (spell check default off like macOS). Settings window (batch 5) will expose the toggles. Needs a human check: icon glyphs, GetRect-based current-line band and caret centring, Ctrl+wheel scrolling, task click caret restore, plain-click link opening vs double-click.

## Batch 3 status (editor rendering, 2026-11-01)

Done in code, build and tests green, not yet seen in the running app: Markdown syntax hidden by default via RichEdit's hidden-text format (View > Show Markdown Syntax, Ctrl+Shift+M, setting `showMarkdownSyntax`), caret/selection reveal with paired delimiters (pure logic in `MarkdownRendering`, tested), bullets / quote bars / rules drawn on an overlay canvas, rendered tables (hidden pipes, per-cell character spacing, grid drawn behind), fenced code bands with language label, copy button and highlighting, inline images (cache, reserved paragraph spacing, UNC/network paths refused), image paste/drop into `assets/`, code line-number gutter (`codeLineNumbers`), reading mode with all markers hidden. Needs a human check: hidden-text behaviour of RichEdit (caret movement, table column alignment from `Spacing`, empty fence lines), overlay alignment and scroll sync, image drop (`Box.AllowDrop` swap), clipboard image paste.
