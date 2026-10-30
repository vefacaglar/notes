# State

## RESUME POINT (2026-10-31, before compact)

macOS app on main (local, 20+ commits ahead of origin, NOT pushed): core, live Markdown/code editors, auto-naming, JSON format, themes + settings window + fonts, multi-root workspace, tabs, drafts, session restore, outside-file windows, EN/TR localization with language setting, VS Code macOS tasks, muted palette (1b8fdb7).

In flight — Windows-parity batch done with Pi (opencode-go/deepseek-v4.1-flash) in worktrees (prompts in the session scratchpad pi-b.txt / pi-c.txt):
- B `pi/tabs-editor` worktree scratchpad/wt-b: "+" tab button (tab bar always shown), Format button above JSON + editor context menu item, selected tab blends into editor, Windows placeholder and draft-close wording, Save(retry) in the save-failure close dialog.
- C `pi/sidebar` worktree scratchpad/wt-c: ⌘F search focus, Esc clears, Return renames, ⌘⌫ trashes; New Note (+ New Folder on roots) in context menus; Add Folder toolbar button; search results grouped per root + "No results for “q”"; repeatable -notesFolder and -theme light|dark test flags.
Next: when each finishes, check its output/diff, build + test in the worktree, merge into main (expect Localizable.xcstrings conflicts — merge both key sets), commit, `git worktree remove` + delete branch. Then ONE batched reviewer pass over the whole phase (commits since 8da335e), fixes, then ask the user to look at the app (no screen recording permission here).

Working rules now in CLAUDE.md: Pi for bounded jobs (run in separate worktrees when parallel), explorer agent on Haiku for exploration, swift-dev/windows-dev on Sonnet medium, reviewer (Opus) only for risky changes or batched per phase, commit directly on main, never push unless asked.

## Windows app (2026-10-30)

`apps/windows` (.NET 10, WinUI 3, unpackaged): core port committed (`3f669e3`); app shell in progress — one window, tabs in the extended Mica title bar (TabView), single instance (Explorer opens become tabs; files inside a root map to that root's item), multi-root sidebar like VS Code (roots can't nest), sidebar toggle Ctrl+B, Markdown bold Ctrl+Shift+B, logoff-safe saving (WM_QUERYENDSESSION). Several reviewer rounds applied. Being localized (English base + Turkish, system language, manual `language` setting, `--lang`). VS Code tasks/launch in `.vscode/`. Not exercised with real input yet: typing, IME, drag-drop, shutdown, conflicts, title-bar drag.

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
