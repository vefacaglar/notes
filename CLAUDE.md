# Notes

Minimal Markdown notes app: a folder of plain `.md` files (plus readable code/text files). Native per platform: macOS first (`apps/macos`, Swift), Windows later (`apps/windows`). `docs/format.md` is the contract both apps follow; change it together with the behaviour.

## Layout

- `apps/macos` — SwiftPM package. `NotesCore`: pure logic with tests (store, Markdown/code scanning, naming, JSON formatting). `Notes`: SwiftUI app, AppKit text editors. `scripts/bundle.sh` builds `build/Notes.app` with document types and registers it with LaunchServices.
- `docs/format.md` — storage and behaviour contract shared by both apps.

## Commands (in `apps/macos`)

- `swift test`
- `swift build`
- `./scripts/bundle.sh` then `open build/Notes.app`

## Working agreement

- The main session coordinates: it splits work, hands implementation to the `swift-dev` agent (later `windows-dev`), gives parallel agents disjoint files, and runs the `reviewer` agent before every commit.
- Small topical local commits; never push unless asked.
- UI strings are Turkish; code, identifiers and comments English.
- Progress and the resume point live in `.claude/progress/STATE.md`.
