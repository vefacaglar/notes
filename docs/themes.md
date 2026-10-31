# Themes

Theme file format shared by the macOS and Windows apps. A theme is one JSON file; the same file works in both apps.

## Choosing a theme

- **Appearance** (Görünüm): `Sistem` follows the OS light/dark setting, `Açık` always uses light, `Koyu` always uses dark.
- The user picks **one light theme and one dark theme**. The app draws with the theme of the effective appearance and switches when it changes.
- Only themes whose `appearance` matches are offered for each slot. If the chosen theme is gone (file deleted, now invalid) or has the other appearance, the default built-in theme of that appearance is used.
- Defaults: `Sistem`, `default-light` and `default-dark`. The stored choice (mode, light id, dark id) is read leniently: a missing or unreadable value falls back to its own default without resetting the others, and an unknown id is kept (the theme may come back) while the default is drawn.

## Where user themes live

- macOS: `~/Library/Application Support/Notes/Themes/`
- Windows: `%APPDATA%\Notes\Themes\` (planned)

- Every entry directly in that folder whose name ends in `.json` (case-insensitive) is a theme candidate. Other names are ignored.
- Ignored silently: hidden entries (name starting with `.`, or the macOS Finder "hidden" flag / Windows hidden attribute), and directories (also a directory named `x.json`). Subfolders are not searched.
- **Symlinks** are followed, both for the folder itself and for each entry (Windows: symbolic links and junctions). The target must be a regular file; a link to a directory is ignored like a directory, a link to anything else (FIFO, device such as `/dev/zero`) or a broken link is reported. The id still comes from the link's own name.
- At most **500** candidate files are read, in the file-name order below; the rest are reported and skipped.
- A missing folder just means no user themes. Apps never write to this folder except when the user explicitly saves or duplicates a theme.
- Loading reads files synchronously; apps do it off the UI thread.

## JSON grammar

Theme files must be strict JSON so both platforms' parsers (Foundation on macOS, `System.Text.Json` on Windows) agree on every file:

- **Encoding**: UTF-8. A leading UTF-8 BOM (`EF BB BF`) is allowed and ignored. UTF-16/UTF-32 (with or without BOM), invalid UTF-8 and NUL bytes are rejected.
- **Syntax**: RFC 8259. No comments, no trailing commas, no single quotes, no unquoted keys, no `NaN`/`Infinity`, no leading zeros or `+` signs. Whitespace is space, tab, CR, LF only. Strings may not contain raw control characters (U+0000–U+001F); `\u` surrogate escapes must form a valid pair.
- **Top level**: exactly one object; nothing but whitespace after it.
- **Duplicate keys**: two equal keys in the same object are an error (keys compared ordinally after unescaping, no normalization), in known and unknown objects alike.
- **Depth**: at most 64 nested objects/arrays, the top-level object counting as 1.
- **Numbers**: a number that is not finite as an IEEE 754 double (e.g. `1e400`) is an error naming its field.
- Size limit: 1,000,000 bytes (after reading, BOM included).

`System.Text.Json` equivalents: `JsonDocumentOptions { AllowTrailingCommas = false, CommentHandling = Disallow, MaxDepth = 64 }`; duplicate keys must be checked explicitly (or with `AllowDuplicateProperties = false` on .NET 9+).

## File format

A JSON object as above. Keys are case-sensitive; unknown keys are ignored (so newer files still load in older apps). An optional key set to `null` counts as missing.

| Key | Required | Value |
| --- | --- | --- |
| `id` | no | Unique identifier. Defaults to the file name without `.json`. Leading/trailing whitespace is trimmed, then it is normalized to Unicode NFC; must not be empty. Ids compare exactly (case-sensitive, ordinal) after NFC: `Kum` and `kum` are different themes, `café` written precomposed or decomposed is the same id. |
| `name` | **yes** | Name shown in the theme menus. Trimmed and NFC-normalized; must not be empty. |
| `appearance` | **yes** | `"light"` or `"dark"`. |
| `colors` | no | Editor colors, see below. |
| `syntax` | no | Code colors, see below. |

Fonts are not part of a theme: the text and code fonts are app settings (Settings → Editor; Ayarlar → Editör in Turkish), so they stay the same when the theme changes. Older files may still have a `fonts` key; it is ignored like any unknown key.

### Colors

Every color is a string `#RRGGBB` or `#RRGGBBAA` (sRGB, hex digits in either case; `AA` is alpha, `FF` = opaque). Nothing else is accepted: no `#RGB`, no names, no `rgb()`, no surrounding spaces.

Alpha:

- `background`: alpha is ignored; the editor background is always opaque.
- Every other background (`selection`, `inlineCodeBackground`, `codeBlockBackground`, `currentLine`) is drawn over `background` (source-over).
- Text colors are drawn over whatever background they sit on.
- Contrast is measured the same way: composite the backgrounds over `background` first, then the text color over that.

`colors`:

