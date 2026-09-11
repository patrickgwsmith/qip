import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import {
  lstat,
  mkdtemp,
  readFile,
  readlink,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import { constants, deflateRawSync } from "node:zlib";
import test from "node:test";

const execFileAsync = promisify(execFile);
const qip = join(process.cwd(), "qip");
const component = join(
  process.cwd(),
  "application/zip/zip-to-tar.wasm",
);
const wasmCounts = join(
  process.cwd(),
  "application/wasm/wasm-counts.wasm",
);
const reverse = join(
  process.cwd(),
  "application/x-tar/tar-to-zip.wasm",
);

const crcTable = new Uint32Array(256);
for (let n = 0; n < 256; n += 1) {
  let value = n;
  for (let bit = 0; bit < 8; bit += 1) {
    value = value & 1 ? 0xedb88320 ^ (value >>> 1) : value >>> 1;
  }
  crcTable[n] = value >>> 0;
}

function crc32(bytes) {
  let value = 0xffffffff;
  for (const byte of bytes) value = crcTable[(value ^ byte) & 0xff] ^ (value >>> 8);
  return (value ^ 0xffffffff) >>> 0;
}

function extra(id, value) {
  const header = Buffer.alloc(4);
  header.writeUInt16LE(id, 0);
  header.writeUInt16LE(value.length, 2);
  return Buffer.concat([header, value]);
}

function timestampExtra(mtime, flags = 1) {
  const value = Buffer.alloc(5);
  value[0] = flags;
  value.writeUInt32LE(mtime, 1);
  return extra(0x5455, value);
}

function unicodePathExtra(rawName, path) {
  const encoded = Buffer.from(path);
  const value = Buffer.alloc(5 + encoded.length);
  value[0] = 1;
  value.writeUInt32LE(crc32(rawName), 1);
  encoded.copy(value, 5);
  return extra(0x7075, value);
}

function uidGidExtra(uid, gid) {
  const value = Buffer.alloc(11);
  value[0] = 1;
  value[1] = 4;
  value.writeUInt32LE(uid, 2);
  value[6] = 4;
  value.writeUInt32LE(gid, 7);
  return extra(0x7875, value);
}

function makeZip(specs, { comment = "" } = {}) {
  const localParts = [];
  const centralParts = [];
  let localOffset = 0;

  for (const spec of specs) {
    const name = Buffer.isBuffer(spec.name) ? spec.name : Buffer.from(spec.name);
    const body = Buffer.from(spec.body ?? "");
    const method = spec.method ?? 0;
    const compressed = spec.compressed
      ? Buffer.from(spec.compressed)
      : method === 8
        ? deflateRawSync(body, spec.deflateOptions)
        : Buffer.from(body);
    const localExtra = spec.localExtra ?? Buffer.alloc(0);
    const centralExtra = spec.centralExtra ?? localExtra;
    const descriptor = spec.descriptor ?? false;
    const flags =
      (spec.flags ?? (Buffer.isBuffer(spec.name) ? 0 : 0x800)) |
      (descriptor ? 8 : 0);
    const checksum = spec.crc ?? crc32(body);
    const dosDate = 0x2821;
    const dosTime = 0;

    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50, 0);
    local.writeUInt16LE(20, 4);
    local.writeUInt16LE(flags, 6);
    local.writeUInt16LE(method, 8);
    local.writeUInt16LE(dosTime, 10);
    local.writeUInt16LE(dosDate, 12);
    if (!descriptor) {
      local.writeUInt32LE(checksum, 14);
      local.writeUInt32LE(compressed.length, 18);
      local.writeUInt32LE(body.length, 22);
    }
    local.writeUInt16LE(name.length, 26);
    local.writeUInt16LE(localExtra.length, 28);
    localParts.push(local, name, localExtra, compressed);

    if (descriptor) {
      const dataDescriptor = Buffer.alloc(spec.signedDescriptor === false ? 12 : 16);
      let position = 0;
      if (dataDescriptor.length === 16) {
        dataDescriptor.writeUInt32LE(0x08074b50, position);
        position += 4;
      }
      dataDescriptor.writeUInt32LE(checksum, position);
      dataDescriptor.writeUInt32LE(compressed.length, position + 4);
      dataDescriptor.writeUInt32LE(body.length, position + 8);
      localParts.push(dataDescriptor);
    }

    const central = Buffer.alloc(46);
    central.writeUInt32LE(0x02014b50, 0);
    central.writeUInt16LE(spec.madeBy ?? 0x0314, 4);
    central.writeUInt16LE(20, 6);
    central.writeUInt16LE(flags, 8);
    central.writeUInt16LE(method, 10);
    central.writeUInt16LE(dosTime, 12);
    central.writeUInt16LE(dosDate, 14);
    central.writeUInt32LE(checksum, 16);
    central.writeUInt32LE(compressed.length, 20);
    central.writeUInt32LE(body.length, 24);
    central.writeUInt16LE(name.length, 28);
    central.writeUInt16LE(centralExtra.length, 30);
    central.writeUInt32LE((spec.external ?? (0o100644 << 16)) >>> 0, 38);
    central.writeUInt32LE(localOffset, 42);
    centralParts.push(central, name, centralExtra);
    localOffset +=
      local.length +
      name.length +
      localExtra.length +
      compressed.length +
      (descriptor ? (spec.signedDescriptor === false ? 12 : 16) : 0);
  }

  const central = Buffer.concat(centralParts);
  const ending = Buffer.alloc(22 + Buffer.byteLength(comment));
  ending.writeUInt32LE(0x06054b50, 0);
  ending.writeUInt16LE(specs.length, 8);
  ending.writeUInt16LE(specs.length, 10);
  ending.writeUInt32LE(central.length, 12);
  ending.writeUInt32LE(localOffset, 16);
  ending.writeUInt16LE(Buffer.byteLength(comment), 20);
  ending.write(comment, 22);
  return Buffer.concat([...localParts, central, ending]);
}

