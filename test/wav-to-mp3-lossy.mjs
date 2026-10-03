import { renderSize as qipRenderSize, renderedOutputPointer as qipRenderedOutputPointer } from "./lib/content-component-host.mjs";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { readFile } from "node:fs/promises";
import test from "node:test";

const encoderModule = await WebAssembly.compile(await readFile("audio/wav/wav-to-mp3-lossy.wasm"));
const lameTestcase = await readFile("third_party/lame-3.101/testcase.wav");
const decoder = new TextDecoder();
const hasFfmpeg = spawnSync("ffmpeg", ["-version"]).status === 0;

const MPEG1_BITRATES = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320];
const MPEG2_BITRATES = [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160];
const SAMPLE_RATES = { 1: [44100, 48000, 32000], 2: [22050, 24000, 16000], 2.5: [11025, 12000, 8000] };

function exportedString(exports, pointerName, sizeName) {
  return decoder.decode(new Uint8Array(exports.memory.buffer, exports[pointerName](), exports[sizeName]()));
}

function chunk(tag, body) {
  const header = Buffer.alloc(8);
  header.write(tag);
  header.writeUInt32LE(body.length, 4);
  return Buffer.concat([header, body, Buffer.alloc(body.length & 1)]);
}

function fmtChunk({ format = 1, channels, sampleRate, bitsPerSample = 16, blockAlign = channels * (bitsPerSample / 8) }) {
  const body = Buffer.alloc(16);
  body.writeUInt16LE(format, 0);
  body.writeUInt16LE(channels, 2);
  body.writeUInt32LE(sampleRate, 4);
  body.writeUInt32LE(sampleRate * blockAlign, 8);
  body.writeUInt16LE(blockAlign, 12);
  body.writeUInt16LE(bitsPerSample, 14);
  return chunk("fmt ", body);
}

function pcm16(channels, frames, sample) {
  const body = Buffer.alloc(frames * channels * 2);
  for (let i = 0; i < frames; i += 1) {
    for (let c = 0; c < channels; c += 1) {
      body.writeInt16LE(Math.max(-32768, Math.min(32767, Math.round(sample(i, c) * 32767))), (i * channels + c) * 2);
    }
  }
  return body;
}

function riff(chunks) {
  const body = Buffer.concat([Buffer.from("WAVE"), ...chunks]);
  const header = Buffer.alloc(8);
  header.write("RIFF");
  header.writeUInt32LE(body.length, 4);
  return Buffer.concat([header, body]);
}

function makeWav({ channels, sampleRate, frames, sample = tone(channels, sampleRate) }) {
  return riff([fmtChunk({ channels, sampleRate }), chunk("data", pcm16(channels, frames, sample))]);
}

// Left 440 Hz, right 1000 Hz, so swapped or merged channels show up in the spectrum.
function tone(channels, sampleRate, frequencies = [440, 1000]) {
  return (i, c) => 0.5 * Math.sin((2 * Math.PI * frequencies[channels === 1 ? 0 : c] * i) / sampleRate);
}

function newEncoder() {
  return new WebAssembly.Instance(encoderModule, {}).exports;
}

function encodeWith(exports, wav, bitrate) {
  if (bitrate !== undefined) exports.uniform_set_bitrate_kbps(bitrate);
  new Uint8Array(exports.memory.buffer, exports.input_ptr(), wav.length).set(wav);
  const size = qipRenderSize(exports, wav.length);
  assert.equal(exports.arena_live_bytes(), 0);
  assert.equal(exports.arena_failed_allocation(), 0);
  assert.equal(exports.arena_free_unmatched_count(), 0);
  return Buffer.from(new Uint8Array(exports.memory.buffer, qipRenderedOutputPointer(exports), size));
}

function encode(wav, bitrate) {
  return encodeWith(newEncoder(), wav, bitrate);
}

