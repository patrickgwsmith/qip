import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { promisify } from "node:util";
import test from "node:test";

import { ContentComponentHost } from "./lib/content-component-host.mjs";

const execFileAsync = promisify(execFile);
const qip = join(process.cwd(), "qip");
const encoderPath = join(process.cwd(), "application/dns-message/dns-query-to-dns-message.wasm");
const decoderPath = join(process.cwd(), "application/dns-message/dns-message-to-text.wasm");
const strictCheckers = [
  "application/wasm/wasm-strict-profile.wasm",
  "application/wasm/wasm-bounded-loops.wasm",
  "application/wasm/wasm-nontrapping-divides.wasm",
].map((path) => join(process.cwd(), path));

const encoder = new ContentComponentHost(await readFile(encoderPath), { label: "DNS query encoder" });
const decoder = new ContentComponentHost(await readFile(decoderPath), { label: "DNS message decoder" });
const ascii = new TextDecoder("ascii", { fatal: true });

function encode(text, uniforms = {}) {
  const result = encoder.run(text, { uniforms });
  if (result.status !== "accepted") throw new Error(`rejected at ${result.inputOffset}`);
  return Buffer.from(result.output);
}

function decode(bytes) {
  const result = decoder.run(new Uint8Array(bytes));
  if (result.status !== "accepted") throw new Error(`rejected at ${result.inputOffset}`);
  return ascii.decode(result.output);
}

function rejectedAt(host, input) {
  const result = host.run(input);
  assert.equal(result.status, "rejected");
  return result.inputOffset;
}

// Builds DNS wire data and records offsets for compression pointers.
class Message {
  bytes = [];

  get pos() {
    return this.bytes.length;
  }

  u8(...values) {
    this.bytes.push(...values);
    return this;
  }

  u16(value) {
    return this.u8(value >> 8, value & 0xff);
  }

  u32(value) {
    return this.u16(value >>> 16).u16(value & 0xffff);
  }

  text(value) {
    return this.u8(...Buffer.from(value, "latin1"));
  }

  // Writes the labels of `dotted`, then a pointer or the root label.
  name(dotted, pointer) {
    for (const label of dotted ? dotted.split(".") : []) this.u8(label.length).text(label);
    return pointer === undefined ? this.u8(0) : this.u16(0xc000 | pointer);
  }

  string(value) {
    return this.u8(Buffer.byteLength(value, "latin1")).text(value);
  }

  record(writeName, type, ttl, writeRdata, rclass = 1) {
    writeName(this);
    this.u16(type).u16(rclass).u32(ttl);
    const length = this.pos;
    this.u16(0);
    writeRdata(this);
    const size = this.pos - length - 2;
    this.bytes[length] = size >> 8;
    this.bytes[length + 1] = size & 0xff;
    return this;
  }

  buffer() {
    return Buffer.from(this.bytes);
  }
}

// A response with compressed names, one record of each RDATA family, and an
// OPT record with three options.
function sampleResponse() {
  const m = new Message();
  m.u16(0x1234).u16(0x8180).u16(1).u16(10).u16(0).u16(1);
  const www = m.pos;
  m.name("www.example.com");
  const example = www + 4;
  m.u16(1).u16(1);

  let cdn;
  m.record((r) => r.name("", www), 5, 300, (r) => {
    cdn = r.pos;
    r.name("cdn", example);
  });
  m.record((r) => r.name("", cdn), 1, 300, (r) => r.u8(192, 0, 2, 1));
  m.record((r) => r.name("", cdn), 28, 300, (r) => r.u16(0x2001).u16(0xdb8).u32(0).u32(0).u16(0).u16(1));
  m.record((r) => r.name("", example), 16, 60, (r) => r.string("v=spf1 -all").string('say "hi"\\ \x01'));
  m.record((r) => r.name("", example), 15, 60, (r) => r.u16(10).name("mail", example));
  m.record((r) => r.name("", example), 65, 60, (r) => {
    r.u16(1).name("");
    r.u16(0).u16(2).u16(1);
    r.u16(1).u16(7).string("h2").string("h,3");
    r.u16(3).u16(2).u16(8443);
    r.u16(4).u16(4).u8(192, 0, 2, 1);
    r.u16(5).u16(3).u8(1, 2, 3);
    r.u16(6).u16(16).u16(0x2001).u16(0xdb8).u32(0).u32(0).u16(0).u16(1);
  });
  m.record((r) => r.name("", example), 47, 60, (r) => {
    r.name("a", example);
    r.u8(0, 6, 0x40, 0x01, 0x80, 0x08, 0x00, 0x03);
    r.u8(1, 1, 0x40);
  });
  m.record((r) => r.name("", example), 0xff00, 60, (r) => r.u8(0xde, 0xad));
  m.record((r) => r.name("", example), 46, 60, (r) => {
    r.u16(1).u8(13, 3).u32(300).u32(1767225600).u32(1764547200).u16(12345);
    r.name("example.com");
    r.u8(0, 1, 2, 3, 4);
  });
  m.record((r) => r.name("", example), 257, 60, (r) => r.u8(0).string("issue").text("ca.example.net"));
  m.record((r) => r.name(""), 41, 0x8000, (r) => {
    r.u16(10).u16(8).u8(1, 2, 3, 4, 5, 6, 7, 8);
    r.u16(15).u16(7).u16(3).text("stale");
    r.u16(12).u16(4).u32(0);
  }, 1232);
  return m.buffer();
}