function tarNumber(field) {
  const text = field.toString("ascii").replace(/\0.*$/, "").trim();
  return text === "" ? 0 : Number.parseInt(text, 8);
}

function parsePax(body) {
  const values = {};
  let offset = 0;
  while (offset < body.length) {
    const space = body.indexOf(0x20, offset);
    const length = Number.parseInt(body.subarray(offset, space).toString(), 10);
    const record = body.subarray(space + 1, offset + length - 1).toString();
    const equals = record.indexOf("=");
    values[record.slice(0, equals)] = record.slice(equals + 1);
    offset += length;
  }
  return values;
}

function readTar(bytes) {
  const entries = [];
  let offset = 0;
  let pending = {};
  while (offset + 512 <= bytes.length) {
    const header = bytes.subarray(offset, offset + 512);
    if (header.every((byte) => byte === 0)) break;
    const name = header.subarray(0, 100).toString().replace(/\0.*$/, "");
    const prefix = header.subarray(345, 500).toString().replace(/\0.*$/, "");
    const size = tarNumber(header.subarray(124, 136));
    const type = String.fromCharCode(header[156] || 0x30);
    const body = bytes.subarray(offset + 512, offset + 512 + size);
    offset += 512 + Math.ceil(size / 512) * 512;
    if (type === "x") {
      pending = parsePax(body);
      continue;
    }
    entries.push({
      name: pending.path ?? (prefix ? `${prefix}/${name}` : name),
      body: Buffer.from(body),
      type,
      mode: tarNumber(header.subarray(100, 108)),
      uid: Number(pending.uid ?? tarNumber(header.subarray(108, 116))),
      gid: Number(pending.gid ?? tarNumber(header.subarray(116, 124))),
      mtime: Number(pending.mtime ?? tarNumber(header.subarray(136, 148))),
      link:
        pending.linkpath ??
        header.subarray(157, 257).toString().replace(/\0.*$/, ""),
    });
    pending = {};
  }
  assert.ok(bytes.subarray(offset, offset + 1024).every((byte) => byte === 0));
  return entries;
}

async function convertZip(zip, prefix = "qip-zip-to-tar-") {
  const directory = await mkdtemp(join(tmpdir(), prefix));
  const inputPath = join(directory, "input.zip");
  const outputPath = join(directory, "output.tar");
  await writeFile(inputPath, zip);
  await execFileAsync(qip, ["run", "-i", inputPath, "-o", outputPath, component]);
  return { directory, inputPath, outputPath, tar: await readFile(outputPath) };
}

