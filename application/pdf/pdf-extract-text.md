# PDF text extraction

`pdf-extract-text.wasm` turns a born-digital PDF into readable UTF-8 plain
text. It interprets the page content streams instead of concatenating PDF
string objects: text is decoded through the page's fonts, placed using the
text and graphics matrices, grouped into visual lines, and separated into
pages with form feed (`U+000C`). It also suppresses overlapping duplicate
glyphs commonly used to simulate bold text.

The extractor supports ordinary unencrypted PDFs with unpacked page, font,
and content-stream objects. Content streams may be unfiltered or use
`FlateDecode`, `ASCII85Decode`, `ASCIIHexDecode`, or an ASCII filter followed
by `FlateDecode`. Simple fonts use WinAnsi decoding; composite fonts need a
`ToUnicode` map. The CMap parser handles the common `bfchar` and sequential
`bfrange` forms.

```sh
./qip run -i document.pdf -o document.txt -- \
  application/pdf/pdf-extract-text.wasm
```

This is deliberately a useful baseline rather than a full PDF layout engine.
It does not perform OCR, infer tables, identify headings, expand compressed
object streams, decrypt files, or perfectly reconstruct columns and reading
order. Unsupported content-stream filters are skipped, so a partially
supported document can still yield text from its other pages or streams.

The fixed Wasm memory allows a 64 MiB input, 32 MiB output, and up to 500,000
positioned glyphs per page. Use a mature PDF library when exact layout,
tagged-PDF structure, forms, annotations, or archival-grade fidelity is part
of the contract.
