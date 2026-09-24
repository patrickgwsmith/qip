#!/usr/bin/env node

import { realpathSync } from "node:fs";
import { readFile, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";

import { __cliInternals as qipx } from "./qipx.mjs";

function stageWithDimensions(stage, dimensions) {
  const uniforms = [...(stage.uniforms ?? [])];
  const explicit = new Set(uniforms.map(([key]) => key));
  for (const [key, value] of [["columns", dimensions.columns], ["lines", dimensions.lines]]) {
    if (!explicit.has(key) && typeof stage.component.exports[`uniform_set_${key}`] === "function") {
      uniforms.push([key, value]);
    }
  }
  return { ...stage, uniforms };
}

async function tuiCommand(argv, hosts) {
  const { options, pipeline } = await qipx.prepareRunPipeline(argv, hosts);
  if (options.output !== "-") throw new Error("qipx tui writes only to terminal stdout; remove -o/--output");
  if (options.inputFromCLI && options.input === "-") throw new Error("qipx tui cannot read -i - because stdin carries terminal events");
  for (const value of options.formValues) {
    if (qipx.parseFormAssignment(value).filePath === "-") {
      throw new Error("qipx tui cannot use -F name=@- or name=<- because stdin carries terminal events");
    }
  }

  let input = new Uint8Array();
  let inputContentType = "";
  if (options.formValues.length > 0) {
    const form = await qipx.buildMultipartFormInput(options.formValues, { hosts });
    input = form.bytes;
    inputContentType = form.contentType;
  } else if (options.inputFromCLI) {
    input = await readFile(options.input);
  }

  const first = pipeline.stages[0];
  const effectiveInputType = qipx.resolveStageInputType(first, inputContentType, true);
  const primaryOutputContentType = qipx.nextContentType(first, effectiveInputType);
  const applyTUIUniforms = (stage, dimensions) => qipx.applyUniforms(stageWithDimensions(stage, dimensions));
  const transformOutput = (primaryBytes, dimensions) => {
    let output = primaryBytes;
    let currentType = primaryOutputContentType;
    for (let index = 1; index < pipeline.stages.length; index += 1) {
      const stage = stageWithDimensions(pipeline.stages[index], dimensions);
      const effectiveType = qipx.resolveStageInputType(stage, currentType, false);
      output = qipx.runStage(stage, output);
      currentType = qipx.nextContentType(stage, effectiveType);
    }
    const last = pipeline.stages.at(-1);
    return { bytes: output, encoding: last.outputType.encoding, contentType: currentType };
  };
  const { runTUI } = await import("./qipx-tui.mjs");
  await runTUI({ pipeline, input, applyUniforms: applyTUIUniforms, transformOutput });
}

export async function main(argv = process.argv.slice(2)) {
  if (argv.length === 0 || argv[0] === "--help" || argv[0] === "-h" || argv[0] === "help") {
    console.log(qipx.usage());
    return;
  }
  const invocation = qipx.parseInvocation(argv);
  if (invocation.command === "tui" && (invocation.args[0] === "--help" || invocation.args[0] === "-h")) {
    console.log(qipx.tuiUsage());
    return;
  }
  if ((invocation.command === "run" || invocation.command === "dry-run") && (invocation.args[0] === "--help" || invocation.args[0] === "-h")) {
    console.log(qipx.usage());
    return;
  }
  if (invocation.command === "comply") {
    await qipx.complyCommand(invocation.args, invocation.hosts);
    return;
  }
  if (invocation.command === "bench") {
    await qipx.benchCommand(invocation.args, invocation.hosts);
    return;
  }
  if (invocation.command === "dry-run") {
    await qipx.dryRunCommand(invocation.args, invocation.hosts);
    return;
  }
  if (invocation.command === "tui") {
    await tuiCommand(invocation.args, invocation.hosts);
    return;
  }

  const { options, pipeline } = await qipx.prepareRunPipeline(invocation.args, invocation.hosts);
  const firstStageIsGenerator = pipeline.stages[0]?.inputless;
  let input;
  let inputContentType = "";
  if (options.formValues.length > 0) {
    const form = await qipx.buildMultipartFormInput(options.formValues, { hosts: invocation.hosts });
    input = form.bytes;
    inputContentType = form.contentType;
  } else {
    input = firstStageIsGenerator && options.input === "-" && !options.inputFromCLI && process.stdin.isTTY
      ? new Uint8Array()
      : (options.input === "-" ? await qipx.readStdin() : await readFile(options.input));
  }
  const result = qipx.runPreparedPipeline(input, pipeline, inputContentType);
  if (options.output === "-") {
    process.stdout.write(result.outputBytes);
    if (result.outputType.encoding === "utf8") process.stdout.write("\n");
  } else {
    await writeFile(options.output, result.outputBytes);
  }
}

const invokedPath = process.argv[1] ? realpathSync(process.argv[1]) : "";
const modulePath = realpathSync(fileURLToPath(import.meta.url));
if (invokedPath === modulePath) {
  main().catch((error) => {
    console.error(error.message ?? error);
    process.exitCode = 1;
  });
}
