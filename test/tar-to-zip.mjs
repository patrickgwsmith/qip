import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import { inflateRawSync } from "node:zlib";
import test from "node:test";

const execFileAsync = promisify(execFile);
const qip = join(process.cwd(), "qip");
const component = join(
  process.cwd(),
  "application/x-tar/tar-to-zip.wasm",
);

function writeOctal(header, start, length, value) {
  const text = value.toString(8).padStart(length - 1, "0");
  assert.ok(text.length < length);
  header.write(text, start, "ascii");
  header[start + length - 1] = 0;
}

function tarHeader({
  name,
  body = Buffer.alloc(0),
  mode = 0o644,
  mtime = 946684800,
  type = "0",
  link = "",
}) {
  const header = Buffer.alloc(512);
  header.write(name, 0, 100, "utf8");
  writeOctal(header, 100, 8, mode);
  writeOctal(header, 108, 8, 0);
  writeOctal(header, 116, 8, 0);
  writeOctal(header, 124, 12, body.length);
  writeOctal(header, 136, 12, mtime);
  header.fill(0x20, 148, 156);
  header.write(type, 156, 1, "ascii");
  header.write(link, 157, 100, "utf8");
  header.write("ustar\0", 257, 6, "ascii");
  header.write("00", 263, 2, "ascii");
  let checksum = 0;
  for (const byte of header) checksum += byte;
  const checksumText = checksum.toString(8).padStart(6, "0");
  header.write(checksumText, 148, 6, "ascii");
  header[154] = 0;
  header[155] = 0x20;
  return header;
}

function tarEntry(options) {
  const body = options.body ?? Buffer.alloc(0);
  const padding = Buffer.alloc((512 - (body.length % 512)) % 512);
  return Buffer.concat([tarHeader({ ...options, body }), body, padding]);
}

function paxRecord(key, value) {
  const suffix = ` ${key}=${value}\n`;
  let length = Buffer.byteLength(suffix) + 1;
  while (true) {
    const next = Buffer.byteLength(String(length)) + Buffer.byteLength(suffix);
    if (next === length) return Buffer.from(`${length}${suffix}`);
    length = next;
  }
}

function makeTar() {
  const longPath = `${"long-segment/".repeat(10)}file.txt`;
  const pax = paxRecord("path", longPath);
  return {
    longPath,
    bytes: Buffer.concat([
      tarEntry({ name: "docs/", type: "5", mode: 0o755 }),
      tarEntry({
        name: "docs/repetitive.txt",
        body: Buffer.from("abcdef".repeat(4096)),
        mode: 0o640,
      }),
      tarEntry({ name: "tiny", body: Buffer.from("x") }),
      tarEntry({
        name: "latest",
        type: "2",
        mode: 0o777,
        link: "docs/repetitive.txt",
      }),
      tarEntry({ name: "PaxHeader", type: "x", body: pax }),
      tarEntry({ name: "placeholder", body: Buffer.from("long path") }),
      Buffer.alloc(1024),
    ]),
  };
}

function findEndRecord(zip) {
  for (let offset = zip.length - 22; offset >= 0; offset -= 1) {
    if (zip.readUInt32LE(offset) === 0x06054b50) return offset;
  }
  assert.fail("missing ZIP end-of-central-directory record");
}