| Key | Used for |
| --- | --- |
| `background` | Editor background |
| `text` | Body text |
| `secondaryText` | Less important text (counts, hints) |
| `marker` | Dimmed Markdown syntax: `#`, `**`, `` ` ``, `>`, list markers, link brackets and URLs |
| `heading` | Heading text |
| `link` | Link text |
| `inlineCode` | Text of `` `inline code` `` |
| `inlineCodeBackground` | Background behind inline code |
| `codeBlockBackground` | Band behind fenced code blocks: a full-width block behind every line of the block, fence lines included (Markdown view, not in Show Source mode) |
| `blockquote` | Text inside `>` quotes |
| `selection` | Selected text background (translucent values are drawn over `background`) |
| `cursor` | Insertion point |
| `accent` | Accent for controls (checkboxes, focus rings) |
| `currentLine` | Full-width band behind the line with the caret (all its wrapped fragments), only while nothing is selected, in both editors; drawn over `background` and over a code block band. Optional: when missing it is derived from the resolved `text` colour as `text` with alpha `0F` (light) or `14` (dark), not taken from the base theme, so a custom `background`/`text` always gets a matching neutral band |

`syntax` (code blocks and code files; one key per token kind):

| Key | Tokens |
| --- | --- |
| `keyword` | Language keywords |
| `string` | String literals |
| `number` | Numbers |
| `comment` | Comments |
| `literal` | `true`, `false`, `null`, `nil`, `None`…, and entities like `&amp;` in markup |
| `type` | Capitalized identifiers, CSS id/class selectors |
| `property` | JSON/YAML/TOML keys, XML attribute names, CSS properties, shell variables |
| `tag` | Markup tags with their brackets, TOML/INI section headers |

## Fallback rules

A theme may set any subset of `colors` and `syntax`. Every value it leaves out is taken from the **default built-in theme of the same appearance** (`default-light` for `"light"`, `default-dark` for `"dark"`), field by field. Values are never taken from another theme, so a partial theme only depends on its appearance. The one exception is `colors.currentLine`, derived as described above; the built-in themes leave it unset.

## Validation and errors

A file is skipped, and the problem shown to the user, when:

- it breaks the JSON grammar above, is not an object (including a file that is just `null`), is larger than 1,000,000 bytes, is not a regular file, or cannot be read;
- `name` or `appearance` is missing or `null`, or any value has the wrong type;
- a color is not `#RRGGBB`/`#RRGGBBAA`, or `id`/`name` is empty;
- its `id` is already used by a built-in theme or by a user file earlier in file-name order. The first one wins.
- it is past the 500th candidate file.

**File-name order**: file names (with extension) are normalized to NFC and compared ordinally by Unicode scalar value, which equals comparing their UTF-8 bytes. Uppercase sorts before lowercase (`B.json` < `a.json`), `é` sorts after `z`, and U+FFFD sorts before 😀. On Windows this is *not* `string.CompareOrdinal` (UTF-16 code units order 😀 before U+FFFD); compare the UTF-8 bytes or `Rune`s instead.

One bad file never affects the other themes. Errors name the field, e.g. `The field "colors.link" is invalid: must be a color like #RRGGBB or #RRGGBBAA.`

## Built-in themes

| id | name | appearance |
| --- | --- | --- |
| `default-light` | Varsayılan Açık | light |
| `sepia` | Sepya | light |
| `paper` | Kağıt | light |
| `default-dark` | Varsayılan Koyu | dark |
| `midnight` | Gece Mavisi | dark |
| `ocean` | Okyanus | dark |

The names above are the built-in files' JSON `name` values (data, like any other theme's). The apps show a built-in theme's name in the UI language instead, through `Theme.displayName`, matching the theme by `id`.

Built-ins are stored in the same JSON format (macOS: `apps/macos/Sources/NotesCore/Theme.swift`) and set every color. Their body text, headings, links, quotes, inline code and code tokens have a contrast ratio of at least 4.5:1 against their background (WCAG 2), and Markdown markers, comments, secondary text, cursor and accent at least 3:1. User themes are not checked.

All six built-ins use one muted palette: low-saturation colors whose lightness sits close to the body text, no bright reds, purples or neon tones. Headings and inline code text are the body color, `literal` tokens take the keyword color, and markers, comments and dimmed text are one tinted grey; the syntax hues are dull plum (keywords, literals), brown (strings), slate blue (numbers, tags), grey (comments), teal (types) and lavender grey (properties), with the same hue families lightened for the dark themes. Keywords are drawn semibold in both apps.

## Full example

Every key set (this is the `default-light` palette):

```json
{
  "id": "my-light",
  "name": "Benim Açık Temam",
  "appearance": "light",
  "colors": {
    "background": "#FAFAFA",
    "text": "#1B1B1B",
    "secondaryText": "#5F5F5F",
    "marker": "#767676",
    "heading": "#1B1B1B",
    "link": "#2F6396",
    "inlineCode": "#1B1B1B",
    "inlineCodeBackground": "#F1F1F1",
    "codeBlockBackground": "#F1F1F1",
    "blockquote": "#5F5F5F",
    "selection": "#B3D7FF",
    "cursor": "#007AFF",
    "accent": "#007AFF"
  },
  "syntax": {
    "keyword": "#8C4A6B",
    "string": "#8A5A3C",
    "number": "#3F6A95",
    "comment": "#767676",
    "literal": "#8C4A6B",
    "type": "#2F7771",
    "property": "#6E5A94",
    "tag": "#3F6A95"
  }
}
```

## Partial example

Saved as `Gece Yarısı.json`, so its id is `Gece Yarısı`. Everything not listed comes from `default-dark`:

```json
{
  "name": "Gece Yarısı",
  "appearance": "dark",
  "colors": {
    "background": "#101014",
    "selection": "#5E9BFF55"
  }
}
```
