# Aces Up (Idiot's Delight)

Click cards to play.

- If a top card can be discarded (same suit, lower rank than another top card), click it.
- If there is an empty pile, click a top card to select it, then click an empty pile to move it.
- Click the deck on the right side (or press `Space` / `Enter`) to deal a new row when legal.
- Press `R` to reshuffle and restart.

Goal: finish with only four aces.

The component advances its staged deal animation in Timed updates. An update
can deal the next card without replacing the published KTX2 frame; the host
renders when it needs to present the new state.

<qip-play>
  <source src="/gui/aces-up.wasm" type="application/wasm"></source>
</qip-play>
