import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdir, mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { promisify } from "node:util";
import test from "node:test";

const execFileAsync = promisify(execFile);
const root = process.cwd();
const qip = join(root, "qip");
const csvComponent = join(
  root,
  "application/x-tar/recipes-tar-to-csv.wasm",
);
const nodeComponent = join(
  root,
  "application/x-tar/recipes-tar-to-node-tar.wasm",
);

function writeOctal(header, offset, length, value) {
  const text = value.toString(8).padStart(length - 1, "0");
  assert.ok(text.length < length);
  header.write(text, offset, "ascii");
  header[offset + length - 1] = 0;
}

function tarEntry(name, body = Buffer.alloc(0), type = "0") {
  const header = Buffer.alloc(512);
  header.write(name, 0, 100, "utf8");
  writeOctal(header, 100, 8, type === "5" ? 0o755 : 0o644);
  writeOctal(header, 108, 8, 0);
  writeOctal(header, 116, 8, 0);
  writeOctal(header, 124, 12, body.length);
  writeOctal(header, 136, 12, 0);
  header.fill(0x20, 148, 156);
  header.write(type, 156, 1, "ascii");
  header.write("ustar\0", 257, 6, "ascii");
  header.write("00", 263, 2, "ascii");
  let checksum = 0;
  for (const byte of header) checksum += byte;
  header.write(checksum.toString(8).padStart(6, "0"), 148, 6, "ascii");
  header[154] = 0;
  header[155] = 0x20;
  const padding = Buffer.alloc((512 - (body.length % 512)) % 512);
  return Buffer.concat([header, body, padding]);
}

function tar(entries) {
  return Buffer.concat([...entries, Buffer.alloc(1024)]);
}

async function run(component, input, output) {
  await execFileAsync(qip, ["run", "-i", input, "-o", output, component]);
}

test("recipe tar produces a deterministic diagnostic CSV", async () => {
  const directory = await mkdtemp(join(tmpdir(), "qip-recipe-csv-"));
  const input = join(directory, "recipes.tar");
  const output = join(directory, "pipeline.csv");
  const markdown = await readFile(
    join(root, "recipes/text/markdown/10-markdown-basic.wasm"),
  );
  const autolink = await readFile(
    join(root, "recipes/text/markdown/11-autolink-https.wasm"),
  );
  await writeFile(
    input,
    tar([
      tarEntry("_recipes/", Buffer.alloc(0), "5"),
      tarEntry("_recipes/text/markdown/11-autolink-https.wasm", autolink),
      tarEntry("_recipes/text/markdown/-12-disabled.wasm", autolink),
      tarEntry("_recipes/text/markdown/10-markdown-basic.wasm", markdown),
      tarEntry("_recipes/text/markdown/10-markdown-basic.zig", Buffer.from("// source")),
    ]),
  );

  await run(csvComponent, input, output);
  const lines = (await readFile(output, "utf8")).trimEnd().split("\n");
  assert.equal(lines[0], "source_mime,step,module,bytes,sha256");
  assert.deepEqual(
    lines.slice(1).map((line) => line.split(",").slice(0, 4)),
    [
      [
        "text/markdown",
        "10",
        "text/markdown/10-markdown-basic.wasm",
        String(markdown.length),
      ],
      [
        "text/markdown",
        "11",
        "text/markdown/11-autolink-https.wasm",
        String(autolink.length),
      ],
    ],
  );
  assert.equal(
    lines[1].split(",")[4],
    createHash("sha256").update(markdown).digest("hex"),
  );
});

test("Node recipe tar is runnable and contains no diagnostic files", async () => {
  const directory = await mkdtemp(join(tmpdir(), "qip-recipe-node-"));
  const input = join(directory, "recipes.tar");
  const output = join(directory, "node.tar");
  const extracted = join(directory, "node");
  const markdown = await readFile(
    join(root, "recipes/text/markdown/10-markdown-basic.wasm"),
  );
  await writeFile(
    input,
    tar([
      tarEntry("_recipes/text/markdown/10-markdown-basic.wasm", markdown),
    ]),
  );

  await run(nodeComponent, input, output);
  await mkdir(extracted);
  await execFileAsync("/usr/bin/tar", ["-xf", output, "-C", extracted]);
  const names = (
    await execFileAsync("/usr/bin/tar", ["-tf", output])
  ).stdout.trimEnd().split("\n");
  assert.deepEqual(names, ["recipe-book.mjs", "modules/000.wasm"]);
  assert.ok(!names.some((name) => name.endsWith(".csv")));
  assert.ok(!names.includes("package.json"));

  const { createRecipeBook } = await import(
    `${pathToFileURL(join(extracted, "recipe-book.mjs")).href}?test=${Date.now()}`
  );
  const book = await createRecipeBook();
  const result = await book.render("text/markdown", "# Hello\n\nFrom Node.");
  assert.equal(result.contentType, "text/html");
  assert.match(new TextDecoder().decode(result.bytes), /<h1>Hello<\/h1>/);
});

test("recipe tar rejects duplicate active step numbers", async () => {
  const directory = await mkdtemp(join(tmpdir(), "qip-recipe-invalid-"));
  const input = join(directory, "recipes.tar");
  const output = join(directory, "pipeline.csv");
  const markdown = await readFile(
    join(root, "recipes/text/markdown/10-markdown-basic.wasm"),
  );
  await writeFile(
    input,
    tar([
      tarEntry("_recipes/text/markdown/10-first.wasm", markdown),
      tarEntry("_recipes/text/markdown/10-second.wasm", markdown),
    ]),
  );
  await assert.rejects(run(csvComponent, input, output));
});
