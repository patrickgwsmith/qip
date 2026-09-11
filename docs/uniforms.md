# Uniforms

Uniforms are optional numeric overrides that a host applies to a QIP component
before execution. Each uniform has an authored default. If the host does not
call its setter, the component uses that default. Uniforms keep configuration
separate from the main content or pixel input: the component receives the same
data shape while callers select values such as column count, color, radius, or
angle.

They are inspired by uniforms in GPU rendering: small values set by the host and read during execution instead of being embedded in the main input buffer.

Uniforms are a shared extension, not a component type. Content and Tile hosts currently apply them at the points defined below.

## Component Exports

For a uniform named `<key>`, export a setter named `uniform_set_<key>`.
A uniform key is a lowercase snake identifier with 1 to 63 characters. It must
start with `[a-z]`, continue with `[a-z0-9_]*`, must not end with `_`, and must
not contain `__`. These limits keep keys portable in URLs, shells, archives,
DNS-like names, and case-insensitive filesystems.

Each setter:

- Accepts exactly one parameter.
- Uses one of `i32`, `i64`, `f32`, or `f64`.
- Returns the clamped or applied value using the same type.

An `i32` uniform is treated as unsigned. Use `i64` when callers need to pass a signed integer value.

For example:

```zig
var color_rgba: u32 = 0x000000FF;

export fn uniform_set_color_rgba(value: u32) u32 {
    color_rgba = value;
    return color_rgba;
}
```

Packed values such as colors and flags fit naturally in `i32`. Fractional image parameters like opacity commonly use `f32`.

## Host Behavior

The host applies setters after instantiation and before `render`, or before tile execution in image mode. A host reusing an instance may call setters again before a later execution.

- A uniform without a matching `uniform_set_<key>` export is an error.
- A value that cannot be parsed as the setter's parameter type is an error.
- Hexadecimal integers require a `0x` or `0X` prefix and are parsed as unsigned bit patterns.
- Keys are applied in sorted key order.
- Setters must not depend on their call order for related state changes.

Returning the applied value lets a host observe clamping or normalization. A setter for a range-limited value should store and return the value the component will actually use.

## Content Reset Semantics

Content uniforms apply to one render only. Each render starts with authored
defaults plus the setters called for that render. Each normal return from
`render` resets every public uniform to its authored default, whether the render
produced bytes, produced valid empty output, or rejected input. A later render
does not inherit the preceding call's public uniform values.

Hosts which reuse a Content instance therefore apply every non-default uniform
before each render. A Compliance oracle must set the uniforms needed by each
case; the bridge does not retain a desired value between cases. These rules do
not change Tile uniform persistence.

Time and Events update uniforms work the same way. A host can omit any
setter whose default it wants. `finish_update` resets all update uniforms, and
the next update starts from authored defaults. Presentation uniforms reset when
`render` returns.

## CLI Syntax

Put `-u <key=value>` or `--uniform <key=value>` immediately after the component
it configures. Repeat the option to set more than one uniform:

```bash
qip run module.wasm -u key=value
qip run module.wasm -u width=900 -u height=400 -u font_size=48
qip image -i in.jpg -o out.png filter.wasm -u radius=2.0 -u angle=0.26
```

Examples from this repository:

```bash
# i32 uniform
qip run text/text-to-bmp.wasm -u cols=120

# f32 uniforms
qip image -i in.jpg -o out.png \
  components/rgba/color-halftone.wasm -u max_radius=2.0 -u angle_c=0.26

# 0xRRGGBBAA passed as the raw bits of an i32
qip run image/svg+xml/svg-recolor-current-color.wasm \
  -u color_rgba=0xff5511ff
```

The Go CLI continues to accept a quoted `'?key=value&key2=value2'` argument
after a component for backward compatibility. New commands should use `-u`.
The qipx CLI accepts only `-u` and `--uniform`.

## Host-Managed Tile Size

Image components may export `uniform_set_width_and_height(width: f32, height: f32)`. This two-parameter function is a host-managed Tile hook, not a caller-set uniform, despite sharing the `uniform_set_` prefix.

The image host calls it with the full input dimensions. Callers cannot set it through CLI uniform arguments.
