import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import test from "node:test";
import { buildMultipartRelatedInput, canonicalRelatedContentType } from "../npm/qipx/qipx.mjs";

const boundary = "uuid-00000000-0000-0000-0000-000000000000";
const hosts = [
  ["Go qip", "./qip", []],
  ["Node qipx", process.execPath, ["npm/qipx/cli.mjs"]],
  ["Rust qipx", resolve("rust/qipx/target/debug/qipx"), []],
];
// Identity component declaring multipart/related with an SVG root.
const relatedSVGIdentity = Buffer.from(
  "AGFzbQEAAAABCgJgAAF/YAF/AX4DBwYAAAAAAAEFBAEBAgIHdwcGbWVtb3J5AgAJaW5wdXRfcHRyAAAPaW5wdXRfYnl0ZXNfY2FwAAEQb3V0cHV0X2J5dGVzX2NhcAACFmlucHV0X2NvbnRlbnRfdHlwZV9wdHIAAxdpbnB1dF9jb250ZW50X3R5cGVfc2l6ZQAEBnJlbmRlcgAFCi0GBQBBgAgLBgBBgIAECwYAQYCABAsEAEEACwUAQdkACwwAQoAIQiCGIACthAsLXwEAQQALWW11bHRpcGFydC9yZWxhdGVkO3R5cGU9ImltYWdlL3N2Zyt4bWwiO2JvdW5kYXJ5PXV1aWQtMDAwMDAwMDAtMDAwMC0wMDAwLTAwMDAtMDAwMDAwMDAwMDAw",
  "base64",
);
const run = (command, args, input) => spawnSync(command, args, { input, maxBuffer: 4 * 1024 * 1024 });

async function fixtures(t) {
  const directory = await mkdtemp(join(tmpdir(), "qip-related-"));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const svgPath = join(directory, "logo.svg");
  const fontPath = join(directory, "Inter.ttf");
  const componentPath = join(directory, "related-svg-identity.wasm");
  await writeFile(svgPath, "<svg/>");
  await writeFile(fontPath, Buffer.from([0, 1, 0, 0, 255]));
  await writeFile(componentPath, relatedSVGIdentity);
  return { svgPath, fontPath, componentPath };
}

test("-i root and typed -F parts produce the same related body in every host", async (t) => {
  const { svgPath, fontPath, componentPath } = await fixtures(t);
  const root = Buffer.from("<svg/>");
  const field = `font=@${fontPath};type=font/ttf`;
  const expected = Buffer.concat([
    Buffer.from(`--${boundary}\r\nContent-Type: image/svg+xml\r\n\r\n<svg/>\r\n--${boundary}\r\nContent-Type: font/ttf\r\n\r\n`),
    Buffer.from([0, 1, 0, 0, 255]), Buffer.from(`\r\n--${boundary}--\r\n`),
  ]);
  const built = await buildMultipartRelatedInput(root, canonicalRelatedContentType("image/svg+xml"), [field]);
  assert.deepEqual(Buffer.from(built.bytes), expected);
  for (const [label, command, prefix] of hosts) {
    const result = run(command, [...prefix, "run", "-i", svgPath, "-F", field, componentPath]);
    assert.equal(result.status, 0, `${label}: ${result.stderr}`);
    assert.deepEqual(result.stdout, expected, label);
  }
});

