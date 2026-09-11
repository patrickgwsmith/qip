# CSS expression to value

`css-expression-to-value.wasm` resolves a small numeric CSS expression to a number or a pixel length. It is the parsing and arithmetic core needed before attempting a whole-stylesheet transformer.

```bash
printf %s 'calc(1rem * 50%%)' | \
  qip run text/css/css-expression-to-value.wasm \
  -u root_font_size=16 -u root_line_height=24 \
  -u viewport_width=1440 -u viewport_height=900
# 8px
```

The component accepts UTF-8 and emits UTF-8 without declaring MIME types. The input is one expression, not a declaration or stylesheet. It supports:

- numbers and `px`, `rem`, and `rlh` dimensions;
- `vw`, `vh`, `vmin`, `vmax` and their `sv*`, `lv*`, and `dv*` physical viewport variants;
- `calc()`, `min()`, `max()`, `clamp()`, nested parentheses, unary signs, and `+`, `-`, `*`, `/`;
- safe-area, safe-area-maximum, and virtual-keyboard `env()` values, with optional fallbacks.

All uniforms are `f64` CSS pixel measurements. Viewport uniforms are:

```text
viewport_width                  viewport_height
small_viewport_width            small_viewport_height
dynamic_viewport_width          dynamic_viewport_height
```

The default `v*` units and explicit `lv*` units both use `viewport_width` and `viewport_height`, following CSS Values Level 4.

Environment uniforms correspond to these CSS names:

```text
safe_area_inset_top             env(safe-area-inset-top)
safe_area_inset_right           env(safe-area-inset-right)
safe_area_inset_bottom          env(safe-area-inset-bottom)
safe_area_inset_left            env(safe-area-inset-left)
safe_area_max_inset_top         env(safe-area-max-inset-top)
safe_area_max_inset_right       env(safe-area-max-inset-right)
safe_area_max_inset_bottom      env(safe-area-max-inset-bottom)
safe_area_max_inset_left        env(safe-area-max-inset-left)
keyboard_inset_top              env(keyboard-inset-top)
keyboard_inset_right            env(keyboard-inset-right)
keyboard_inset_bottom           env(keyboard-inset-bottom)
keyboard_inset_left             env(keyboard-inset-left)
keyboard_inset_width            env(keyboard-inset-width)
keyboard_inset_height           env(keyboard-inset-height)
```

Unknown environment names use their fallback, if present, and otherwise trap.

Defaults are a 16px root font, a 19.2px root line height, identical 1280×720px large/small/dynamic viewports, and zero-valued environment insets. `root_line_height` is independent from `root_font_size` because a browser's `normal` line height depends on its font metrics. Uniforms clamp negative values to zero and reject non-finite values.

The output is a unitless number when the result is a number, or a `px` dimension when it is a length. Invalid syntax, unsupported units, division by zero, and incompatible dimensions trap.

## Percentage factors

This first slice treats a percentage as a unitless factor: `50%` is `0.5`. That makes `calc(1rem * 50%)` return `8px` with a 16px root font.

This is a useful expression-language extension, not general CSS percentage behavior. In CSS, the meaning of a percentage comes from the property and layout context. A future stylesheet component will need property-aware percentage bases rather than applying this rule to declarations.

## Boundaries

This component does not parse declarations, cascade styles, resolve custom properties, provide an `em` font context, or calculate layout-dependent used values. It also does not infer visual viewport or keyboard behavior: callers pass the resulting browser state explicitly. Do not use it as a replacement for browser style calculation when property or layout context affects the answer.