// Walks every MPEG audio frame and requires the frames to tile the output exactly.
function parseFrames(mp3) {
  const frames = [];
  let offset = 0;
  while (offset < mp3.length) {
    assert.ok(offset + 4 <= mp3.length, `truncated header at ${offset}`);
    const h = mp3.readUInt32BE(offset);
    assert.equal(h >>> 21, 0x7ff, `no frame sync at ${offset}`);
    const version = { 3: 1, 2: 2, 0: 2.5 }[(h >>> 19) & 3];
    assert.ok(version, `reserved MPEG version at ${offset}`);
    assert.equal((h >>> 17) & 3, 1, `not Layer III at ${offset}`);
    const bitrateIndex = (h >>> 12) & 15;
    const sampleRateIndex = (h >>> 10) & 3;
    assert.ok(bitrateIndex > 0 && bitrateIndex < 15, `bad bitrate index at ${offset}`);
    assert.ok(sampleRateIndex < 3, `bad sample rate index at ${offset}`);
    const bitrate = (version === 1 ? MPEG1_BITRATES : MPEG2_BITRATES)[bitrateIndex];
    const sampleRate = SAMPLE_RATES[version][sampleRateIndex];
    const padding = (h >>> 9) & 1;
    const mode = (h >>> 6) & 3;
    const length = Math.floor(((version === 1 ? 144000 : 72000) * bitrate) / sampleRate) + padding;
    frames.push({ version, bitrate, sampleRate, mono: mode === 3, length, samples: version === 1 ? 1152 : 576 });
    offset += length;
  }
  assert.equal(offset, mp3.length, "last frame overruns the output");
  return frames;
}

function summarize(mp3) {
  const frames = parseFrames(mp3);
  assert.ok(frames.length > 0);
  const first = frames[0];
  for (const frame of frames) {
    assert.equal(frame.version, first.version);
    assert.equal(frame.bitrate, first.bitrate, "CBR output changed bitrate");
    assert.equal(frame.sampleRate, first.sampleRate);
    assert.equal(frame.mono, first.mono);
  }
  const { version, bitrate, sampleRate, mono, samples } = first;
  return { version, bitrate, sampleRate, mono, frameCount: frames.length, samples: frames.length * samples };
}

function rejected(wav) {
  const exports = newEncoder();
  new Uint8Array(exports.memory.buffer, exports.input_ptr(), wav.length).set(wav);
  return qipRenderSize(exports, wav.length) === 0;
}

test("the encoder is self-contained with one fixed 1 GiB memory", () => {
  assert.deepEqual(WebAssembly.Module.imports(encoderModule), []);
  const exports = newEncoder();
  assert.equal(exports.memory.buffer.byteLength, 1024 * 1024 * 1024);
  assert.throws(() => exports.memory.grow(1), RangeError);
  assert.equal(exports.input_bytes_cap(), 1008 * 1024 * 1024);
  assert.equal(exports.output_bytes_cap(), 1008 * 1024 * 1024);
  assert.equal(exportedString(exports, "input_content_type_ptr", "input_content_type_size"), "audio/wav");
  assert.equal(exportedString(exports, "output_content_type_ptr", "output_content_type_size"), "audio/mpeg");
});

test("the bitrate uniform snaps to an MPEG-1 bitrate in 32-320 kbps", () => {
  const exports = newEncoder();
  assert.equal(exports.uniform_set_bitrate_kbps(0), 32);
  assert.equal(exports.uniform_set_bitrate_kbps(31), 32);
  assert.equal(exports.uniform_set_bitrate_kbps(128), 128);
  assert.equal(exports.uniform_set_bitrate_kbps(100), 96);
  assert.equal(exports.uniform_set_bitrate_kbps(104), 96); // ties round down, like LAME
  assert.equal(exports.uniform_set_bitrate_kbps(105), 112);
  assert.equal(exports.uniform_set_bitrate_kbps(300), 320);
  assert.equal(exports.uniform_set_bitrate_kbps(321), 320);
  assert.equal(exports.uniform_set_bitrate_kbps(0xffffffff), 320);
  for (const kbps of MPEG1_BITRATES.filter((rate) => rate >= 32)) {
    assert.equal(exports.uniform_set_bitrate_kbps(kbps), kbps);
  }
});

test("the returned bitrate is the one in the frames, and resets after render", () => {
  const wav = makeWav({ channels: 2, sampleRate: 44100, frames: 4410 });
  for (const requested of [100, 150, 300]) {
    const exports = newEncoder();
    const applied = exports.uniform_set_bitrate_kbps(requested);
    assert.equal(summarize(encodeWith(exports, wav)).bitrate, applied);
    assert.deepEqual(encodeWith(exports, wav), encode(wav));
  }
});

