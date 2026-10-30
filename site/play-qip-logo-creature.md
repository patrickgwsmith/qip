# QIP logo creature

Hover over the QIP logo and its twelve bars spring apart and rearrange into a little character (a crab, a bird, a giraffe, a starfish, a snail or a flamingo) or into a term from around qip: .SVG, .CSV, .PNG, .ZIG, TUI or GUI. Move the pointer away and the bars fly back into the logo. Each hover builds the next shape with a new random palette.

<qip-play aria-label="QIP logo that rearranges into a character or a word" canvas-width="min(100%, 640px)" touch-action="pan-y">
  <source id="qip-logo-creature-source" src="/gui/qip-logo-creature.wasm" type="application/wasm" />
</qip-play>
<script>
  document.getElementById("qip-logo-creature-source").setAttribute(
    "data-uniform-seed", String(crypto.getRandomValues(new Uint32Array(1))[0])
  );
</script>

Click or tap to keep the character on screen after the pointer leaves. Clicking it again sends it back into the logo. From the keyboard, press `Space` or `Enter` to do the same, `N` for the next shape and `C` for new colors.

Every shape is built only from the logo's own bars, at their real sizes. The bars can move and turn, but they never stretch. The only extra shapes are the eyes. Each bar follows its own spring, starts a few milliseconds after the one before, and sometimes takes an extra turn on the way. Once in place, a character breathes, blinks and looks towards the pointer, and some move on their own: the crab snaps its pincers, the starfish waves, the bird flaps and the giraffe swishes its tail. It smiles with `^ ^` eyes when it lands, when you click it and every so often on its own.

The terms use a three-by-five bar font. Each letter is written as strokes of a given length, and the build gives each stroke a logo bar of that length. The six-cell bar is too long for any letter, so it becomes the mark. File formats get a leading period, the one place a bar shrinks, down to a single cell. TUI gets a blinking text cursor after the word instead, and lights up like an old monochrome terminal: the letters and cursor share one phosphor color with a soft CRT bloom, in P1 or P31 green, P3 amber, P4 white or the orange of a gas plasma display. GUI is a neon sign: the six-cell bar and its spare three-cell bar lie end to end as an underline exactly as wide as the word, and every letter and the underline glow in their own color. Every 4 seconds the tubes switch to new colors one after another, flickering as each relights. Bars a word doesn't need tuck in under a stroke of the same color. SVG has too few short bars left after its G for a square S, so its S is angular, with the spare five-cell bar as a diagonal spine. CSV has enough short bars for a square S. The letters land left to right, as if typed, and the breathing runs along the word as a wave.

Palettes are picked in OKLCH: a random hue with analogous, split-complementary or triadic partners, with chroma lowered until every color fits in sRGB. The logo itself stays the site's orange.

The component returns SVG frames from [`qip-logo-creature.wasm`](/gui/qip-logo-creature.wasm). It only asks `<qip-play>` for frames while something moves. When the logo is at rest, it renders nothing until the next pointer or key event. To get the same sequence of palettes in another host, call `uniform_set_seed(u32)` before the first `render(0)`.
