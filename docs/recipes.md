# Recipes

A recipe is an ordered list of Content components that a host runs as one
pipeline: the output bytes of each step become the input bytes of the next.
Before a host reads any input or calls any component, it validates the whole
recipe with the algorithm on this page. Every QIP host applies the same rules
and prints the same messages, so a recipe that one host refuses is refused
everywhere, for the same reason.

The rules below are what `qip`, the Node.js `qipx`, and the Rust `qipx`
implement. `test/pipeline-consensus.mjs` runs the same recipes through all
three and asserts that their exit codes and messages agree.

## What a step declares

A host reads each component's contract from its exports before running it.
The parts that matter for composition are:

| Fact | Source | Values |
| --- | --- | --- |
| Input encoding | `input_utf8_cap` or `input_bytes_cap` | UTF-8 or bytes; absent for an inputless generator |
| Output encoding | `output_utf8_cap` or `output_bytes_cap` | UTF-8 or bytes |
| Input content type | `input_content_type_ptr` and `input_content_type_size` | optional canonical content type |
| Output content type | `output_content_type_ptr` and `output_content_type_size` | optional canonical content type |
| Capacities | the same capacity exports | maximum input and output bytes |

Before any of this, each module must pass the host's module policy: it is
refused if it declares memory without a maximum or uses `memory.grow`, so
every step has a fixed, known memory size. See [Hard Limits](/docs/hard-limits).

A declared content type must be in canonical form: a lowercase media type,
then `;name=value` for each parameter, with no whitespace anywhere, for
example `image/ktx2;vkFormat=R8G8B8A8_SRGB;colorPrimaries=BT709;transferFunction=SRGB`.
Parameter names are case-insensitive; values are case-sensitive. The one
exception is `multipart/form-data;boundary=uuid-00000000-0000-0000-0000-000000000000`,
the placeholder boundary a form component declares. A host rejects a
component whose declared type is spelled any other way, before validating the
recipe. See [Formats and Encodings](/docs/formats) for the parameters QIP uses.

## The tracked state

Validation walks the steps in order while tracking two facts about the bytes
that will flow into the next step:

- **the encoding**, UTF-8 or bytes, once any step has produced output;
- **the content type**, which may be unspecified.

The tracked type starts as the caller's input type when the host knows one.
Multipart form input (`-F`) sets it to the canonical `multipart/form-data`
boundary form. Plain stdin or `-i` file input has no type channel, so the
tracked type starts unspecified. The tracked encoding starts unset.

The host does validate the initial bytes when step 1 reads UTF-8: it checks
them with a strict decoder before writing them into the component, and
refuses the run at the first invalid sequence. Nothing before step 1 has
established the UTF-8 guarantee, so the host establishes it. Later UTF-8
stages trust the preceding stage's `output_utf8_cap` promise.

## The algorithm

For each step, numbered from 1, in order:

1. **Position.** An inputless generator, a component with no `input_ptr`, is
   valid only as step 1. Later, it is an error.

2. **Encoding.** If a tracked encoding exists, it must fit the step's input
   encoding. UTF-8 output may enter a bytes input. Bytes output may not enter a
   UTF-8 input: the host never re-validates bytes, and a UTF-8 component
   relies on valid input. Insert an explicit validator step when that is what
   you mean.

3. **Capacity.** If the previous step's output capacity exceeds this step's
   input capacity, the recipe is still valid, because the actual intermediate
   output may fit. `dry run` prints a note. With `--capacities-must-fit`, it
   is an error. At run time, an actual output larger than the next step's
   input capacity always stops the pipeline, whichever mode planned it.

4. **Input content type.** If the step declares an input type:
   - When the tracked type is unspecified and this is step 1, the step is
     permitted on trust; the host cannot see the caller's type.
   - When the tracked type is unspecified at any later step, it is an error:
     the recipe has lost the type and the step needs one.
   - Otherwise the tracked type must match the declared type: the media types
     must be equal ignoring case, and every parameter that both declare must
     have equal values. A parameter only one side declares does not have to
     match, so a bare `image/ktx2` output satisfies a step that declares a
     profile, and a profiled output satisfies a step that declares bare
     `image/ktx2`.

   A step that declares no input type accepts whatever its encoding allows.

5. **Output content type.** After the step:
   - A declared output type replaces the tracked type.
   - Otherwise, a step that reads bytes and writes UTF-8 clears the tracked
     type to unspecified: it produced new text that the incoming type does not
     describe.
   - Otherwise the tracked type passes through unchanged. A UTF-8 to UTF-8
     step, or any step writing through `output_bytes_cap`, preserves it.

   The tracked encoding becomes the step's output encoding.

The recipe is valid when every step passes. Validation is complete before any
input is read, so an invalid recipe never runs a component.

## Content type parameters

Rule 4 is what lets two components that both say `image/ktx2` be told apart.
A component declares the KTX2 profile it reads or writes with parameters that
mirror the file's own fields, and a mismatch is refused before the component
would trap on the wrong pixel layout:

```text
image/ktx2;vkFormat=R8G8B8A8_SRGB;colorPrimaries=BT709;transferFunction=SRGB
image/ktx2;vkFormat=R32G32B32A32_SFLOAT;colorPrimaries=BT709;transferFunction=LINEAR
```

Because only shared parameters are compared, adding a parameter to a component
never breaks recipes that use components declaring the bare type; it only
starts refusing recipes that were already wrong.

## Messages

Hosts print one line per refusal, naming the step number and component path
first. `step 1` is the first component on the command line.