test("-F alone remains form-data; invalid related inputs fail", async (t) => {
  const { svgPath, fontPath, componentPath } = await fixtures(t);
  for (const [label, command, prefix] of hosts) {
    const form = run(command, [...prefix, "run", "-F", `font=@${fontPath};type=font/ttf`, "bytes/identity.wasm"]);
    assert.equal(form.status, 0, `${label}: ${form.stderr}`);
    assert.match(form.stdout.toString(), /Content-Disposition: form-data/);
    assert.match(form.stdout.toString(), /Content-Type: font\/ttf/);
    const textPart = run(command, [...prefix, "run", "-F", `data=<${svgPath};type=image/svg+xml`, "bytes/identity.wasm"]);
    assert.equal(textPart.status, 0, `${label}: ${textPart.stderr}`);
    assert.match(textPart.stdout.toString(), /Content-Type: image\/svg\+xml/, label);
    assert.doesNotMatch(textPart.stdout.toString(), /filename=/, label);
    for (const [field, pattern] of [["font=@" + fontPath, /requires \[name=\]@path;type=/], ["font=abc", /requires \[name=\]@path;type=/]]) {
      const result = run(command, [...prefix, "run", "-i", svgPath, "-F", field, componentPath]);
      assert.notEqual(result.status, 0, label);
      assert.match(result.stderr.toString(), pattern, label);
    }
    const untyped = run(command, [...prefix, "run", "-i", svgPath, "-F", `font=@${fontPath};type=font/ttf`, "bytes/identity.wasm"]);
    assert.notEqual(untyped.status, 0, label);
    assert.match(untyped.stderr.toString(), /requires the first component to declare multipart\/related/, label);
    const old = run(command, [...prefix, "run", "--related", `font/ttf=@${fontPath}`, componentPath]);
    assert.notEqual(old.status, 0, `${label} accepted --related`);
  }
});

test("unnamed related part and stdin root work in every host", async (t) => {
  const { fontPath, componentPath } = await fixtures(t);
  for (const [label, command, prefix] of hosts) {
    const result = run(command, [...prefix, "run", "-i", "-", "-F", `@${fontPath};type=font/ttf`, componentPath], "<svg/>");
    assert.equal(result.status, 0, `${label}: ${result.stderr}`);
    assert.match(result.stdout.toString(), /Content-Type: font\/ttf/, label);
    const doubleStdin = run(command, [...prefix, "run", "-i", "-", "-F", "@-;type=font/ttf", componentPath], "<svg/>");
    assert.notEqual(doubleStdin.status, 0, label);
    assert.match(doubleStdin.stderr.toString(), /cannot both read stdin/, label);
  }
});

test("a boundary line at either edge of a root, part, or form field is rejected", async (t) => {
  const { svgPath, componentPath } = await fixtures(t);
  const directory = await mkdtemp(join(tmpdir(), "qip-related-boundary-"));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const bodies = [`--${boundary}\r\n<svg/>`, `--${boundary}`, `abc\r\n--${boundary}`, `abc\r\n--${boundary}--`];
  for (const [index, body] of bodies.entries()) {
    const badPath = join(directory, `bad-${index}.bin`);
    await writeFile(badPath, body);
    for (const [label, command, prefix] of hosts) {
      for (const args of [
        ["-i", badPath, "-F", `@${svgPath};type=image/svg+xml`, componentPath],
        ["-i", svgPath, "-F", `@${badPath};type=font/ttf`, componentPath],
        ["-F", `data=<${badPath}`, "bytes/identity.wasm"],
      ]) {
        const result = run(command, [...prefix, "run", ...args]);
        assert.notEqual(result.status, 0, `${label} ${JSON.stringify(body)} ${args.join(" ")}`);
        assert.match(result.stderr.toString(), /contains the multipart boundary/, label);
      }
    }
  }
});

test("an unnamed -F part without -i fails before reading input in every host", () => {
  for (const [label, command, prefix] of hosts) {
    const result = run(command, [...prefix, "run", "-F", "@missing.ttf;type=font/ttf", "bytes/identity.wasm"]);
    assert.notEqual(result.status, 0, label);
    assert.match(result.stderr.toString(), /-F \\?"@missing\.ttf;type=font\/ttf\\?" has no field name; only related parts with -i may omit it/, label);
  }
});

