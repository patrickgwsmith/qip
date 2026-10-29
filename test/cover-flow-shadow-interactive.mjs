import { renderSize as qipRenderSize, renderedOutputPointer as qipRenderedOutputPointer } from "./lib/content-component-host.mjs";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import test from "node:test";

const coverFlowWasm = await readFile("gui/cover-flow.wasm");
const shadowRenderingWasm = await readFile("gui/shadow-rendering.wasm");

function instantiate(bytes) {
  return new WebAssembly.Instance(new WebAssembly.Module(bytes), {}).exports;
}

function output(exports, size) {
  return new Uint8Array(exports.memory.buffer, qipRenderedOutputPointer(exports), size);
}

function digest(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

function assertTransactionalInteractiveABI(exports) {
  for (const legacy of ["tick", "render_width_px", "render_height_px", "output_rgba8_srgb_bytes"]) {
    assert.equal(exports[legacy], undefined);
  }
  assert.equal(exports.key_event.length, 2);
  assert.equal(exports.pointer_event.length, 3);
  assert.equal(exports.input_bytes_cap(), 0);
  const contentType = new TextDecoder("utf-8", { fatal: true }).decode(
    new Uint8Array(
      exports.memory.buffer,
      exports.output_content_type_ptr(),
      exports.output_content_type_size(),
    ),
  );
  assert.equal(String(contentType).split(";")[0].trim(), "image/ktx2");
}

test("shadow rendering keeps its controls as update component state", () => {
  const shadow = instantiate(shadowRenderingWasm);
  assertTransactionalInteractiveABI(shadow);
  for (const name of ["x_offset", "y_offset", "blur", "spread", "opacity", "radius"]) {
    assert.equal(shadow[`uniform_set_${name}`], undefined);
  }
  assert.equal(shadow.begin_at, undefined);
  assert.equal(shadow.commit, undefined);

  const size = qipRenderSize(shadow, 0);
  assert.equal(size, 224 + 1120 * 720 * 4);
  const initialDigest = digest(output(shadow, size));

  shadow.begin_update_at(1n);
  assert.equal(shadow.key_event(0xff51, 1), 1);
  assert.equal(shadow.finish_update(), 1n);
  assert.equal(digest(output(shadow, size)), initialDigest);
  assert.equal(qipRenderSize(shadow, 0), size);
  const adjustedDigest = digest(output(shadow, size));
  assert.notEqual(adjustedDigest, initialDigest);

  shadow.begin_update_at(2n);
  assert.equal(shadow.key_event("R".codePointAt(0), 1), 1);
  assert.equal(shadow.finish_update(), 2n);
  assert.equal(digest(output(shadow, size)), adjustedDigest);

  assert.equal(qipRenderSize(shadow, 0), size);
  assert.equal(digest(output(shadow, size)), initialDigest);
});

test("cover flow finishes event state and schedules animation without publishing a frame", () => {
  const cover = instantiate(coverFlowWasm);
  assertTransactionalInteractiveABI(cover);
  assert.equal(cover.uniform_set_feature_mask, undefined);
  assert.equal(cover.begin_at, undefined);
  assert.equal(cover.commit, undefined);

  const size = qipRenderSize(cover, 0);
  assert.equal(size, 224 + 1440 * 960 * 4);
  const initialDigest = digest(output(cover, size));

  cover.begin_update_at(1n);
  assert.equal(cover.key_event(0xff53, 1), 1);
  assert.equal(cover.finish_update(), 17n);
  assert.equal(digest(output(cover, size)), initialDigest);

  cover.begin_update_at(17n);
  assert.equal(cover.finish_update(), 33n);
  assert.equal(qipRenderSize(cover, 0), size);
  assert.notEqual(digest(output(cover, size)), initialDigest);
});

test("cover flow holding the pointer still requests no renders or wakes", () => {
  for (const [x, y] of [[720, 400], [720, 896]]) {
    const cover = instantiate(coverFlowWasm);
    qipRenderSize(cover, 0);
    cover.begin_update_at(1n);
    assert.equal(cover.pointer_event(1, x, y), 1);
    assert.equal(cover.finish_update(), 1n, `press at ${x},${y} schedules no wake`);
    cover.begin_update_at(2n);
    assert.equal(cover.pointer_event(1, x, y), 0, `held still at ${x},${y} changes nothing`);
    assert.equal(cover.finish_update(), 2n);
  }

  // Dragging while held still reports each move that shifts the covers.
  const cover = instantiate(coverFlowWasm);
  qipRenderSize(cover, 0);
  cover.begin_update_at(1n);
  assert.equal(cover.pointer_event(1, 720, 400), 1);
  assert.equal(cover.pointer_event(1, 600, 400), 1);
  assert.equal(cover.finish_update(), 1n);
});

test("cover flow and shadow rendering trap on lifecycle misuse", () => {
  for (const bytes of [coverFlowWasm, shadowRenderingWasm]) {
    const exports = instantiate(bytes);
    assert.throws(() => exports.begin_update_at(1n), WebAssembly.RuntimeError);
    qipRenderSize(exports, 0);
    assert.throws(() => exports.finish_update(), WebAssembly.RuntimeError);
    exports.begin_update_at(1n);
    assert.throws(() => qipRenderSize(exports, 0), WebAssembly.RuntimeError);
    exports.finish_update();
    assert.throws(() => exports.begin_update_at(1n), WebAssembly.RuntimeError);
  }
});

test("cover flow scroll bar scrubs and settles on the nearest album", () => {
  // Scroll bar track, in render px: x 420..1020, y 884..908.
  const trackY = 896;
  // Runs updates from a finished update at `committed` until no more wakes
  // are scheduled; an idle finish_update returns its own time.
  function settle(exports, committed, wake) {
    for (let i = 0; i < 200; i++) {
      if (wake === committed) return;
      exports.begin_update_at(wake);
      committed = wake;
      wake = exports.finish_update();
    }
    assert.fail("cover flow did not settle");
  }

  const viaKey = instantiate(coverFlowWasm);
  const size = qipRenderSize(viaKey, 0);
  viaKey.begin_update_at(1n);
  assert.equal(viaKey.key_event(0xff57, 1), 1);
  settle(viaKey, 1n, viaKey.finish_update());
  qipRenderSize(viaKey, 0);
  const endDigest = digest(output(viaKey, size));
  // Rows holding the album title and artist, which name the target album.
  const captionRows = (exports) => output(exports, size).subarray(224 + 740 * 1440 * 4, 224 + 850 * 1440 * 4);
  const endCaptionDigest = digest(captionRows(viaKey));

  const viaTrack = instantiate(coverFlowWasm);
  const initialDigest = digest(output(viaTrack, qipRenderSize(viaTrack, 0)));
  // Press the thumb and drag it most of the way right; the covers follow
  // while the pointer is held.
  viaTrack.begin_update_at(1n);
  assert.equal(viaTrack.pointer_event(1, 600, trackY), 1);
  assert.equal(viaTrack.pointer_event(1, 900, trackY), 1);
  viaTrack.finish_update();
  qipRenderSize(viaTrack, 0);
  const heldDigest = digest(output(viaTrack, size));
  assert.notEqual(heldDigest, initialDigest);
  assert.notEqual(heldDigest, endDigest);

  // Pressing the far end of the track jumps there, and releasing settles on
  // the last album, as the End key does. (The End key's spring stops within
  // 1/256 of a cover, so only the caption is compared.)
  viaTrack.begin_update_at(2n);
  assert.equal(viaTrack.pointer_event(0, 900, trackY), 1);
  viaTrack.finish_update();
  viaTrack.begin_update_at(3n);
  assert.equal(viaTrack.pointer_event(1, 1015, trackY), 1);
  assert.equal(viaTrack.pointer_event(0, 1015, trackY), 1);
  settle(viaTrack, 3n, viaTrack.finish_update());
  qipRenderSize(viaTrack, 0);
  assert.equal(digest(captionRows(viaTrack)), endCaptionDigest);
  const jumpDigest = digest(output(viaTrack, size));

  // Dragging the thumb past the end of the track lands on the same frame.
  const viaDrag = instantiate(coverFlowWasm);
  qipRenderSize(viaDrag, 0);
  viaDrag.begin_update_at(1n);
  assert.equal(viaDrag.pointer_event(1, 600, trackY), 1);
  assert.equal(viaDrag.pointer_event(1, 1300, trackY), 1);
  assert.equal(viaDrag.pointer_event(0, 1300, trackY), 1);
  settle(viaDrag, 1n, viaDrag.finish_update());
  qipRenderSize(viaDrag, 0);
  assert.equal(digest(output(viaDrag, size)), jumpDigest);
});
