# HTML ID Reference Validator

`html-id-reference-validator.wasm` accepts a UTF-8 `text/html` document and
traps when a same-document ID reference does not resolve. On success it returns
the input unchanged from the same address: the returned output pointer equals
`input_ptr()`.

The validator checks HTML references in `for`, `headers`, `form`, `list`,
`itemref`, `popovertarget`, and `commandfor`; WAI-ARIA ID references in
`aria-activedescendant`, `aria-controls`, `aria-describedby`, `aria-details`,
`aria-errormessage`, `aria-flowto`, `aria-labelledby`, and `aria-owns`; and
same-document `href` and `xlink:href` fragments beginning with `#`.

Target types are checked where HTML defines one. For example, `label[for]` must
identify a labelable control, `input[list]` must identify a `datalist`, and
`popovertarget` must identify an element with a `popover` attribute.

```bash
printf '%s' '<label for="email">Email</label><input id="email">' \
  | qip run text/html/html-id-reference-validator.wasm
```

Use `html-unique-id-validator.wasm` before this component. ARIA specifies that
browsers use the first element when duplicate IDs exist; requiring uniqueness
first avoids silently binding a relation to the wrong target.

This component validates references whose targets can be determined from one
HTML document. It does not fetch external URLs, execute custom-element code to
discover form association, or resolve fragments in another response. ID and
reference values are compared as literal UTF-8 attribute bytes; character
references and percent-encoded URL fragments are not normalized. Run the WARC
broken-link validators for whole-site resource checks.
