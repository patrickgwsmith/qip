import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import { validateTerminalFrame } from "../npm/qiptui/qiptui.mjs";

const wasm = await readFile("tui/plist-viewer.wasm");
const module = new WebAssembly.Module(wasm);
const infoModule = new WebAssembly.Module(await readFile("tui/info-plist-viewer.wasm"));
const decoder = new TextDecoder("utf-8", { fatal: true });
const encoder = new TextEncoder();

const xml = encoder.encode(`<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Title</key><string>A &amp; B</string>
<key>Enabled</key><true/>
<key>Count</key><integer>42</integer>
<key>Ratio</key><real>1.5</real>
<key>Nested</key><dict><key>Name</key><string>Café</string><key>Items</key><array><string>one</string><string>two</string></array></dict>
<key>Blob</key><data>YWJj</data>
<key>When</key><date>2024-01-02T03:04:05Z</date>
</dict></plist>`);
const binary = Buffer.from(
  "YnBsaXN0MDDYAQIDBAUGBwgJCgsMDRQVFlVUaXRsZVdFbmFibGVkVUNvdW50VVJhdGlvVk5lc3RlZFRCbG9iVFdoZW5TVUlEVUEgJiBCCRAqIz/4AAAAAAAA0g4PEBFUTmFtZVVJdGVtc2QAQwBhAGYA6aISE1NvbmVTdHdvQ2FiYzNBxaHaUoAAAIAHCBkfJy0zOj9ESE5PUVpfZGpzdnp+gosAAAAAAAABAQAAAAAAAAAXAAAAAAAAAAAAAAAAAAAAjQ==",
  "base64",
);

function viewer(bytes, component = module, width = 100) {
  const instance = new WebAssembly.Instance(component);
  const api = instance.exports;
  api.uniform_set_columns(width);
  api.uniform_set_lines(20);
  new Uint8Array(api.memory.buffer).set(bytes, api.input_ptr());
  const frame = (size) => {
    const packed = api.render(size);
    assert.equal(packed >> 63n, 0n);
    const length = Number(packed & 0xffffffffn);
    const pointer = Number((packed >> 32n) & 0x7fffffffn);
    return decoder.decode(validateTerminalFrame(new Uint8Array(api.memory.buffer, pointer, length)));
  };
  let clock = 0n;
  const key = (code) => {
    clock += 1n;
    api.begin_update_at(clock);
    api.key_event(code, 1);
    api.finish_update();
    return frame(0);
  };
  return { initial: frame(bytes.length), key };
}

const infoXml = encoder.encode(`<plist><dict>
<key>CFBundleIdentifier</key><string>com.example.viewer</string>
<key>NSCameraUsageDescription</key><string>Capture a photo</string>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><false/></dict>
<key>CFBundleURLTypes</key><array><dict><key>CFBundleURLName</key><string>example</string></dict></array>
<key>CustomKey</key><integer>42</integer>
<key>NSMicrophoneUsageDescription</key><true/>
</dict></plist>`);
const infoBinary = Buffer.from("YnBsaXN0MDDWAQIDBAUGBwgMDRARXxASQ0ZCdW5kbGVJZGVudGlmaWVyXxAQQ0ZCdW5kbGVVUkxUeXBlc1lDdXN0b21LZXlfEBZOU0FwcFRyYW5zcG9ydFNlY3VyaXR5XxAYTlNDYW1lcmFVc2FnZURlc2NyaXB0aW9uXxAcTlNNaWNyb3Bob25lVXNhZ2VEZXNjcmlwdGlvbl8QEmNvbS5leGFtcGxlLnZpZXdlcqEJ0QoLXxAPQ0ZCdW5kbGVVUkxOYW1lV2V4YW1wbGUQKtEOD18QFk5TQWxsb3dzQXJiaXRyYXJ5TG9hZHMIXxAPQ2FwdHVyZSBhIHBob3RvCQAIABUAKgA9AEcAYAB7AJoArwCxALQAxgDOANAA0wDsAO0A/wAAAAAAAAIBAAAAAAAAABIAAAAAAAAAAAAAAAAAAAEA", "base64");

