import { runCoreSpecSuite } from "./lib/wasm-core-spec-suite.mjs";

await runCoreSpecSuite({
  version: "2.0",
  expectedSpecCommit: "fffc6e12fa454e475455a7b58d3b5dc343980c10",
  minimumScriptCount: 148,
  specRoot: process.argv[2] ?? process.env.WASM_CORE_2_0_SPEC_DIR,
  validatorUrl: new URL(
    "../components/application/wasm/wasm-validate-core-2.0.wasm",
    import.meta.url,
  ),
});

