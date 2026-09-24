# Perlin Noise Explorer

Held keys advance the camera in Timed updates. The component requests a
16 ms wake while a movement key is held and publishes frames as KTX2.

Controls:

- Arrow keys pan continuously
- Hold `Shift` to pan faster
- `=` and `+` zoom in
- `-` zoom out
- `R` regenerates with a new seed and recenters

<qip-play>
  <source src="/gui/perlin-noise.wasm" type="application/wasm" />
</qip-play>