for (const [name, bytes] of [["XML", infoXml], ["binary", infoBinary]]) {
  test(`${name} Info.plist shows known labels and nested types`, () => {
    const view = viewer(bytes, infoModule, 180);
    assert.match(view.initial, /INFO\.PLIST VIEWER/);
    assert.match(view.initial, /Bundle identifier  string: com\.example\.viewer/);
    assert.match(view.initial, /Privacy - Camera Usage Description  string: Capture a photo/);
    assert.match(view.initial, /CustomKey  integer: 42/);
    assert.match(view.key(0xff54), /Key: CFBundleIdentifier  Expected: String/);
    const expanded = view.key('a'.charCodeAt(0));
    assert.match(expanded, /Allow Arbitrary Loads  bool: false/);
    assert.match(expanded, /URL identifier  string: example/);
    assert.match(expanded, /Privacy - Microphone Usage Description  bool: true  ! expected String/);
  });
}

for (const [name, bytes] of [["XML", xml], ["binary", binary]]) {
  test(`${name} plist tree can be opened and navigated`, () => {
    const view = viewer(bytes);
    assert.match(view.initial, /Title  string: A & B/);
    assert.match(view.initial, /Count  integer: 42/);
    assert.match(view.initial, /Nested  dict \(2\)/);
    assert.match(view.initial, /Blob  data: 3 bytes/);
    assert.match(view.initial, /When  date: 2024-01-02T03:04:05Z/);
    for (let index = 0; index < 5; index += 1) view.key(0xff54);
    const expanded = view.key(0xff53);
    assert.match(expanded, /Name  string: Café/);
    assert.match(expanded, /Items  array \(2\)/);
    assert.match(view.key(0xff51), /\+ Nested  dict \(2\)/);
  });

  test(`${name} plist opens every container with a`, () => {
    const view = viewer(bytes);
    view.key(0xff51);
    const expanded = view.key('a'.charCodeAt(0));
    assert.match(expanded, /- root  dict/);
    assert.match(expanded, /- Nested  dict \(2\)/);
    assert.match(expanded, /- Items  array \(2\)/);
    assert.match(expanded, /\[0\]  string: one/);
  });
}

test("binary plist shows UID values", () => {
  assert.match(viewer(binary).initial, /UID  UID: 7/);
});

test("XML plist accepts a UTF-8 byte order mark", () => {
  const input = Buffer.concat([Buffer.from([0xef, 0xbb, 0xbf]), xml]);
  assert.match(viewer(input).initial, /Title  string: A & B/);
});

test("malformed input gives a readable frame", () => {
  assert.match(viewer(encoder.encode("<plist><dict><key>x</key><string>&unknown;</string></dict></plist>")).initial, /Invalid or unsupported XML plist/);
  assert.match(viewer(binary.subarray(0, 24)).initial, /Invalid or unsupported binary plist/);
});

test("truncated binary plists fail without trapping", () => {
  for (let length = 8; length < binary.length; length++) {
    const frame = viewer(binary.subarray(0, length)).initial;
    assert.match(frame, /Invalid or unsupported binary plist/);
  }
});

test("excessive XML nesting fails without trapping", () => {
  const input = encoder.encode(`<plist>${"<array>".repeat(130)}<string>x</string>${"</array>".repeat(130)}</plist>`);
  assert.match(viewer(input).initial, /Invalid or unsupported XML plist/);
});

test("plist text cannot inject terminal controls", () => {
  const input = encoder.encode("<plist><string>one\u001b[2J\u202Etwo</string></plist>");
  const frame = viewer(input).initial;
  assert.ok(!frame.includes("\u001b") && !frame.includes("\u202E"));
  assert.match(frame, /one\?\[2J\?two/);
});
