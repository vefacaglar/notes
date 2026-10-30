# State

## RESUME POINT (2026-10-30)

Done (uncommitted): `docs/format.md`; `NotesCore` search ı/İ fix and `MarkdownStyler`; live Markdown editor (`Editor/MarkdownEditor.swift`); app shell (sidebar tree, search, debounced autosave, folder watcher, new/rename/trash, folder picker); `.md` default-app support (document types, standalone windows for outside files); `scripts/bundle.sh`.

In progress:
- Automatic note names from the first line (Apple Notes style; manually renamed notes are left alone).
- Code/JSON files: `CodeHighlighter`, `JSONFormatter` (order-preserving beautify), code editor mode. Phase 2 still to do: list code/text files in the sidebar and search, document types for them in `bundle.sh`, Biçimlendir command.

Next: apply the review findings (same-name rename blanks the editor; autosave overwrites newer disk content; failed save drops edits; notes with non-portable names can't be opened; Return leaves stale styling on the next line; undo shared across notes; same file in two documents; external reload jumps the cursor; plus lower-priority items). Then reviewer pass, visual check in the app, local commits.

Queued UI phase (after the review-fix agent): every window is a workspace with a root folder (main window = notes root; a file opened from Finder outside it = that file's parent folder, sidebar starts collapsed; auto-naming only inside the notes root). In-window tab bar (click opens in current tab or focuses an open tab, ⌘-click / "Yeni Sekmede Aç" new tab, ⌘T, ⌘W). Sidebar toggle ⌃⌘S. "Kaynağı Göster" ⇧⌘R per tab (raw Markdown). Appearance System/Light/Dark + separate theme for light and dark (Theme/ThemeLibrary from the theme agent, user JSON themes in ~/Library/Application Support/Notes/Themes). Settings window (⌘,): Genel (notes folder + Klasör Seç, auto-naming on/off), Görünüm (System/Light/Dark, light theme, dark theme with live preview, "Tema Klasörünü Aç", theme load errors listed), Editör (text font and code font chosen separately from ALL installed font families — searchable list, each name previewed in its own font, default = macOS system font ("Sistem": SF Pro for text, SF Mono for code); size per font. Fonts come ONLY from settings: remove `fonts` from Theme/ResolvedTheme and docs/themes.md (unknown keys are ignored anyway), no per-note font formatting since notes are plain .md; line width limit on/off; show/hide Markdown markers; line spacing; spell check on/off (default OFF); line numbers + line wrap for code files). Also: restore open tabs (per window/workspace: files, active tab, raw-view state, cursor/scroll) after quitting and relaunching — on by default; sidebar sort by name / last modified; show/hide non-.md files in the sidebar.

## Windows app (resume point 2026-10-31)

`apps/windows` (.NET 10, WinUI 3, unpackaged), all committed (3f669e3..b252201), nothing pushed. Done: core port + tests (292 green), one window with tabs in the extended Mica title bar, single instance (Explorer opens become tabs; files inside a root map to that root), VS Code-like multi-root sidebar, Ctrl+B sidebar toggle, Markdown bold Ctrl+Shift+B, raised editor layer (no focus cue or borders, caret only), muted syntax palette, neutral status colors, English/Turkish UI (system language, `language` setting, `--lang`), drafts for new tabs (store lock, pending stores adopted by the next owner), logoff-safe saving. Test overrides: `--root`, `--lang`, `--theme`, `--drafts`. VS Code F5 in `.vscode/`.

Not yet checked by a person in the running app: both themes, selection without borders, colors, draft restore order, Ctrl+S / Ctrl+Shift+S on drafts, title-bar drag, IME, drag-drop, shutdown, conflicts.

Open small items: a pending draft folder can end up without its lock if opening `.lock` fails (`Drafts.Default`), causing duplicate drafts (no loss); the `DraftsUnavailable` text still says drafts are lost on close. Tabs can't be reordered; tab restore after relaunch only for drafts.

## macOS follow-ups (do on the Mac; user said don't touch macOS for now)

- Localization like Windows: English base + Turkish, following the system language with an override; on-disk names follow the UI language (`Untitled`/`Adsız`, `(conflict)`/`(çakışma)`), both untitled names recognized for auto-naming (see `docs/format.md`). Error messages in NotesCore localized too.
- Multi-root workspace sidebar and tabs (now in the spec / Windows app) — fold into the queued UI phase.
- Spec additions to mirror: trailing `.`/space names (Windows-only rule), OS-hidden items ignored.

Later: shared test fixtures in `docs/fixtures/` for both apps.

## Windows parity from the macOS NoteFile review (2026-10-31)

Check the C# port for the same issues fixed on macOS: same-size in-place edits within the mtime granularity (compare content when the stamp is equal), read-only files (open read-only with a clear message instead of failing every save), broken symlinks/junctions (never replace the link, no stamp when the target is missing), replace failing on network shares (fallback temp file in the target folder), size limits re-checked on reload.
- Also check on Windows: pasting CRLF text must not trigger the equal-stamp content check into a conflict copy (normalize on write and when text enters the document); equal-stamp content reads must not stutter on large files; `Drafts.MoveInto` returns early on a failed move without adding already-moved names to order.txt (macOS appends them).

## macOS → Windows gaps (feature comparison, 2026-10-31)

Windows lacks what macOS has: read-only by permission check with a reason banner and tab lock; unavailable roots kept greyed with retry/remove (Windows recreates a missing root at launch, NoteStore.cs:58); session restore of open tabs/active tab/cursor/scroll; window size/position memory; fenced-code highlighting inside Markdown; code line numbers and wrap toggle; Show Source; tab context menu (Close / Close Others / Show in Explorer); tag syntax kind has no colour (falls to number colour, EditorTheme.cs:27-38). Optional: settings window (themes, fonts, sort by modified, auto-naming toggle), hidden markers.
