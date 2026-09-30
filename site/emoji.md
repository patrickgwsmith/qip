<title>Emoji finder</title>

# Emoji finder

Find emoji by name, emoji, or code point. Try `woman technologist`, `👩`, or
`1F469`. Use Up and Down to inspect a result’s details below the list.
Editing the query returns to the first result. The input limit is 1,024 UTF-8 bytes.

<qip-tui aria-label="Emoji finder" height="26rem">
  <source src="/tui/emoji-finder.wasm" type="application/wasm" />
</qip-tui>

## Run in your terminal

Run the same finder with `qiptui`:

```sh
npx qiptui qip.dev tui/emoji-finder.wasm
```

The finder includes 3,972 emoji and emoji components from
[Unicode Emoji 18.0](https://www.unicode.org/Public/18.0.0/emoji/emoji-test.txt).
Emoji 18.0 entries appear after older entries. The glyphs depend on your
system’s emoji font; newer sequences can appear as separate symbols or missing
characters. The source data uses the
[Unicode License v3](https://www.unicode.org/license.txt).

<script type="module">
import "/elements/qip-tui.js";
</script>
