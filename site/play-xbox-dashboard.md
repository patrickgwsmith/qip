# Original Xbox Dashboard

A console dashboard in the style of the original Xbox. It renders at twice
its display size: a glowing green orb with hollow light tubes flowing out of
it, and chrome capsule buttons with Inter Display labels.

- **Memory** lists the saves on the hard disk and a memory unit, with block
  counts. A save can be deleted after a confirmation.
- **Music** plays a soundtrack. The orb pulses on the beat, and the visualiser
  follows the audio output setting (mono, stereo or surround).
- **Online** runs a connection test that checks each step in turn.
- **Settings** changes the glow, background motion, audio output and the
  button guide.

Controls:

- Arrow keys, or `W` / `S`, move the selection. In Memory, `Left` / `Right`
  switch device
- `Enter`, `Space` or `A` selects
- `Escape`, `Backspace` or `B` goes back
- Hover to select and click to open. Right-click, or click the orb or the
  title, to go back

<qip-play canvas-width="480px" canvas-height="auto">
  <source src="/gui/xbox-dashboard.wasm" type="application/wasm" />
</qip-play>

All motion comes from update time, including music playback. With background
motion off and nothing playing, the dashboard stops asking for frames once it
settles. Only `render` replaces the published KTX2 output.