test("every host prints the same multipart help", () => {
  const section = (help) => {
    const start = help.indexOf("Multipart input:");
    assert.notEqual(start, -1, help);
    const examples = help.indexOf("Examples:\n", start);
    const end = help.indexOf("\n\n", examples);
    return help.slice(start, end === -1 ? undefined : end).trimEnd().replaceAll("qipx ", "qip ");
  };
  for (const [command, goArgs, qipxArgs] of [
    ["run", ["help", "run"], ["--help"]],
    ["bench", ["help", "bench"], ["bench", "--help"]],
    ["tui", ["help", "tui"], ["tui", "--help"]],
  ]) {
    const sections = hosts.map(([label, binary, prefix]) => {
      const result = run(binary, [...prefix, ...(label === "Go qip" ? goArgs : qipxArgs)]);
      assert.equal(result.status, 0, `${label} ${command}: ${result.stderr}`);
      return [label, section(result.stdout.toString())];
    });
    for (const [label, text] of sections.slice(1)) assert.equal(text, sections[0][1], `${label} ${command} help differs from Go qip`);
  }
});

test("dry run validates the related root type without reading part bytes", async (t) => {
  const { svgPath, componentPath } = await fixtures(t);
  const absent = join(tmpdir(), `qip-absent-font-${process.pid}.ttf`);
  for (const [label, command, prefix] of hosts) {
    const good = run(command, [...prefix, "dry", "run", "-i", svgPath, "-F", `font=@${absent};type=font/ttf`, componentPath]);
    assert.equal(good.status, 0, `${label}: ${good.stderr}`);
    assert.match(good.stdout.toString(), /Pipeline compatible/, label);
    const bad = run(command, [...prefix, "dry", "run", "-i", svgPath, "-F", `font=@${absent};type=font/ttf`, "bytes/identity.wasm"]);
    assert.notEqual(bad.status, 0, `${label} accepted an untyped first component`);
  }
});

test("hosts build related input with a nondefault declared UUID", async (t) => {
  const { svgPath, fontPath } = await fixtures(t);
  const directory = await mkdtemp(join(tmpdir(), "qip-related-uuid-"));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const componentPath = join(directory, "nondefault.wasm");
  const changed = Buffer.from(relatedSVGIdentity);
  const oldUUID = Buffer.from("uuid-00000000-0000-0000-0000-000000000000");
  const index = changed.indexOf(oldUUID);
  assert.ok(index >= 0);
  changed.set(Buffer.from("uuid-12345678-90ab-cdef-1234-567890abcdef"), index);
  await writeFile(componentPath, changed);
  for (const [label, command, prefix] of hosts) {
    const result = run(command, [...prefix, "run", "-i", svgPath, "-F", `@${fontPath};type=font/ttf`, componentPath]);
    assert.equal(result.status, 0, `${label}: ${result.stderr}`);
    assert.match(result.stdout.toString(), /--uuid-12345678-90ab-cdef-1234-567890abcdef/, label);
  }
});

test("related part Content-Type keeps canonical parameters", async (t) => {
  const { svgPath, fontPath, componentPath } = await fixtures(t);
  const partType = "image/ktx2;vkFormat=R8G8B8A8_SRGB;colorPrimaries=BT709;transferFunction=SRGB";
  for (const [label, command, prefix] of hosts) {
    const result = run(command, [...prefix, "run", "-i", svgPath, "-F", `data=@${fontPath};type=${partType}`, componentPath]);
    assert.equal(result.status, 0, `${label}: ${result.stderr}`);
    assert.ok(result.stdout.includes(Buffer.from(`Content-Type: ${partType}\r\n`)), label);
  }
});

test("TUI mode reserves stdin for terminal events with unnamed related parts", async (t) => {
  const { svgPath, componentPath } = await fixtures(t);
  for (const [label, command, prefix] of hosts) {
    const result = run(command, [...prefix, "tui", "-i", svgPath, "-F", "@-;type=font/ttf", componentPath]);
    assert.notEqual(result.status, 0, label);
    assert.match(result.stderr.toString(), /stdin carries terminal/, label);
  }
});

test("only one related resource may read stdin", async (t) => {
  const { svgPath, componentPath } = await fixtures(t);
  for (const [label, command, prefix] of hosts) {
    const result = run(command, [...prefix, "run", "-i", svgPath, "-F", "a=@-;type=font/ttf", "-F", "b=@-;type=font/ttf", componentPath], "font");
    assert.notEqual(result.status, 0, label);
    assert.match(result.stderr.toString(), /only one related -F part may read stdin/, label);
  }
});
