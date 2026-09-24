# TextEdit (Plain Text)

An interactive plain-text editor inspired by TextEdit.app basics.

Supported:

- Typing plain ASCII text
- Mouse caret placement and drag selection
- Click Markdown task-list boxes such as `- [ ]` and `- [x]` to toggle them
- Double-click word selection
- Arrow/Home/End/PageUp/PageDown navigation
- `Shift` + navigation for selection extension
- `Shift` + click/drag extends selection from current anchor
- `Option/Alt` + `Left/Right` word navigation
- `Option/Alt` + `Up/Down` move current line up/down (VS Code-style)
- `Option/Alt` + `Delete/Backspace` word delete
- `Cmd` + `Left/Right` line start/end
- `Cmd` + `Up/Down` document start/end
- `Cmd` + `Delete/Backspace` delete to start of line
- `Ctrl` + `T` transpose adjacent characters (Emacs-style)
- `Backspace` / `Delete` / `Enter` / `Tab`
- `Ctrl`/`Cmd` + `A`, `C`, `X`, `V`, `Z`

Notes:

- Clipboard is internal to this module (`Copy/Cut/Paste` within this editor session).
- Plain text only (no style attributes).

<qip-play>
  <source src="/gui/textedit.wasm" type="application/wasm" />
</qip-play>
