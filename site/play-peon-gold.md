# Peon Gold Loop

RTS-style peon micro inspired by Warcraft-era gold harvesting.

Controls:

- Left click peon to select
- Right click mine to start gather loop
- Right click ground to move
- `M` then right click: force move command
- `H` or `G` then right click mine: force harvest command
- `B`: train a new peon at the hall for 300 collected gold
- `S`: stop current order
- `P`: cycle selected peon
- `Esc`: return to smart command mode
- `R`: reset game

HUD:

- Left number: collected gold
- Middle number: gold currently carried by selected peon
- Small peon icon: current peon count, bright when you can train another peon
- Right number: mine gold remaining
- Right color tabs: command mode (`smart`, `move`, `harvest`)

<qip-play>
  <source src="/gui/peon-gold.wasm" type="application/wasm" />
</qip-play>