test("LAME's testcase.wav encodes to deterministic 192 kbps MPEG-1 Layer III", () => {
  const mp3 = encode(lameTestcase);
  assert.deepEqual(mp3, encode(lameTestcase));
  const info = summarize(mp3);
  assert.deepEqual(
    { version: info.version, bitrate: info.bitrate, sampleRate: info.sampleRate, mono: info.mono },
    { version: 1, bitrate: 192, sampleRate: 44100, mono: false },
  );
  // No ID3 or Xing/LAME tag frame: the first frame is audio.
  assert.equal(mp3.subarray(0, 3).toString("latin1") === "ID3", false);
  assert.equal(mp3.indexOf("Xing"), -1);
  assert.equal(mp3.indexOf("Info"), -1);
  const inputFrames = (lameTestcase.length - 44) / 4;
  assert.ok(info.samples >= inputFrames, "output is shorter than the input");
  assert.ok(info.samples <= inputFrames + 576 + 3 * 1152, "output has too much padding");
});

test("frame headers follow channel count, sample rate and bitrate", () => {
  const cases = [
    // [channels, input rate, requested kbps] -> MPEG version, rate and bitrate in the frames
    [[2, 44100, 192], { version: 1, sampleRate: 44100, bitrate: 192, mono: false }],
    [[2, 44100, 320], { version: 1, sampleRate: 44100, bitrate: 320, mono: false }],
    [[2, 44100, 128], { version: 1, sampleRate: 44100, bitrate: 128, mono: false }],
    [[1, 44100, 128], { version: 1, sampleRate: 44100, bitrate: 128, mono: true }],
    [[2, 48000, 256], { version: 1, sampleRate: 48000, bitrate: 256, mono: false }],
    [[2, 32000, 96], { version: 1, sampleRate: 32000, bitrate: 96, mono: false }],
    [[1, 22050, 64], { version: 2, sampleRate: 22050, bitrate: 64, mono: true }],
    [[2, 16000, 48], { version: 2, sampleRate: 16000, bitrate: 48, mono: false }],
    [[2, 11025, 32], { version: 2.5, sampleRate: 11025, bitrate: 32, mono: false }],
    [[2, 8000, 32], { version: 2.5, sampleRate: 8000, bitrate: 32, mono: false }],
    // MPEG-2 and 2.5 stop at 160 kbps, so LAME lowers higher requests.
    [[1, 22050, 320], { version: 2, sampleRate: 22050, bitrate: 160, mono: true }],
    // At 8 kHz LAME caps the bitrate at 64 kbps.
    [[2, 8000, 320], { version: 2.5, sampleRate: 8000, bitrate: 64, mono: false }],
    // At 32 kbps LAME resamples 44.1 kHz stereo down to 16 kHz MPEG-2.
    [[2, 44100, 32], { version: 2, sampleRate: 16000, bitrate: 32, mono: false }],
  ];
  for (const [[channels, sampleRate, kbps], expected] of cases) {
    const info = summarize(encode(makeWav({ channels, sampleRate, frames: sampleRate }), kbps));
    assert.deepEqual(
      { version: info.version, sampleRate: info.sampleRate, bitrate: info.bitrate, mono: info.mono },
      expected,
      `${channels}ch ${sampleRate} Hz at ${kbps} kbps`,
    );
  }
});

test("output size tracks the constant bitrate", () => {
  const seconds = 5;
  const wav = makeWav({ channels: 2, sampleRate: 44100, frames: 44100 * seconds });
  const sizes = [];
  for (const kbps of [64, 128, 192, 320]) {
    const mp3 = encode(wav, kbps);
    const expected = (kbps * 1000 * seconds) / 8;
    assert.ok(Math.abs(mp3.length - expected) / expected < 0.05, `${kbps} kbps gave ${mp3.length} bytes`);
    sizes.push(mp3.length);
  }
  assert.deepEqual([...sizes].sort((a, b) => a - b), sizes);
});

