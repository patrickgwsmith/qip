# Klondike solitaire

Play draw-one Klondike by dragging cards between the tableau and foundations.

<qip-play aria-label="Klondike solitaire game" canvas-width="min(100%, 1000px)" svg-inline no-text-selection svg-width="1000" svg-height="760">
  <source id="klondike-source" src="/gui/klondike.wasm" type="application/wasm" />
</qip-play>
<script>
  document.getElementById("klondike-source").setAttribute(
    "data-uniform-seed", String(crypto.getRandomValues(new Uint32Array(1))[0])
  );
</script>

Click the stock to turn one card. When it is empty, click it again to recycle
the waste pile. Drag a face-up card or a descending run to a tableau column.
Build tableau columns in alternating colours, from King down to Ace. Drag one
card to its suit foundation to build from Ace up to King. Only a King can fill
an empty tableau column. Hover over a partly covered face-up card and it pokes
up from its stack so you can read more of it.

Click a top card to move it to a foundation when the move is legal. The card
glides to its foundation over a quarter of a second. Press `N`
for a new game, or `Space` to draw from the stock. The game allows unlimited
stock passes. It does not yet have undo or scoring.

When you win, the cards bounce off the foundations one by one, Kings first,
and leave trails across the table like Windows Solitaire. Click to skip to the
end, then use the New game button in the "You won!" panel to deal again.

To replay an initial deal in another host, call `uniform_set_seed(u32)` before
the first `render(0)`. The same nonzero seed produces the same shuffled deck.