const sampleText = [
  ";; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 4660",
  ";; flags: qr rd ra; QUERY: 1, ANSWER: 10, AUTHORITY: 0, ADDITIONAL: 1",
  "",
  ";; OPT PSEUDOSECTION:",
  "; EDNS: version: 0, flags: do; udp: 1232",
  "; COOKIE: 0102030405060708",
  '; EDE: 3 (Stale Answer): "stale"',
  "; PADDING: (4 bytes)",
  "",
  ";; QUESTION SECTION:",
  ";www.example.com.\tIN\tA",
  "",
  ";; ANSWER SECTION:",
  "www.example.com.\t300\tIN\tCNAME\tcdn.example.com.",
  "cdn.example.com.\t300\tIN\tA\t192.0.2.1",
  "cdn.example.com.\t300\tIN\tAAAA\t2001:db8::1",
  'example.com.\t60\tIN\tTXT\t"v=spf1 -all" "say \\"hi\\"\\\\ \\001"',
  "example.com.\t60\tIN\tMX\t10 mail.example.com.",
  'example.com.\t60\tIN\tHTTPS\t1 . mandatory=alpn alpn="h2,h\\\\,3" port=8443 ipv4hint=192.0.2.1 ech=AQID ipv6hint=2001:db8::1',
  "example.com.\t60\tIN\tNSEC\ta.example.com. A MX TXT AAAA RRSIG NSEC CAA",
  "example.com.\t60\tIN\tTYPE65280\t\\# 2 DEAD",
  "example.com.\t60\tIN\tRRSIG\tA 13 3 300 20260101000000 20251201000000 12345 example.com. AAECAwQ=",
  'example.com.\t60\tIN\tCAA\t0 issue "ca.example.net"',
  "",
].join("\n");

test("encoder matches the RFC 8484 example query", () => {
  // RFC 8484 section 4.1.1 uses this GET request, with ID 0xabcd.
  const expected = Buffer.from("q80BAAABAAAAAAAAA3d3dwdleGFtcGxlA2NvbQAAAQAB", "base64url");
  assert.deepEqual(encode("www.example.com. IN A\n", { id: 0xabcd }), expected);
  assert.deepEqual(encode("www.example.com A", { id: 0xabcd }), expected);
  assert.deepEqual(encode("WWW.example.com in a", { id: 0xabcd }).subarray(12, 16), Buffer.from("\x03WWW"));
});

test("encoder uniforms clear RD and add an OPT record with DO", () => {
  const query = encode("example.com AAAA", { recursion_desired: 0, dnssec_ok: 1 });
  assert.equal(query.readUInt16BE(2), 0);
  assert.equal(query.readUInt16BE(10), 1);
  assert.deepEqual(query.subarray(-11), Buffer.from([0, 0, 41, 0x04, 0xd0, 0, 0, 0x80, 0, 0, 0]));
  // Uniforms persist on a reused instance, so restore the defaults.
  encode("example.com", { recursion_desired: 1, dnssec_ok: 0, id: 0 });
});

test("encoder rejects bad questions at the failing byte", () => {
  assert.equal(rejectedAt(encoder, "example..com"), 8);
  assert.equal(rejectedAt(encoder, `${"a".repeat(64)}.com`), 63);
  assert.equal(rejectedAt(encoder, "example.com BOGUS"), 12);
  assert.equal(rejectedAt(encoder, "example.com A IN A"), 17);
  assert.equal(rejectedAt(encoder, "example.com\nmore"), 12);
});

