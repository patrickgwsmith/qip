# Aces Up solitaire

Keep the four aces by clearing lower cards of the same suit from four piles.

<qip-play aria-label="Aces Up solitaire game" canvas-width="min(100%, 1000px)" svg-inline no-text-selection svg-width="1000" svg-height="760">
  <source src="/gui/aces-up.wasm" type="application/wasm" />
</qip-play>

Click a gold-outlined top card to discard it. A top card is discardable when
another top card has the same suit and a higher rank. Aces rank above kings.
Drag a top card to an empty pile, or click the card and then the empty pile.
When no card can be discarded, click the deck to deal one new card to each
pile, including empty piles. Press `Space` to deal or `R` to start a new game.
