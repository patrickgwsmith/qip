# Side Scroller Platformer

Run, jump, stomp enemies, break blocks from below, and clear gaps without falling.

The component simulates fixed 16 ms steps before events at each update time. A
late update runs at most eight steps before dropping the remaining backlog.
Presentation is separate from simulation and produces canonical KTX2 output.

Controls:

- Arrow keys / WASD: move
- Space / Up / W: jump
- `Z` / `X`: shoot bouncy flames after collecting the power-up
- Jump onto enemies to defeat them
- Hit brick and gold blocks from below to smash them
- One smashable brick releases a flame power-up
- `R` / Enter: restart

<qip-play>
  <source src="/gui/side-scroller-platformer.wasm" type="application/wasm" />
</qip-play>
