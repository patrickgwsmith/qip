# JSON-Schema-Test-Suite (vendored subset)

From <https://github.com/json-schema-org/JSON-Schema-Test-Suite> at commit
`3f05891cac5d51ffa068d7076d1372130e00c829` (2026-10-31), under the MIT
license in `LICENSE`.

Only what the draft 2020-12 core tests need is kept:

- `tests/draft2020-12/*.json`: the core tests, without `optional/`
  (1,298 tests in 384 groups).
- `remotes/draft2020-12/`: documents the tests reference as
  `http://localhost:1234/draft2020-12/...`.

`tools/gen-json-schema-2020-12-fixtures.mjs` flattens these into
`compliance/json-schema-2020-12.fixtures.txt`, which
`compliance/json-schema-2020-12.comply.wasm` embeds. To update, replace these
folders from a newer checkout, rerun the generator, and rebuild the oracle.
