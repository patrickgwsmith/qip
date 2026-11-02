The draft 2020-12 meta-schema and its vocabulary meta-schemas, as published at
`https://json-schema.org/draft/2020-12/schema` and
`https://json-schema.org/draft/2020-12/meta/*` (BSD 3-Clause, `LICENSE`).
`json-schema-2020-12-must-be-valid.zig` embeds them so `$schema` and `$ref`
to these URIs resolve without fetching.