test("silence, full-scale square waves and single samples encode", () => {
  for (const sample of [() => 0, (i) => (i & 64 ? 1 : -1), (i) => (i % 2 ? 1 : -1)]) {
    summarize(encode(makeWav({ channels: 2, sampleRate: 44100, frames: 20000, sample })));
  }
  for (const channels of [1, 2]) {
    const info = summarize(encode(makeWav({ channels, sampleRate: 44100, frames: 1 })));
    assert.ok(info.frameCount >= 1);
  }
});

test("unrelated, odd-sized and reordered chunks are skipped", () => {
  const fmt = fmtChunk({ channels: 2, sampleRate: 44100 });
  const data = chunk("data", pcm16(2, 4410, tone(2, 44100)));
  const plain = encode(riff([fmt, data]));
  const odd = chunk("LIST", Buffer.from("INFOISFT\x05\x00\x00\x00qip!!", "latin1"));
  assert.equal(odd.length % 2, 0);
  assert.deepEqual(encode(riff([odd, fmt, chunk("fact", Buffer.alloc(4)), odd, data, odd])), plain);
  assert.deepEqual(encode(riff([data, fmt])), plain);
  // A header followed by trailing bytes too short to be a chunk is tolerated.
  assert.deepEqual(encode(Buffer.concat([riff([fmt, data]), Buffer.from([0, 0, 0])])), plain);
});

test("mono encoding reads only the data chunk", () => {
  const fmt = fmtChunk({ channels: 1, sampleRate: 22050 });
  const data = chunk("data", pcm16(1, 7000, tone(1, 22050)));
  const plain = encode(riff([fmt, data]));
  const noisy = chunk("LIST", Buffer.from(Array.from({ length: 20000 }, (_, i) => (i * 7919) & 255)));
  assert.deepEqual(encode(riff([fmt, data, noisy])), plain);
  const exports = newEncoder();
  encodeWith(exports, makeWav({ channels: 2, sampleRate: 44100, frames: 30000 }), 192);
  assert.deepEqual(encodeWith(exports, riff([fmt, data])), plain);
});

test("unsupported and malformed WAV input renders empty output", () => {
  const data = chunk("data", pcm16(2, 1000, tone(2, 44100)));
  const good = riff([fmtChunk({ channels: 2, sampleRate: 44100 }), data]);
  assert.equal(rejected(good), false);
  const cases = {
    "empty input": Buffer.alloc(0),
    "shorter than a WAV header": good.subarray(0, 43),
    "not RIFF": Buffer.concat([Buffer.from("RIFX"), good.subarray(4)]),
    "not WAVE": Buffer.concat([good.subarray(0, 8), Buffer.from("AVI "), good.subarray(12)]),
    "8-bit PCM": riff([fmtChunk({ channels: 2, sampleRate: 44100, bitsPerSample: 8 }), data]),
    "24-bit PCM": riff([fmtChunk({ channels: 2, sampleRate: 44100, bitsPerSample: 24 }), data]),
    "IEEE float": riff([fmtChunk({ format: 3, channels: 2, sampleRate: 44100, bitsPerSample: 32 }), data]),
    "WAVE_FORMAT_EXTENSIBLE": riff([fmtChunk({ format: 0xfffe, channels: 2, sampleRate: 44100 }), data]),
    "zero channels": riff([fmtChunk({ channels: 0, sampleRate: 44100, blockAlign: 0 }), data]),
    "three channels": riff([fmtChunk({ channels: 3, sampleRate: 44100 }), chunk("data", pcm16(3, 1000, () => 0))]),
    "7999 Hz": riff([fmtChunk({ channels: 2, sampleRate: 7999 }), data]),
    "48001 Hz": riff([fmtChunk({ channels: 2, sampleRate: 48001 }), data]),
    "96 kHz": riff([fmtChunk({ channels: 2, sampleRate: 96000 }), data]),
    "block align mismatch": riff([fmtChunk({ channels: 2, sampleRate: 44100, blockAlign: 2 }), data]),
    "short fmt chunk": riff([chunk("fmt ", Buffer.alloc(14)), data]),
    "no fmt chunk": riff([data]),
    "no data chunk": riff([fmtChunk({ channels: 2, sampleRate: 44100 })]),
    "empty data chunk": riff([fmtChunk({ channels: 2, sampleRate: 44100 }), chunk("data", Buffer.alloc(0))]),
    "partial sample frame": riff([fmtChunk({ channels: 2, sampleRate: 44100 }), chunk("data", Buffer.alloc(6))]),
    "data chunk past end": (() => {
      const wav = Buffer.from(good);
      wav.writeUInt32LE(data.length, wav.indexOf("data") + 4);
      return wav;
    })(),
    "chunk size near 4 GiB": (() => {
      const wav = Buffer.from(good);
      wav.writeUInt32LE(0xfffffff9, 16);
      return wav;
    })(),
  };
  for (const [name, wav] of Object.entries(cases)) {
    assert.equal(rejected(wav), true, name);
  }
});

