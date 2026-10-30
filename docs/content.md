# Content

This document defines the on-disk content layout consumed by routing/build workflows.

## Root

- Content root directory is provided by the host (for example `qip router dev -C ./docs`).
- Every regular file under the root is eligible input.
- File key is its relative path from the chosen root using `/` separators.

Examples:

- `<root>/index.html` -> `index.html`
- `<root>/blog/post-1/index.html` -> `blog/post-1/index.html`
- `<root>/images/logo.png` -> `images/logo.png`

## Path Rules

- Relative file keys must be UTF-8.
- `.` and `..` path segments are invalid.
- Paths beginning with `/` are invalid.
- Backslash `\` is invalid.

## Hashing

- Host computes content digest as SHA-256 of raw file bytes.
- Routing/build input tuple is:
  - `file_path_bytes | content_sha256_bytes(32)`

## Scope

- This contract does not define routing policy.
- Routing/build policy is handled by host logic and runtime router modules.
- Recipe discovery/order is defined in `docs/recipes.md`.
