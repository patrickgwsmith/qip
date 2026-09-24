# Moon Phases

Controls:

- Left / Right: move day-by-day

Input is passed via a normal form input element:

The date bytes are read by the initial Content `render`. Left and Right change
retained state in later updates. An update does not replace the displayed KTX2
frame until the host renders again.

<qip-play id="moon-phase-play">
  <input id="moon-phase-date" name="input" type="hidden" value="2026-05-31" />
  <source src="/gui/moon-phases.wasm" type="application/wasm" />
</qip-play>

<script>
  (function () {
    const el = document.querySelector("#moon-phase-play input[name=input]");
    el.value = new Date().toISOString().slice(0, 10);
  })();
</script>
