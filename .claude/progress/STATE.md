# State

## RESUME POINT (2026-10-31, before compact)

macOS app on main (local, 20+ commits ahead of origin, NOT pushed): core, live Markdown/code editors, auto-naming, JSON format, themes + settings window + fonts, multi-root workspace, tabs, drafts, session restore, outside-file windows, EN/TR localization with language setting, VS Code macOS tasks, muted palette (1b8fdb7).

Windows-parity batch done and merged (Pi B: df63a8d, Pi C: dee1168): "+" tab button, Format button/menu, tab blending, Save(retry) on failed close; sidebar ⌘F/Esc/Return/⌘⌫, New Note in menus, Add Folder button, grouped search, repeatable -notesFolder, -theme.
Batched review done; fixes in 99c49ce (⇧⌘F sidebar search, test-run prefs suite, close/quit retry, ownsDraftStore, restore fixes). Also 2bc572e: tab bar at top with no tab, no app-name title.
Next: user looks at the app (relaunch needed); unverified by hand: ⇧⌘F focus (collapsed sidebar, macOS 14/15), Try Again loops, test-run prefs isolation.

Working rules now in CLAUDE.md: Pi for bounded jobs (run in separate worktrees when parallel), explorer agent on Haiku for exploration, swift-dev/windows-dev on Sonnet medium, reviewer (Opus) only for risky changes or batched per phase, commit directly on main, never push unless asked.

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
