# Tic-Tac-Toe (Sun vs Moon)

Click a square to place a symbol.

Key and pointer events run inside a timed update. `finish_update` closes the
update without rejection, and a separate render presents the board as a
canonical KTX2 image.

- Sun goes first.
- Moon goes second.
- Click anywhere after win/draw to reset.
- Press `Enter`, `Space`, or `R` to reset.

<qip-play>
  <source src="/gui/tic-tac-toe-sun-moon.wasm" type="application/wasm"></source>
</qip-play>
