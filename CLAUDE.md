# Notes

Minimal Markdown notes app: a folder of plain `.md` files (plus readable code/text files). Native per platform: macOS (`apps/macos`, Swift) and Windows (`apps/windows`, C# / WinUI 3). `docs/format.md` is the contract both apps follow; change it together with the behaviour.

## Layout

- `apps/macos` — SwiftPM package. `NotesCore`: pure logic with tests (store, Markdown/code scanning, naming, JSON formatting). `Notes`: SwiftUI app, AppKit text editors. `scripts/bundle.sh` builds `build/Notes.app` with document types and registers it with LaunchServices.
- `apps/windows` — .NET 10 solution `Notes.slnx`. `src/NotesCore`: C# port of the Swift core with xUnit tests in `tests/NotesCore.Tests`. `src/Notes`: WinUI 3 app (unpackaged, single instance, tabs in the title bar, multi-root sidebar), `RichEditBox` editors.
- `docs/format.md` — storage and behaviour contract shared by both apps.
- `.vscode/` — build, test, run and debug tasks for both apps (`Windows: …` and `macOS: …`; F5 debugs against a temp notes folder; macOS debugging needs the Swift extension, `swiftlang.swift-vscode`).

## Commands

macOS (in `apps/macos`):

- `swift test`
- `swift build`
- `./scripts/bundle.sh` then `open build/Notes.app`
- `swift run Notes -notesFolder <temp folder> [-notesFolder <another>] [-theme light|dark] [-lang en|tr] [-supportFolder <temp folder>]` (test flags: roots and appearance are not saved)

Windows (in `apps/windows`):

- `dotnet test tests/NotesCore.Tests`
- `dotnet build src/Notes/Notes.csproj -p:Platform=x64`
- `dotnet run --project src/Notes/Notes.csproj -p:Platform=x64 -- --root <temp folder> [--lang en|tr]`

## Working agreement

- The main session coordinates: it splits work, hands implementation to the `swift-dev` / `windows-dev` agents, and gives parallel agents disjoint files. The `reviewer` agent is not run on every commit: use it for changes where a bug costs data or is hard to see in tests (saving, file I/O, conflict and draft handling, concurrency, editor undo/selection, large features). Docs, config, translations, small mechanical or Pi-sized changes go in after the coordinator's own diff check and a passing `swift test` / `dotnet test`. Prefer one batched review over a range of commits (end of a phase, before a push) to many small ones: save tokens.
- Easy, well-bounded jobs (a doc update, a mechanical rename, adding translations or test cases, a small isolated fix with a clear done-check) go to Pi instead of a Claude agent: `pi -p --model opencode-go/deepseek-v4.1-flash --thinking medium "<prompt>" < /dev/null`, run from the repo root. Pi reads this file. The prompt names the files it may touch and the command that proves it is done; the coordinator checks the diff and runs the tests itself before committing, and tells the user the Pi session file (under `~/.pi/agent/sessions/`). Anything design-heavy, cross-cutting or data-safety related stays with `swift-dev` / `windows-dev`.
- Exploration (searching, reading across files, comparing the two apps, gap lists, "where is X") runs on a cheap model: the `explorer` agent (Haiku, read-only), or Pi with `opencode-go/deepseek-v4.1-flash` and read-only tools (`--tools read,bash`). Never on Opus. Opus is only for the `reviewer` and the coordinator; implementation agents run on Sonnet at medium effort.
- Small topical local commits; never push unless asked.
- Language: code, identifiers, comments, docs, commit messages and dev tooling are English. The UI is localized in English (base) and Turkish, following the system language with a manual override; never hardcode user-facing strings (Windows: `.resw` in the app, `.resx` in the core; macOS: `Localizable.xcstrings` in each SwiftPM target, looked up through the module bundle: `L(…)`, `Text(loc:)`, `Button(loc:)`). Both apps are localized and read the same where the same UI exists.
- Colors: only the app's palette — the theme's neutral greys, the system accent, and the muted syntax palette inside the editor. No red errors, yellow warnings or green success states; every status message (errors included) looks neutral.
- Progress and the resume point live in `.claude/progress/STATE.md`.
