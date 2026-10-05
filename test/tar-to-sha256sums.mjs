import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdir, mkdtemp, readFile, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import test from "node:test";

const execFileAsync = promisify(execFile);
const qip = join(process.cwd(), "qip");
const component = join(
  process.cwd(),
  "application/x-tar/tar-to-sha256sums.wasm",
);

function writeOctal(header, start, length, value) {
  const text = value.toString(8).padStart(length - 1, "0");
  assert.ok(text.length < length);
  header.write(text, start, "ascii");
  header[start + length - 1] = 0;
}

function tarHeader({ name, prefix = "", size, type = "0", link = "" }) {
  const header = Buffer.alloc(512);
  header.write(name, 0, 100, "utf8");
  writeOctal(header, 100, 8, 0o644);
  writeOctal(header, 108, 8, 0);
  writeOctal(header, 116, 8, 0);
  writeOctal(header, 124, 12, size);
  writeOctal(header, 136, 12, 946684800);
  header.fill(0x20, 148, 156);
  header.write(type, 156, 1, "ascii");
  header.write(link, 157, 100, "utf8");
  header.write("ustar\0", 257, 6, "ascii");
  header.write("00", 263, 2, "ascii");
  header.write(prefix, 345, 155, "utf8");
  let checksum = 0;
  for (const byte of header) checksum += byte;
  header.write(checksum.toString(8).padStart(6, "0"), 148, 6, "ascii");
  header[154] = 0;
  header[155] = 0x20;
  return header;
}

function tarEntry(options) {
  const body = options.body ?? Buffer.alloc(0);
  const padding = Buffer.alloc((512 - (body.length % 512)) % 512);
  return Buffer.concat([
    tarHeader({ ...options, size: options.size ?? body.length }),
    body,
    padding,
  ]);
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

function sha256(body) {
  return createHash("sha256").update(body).digest("hex");
}

async function run(archive) {
  const directory = await mkdtemp(join(tmpdir(), "qip-tar-to-sha256sums-"));
  const inputPath = join(directory, "input.tar");
  const outputPath = join(directory, "SHA256SUMS");
  await writeFile(inputPath, archive);
  await execFileAsync(qip, ["run", "-i", inputPath, "-o", outputPath, component]);
  return readFile(outputPath, "utf8");
}

test("tar-to-sha256sums lists regular files in archive order", async () => {
  const longPath = `${"long-segment/".repeat(10)}file.txt`;
  const gnuPath = `${"gnu-segment/".repeat(10)}file.txt`;
  const big = Buffer.alloc(70_000, 0x61);
  const archive = Buffer.concat([
    tarEntry({ name: "docs/", type: "5" }),
    tarEntry({ name: "docs/readme.md", body: Buffer.from("# Hello\n") }),
    tarEntry({ name: "empty" }),
    tarEntry({ name: "latest", type: "2", link: "docs/readme.md" }),
    tarEntry({ name: "copy", type: "1", link: "docs/readme.md" }),
    tarEntry({ name: "old-dir/", type: "0" }),
    tarEntry({ name: "file.bin", prefix: "nested/dir", body: big }),
    tarEntry({ name: "PaxHeader", type: "x", body: paxRecord("path", longPath) }),
    tarEntry({ name: "placeholder", body: Buffer.from("pax") }),
    tarEntry({
      name: "././@LongLink",
      type: "L",
      body: Buffer.from(`${gnuPath}\0`),
    }),
    tarEntry({ name: "truncated", body: Buffer.from("gnu") }),
    Buffer.alloc(1024),
  ]);

  assert.equal(
    await run(archive),
    [
      `${sha256("# Hello\n")}  docs/readme.md`,
      `${sha256("")}  empty`,
      `${sha256(big)}  nested/dir/file.bin`,
      `${sha256("pax")}  ${longPath}`,
      `${sha256("gnu")}  ${gnuPath}`,
      "",
    ].join("\n"),
  );
});

test("tar-to-sha256sums escapes backslashes and newlines like coreutils", async () => {
  const archive = Buffer.concat([
    tarEntry({ name: "a\\b", body: Buffer.from("1") }),
    tarEntry({ name: "line\nbreak", body: Buffer.from("2") }),
    Buffer.alloc(1024),
  ]);

  assert.equal(
    await run(archive),
    `\\${sha256("1")}  a\\\\b\n\\${sha256("2")}  line\\nbreak\n`,
  );
});

test("tar-to-sha256sums output passes sha256sum -c on a system tar", async (t) => {
  try {
    await execFileAsync("sha256sum", ["--version"]);
  } catch {
    t.skip("sha256sum is not installed");
    return;
  }
  const directory = await mkdtemp(join(tmpdir(), "qip-tar-to-sha256sums-sys-"));
  const tree = join(directory, "tree");
  await mkdir(join(tree, "sub"), { recursive: true });
  await writeFile(join(tree, "one.txt"), "one\n");
  await writeFile(join(tree, "sub", "two.bin"), Buffer.alloc(5000, 7));
  await writeFile(join(tree, "sub", "back\\slash"), "three");
  await symlink("one.txt", join(tree, "link"));
  const inputPath = join(directory, "tree.tar");
  await execFileAsync("tar", ["-cf", inputPath, "-C", tree, "."], {
    env: { ...process.env, COPYFILE_DISABLE: "1" },
  });

  const sumsPath = join(directory, "SHA256SUMS");
  await execFileAsync(qip, ["run", "-i", inputPath, "-o", sumsPath, component]);
  const sums = await readFile(sumsPath, "utf8");
  assert.equal(sums.trimEnd().split("\n").length, 3);
  const { stdout } = await execFileAsync("sha256sum", ["-c", sumsPath], { cwd: tree });
  assert.match(stdout, /one\.txt: OK/);
});

test("tar-to-sha256sums traps on malformed tar input", async () => {
  const archive = Buffer.concat([
    tarEntry({ name: "file", body: Buffer.from("x") }),
    Buffer.alloc(1024),
  ]);
  archive[0] ^= 1;
  await assert.rejects(run(archive), /wasm error: unreachable/);
});
