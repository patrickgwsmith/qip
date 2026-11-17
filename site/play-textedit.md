# TextEdit (Mac OS X Tiger)

A plain-text editor in a Mac OS X 10.4 Tiger TextEdit window. It has a smooth gray title bar with gel close, minimize and zoom buttons directly over the text, with no format bar or ruler. The buttons are Tiger's own, rebuilt at 2x from its 1x pixels. The text is monospaced 10-point type, with JetBrains Mono standing in for Monaco, Tiger's plain-text font, and the window text is Inter. Both are drawn from their outlines with anti-aliasing. Long lines wrap to the window.

Supported:

- Typing plain ASCII text
- Click to place the insertion point, drag to select
- Double-click to select a word, triple-click to select a paragraph
- Click Markdown task-list boxes such as `- [ ]` and `- [x]` to toggle them
- Drag the scroll bar thumb, click its arrows to scroll one line, or click the track above or below the thumb to scroll a page
- Point at the close, minimize and zoom buttons to show Tiger's ×, − and + glyphs. Pressing one darkens it, but releasing does nothing, because there's no window to close, minimize or zoom.
- Arrow/Home/End/PageUp/PageDown navigation, moving by wrapped row
- `Shift` + navigation for selection extension
- `Shift` + click/drag extends selection from current anchor
- `Option/Alt` + `Left/Right` word navigation
- `Option/Alt` + `Up/Down` move current line up/down (VS Code-style)
- `Option/Alt` + `Delete/Backspace` word delete
- `Cmd` + `Left/Right` row start/end
- `Cmd` + `Up/Down` document start/end
- `Cmd` + `Delete/Backspace` delete to start of row
- `Ctrl` + `T` transpose adjacent characters (Emacs-style)
- `Backspace` / `Delete` / `Enter` / `Tab`
- `Ctrl`/`Cmd` + `A`, `C`, `X`, `V`, `Z`, and `Shift` + `Cmd` + `Z` to redo

Notes:

- Clipboard is internal to this module (`Copy/Cut/Paste` within this editor session).
- A run of typing is one undo step. Undo and redo are one level each.
- Unsaved changes put a dark dot in the close button. As in Tiger, it counts edits: typing then deleting keeps the dot, and only Undo back to the opening document clears it. With unsaved changes, the close button keeps its dot instead of showing × when you point at it.
- The scroll bar is an empty track while the whole document fits. Once it doesn't, a blue thumb and both arrows appear.
- Plain text only (no style attributes).
- Frames are drawn at 2× (750×800 pixels) and shown at 375×400, so text stays sharp on Retina displays.

<qip-play canvas-width="375px" canvas-height="auto">
  <source src="/gui/textedit.wasm" type="application/wasm" />
</qip-play>