function rawStoredBlocks(parts) {
  const blocks = [];
  for (const [index, partValue] of parts.entries()) {
    const part = Buffer.from(partValue);
    assert.ok(part.length <= 0xffff);
    const header = Buffer.alloc(5);
    header[0] = index === parts.length - 1 ? 1 : 0;
    header.writeUInt16LE(part.length, 1);
    header.writeUInt16LE((~part.length) & 0xffff, 3);
    blocks.push(header, part);
  }
  return Buffer.concat(blocks);
}

test("zip-to-tar has no indirect calls", async () => {
  const { stdout } = await execFileAsync(qip, [
    "run", "-i", component, "--", wasmCounts,
  ]);
  assert.match(stdout, /^calls_indirect,0$/m);
});

test("zip-to-tar converts stored, DEFLATE, metadata, names, and symlinks", async () => {
  const mtime = 1_700_000_001;
  const cp437Name = Buffer.from([0x63, 0x61, 0x66, 0x82, 0x2e, 0x74, 0x78, 0x74]);
  const unicodeRaw = Buffer.from("fallback.txt");
  const longPath = `${"x".repeat(156)}/file.txt`;
  const zip = makeZip(
    [
      { name: "dir/", external: 0o040755 << 16 },
      { name: "plain.txt", body: "stored", external: 0o100640 << 16 },
      {
        name: "fixed.txt",
        body: "fixed huffman ".repeat(300),
        method: 8,
        deflateOptions: { strategy: constants.Z_FIXED },
        descriptor: true,
      },
      {
        name: "dynamic.txt",
        body: "dynamic huffman ".repeat(2000),
        method: 8,
        descriptor: true,
        signedDescriptor: false,
      },
      {
        name: "multi-block.txt",
        body: "first blocksecond block",
        method: 8,
        compressed: rawStoredBlocks(["first block", "second block"]),
      },
      {
        name: "compressed-dir/",
        method: 8,
        compressed: deflateRawSync(Buffer.alloc(0)),
        external: 0o040755 << 16,
      },
      { name: cp437Name, body: "cp437", flags: 0 },
      {
        name: unicodeRaw,
        body: "unicode",
        flags: 0,
        localExtra: unicodePathExtra(unicodeRaw, "日本語.txt"),
        centralExtra: Buffer.alloc(0),
      },
      { name: "windows\\path.txt", body: "slashes" },
      { name: longPath, body: "long" },
      {
        name: "dir/latest",
        body: "../plain.txt",
        external: 0o120777 << 16,
      },
      {
        name: "owned.txt",
        body: "metadata",
        localExtra: Buffer.concat([
          timestampExtra(mtime),
          uidGidExtra(3_000_000, 4_000_000),
        ]),
        centralExtra: Buffer.concat([
          timestampExtra(mtime, 3),
          uidGidExtra(3_000_000, 4_000_000),
        ]),
      },
    ],
    { comment: "ignored archive comment" },
  );

  const { directory, outputPath, tar } = await convertZip(zip);
  const entries = readTar(tar);
  assert.deepEqual(
    entries.map((entry) => entry.name),
    [
      "dir/",
      "plain.txt",
      "fixed.txt",
      "dynamic.txt",
      "multi-block.txt",
      "compressed-dir/",
      "café.txt",
      "日本語.txt",
      "windows/path.txt",
      longPath,
      "dir/latest",
      "owned.txt",
    ],
  );
  assert.equal(entries[1].body.toString(), "stored");
  assert.equal(entries[1].mode, 0o640);
  assert.equal(entries[2].body.toString(), "fixed huffman ".repeat(300));
  assert.equal(entries[3].body.toString(), "dynamic huffman ".repeat(2000));
  assert.equal(entries[4].body.toString(), "first blocksecond block");
  assert.equal(entries[5].type, "5");
  assert.equal(entries[10].type, "2");
  assert.equal(entries[10].link, "../plain.txt");
  assert.equal(entries[11].mtime, mtime);
  assert.equal(entries[11].uid, 3_000_000);
  assert.equal(entries[11].gid, 4_000_000);
  assert.match(tar.toString("utf8"), / path=x{156}\/file\.txt/);

  const extraction = join(directory, "extracted");
  await execFileAsync("mkdir", [extraction]);
  await execFileAsync("bsdtar", ["-xf", outputPath, "-C", extraction]);
  assert.equal((await readFile(join(extraction, "plain.txt"))).toString(), "stored");
  assert.equal(await readlink(join(extraction, "dir/latest")), "../plain.txt");
  assert.ok((await lstat(join(extraction, "dir/latest"))).isSymbolicLink());
});

