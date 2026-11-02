// JSON-Schema-Test-Suite, draft 2020-12 core tests (no optional/), limited to
// the groups whose regexes stay within the interoperable subset of JSON Schema
// 2020-12 core section 6.4: single characters, [abc], [a-z] and [^...]
// classes, + * ? {x} {x,y} {x,} and their lazy forms, ^ and $, (...) and |.
// Like Understanding JSON Schema, it also allows "." and a backslash before a
// syntax character (\. \* \\ ...). No other escapes: no \d \w \s \b \p{...}.
// This is the full suite for a validator that rejects
// every other regex at compile time, such as a future
// json-schema-strict-to-wasm.
//
// The cases come from json-schema-2020-12-interoperable-regex.fixtures.txt,
// which tools/gen-json-schema-2020-12-fixtures.mjs writes alongside the full
// fixture and documents the subset rules in. The envelope and the pass rules
// are in lib/json-schema-2020-12-comply.zig.
const runner = @import("lib/json-schema-2020-12-comply.zig");

export fn comply() i32 {
    return runner.run(@embedFile("json-schema-2020-12-interoperable-regex.fixtures.txt"));
}
