# State

## RESUME POINT (2026-10-30)

Done (uncommitted): `docs/format.md`; `NotesCore` search ı/İ fix and `MarkdownStyler`; live Markdown editor (`Editor/MarkdownEditor.swift`); app shell (sidebar tree, search, debounced autosave, folder watcher, new/rename/trash, folder picker); `.md` default-app support (document types, standalone windows for outside files); `scripts/bundle.sh`.

In progress:
- Automatic note names from the first line (Apple Notes style; manually renamed notes are left alone).
- Code/JSON files: `CodeHighlighter`, `JSONFormatter` (order-preserving beautify), code editor mode. Phase 2 still to do: list code/text files in the sidebar and search, document types for them in `bundle.sh`, Biçimlendir command.

Next: apply the review findings (same-name rename blanks the editor; autosave overwrites newer disk content; failed save drops edits; notes with non-portable names can't be opened; Return leaves stale styling on the next line; undo shared across notes; same file in two documents; external reload jumps the cursor; plus lower-priority items). Then reviewer pass, visual check in the app, local commits.

Later: shared test fixtures in `docs/fixtures/` for the Windows app; Windows app (`windows-dev` agent).