test("zip-to-tar round trips semantically through tar-to-zip", async () => {
  const first = await convertZip(
    makeZip([
      { name: "bin/", external: 0o040755 << 16 },
      { name: "bin/tool", body: "#!/bin/sh\n", method: 8, external: 0o100755 << 16 },
      { name: "tool-link", body: "bin/tool", external: 0o120777 << 16 },
    ]),
    "qip-zip-to-tar-roundtrip-",
  );
  const zipPath = join(first.directory, "roundtrip.zip");
  const tarPath = join(first.directory, "roundtrip.tar");
  await execFileAsync(qip, ["run", "-i", first.outputPath, "-o", zipPath, reverse]);
  await execFileAsync(qip, ["run", "-i", zipPath, "-o", tarPath, component]);
  const original = readTar(first.tar);
  const roundtrip = readTar(await readFile(tarPath));
  assert.deepEqual(
    roundtrip.map(({ name, body, type, mode, link, mtime }) => ({
      name,
      body: body.toString("hex"),
      type,
      mode,
      link,
      mtime,
    })),
    original.map(({ name, body, type, mode, link, mtime }) => ({
      name,
      body: body.toString("hex"),
      type,
      mode,
      link,
      mtime,
    })),
  );
});

test("zip-to-tar rejects corrupt and unsafe archives", async () => {
  const cases = [];
  cases.push(makeZip([{ name: "../escape", body: "x" }]));
  cases.push(makeZip([{ name: "secret", body: "x", flags: 1 }]));
  cases.push(makeZip([{ name: "method", body: "x", method: 12 }]));
  cases.push(makeZip([{ name: "bad", body: "x", crc: 123 }]));
  cases.push(makeZip([{ name: "special", external: 0o020600 << 16 }]));
  cases.push(makeZip([{ name: "dir/link", body: "../../escape", external: 0o120777 << 16 }]));
  cases.push(makeZip([{ name: "extra", localExtra: extra(0x7075, Buffer.from([1])) }]));
  const goodDeflate = deflateRawSync(Buffer.from("body"));
  cases.push(
    makeZip([
      {
        name: "trailing",
        body: "body",
        method: 8,
        compressed: Buffer.concat([goodDeflate, Buffer.from([0])]),
      },
    ]),
  );

  const zip64 = makeZip([{ name: "x", body: "x" }]);
  zip64.writeUInt16LE(0xffff, zip64.length - 12);
  cases.push(zip64);

  const multiDisk = makeZip([{ name: "x", body: "x" }]);
  multiDisk.writeUInt16LE(1, multiDisk.length - 18);
  cases.push(multiDisk);

  const overlap = makeZip([
    { name: "one", body: "1" },
    { name: "two", body: "2" },
  ]);
  const eocd = overlap.length - 22;
  const centralOffset = overlap.readUInt32LE(eocd + 16);
  const firstCentralLength =
    46 +
    overlap.readUInt16LE(centralOffset + 28) +
    overlap.readUInt16LE(centralOffset + 30);
  overlap.writeUInt32LE(0, centralOffset + firstCentralLength + 42);
  cases.push(overlap);

  for (const [index, zip] of cases.entries()) {
    const directory = await mkdtemp(join(tmpdir(), `qip-zip-reject-${index}-`));
    const inputPath = join(directory, "bad.zip");
    const outputPath = join(directory, "bad.tar");
    await writeFile(inputPath, zip);
    await assert.rejects(
      execFileAsync(qip, ["run", "-i", inputPath, "-o", outputPath, component]),
      /wasm error: unreachable/,
    );
  }
});
