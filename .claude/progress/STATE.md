# State

## RESUME POINT (2026-10-30)

Done (uncommitted): `docs/format.md`; `NotesCore` search ı/İ fix and `MarkdownStyler`; live Markdown editor (`Editor/MarkdownEditor.swift`); app shell (sidebar tree, search, debounced autosave, folder watcher, new/rename/trash, folder picker); `.md` default-app support (document types, standalone windows for outside files); `scripts/bundle.sh`.

In progress:
- Automatic note names from the first line (Apple Notes style; manually renamed notes are left alone).
- Code/JSON files: `CodeHighlighter`, `JSONFormatter` (order-preserving beautify), code editor mode. Phase 2 still to do: list code/text files in the sidebar and search, document types for them in `bundle.sh`, Biçimlendir command.

Next: apply the review findings (same-name rename blanks the editor; autosave overwrites newer disk content; failed save drops edits; notes with non-portable names can't be opened; Return leaves stale styling on the next line; undo shared across notes; same file in two documents; external reload jumps the cursor; plus lower-priority items). Then reviewer pass, visual check in the app, local commits.

Queued UI phase (after the review-fix agent): every window is a workspace with a root folder (main window = notes root; a file opened from Finder outside it = that file's parent folder, sidebar starts collapsed; auto-naming only inside the notes root). In-window tab bar (click opens in current tab or focuses an open tab, ⌘-click / "Yeni Sekmede Aç" new tab, ⌘T, ⌘W). Sidebar toggle ⌃⌘S. "Kaynağı Göster" ⇧⌘R per tab (raw Markdown). Appearance System/Light/Dark + separate theme for light and dark (Theme/ThemeLibrary from the theme agent, user JSON themes in ~/Library/Application Support/Notes/Themes). Settings window (⌘,): Genel (notes folder + Klasör Seç, auto-naming on/off), Görünüm (System/Light/Dark, light theme, dark theme with live preview, "Tema Klasörünü Aç", theme load errors listed), Editör (text font and code font chosen separately from ALL installed font families — searchable list, each name previewed in its own font, default = macOS system font ("Sistem": SF Pro for text, SF Mono for code); size per font. Fonts come ONLY from settings: remove `fonts` from Theme/ResolvedTheme and docs/themes.md (unknown keys are ignored anyway), no per-note font formatting since notes are plain .md; line width limit on/off; show/hide Markdown markers; line spacing; spell check on/off (default OFF); line numbers + line wrap for code files). Also: restore open tabs (per window/workspace: files, active tab, raw-view state, cursor/scroll) after quitting and relaunching — on by default; sidebar sort by name / last modified; show/hide non-.md files in the sidebar.

## Windows app (2026-10-30)

`apps/windows` (.NET 10, WinUI 3, unpackaged): core port committed (`3f669e3`); app shell in progress — one window, tabs in the extended Mica title bar (TabView), single instance (Explorer opens become tabs; files inside a root map to that root's item), multi-root sidebar like VS Code (roots can't nest), sidebar toggle Ctrl+B, Markdown bold Ctrl+Shift+B, logoff-safe saving (WM_QUERYENDSESSION). Several reviewer rounds applied. Being localized (English base + Turkish, system language, manual `language` setting, `--lang`). VS Code tasks/launch in `.vscode/`. Not exercised with real input yet: typing, IME, drag-drop, shutdown, conflicts, title-bar drag.

## macOS follow-ups (do on the Mac; user said don't touch macOS for now)

- Localization like Windows: English base + Turkish, following the system language with an override; on-disk names follow the UI language (`Untitled`/`Adsız`, `(conflict)`/`(çakışma)`), both untitled names recognized for auto-naming (see `docs/format.md`). Error messages in NotesCore localized too.
- Multi-root workspace sidebar and tabs (now in the spec / Windows app) — fold into the queued UI phase.
- Spec additions to mirror: trailing `.`/space names (Windows-only rule), OS-hidden items ignored.

Later: shared test fixtures in `docs/fixtures/` for both apps.
