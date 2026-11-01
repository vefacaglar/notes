# State

## Next (2026-11-01)

- Done today (macOS): toolbar with a centered formatting capsule (title kept but empty: hiding or removing it lines toolbar items up on the left; SwiftUI resets `titleVisibility`), Format icon for code files, middle-click closes a tab, Markdown syntax hidden by default with a toolbar/⇧⌘M toggle, sidebar folder open/closed state in session.json, new app icon, `scripts/install.sh` (→ /Applications).
- Later (0cb9374, a08aa4a, reviewed): hidden syntax shows only the markers the cursor touches (plus both delimiters of the element it is in), fences hide too; reading mode (⇧⌘E, app-wide, remembered); closing the last tab closes the window and the app keeps running (reopen via Dock/⌘N/Finder); the first run opens an empty draft. Verified in a test instance via AX: marker widths per caret position, reading mode, first-run draft (nothing written to the folder until saved, restored once). Not verified by hand: the last-tab window close itself and reopening (tab close buttons aren't reachable in the background), ⌘Z in reading mode. Reviewer leftover: a huge fenced block re-highlights when the caret crosses its closing fence (perf only).
- Next phase the user asked for: save notes encrypted to a database through an API. Open questions put to the user (no answers yet): which server/DB (own API vs Supabase/Firebase/existing), backup vs two-way sync, end-to-end encryption on the client (recommended; builds on `.mdenc`), which notes, single user vs accounts. It changes the "folder is the only source of truth" rule in docs/format.md: write a design doc first.

## Encrypted notes (macOS, 2026-11-01: 2505606, 97fcd9b)

`.mdenc` notes (docs/format.md "Encrypted notes", with a test vector for the Windows port), lock/unlock, Encrypt / Remove Encryption / New Encrypted Note, auto-lock, password PDF, Export as Encrypted Note. Reviewed (Opus), all findings fixed. Verified in a test instance: locked open, wrong/right password, encrypted save (independently decrypted), Lock, restore opens locked, session.json paths only. Not verified by hand (window-focused commands couldn't run in the background): Encrypt / Remove Encryption / New Encrypted Note dialogs, PDF password panel, Export as Encrypted Note, image refusal, idle/sleep/screen-lock triggers, Settings picker; whether macOS saved window state captures an unlocked note. Windows: not implemented (ignores `.mdenc`).

## RESUME POINT (2026-10-31, before compact)

macOS app on main (local, 20+ commits ahead of origin, NOT pushed): core, live Markdown/code editors, auto-naming, JSON format, themes + settings window + fonts, multi-root workspace, tabs, drafts, session restore, outside-file windows, EN/TR localization with language setting, VS Code macOS tasks, muted palette (1b8fdb7).

Windows-parity batch done and merged (Pi B: df63a8d, Pi C: dee1168): "+" tab button, Format button/menu, tab blending, Save(retry) on failed close; sidebar ⌘F/Esc/Return/⌘⌫, New Note in menus, Add Folder button, grouped search, repeatable -notesFolder, -theme.
Feature phase 2 merged (2026-10-31, b212835..HEAD): full-width editor default; list continuation/indent/⌘K/task toggle/links ([[wiki]], relative .md; programs revealed not run); find shortcuts; sidebar drag-drop/copy-in (background), duplicate, pins (pins.json), recents (recents.json), Quick Open ⌘P, previews; status bar counts; HTML/PDF export, Print ⌥⌘P; zoom; app icon; About; inline images + paste/drop into assets/; outline ⌃⌘O; focus mode ⇧⌘J. Batched review workflow (28 confirmed) all fixed (8622922, 47c2e4d + asset naming).
Next: user looks at the app (relaunch / bundle.sh). Unverified by hand: everything UI in this phase — esp. image at end of note, drag-drop, quick open keys, PDF/print output, focus mode, ⇧⌘F with collapsed sidebar.

## Windows parity for phase 2 (docs/format.md sections added)

Windows lacks all of phase 2: Links (incl. program rule), Editing helpers, Moving/duplicating/copying in + portable names for copies, pins/recents, Sidebar preview, Status bar counts, HTML export, Zoom, Images/assets, Outline, Focus mode. Also Windows bold is Ctrl+Shift+B vs macOS ⌘B; Windows Ctrl+F is sidebar search (macOS ⇧⌘F, ⌘F = in-note find).

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