| Rule | Message |
| --- | --- |
| Position | `step 2 <path> inputless generator must be the first pipeline stage` |
| Encoding | `step 2 <path> expected UTF-8 input, got bytes from step 1 <path>` |
| Capacity, with `--capacities-must-fit` | `step 2 <path> input capacity 64.0 KiB (65536 bytes) cannot fit step 1 <path> output capacity 8.0 MiB (8388608 bytes)` |
| Capacity note in `dry run` | `Note: step 2 <path>: previous output capacity 8.0 MiB (8388608 bytes) exceeds this input capacity 64.0 KiB (65536 bytes); the run remains valid when the actual intermediate output fits` |
| Type unspecified | `step 2 <path> expected text/markdown, but pipeline content type is unspecified` |
| Type mismatch | `step 3 <path> expected <declared>, got <incoming> from step 2 <path>: <detail>` |
| Invalid initial UTF-8 | `step 1 <path> expected UTF-8 input, got invalid UTF-8 at input offset 2` |
| Input too large at run time | `step 2 <path> input is too large (66668 bytes > 65536 bytes input capacity)` |
| Rejection at run time | `step 2 <path> rejected input at input offset 7` (the offset and mode are present when the component reports them) |
| Trap at run time | `step 1 <path> trapped: <engine-specific reason>` |

In the mismatch message, `<incoming>` shows only its parameters when both
types share a media type, and `<detail>` lists what differs: `media type
expected image/ktx2 got image/png`, or one `name expected X got Y` entry per
parameter, separated by `; `. When the offending input is the recipe's own
input rather than a step's output, the `from step` clause is omitted. The
Rust `qipx` prefixes every error with `qipx: `; the line is otherwise
identical across hosts.

## Examples

A valid recipe. The PNG decoder declares bare `image/ktx2`, the resizer
declares and emits the RGBA8 sRGB profile, and the WebP encoder accepts any
`image/ktx2`:

```sh
npx @qip.dev/qipx qip.dev run \
  image/png/png-to-ktx2-r8g8b8a8-srgb.wasm \
  image/ktx2/ktx2-r8g8b8a8-srgb-resize-down-lanczos3.wasm \
  image/ktx2/ktx2-r8g8b8a8-srgb-to-webp-lossy.wasm \
  < photo.png > photo.webp
```

`dry run` shows the plan the algorithm produced:

```text
Pipeline compatible: 3 step(s)
1. image/png/png-to-ktx2-r8g8b8a8-srgb.wasm — Content
   Input:  encoding=bytes, type=image/png, capacity=64.0 MiB (67108864 bytes)
   Output: encoding=bytes, type=image/ktx2, capacity=95.4 MiB (100000224 bytes)
   Buffers: 159.4 MiB (167109088 bytes)
2. image/ktx2/ktx2-r8g8b8a8-srgb-resize-down-lanczos3.wasm — Content
   Input:  encoding=bytes, type=image/ktx2, capacity=95.4 MiB (100000224 bytes)
   Output: encoding=bytes, type=image/ktx2;vkFormat=R8G8B8A8_SRGB;colorPrimaries=BT709;transferFunction=SRGB, capacity=95.4 MiB (100000224 bytes)
   Buffers: 190.7 MiB (200000448 bytes)
3. image/ktx2/ktx2-r8g8b8a8-srgb-to-webp-lossy.wasm — Content
   Input:  encoding=bytes, type=image/ktx2, capacity=95.4 MiB (100000224 bytes)
   Output: encoding=bytes, type=image/webp, capacity=64.0 MiB (67108864 bytes)
   Buffers: 159.4 MiB (167109088 bytes)
Total declared buffer capacity: 509.5 MiB (534218624 bytes)
```

An invalid recipe, refused by rule 4 because the resizer emits RGBA8 into a
component that declares linear float:

```sh
npx @qip.dev/qipx qip.dev run \
  image/png/png-to-ktx2-r8g8b8a8-srgb.wasm \
  image/ktx2/ktx2-r8g8b8a8-srgb-resize-down-lanczos3.wasm \
  image/ktx2/ktx2-rgba32float-look-warm-fade.wasm \
  < photo.png > warm.png
```

```text
step 3 image/ktx2/ktx2-rgba32float-look-warm-fade.wasm expected image/ktx2;vkFormat=R32G32B32A32_SFLOAT;colorPrimaries=BT709;transferFunction=LINEAR, got vkFormat=R8G8B8A8_SRGB;colorPrimaries=BT709;transferFunction=SRGB from step 2 image/ktx2/ktx2-r8g8b8a8-srgb-resize-down-lanczos3.wasm: vkFormat expected R32G32B32A32_SFLOAT got R8G8B8A8_SRGB; transferFunction expected LINEAR got SRGB
```

Inserting `image/ktx2/ktx2-r8g8b8a8-srgb-to-ktx2-rgba32float.wasm` between the
two makes it valid. Both converters declare bare `image/ktx2`, so they accept
any profile on input and let the next step's declaration decide.

A recipe refused by rule 2, because compressed bytes cannot feed a UTF-8
input without a validator in between:

```text
step 2 text/base64-decode-c-simd.wasm expected UTF-8 input, got bytes from step 1 bytes/zlib-compress.wasm
```

## Checking modes

`qip` validates content types in strong mode by default and offers
`--content-type-checking none` to skip rule 4 at run time, for hosts that
supply content whose type they cannot express. Encoding, position, and
capacity rules always apply. The `qipx` tools validate in strong mode only.

## Related pages

- [Content Component Contract](/docs/content-component) defines the exports
  this page reads.
- [Formats and Encodings](/docs/formats) defines the canonical content types
  and the KTX2 parameters.
