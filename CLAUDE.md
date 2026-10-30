# Notes

Minimal Markdown notes app: a folder of plain `.md` files (plus readable code/text files). Native per platform: macOS (`apps/macos`, Swift) and Windows (`apps/windows`, C# / WinUI 3). `docs/format.md` is the contract both apps follow; change it together with the behaviour.

## Layout

- `apps/macos` — SwiftPM package. `NotesCore`: pure logic with tests (store, Markdown/code scanning, naming, JSON formatting). `Notes`: SwiftUI app, AppKit text editors. `scripts/bundle.sh` builds `build/Notes.app` with document types and registers it with LaunchServices.
- `apps/windows` — .NET 10 solution `Notes.slnx`. `src/NotesCore`: C# port of the Swift core with xUnit tests in `tests/NotesCore.Tests`. `src/Notes`: WinUI 3 app (unpackaged, single instance, tabs in the title bar, multi-root sidebar), `RichEditBox` editors.
- `docs/format.md` — storage and behaviour contract shared by both apps.
- `.vscode/` — build, test, run and debug tasks for the Windows app (F5 debugs against a temp notes folder).

## Commands

macOS (in `apps/macos`):

- `swift test`
- `swift build`
- `./scripts/bundle.sh` then `open build/Notes.app`

Windows (in `apps/windows`):

- `dotnet test tests/NotesCore.Tests`
- `dotnet build src/Notes/Notes.csproj -p:Platform=x64`
- `dotnet run --project src/Notes/Notes.csproj -p:Platform=x64 -- --root <temp folder> [--lang en|tr]`

## Working agreement

- The main session coordinates: it splits work, hands implementation to the `swift-dev` / `windows-dev` agents, gives parallel agents disjoint files, and runs the `reviewer` agent before every commit.
- Small topical local commits; never push unless asked.
- Language: code, identifiers, comments, docs, commit messages and dev tooling are English. The UI is localized in English (base) and Turkish, following the system language with a manual override; never hardcode user-facing strings (Windows: `.resw` in the app, `.resx` in the core). macOS is still Turkish-only until it gets the same localization.
- Progress and the resume point live in `.claude/progress/STATE.md`.
