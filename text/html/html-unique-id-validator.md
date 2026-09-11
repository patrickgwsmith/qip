# Unique HTML ID Validator

`html-unique-id-validator.wasm` accepts a UTF-8 `text/html` document and traps
when two `id` attributes resolve to the same value. ID comparison is
case-sensitive, while the attribute name is ASCII case-insensitive as required
by HTML. The validator recognizes quoted, unquoted, and empty attribute values,
and compares numeric character references and the common named references
`amp`, `apos`, `gt`, `lt`, `nbsp`, and `quot` by their decoded values.

On success, `render` returns the input address and byte length. The address is
the same as `input_ptr()`. The bytes are not copied or modified. After a trap
there is no output; a host must not read the input
buffer as though validation succeeded.

```bash
printf '%s' '<main id="content"><p id="intro">Hello</p></main>' \
  | qip run text/html/html-unique-id-validator.wasm
```

This input traps because `content` occurs twice:

```html
<main id="content"><aside id="content"></aside></main>
```

The component is a focused assertion gate, not a full HTML conformance checker.
It skips comments and the contents of raw-text elements such as `script` and
`style`, and traps on unterminated tags, comments, or quoted attributes when it
cannot safely finish scanning the document.
