# Unique Accessible Name Validator

`html-accessible-name-unique-validator.wasm` computes the accessible names of
exposed interactive HTML controls and traps when the same non-empty name occurs
more than once. Links must be unique within their nearest `nav` or
`role="navigation"` landmark, but may repeat in separate navigation landmarks
or ordinary document content. Native `h2` headings must have unique accessible
names across the page. Other structural and document roles are excluded because
repeated names are normal in nested headings and tables. On success it returns
the input unchanged and returns the input buffer address in the render result.

The calculation is shared with `html-to-accessibility-tree.wasm`. It follows
the Accessible Name and Description Computation precedence for
`aria-labelledby`, `aria-label`, native HTML labels and text alternatives,
name-from-content roles, and `title`. It handles native sources including
`label`, `alt`, input values and defaults, `legend`, `caption`, and
`placeholder`, and excludes `hidden` and `aria-hidden="true"` subtrees unless
their text is reached through a naming reference.

```bash
printf '%s' '<button>Save</button><button>Cancel</button>' \
  | qip run text/html/html-accessible-name-unique-validator.wasm
```

This stricter project policy is not an ARIA conformance requirement. Repeated
names can be valid when surrounding context distinguishes controls. The
validator deliberately rejects them for interactive control roles such as
buttons, textboxes, checkboxes, menu items, tabs, and sliders. Link comparison
uses the nearest navigation landmark as its scope; document structure remains
contextual except for the page-wide `h2` check.

The component does not execute CSS or JavaScript. CSS-generated text and
computed-style hiding therefore require a browser-level accessibility test;
static `hidden` and `aria-hidden` markup is handled directly. ID matching for
`aria-labelledby` uses literal UTF-8 attribute bytes rather than normalizing
character references.
