import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import { deflateRawSync } from "node:zlib";
import test from "node:test";

const execFileAsync = promisify(execFile);
const qip = join(process.cwd(), "qip");
const entriesComponent = join(
  process.cwd(),
  "application/zip/zip-list-entries-csv.wasm",
);
const filesComponent = join(
  process.cwd(),
  "application/zip/zip-list-files-csv.wasm",
);
const wasmCounts = join(
  process.cwd(),
  "application/wasm/wasm-counts.wasm",
);
const extractComponent = join(
  process.cwd(),
  "application/zip/zip-extract-file.wasm",
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
  for (const byte of bytes) {
    value = crcTable[(value ^ byte) & 0xff] ^ (value >>> 8);
  }
  return (value ^ 0xffffffff) >>> 0;
}

function makeZip(specs) {
  const locals = [];
  const centrals = [];
  let localOffset = 0;
  for (const spec of specs) {
    const name = Buffer.from(spec.name);
    const body = Buffer.from(spec.body ?? "");
    const method = spec.method ?? 0;
    const compressed = method === 8 ? deflateRawSync(body) : body;
    const checksum = crc32(body);
    const flags = 0x800;

    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50, 0);
    local.writeUInt16LE(20, 4);
    local.writeUInt16LE(flags, 6);
    local.writeUInt16LE(method, 8);
    local.writeUInt16LE(0, 10);
    local.writeUInt16LE(0x2821, 12);
    local.writeUInt32LE(checksum, 14);
    local.writeUInt32LE(compressed.length, 18);
    local.writeUInt32LE(body.length, 22);
    local.writeUInt16LE(name.length, 26);
    locals.push(local, name, compressed);

    const central = Buffer.alloc(46);
    central.writeUInt32LE(0x02014b50, 0);
    central.writeUInt16LE(spec.madeBy ?? 0x0314, 4);
    central.writeUInt16LE(20, 6);
    central.writeUInt16LE(flags, 8);
    central.writeUInt16LE(method, 10);
    central.writeUInt16LE(0, 12);
    central.writeUInt16LE(0x2821, 14);
    central.writeUInt32LE(checksum, 16);
    central.writeUInt32LE(compressed.length, 20);
    central.writeUInt32LE(body.length, 24);
    central.writeUInt16LE(name.length, 28);
    central.writeUInt32LE((spec.external ?? (0o100644 << 16)) >>> 0, 38);
    central.writeUInt32LE(localOffset, 42);
    centrals.push(central, name);
    localOffset += local.length + name.length + compressed.length;
  }

  const centralDirectory = Buffer.concat(centrals);
  const ending = Buffer.alloc(22);
  ending.writeUInt32LE(0x06054b50, 0);
  ending.writeUInt16LE(specs.length, 8);
  ending.writeUInt16LE(specs.length, 10);
  ending.writeUInt32LE(centralDirectory.length, 12);
  ending.writeUInt32LE(localOffset, 16);
  return Buffer.concat([...locals, centralDirectory, ending]);
}

async function runComponent(directory, inputPath, outputName, component, query) {
  const outputPath = join(directory, outputName);
  const args = ["run", "-i", inputPath, "-o", outputPath, component];
  if (query) args.push(query);
  await execFileAsync(qip, args);
  return readFile(outputPath);
}

test("ZIP listing components have no indirect calls", async () => {
  for (const component of [entriesComponent, filesComponent]) {
    const { stdout } = await execFileAsync(qip, [
      "run", "-i", component, "--", wasmCounts,
    ]);
    assert.match(stdout, /^calls_indirect,0$/m);
  }
});

test("ZIP listings expose entry and dense regular-file indices", async () => {
  const directory = await mkdtemp(join(tmpdir(), "qip-zip-list-"));
  const inputPath = join(directory, "input.zip");
  await writeFile(
    inputPath,
    makeZip([
      { name: "root/", external: 0o040755 << 16 },
      { name: "root/first.txt", body: "first", external: 0o100640 << 16 },
      { name: "root/latest", body: "first.txt", external: 0o120777 << 16 },
      {
        name: 'root/a,"quoted".txt',
        body: "second file",
        method: 8,
        external: 0o100755 << 16,
      },
      { name: "root/empty/", external: 0o040755 << 16 },
      { name: "fat-directory", madeBy: 0, external: 0x10 },
    ]),
  );

  const entries = await runComponent(
    directory,
    inputPath,
    "entries.csv",
    entriesComponent,
  );
  assert.equal(
    entries.toString(),
    [
      "entry_index,file_index,path,type,method,compressed_size,size,mode,mtime",
      '0,,"root/",directory,store,0,0,0755,946684800',
      '1,0,"root/first.txt",file,store,5,5,0640,946684800',
      '2,,"root/latest",symlink,store,9,9,0777,946684800',
      '3,1,"root/a,"""quoted""".txt",file,deflate,13,11,0755,946684800',
      '4,,"root/empty/",directory,store,0,0,0755,946684800',
      '5,,"fat-directory/",directory,store,0,0,0755,946684800',
      "",
    ].join("\n"),
  );

  const files = await runComponent(
    directory,
    inputPath,
    "files.csv",
    filesComponent,
  );
  assert.equal(
    files.toString(),
    [
      "file_index,entry_index,path,method,compressed_size,size,mode,mtime",
      '0,1,"root/first.txt",store,5,5,0640,946684800',
      '1,3,"root/a,"""quoted""".txt",deflate,13,11,0755,946684800',
      "",
    ].join("\n"),
  );
});

test("zip-extract-file uses file_index rather than entry_index", async () => {
  const directory = await mkdtemp(join(tmpdir(), "qip-zip-extract-"));
  const inputPath = join(directory, "input.zip");
  await writeFile(
    inputPath,
    makeZip([
      { name: "root/", external: 0o040755 << 16 },
      { name: "root/first", body: "first body" },
      { name: "root/link", body: "first", external: 0o120777 << 16 },
      { name: "root/second", body: "second body", method: 8 },
    ]),
  );

  assert.equal(
    (
      await runComponent(
        directory,
        inputPath,
        "default.bin",
        extractComponent,
      )
    ).toString(),
    "first body",
  );
  assert.equal(
    (
      await runComponent(
        directory,
        inputPath,
        "second.bin",
        extractComponent,
        "?file_index=1",
      )
    ).toString(),
    "second body",
  );

  await assert.rejects(
    runComponent(
      directory,
      inputPath,
      "missing.bin",
      extractComponent,
      "?file_index=2",
    ),
    /wasm error: unreachable/,
  );
});

test("file_index uniform has the unsigned i32 setter contract", async () => {
  const bytes = await readFile(extractComponent);
  const instance = await WebAssembly.instantiate(bytes);
  assert.equal(instance.instance.exports.uniform_set_file_index(7), 7);
  assert.equal(instance.instance.exports.uniform_set_file_index(-1), -1);
});