function readZip(zip) {
  const end = findEndRecord(zip);
  const count = zip.readUInt16LE(end + 10);
  let offset = zip.readUInt32LE(end + 16);
  const result = new Map();

  for (let index = 0; index < count; index += 1) {
    assert.equal(zip.readUInt32LE(offset), 0x02014b50);
    const method = zip.readUInt16LE(offset + 10);
    const compressedSize = zip.readUInt32LE(offset + 20);
    const uncompressedSize = zip.readUInt32LE(offset + 24);
    const nameLength = zip.readUInt16LE(offset + 28);
    const extraLength = zip.readUInt16LE(offset + 30);
    const commentLength = zip.readUInt16LE(offset + 32);
    const externalAttributes = zip.readUInt32LE(offset + 38);
    const localOffset = zip.readUInt32LE(offset + 42);
    const name = zip
      .subarray(offset + 46, offset + 46 + nameLength)
      .toString("utf8");

    assert.equal(zip.readUInt32LE(localOffset), 0x04034b50);
    const localNameLength = zip.readUInt16LE(localOffset + 26);
    const localExtraLength = zip.readUInt16LE(localOffset + 28);
    const bodyStart =
      localOffset + 30 + localNameLength + localExtraLength;
    const compressed = zip.subarray(bodyStart, bodyStart + compressedSize);
    const body =
      method === 8
        ? inflateRawSync(compressed)
        : Buffer.from(compressed);
    assert.equal(body.length, uncompressedSize);
    result.set(name, { body, method, externalAttributes });
    offset += 46 + nameLength + extraLength + commentLength;
  }
  return result;
}

test("tar-to-zip preserves entries and chooses DEFLATE or store", async () => {
  const directory = await mkdtemp(join(tmpdir(), "qip-tar-to-zip-"));
  const inputPath = join(directory, "input.tar");
  const firstPath = join(directory, "first.zip");
  const secondPath = join(directory, "second.zip");
  const archive = makeTar();
  await writeFile(inputPath, archive.bytes);

  await execFileAsync(qip, [
    "run",
    "-i",
    inputPath,
    "-o",
    firstPath,
    component,
  ]);
  await execFileAsync(qip, [
    "run",
    "-i",
    inputPath,
    "-o",
    secondPath,
    component,
  ]);

  const first = await readFile(firstPath);
  const second = await readFile(secondPath);
  assert.deepEqual(first, second);

  const entries = readZip(first);
  assert.equal(entries.get("docs/").externalAttributes >>> 16, 0o040755);
  assert.equal(entries.get("docs/repetitive.txt").method, 8);
  assert.equal(
    entries.get("docs/repetitive.txt").body.toString(),
    "abcdef".repeat(4096),
  );
  assert.equal(entries.get("docs/repetitive.txt").externalAttributes >>> 16, 0o100640);
  assert.equal(entries.get("tiny").method, 0);
  assert.equal(entries.get("tiny").body.toString(), "x");
  assert.equal(entries.get("latest").externalAttributes >>> 16, 0o120777);
  assert.equal(entries.get("latest").body.toString(), "docs/repetitive.txt");
  assert.equal(entries.get(archive.longPath).body.toString(), "long path");
});

test("tar-to-zip dynamically compresses entries larger than the old 8 MiB threshold", async () => {
  const directory = await mkdtemp(join(tmpdir(), "qip-tar-to-zip-large-"));
  const inputPath = join(directory, "input.tar");
  const outputPath = join(directory, "output.zip");
  const body = Buffer.alloc(9 * 1024 * 1024, 0x61);
  const archive = Buffer.concat([
    tarEntry({ name: "large-repetitive.bin", body }),
    Buffer.alloc(1024),
  ]);
  await writeFile(inputPath, archive);

  await execFileAsync(qip, [
    "run",
    "-i",
    inputPath,
    "-o",
    outputPath,
    component,
  ]);

  const entries = readZip(await readFile(outputPath));
  const entry = entries.get("large-repetitive.bin");
  assert.equal(entry.method, 8);
  assert.deepEqual(entry.body, body);
});

test("tar-to-zip traps on malformed tar input", async () => {
  const directory = await mkdtemp(join(tmpdir(), "qip-tar-to-zip-invalid-"));
  const inputPath = join(directory, "invalid.tar");
  const outputPath = join(directory, "invalid.zip");
  const archive = makeTar().bytes;
  archive[0] ^= 1;
  await writeFile(inputPath, archive);

  await assert.rejects(
    execFileAsync(qip, [
      "run",
      "-i",
      inputPath,
      "-o",
      outputPath,
      component,
    ]),
    /wasm error: unreachable/,
  );
});