test("input sizes beyond the input buffer are rejected without reading it", () => {
  const exports = newEncoder();
  new Uint8Array(exports.memory.buffer, exports.input_ptr(), lameTestcase.length).set(lameTestcase);
  assert.equal(qipRenderSize(exports, exports.input_bytes_cap() + 1), 0);
  assert.equal(qipRenderSize(exports, 0xffffffff), 0);
});

test("a reused instance matches fresh instances when the uniform is set per render", () => {
  const exports = newEncoder();
  const inputs = [
    makeWav({ channels: 2, sampleRate: 44100, frames: 30000 }),
    makeWav({ channels: 1, sampleRate: 22050, frames: 7000 }),
    Buffer.from("not a wav file at all, but longer than 44 bytes........"),
    makeWav({ channels: 2, sampleRate: 48000, frames: 1 }),
    lameTestcase,
  ];
  for (let round = 0; round < 4; round += 1) {
    for (const wav of inputs) {
      const fresh = newEncoder();
      fresh.uniform_set_bitrate_kbps(96);
      new Uint8Array(fresh.memory.buffer, fresh.input_ptr(), wav.length).set(wav);
      const freshSize = qipRenderSize(fresh, wav.length);
      const expected = Buffer.from(new Uint8Array(fresh.memory.buffer, qipRenderedOutputPointer(fresh), freshSize));
      assert.deepEqual(encodeWith(exports, wav, 96), expected);
    }
  }
});

test("a long recording stays within the arena", () => {
  const exports = newEncoder();
  const mp3 = encodeWith(exports, makeWav({ channels: 2, sampleRate: 48000, frames: 48000 * 60 }), 320);
  const info = summarize(mp3);
  assert.ok(info.samples >= 48000 * 60);
  assert.ok(exports.arena_peak_bytes() < 2 * 1024 * 1024, `arena peak ${exports.arena_peak_bytes()}`);
});

test("the MP3 is written over input already encoded", () => {
  const exports = newEncoder();
  const wav = makeWav({ channels: 2, sampleRate: 44100, frames: 44100 });
  encodeWith(exports, wav, 128);
  assert.equal(qipRenderedOutputPointer(exports), exports.input_ptr());
  // Mono at low sample rates with the bitrate maxed out gives the largest
  // output relative to the input, and still fits behind the read cursor.
  for (const sampleRate of [8000, 11025, 12000, 16000, 22050, 24000, 32000, 44100, 48000]) {
    for (const sample of [tone(1, sampleRate), (i) => ((i * 2654435761) % 65536) / 32768 - 1]) {
      const input = makeWav({ channels: 1, sampleRate, frames: sampleRate * 2, sample });
      const mp3 = encode(input, 320);
      assert.ok(mp3.length < input.length, `${sampleRate} Hz mono gave ${mp3.length} of ${input.length} bytes`);
      summarize(mp3);
    }
  }
});

function decodeMp3(mp3, channels) {
  const result = spawnSync(
    "ffmpeg",
    ["-v", "error", "-err_detect", "explode", "-f", "mp3", "-i", "pipe:0", "-f", "s16le", "-ac", String(channels), "pipe:1"],
    { input: mp3, maxBuffer: 256 * 1024 * 1024 },
  );
  assert.equal(result.status, 0, result.stderr.toString());
  assert.equal(result.stderr.toString(), "");
  const samples = new Int16Array(result.stdout.buffer, result.stdout.byteOffset, result.stdout.length / 2);
  return Array.from({ length: channels }, (_, c) => Float64Array.from({ length: samples.length / channels }, (_, i) => samples[i * channels + c] / 32768));
}

