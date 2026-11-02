// JSON-Schema-Test-Suite, draft 2020-12 core tests (no optional/), as a
// Compliance oracle for validators that take the JSON envelope of
// application/json/json-schema-2020-12-must-be-valid.wasm.
//
// The cases come from json-schema-2020-12.fixtures.txt, flattened from the
// vendored suite in json-schema-test-suite/ by
// tools/gen-json-schema-2020-12-fixtures.mjs. The envelope and the pass rules
// are in lib/json-schema-2020-12-comply.zig.
const runner = @import("lib/json-schema-2020-12-comply.zig");

export fn comply() i32 {
    return runner.run(@embedFile("json-schema-2020-12.fixtures.txt"));
}
