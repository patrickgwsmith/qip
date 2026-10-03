<title>Audio content components</title>

# Audio content components

These components accept an `audio/*` MIME type. Download a `.wasm` file and run it with [`qipx run`](/docs/qipx), or use the [recipe finder](/recipes) to connect compatible inputs and outputs.

## WAV (`audio/wav`)

- [`wav-to-mp3-lossy.wasm`](/audio/wav/wav-to-mp3-lossy.wasm) encodes 16-bit PCM WAV, mono or stereo at 8–48 kHz, to constant-bitrate MP3 (`audio/mpeg`) with LAME 3.101. Its `bitrate_kbps` uniform accepts 32 to 320 and defaults to 192. Input can be up to 1008 MiB, about 100 minutes of 44.1 kHz stereo.

LAME is licensed under the LGPL v2. Its unmodified source is in the QIP repository under `third_party/lame-3.101`.

Related tool: [WAV to MP3 encoder](/mp3).

Looking for other components? See [text](/text), [image](/image), [TUI](/tui), and [GUI](/gui).
