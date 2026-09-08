import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { mkdir, mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { basename, dirname, join, relative } from "node:path";
import { promisify } from "node:util";

import { ContentComponentHost } from "./content-component-host.mjs";

const execFileP = promisify(execFile);

async function pathsBelow(path) {
  const entries = await readdir(path, { withFileTypes: true });
  const paths = [];
  for (const entry of entries) {
    const child = join(path, entry.name);
    if (entry.isDirectory()) paths.push(...(await pathsBelow(child)));
    else paths.push(child);
  }
  return paths;
}

function topLevelForms(source) {
  const forms = [];
  let start = -1;
  let depth = 0;
  let blockCommentDepth = 0;
  let inLineComment = false;
  let inString = false;

  for (let index = 0; index < source.length; index += 1) {
    const char = source[index];
    const next = source[index + 1];
    if (inLineComment) {
      if (char === "\n") inLineComment = false;
      continue;
    }
    if (blockCommentDepth > 0) {
      if (char === "(" && next === ";") {
        blockCommentDepth += 1;
        index += 1;
      } else if (char === ";" && next === ")") {
        blockCommentDepth -= 1;
        index += 1;
      }
      continue;
    }
    if (inString) {
      if (char === "\\") index += 1;
      else if (char === '"') inString = false;
      continue;
    }
    if (char === ";" && next === ";") {
      inLineComment = true;
      index += 1;
    } else if (char === "(" && next === ";") {
      blockCommentDepth = 1;
      index += 1;
    } else if (char === '"') {
      inString = true;
    } else if (char === "(") {
      if (depth === 0) start = index;
      depth += 1;
    } else if (char === ")" && depth > 0) {
      depth -= 1;
      if (depth === 0) forms.push(source.slice(start, index + 1));
    }
  }
  return forms;
}

export function validationForms(source) {
  return topLevelForms(source).filter((form) => {
    const head = /^\(\s*([^\s()]+)/.exec(form)?.[1];
    if (
      head === "module" ||
      head === "assert_invalid" ||
      head === "assert_malformed" ||
      head === "assert_unlinkable" ||
      head === "assert_uninstantiable"
    ) {
      return true;
    }
    return head === "assert_trap" && /^\(\s*assert_trap\s+\(\s*module\b/.test(form);
  });
}

export async function runCoreSpecSuite({
  version,
  expectedSpecCommit,
  minimumScriptCount,
  specRoot,
  validatorUrl,
  wast2jsonArgs = [],
  filterOnParseFailure = false,
}) {
  if (!specRoot) {
    throw new Error(
      `pass the WebAssembly spec wg-${version} checkout path or set WASM_CORE_${version.replace(".", "_")}_SPEC_DIR`,
    );
  }

  const coreDir = join(specRoot, "test", "core");
  const validatorBytes = await readFile(validatorUrl);
  const host = new ContentComponentHost(validatorBytes, {
    label: `WebAssembly Core ${version} validator`,
  });

  try {
    const { stdout } = await execFileP("git", ["-C", specRoot, "rev-parse", "HEAD"]);
    assert.equal(
      stdout.trim(),
      expectedSpecCommit,
      `the acceptance suite must use the pinned wg-${version} specification commit`,
    );
  } catch (error) {
    // Release archives have no .git directory. Their directory name must still
    // identify the pinned tag; the test inputs themselves remain authoritative.
    if (!basename(specRoot).includes(`wg-${version}`)) throw error;
  }

  const wastFiles = (await pathsBelow(coreDir))
    .filter((path) => path.endsWith(".wast"))
    .sort();
  assert.ok(
    wastFiles.length >= minimumScriptCount,
    `the complete Core ${version} suite was not found`,
  );

  const temp = await mkdtemp(join(tmpdir(), `qip-wasm-core-${version}-spec-`));
  const mismatches = [];
  let accepted = 0;
  let rejected = 0;
  let textMalformed = 0;
  let compatibilityFiltered = 0;

  try {
    for (const [index, wast] of wastFiles.entries()) {
      const stem = `${String(index).padStart(3, "0")}-${basename(wast, ".wast")}`;
      const outputDir = join(temp, stem);
      const jsonPath = join(outputDir, `${stem}.json`);
      const filteredWast = join(outputDir, `${stem}.wast`);
      await mkdir(outputDir);
      try {
        await execFileP("wast2json", [...wast2jsonArgs, wast, "-o", jsonPath]);
      } catch (error) {
        if (!filterOnParseFailure) throw error;
        // Core 1.0 uses execution-assertion spellings that current WABT no
        // longer accepts. Keep every module-bearing form and remove only those
        // unrelated execution assertions before retrying the conversion.
        const forms = validationForms(await readFile(wast, "utf8"));
        await writeFile(filteredWast, `${forms.join("\n")}\n`);
        await execFileP("wast2json", [...wast2jsonArgs, filteredWast, "-o", jsonPath]);
        compatibilityFiltered += 1;
      }
      const script = JSON.parse(await readFile(jsonPath, "utf8"));

      for (const command of script.commands) {
        if (!command.filename) continue;
        if (command.module_type === "text") {
          if (command.type === "assert_malformed") textMalformed += 1;
          continue;
        }

        const expected = new Map([
          ["module", true],
          ["assert_unlinkable", true],
          ["assert_uninstantiable", true],
          ["assert_trap", true],
          ["assert_invalid", false],
          ["assert_malformed", false],
        ]).get(command.type);
        if (expected === undefined) continue;

        const bytes = await readFile(join(dirname(jsonPath), command.filename));
        let actual;
        try {
          actual = host.run(bytes).status === "accepted";
        } catch (error) {
          mismatches.push(
            `${relative(coreDir, wast)}:${command.line} trapped: ${error.message}`,
          );
          continue;
        }
        if (actual) accepted += 1;
        else rejected += 1;
        if (actual !== expected) {
          mismatches.push(
            `${relative(coreDir, wast)}:${command.line} ${command.type}: expected ${expected ? "accept" : "reject"}`,
          );
        }
      }
    }
  } finally {
    await rm(temp, { recursive: true, force: true });
  }

  assert.deepEqual(mismatches, []);
  console.log(
    `Core ${version} specification: ${wastFiles.length} scripts, ${accepted} accepted binaries, ${rejected} rejected binaries, ${textMalformed} text-only malformed cases skipped, ${compatibilityFiltered} scripts filtered for WABT syntax compatibility`,
  );
}
