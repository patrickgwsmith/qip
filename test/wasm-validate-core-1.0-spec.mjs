import { runCoreSpecSuite } from "./lib/wasm-core-spec-suite.mjs";

await runCoreSpecSuite({
  version: "1.0",
  expectedSpecCommit: "977f97014c962f7bd1291fcc6d28b41a924882bf",
  minimumScriptCount: 73,
  specRoot: process.argv[2] ?? process.env.WASM_CORE_1_0_SPEC_DIR,
  validatorUrl: new URL(
    "../components/application/wasm/wasm-validate-core-1.0.wasm",
    import.meta.url,
  ),
  // These flags also select the historical element-segment text grammar. In
  // current WABT, the first identifier otherwise names the segment instead of
  // selecting its table.
  wast2jsonArgs: [
    "--disable-sign-extension",
    "--disable-simd",
    "--disable-multi-value",
    "--disable-bulk-memory",
    "--disable-reference-types",
  ],
  filterOnParseFailure: true,
});