// Finds the encoder delay by cross-correlation, then measures signal-to-noise against the source.
function snrDb(source, decoded, maxLag = 4000) {
  const span = Math.min(source.length - 2000, decoded.length - maxLag - 2000);
  let bestLag = 0;
  let best = -Infinity;
  for (let lag = 0; lag <= maxLag; lag += 1) {
    let sum = 0;
    for (let i = 1000; i < span; i += 7) sum += source[i] * decoded[i + lag];
    if (sum > best) {
      best = sum;
      bestLag = lag;
    }
  }
  let signal = 0;
  let noise = 0;
  for (let i = 1000; i < span; i += 1) {
    signal += source[i] ** 2;
    noise += (source[i] - decoded[i + bestLag]) ** 2;
  }
  return { lag: bestLag, snr: 10 * Math.log10(signal / noise) };
}

function goertzelPower(samples, frequency, sampleRate) {
  const k = (2 * Math.cos((2 * Math.PI * frequency) / sampleRate));
  let s1 = 0;
  let s2 = 0;
  for (const x of samples) {
    const s0 = x + k * s1 - s2;
    s2 = s1;
    s1 = s0;
  }
  return s1 * s1 + s2 * s2 - k * s1 * s2;
}

test("ffmpeg decodes the MP3 back to the source audio", { skip: !hasFfmpeg && "ffmpeg is not installed" }, () => {
  const sampleRate = 44100;
  const frames = sampleRate * 2;
  const freqs = [440, 1000];
  // A chord plus a slow chirp gives the cross-correlation one clear peak.
  const sample = (i, c) =>
    0.3 * Math.sin((2 * Math.PI * freqs[c] * i) / sampleRate) +
    0.2 * Math.sin((2 * Math.PI * (200 + (i / frames) * 3000) * i) / sampleRate);
  const wav = makeWav({ channels: 2, sampleRate, frames, sample });
  const source = [0, 1].map((c) => Float64Array.from({ length: frames }, (_, i) => wav.readInt16LE(44 + (i * 2 + c) * 2) / 32768));

  for (const [kbps, minSnr] of [[320, 25], [192, 20], [128, 15]]) {
    const decoded = decodeMp3(encode(wav, kbps), 2);
    assert.ok(decoded[0].length >= frames, `${kbps} kbps decoded ${decoded[0].length} of ${frames} samples`);
    for (const c of [0, 1]) {
      const { lag, snr } = snrDb(source[c], decoded[c]);
      assert.ok(snr > minSnr, `${kbps} kbps channel ${c}: SNR ${snr.toFixed(1)} dB at lag ${lag}`);
      assert.ok(lag >= 576 && lag <= 2400, `${kbps} kbps channel ${c}: lag ${lag}`);
    }
  }

  // Channels stay separate and in order: each channel's own tone dominates the other's.
  const decoded = decodeMp3(encode(makeWav({ channels: 2, sampleRate, frames: sampleRate }), 192), 2);
  const left = decoded[0].subarray(4000, 40000);
  const right = decoded[1].subarray(4000, 40000);
  assert.ok(goertzelPower(left, 440, sampleRate) > 100 * goertzelPower(left, 1000, sampleRate));
  assert.ok(goertzelPower(right, 1000, sampleRate) > 100 * goertzelPower(right, 440, sampleRate));

  // Mono input decodes as one channel of the same tone.
  const mono = decodeMp3(encode(makeWav({ channels: 1, sampleRate: 22050, frames: 22050 }), 64), 1)[0];
  const monoSource = Float64Array.from({ length: 22050 }, (_, i) => 0.5 * Math.sin((2 * Math.PI * 440 * i) / 22050));
  assert.ok(snrDb(monoSource, mono).snr > 15);

  // Silence stays silent.
  const silent = decodeMp3(encode(makeWav({ channels: 2, sampleRate, frames: 20000, sample: () => 0 })), 2);
  assert.ok(silent[0].every((x) => Math.abs(x) < 1e-3));
});