test("decoder prints every record family in presentation format", () => {
  assert.equal(decode(sampleResponse()), sampleText);
});

test("decoder output round-trips through the encoder", () => {
  const query = encode("www.example.com. IN A", { id: 0x1234 });
  assert.match(decode(query), /^;www\.example\.com\.\tIN\tA$/m);
  assert.match(decode(query), /flags: rd; QUERY: 1, ANSWER: 0/);
});

test("decoder combines the OPT extended RCODE with the header RCODE", () => {
  const m = new Message();
  m.u16(1).u16(0x8000).u16(0).u16(0).u16(0).u16(1);
  m.record((r) => r.name(""), 41, 0x0100_0000, () => {}, 512);
  assert.match(decode(m.buffer()), /status: BADVERS,/);
  assert.match(decode(m.buffer()), /; EDNS: version: 0, flags:; udp: 512\n/);
});

test("decoder rejects pointer loops, forward pointers, and long names", () => {
  const header = [0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0];
  // A pointer to itself, and a pointer forward to the next byte.
  assert.equal(rejectedAt(decoder, new Uint8Array([...header, 0xc0, 12, 0, 1, 0, 1])), 12);
  assert.equal(rejectedAt(decoder, new Uint8Array([...header, 0xc0, 14, 0, 0, 1, 0, 1])), 12);
  // A label followed by a backward pointer to itself repeats until the name
  // passes 255 bytes. The fourth copy of the 64-byte label is rejected.
  const loop = new Message();
  loop.u8(...header).u8(63).text("a".repeat(63)).u16(0xc000 | 12).u16(1).u16(1);
  assert.equal(rejectedAt(decoder, loop.buffer()), 12);
  // Extended label types 0x40 and 0x80 are reserved.
  assert.equal(rejectedAt(decoder, new Uint8Array([...header, 0x41, 0, 0, 1, 0, 1])), 12);
});

test("decoder rejects OPT outside the additional section and trailing bytes", () => {
  const m = new Message();
  m.u16(1).u16(0x8000).u16(0).u16(1).u16(0).u16(0);
  m.record((r) => r.name(""), 41, 0, () => {}, 512);
  assert.equal(rejectedAt(decoder, m.buffer()), 13);
  const trailing = Buffer.concat([encode("example.com"), Buffer.from([0])]);
  assert.equal(rejectedAt(decoder, trailing), trailing.length - 1);
});

test("decoder rejects every truncation of a valid message without trapping", () => {
  const message = sampleResponse();
  for (let size = 0; size < message.length; size += 1) {
    const result = decoder.run(message.subarray(0, size));
    assert.equal(result.status, "rejected", `size ${size}`);
    assert.ok(result.inputOffset <= size, `size ${size} offset ${result.inputOffset}`);
  }
});

test("decoder survives random corruption without trapping", () => {
  const message = sampleResponse();
  let seed = 0x9e3779b9;
  const next = () => {
    seed ^= seed << 13;
    seed ^= seed >>> 17;
    seed ^= seed << 5;
    return seed >>> 0;
  };
  let accepted = 0;
  for (let round = 0; round < 20000; round += 1) {
    const mutated = Buffer.from(message);
    const flips = 1 + (next() % 4);
    for (let i = 0; i < flips; i += 1) mutated[next() % mutated.length] = next() & 0xff;
    const result = decoder.run(mutated);
    if (result.status === "accepted") {
      accepted += 1;
      ascii.decode(result.output);
    } else {
      assert.ok(result.inputOffset <= mutated.length);
    }
  }
  assert.ok(accepted > 0);
});

test("components pass the strict profile, loop and division checkers", async () => {
  for (const module of [encoderPath, decoderPath]) {
    await execFileAsync(qip, ["run", "-i", module, "--", ...strictCheckers]);
  }
});

test("qip pipes the encoder output into the decoder", async () => {
  const { stdout } = await execFileAsync("sh", [
    "-c",
    `printf 'example.org TXT' | "${qip}" run "${encoderPath}" -u id=7 | "${qip}" run "${decoderPath}"`,
  ]);
  assert.match(stdout, /id: 7\n;; flags: rd; QUERY: 1/);
  assert.match(stdout, /^;example\.org\.\tIN\tTXT$/m);
});
