# Tetris

The game loop advances within updates and asks for a wake at the next
drop. It replays at most 24 drops after a long pause, then discards older
backlog. Only `render` publishes a new KTX2 frame.

Controls:

- Left / Right: move
- Up: rotate
- Down: soft drop
- Space: hard drop
- `P`: pause
- `R`: restart

<qip-play>
  <source src="/gui/tetris.wasm" type="application/wasm" />
</qip-play>
