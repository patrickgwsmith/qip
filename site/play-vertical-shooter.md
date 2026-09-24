# Vertical Shooter

Procedural enemy waves, arcade style, with a simple minimal look.

Controls:

- Arrow keys move
- `Space` / `Z` shoots
- Tougher enemies can now fire back
- Your bullets can destroy enemy bullets
- Shots inherit some vehicle motion (strafe adds lateral bullet drift)
- Big enemies can drop:
  - health packs (`+1` health)
  - weapon upgrade (unlocks spray fire)
- `X` toggles single/spray after unlock (`1` = single, `2` = spray)
- `R` restarts with a new procedural seed
- `Enter` restarts after game over

<qip-play>
  <source src="/gui/vertical-shooter.wasm" type="application/wasm" />
</qip-play>
