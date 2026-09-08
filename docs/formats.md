# Formats and Encodings

Choose a format for each boundary between components or systems. The format
must preserve the required data. It must also work with existing tools and
resource limits.

QIP uses stable, open formats with simple parsers. Stable formats improve
long-term compatibility. Open formats reduce vendor lock-in. Simple formats
help people and coding agents write correct implementations.

Many older formats were built for computers with little memory. These formats
often divide data into records, rows, or chunks. A program can process one unit
and then reuse its working memory. This avoids a complete object tree and a
separate allocation for each node.

Sequential processing can reduce peak memory and parser complexity. However,
older formats are not always more efficient. BMP is simple to decode, but BMP
files are large. TAR supports sequential access, but TAR does not compress
data. SQLite supports indexed queries, but SQLite needs random access to its
pages.

Before you select a format, answer these questions:

1. Which data and metadata must the boundary preserve?
2. Which formats do both systems support?
3. Does the operation need sequential access or random access?
4. Is the main constraint file size, CPU time, or working memory?

## Images

Use an uncompressed image inside a processing pipeline when components need
direct access to pixels. Use a compressed image at a storage, download, or
application boundary.

| Format | Use it for | Tradeoff |
| --- | --- | --- |
| `image/bmp` | A simple uncompressed raster boundary. | Parsing is simple, but files are large and row order can vary. |
| `image/svg+xml` | Editable or resolution-independent paths, diagrams, and text. | A raster consumer must render the SVG before processing pixels. |
| PNG | Lossless storage and broad interoperability. | Decoding needs more code and CPU time than BMP or QIP KTX2. |
| JPEG | Small photographs for systems that need lossy compression and broad support. | JPEG does not preserve alpha and changes pixel values. |
| WebP or AVIF | Compressed application and web boundaries. | Confirm that all target tools can decode the selected format. |
| JPEG 2000, GIF, or ICO | Interoperation with a system that requires that format. | Convert to a QIP working format after input enters the pipeline. |

QIP can convert PNG, JPEG, WebP, AVIF, JPEG 2000, and SVG to a working raster
format. QIP can write PNG, JPEG, WebP, AVIF, and ICO. QIP can also process GIF.

### Raster limits

Raster converters accept no more than 25,000,000 decoded pixels. Neither
dimension can be more than 8192 pixels. Compressed PNG, JPEG, JPEG 2000, and
WebP input also has a 64 MiB byte limit. Both limits apply. A small compressed
file is still invalid if its decoded image exceeds the pixel limit.

The ICO component writes one BMP-backed image. The image can be no larger than
256 by 256 pixels. See [Hard Limits](/docs/hard-limits) for host memory and
execution controls.

## QIP KTX2 profiles

KTX2 is QIP's canonical raster container between Content image components. GUI
components also use it for complete rendered frames. QIP supports a narrow,
uncompressed subset so components can address pixels directly.

QIP supports two payload layouts in a small subset of KTX2:

| Profile | Payload | Use |
| --- | --- | --- |
| RGBA8 sRGB | `VK_FORMAT_R8G8B8A8_SRGB`, 4 bytes per pixel | General 8-bit Content images. |
| RGBA32F | `VK_FORMAT_R32G32B32A32_SFLOAT`, 16 bytes per pixel | Linear BT.709, linear Display P3, or transfer-encoded Display P3 data. |

Each profile contains one uncompressed image. The profiles do not accept
compressed textures, mipmaps, arrays, or cubemaps. Keep linear float data
between operations that need it. Convert the final image when transfer size is
the main constraint. See the
[KTX2 component documentation](https://github.com/royalicing/qip/blob/main/components/image/ktx2/README.md)
for the complete profiles.

### Image container names and pixel format names

An image component name can identify a file container, a pixel layout, and a
color interpretation. For example, `bmp-b8g8r8a8-srgb` identifies a complete
BMP file. The pixels have four 8-bit channels in BGRA order. QIP interprets the
color channels as sRGB.

`B8G8R8A8_SRGB` identifies only a Vulkan pixel format. It does not identify a
complete file.

```text
bmp-b8g8r8a8-srgb             ktx2-r8g8b8a8-srgb
BMP container                 KTX2 container
BGRA, 8 bits per channel      VK_FORMAT_R8G8B8A8_SRGB
top-down or bottom-up    -->  top-down (`rd`), RGBA
```

The adapter changes the container and channel order. The adapter also reverses
bottom-up BMP rows. A float adapter converts 8-bit sRGB values to linear
32-bit float values.

The container prefix is part of the component contract.
`ktx2-r8g8b8a8-srgb` is a complete KTX2 file. `b8g8r8a8-srgb` identifies only
the pixels. It does not specify headers, dimensions, or row orientation.

The `-srgb` suffix states QIP's color interpretation. A standard BMP header
does not always identify sRGB. QIP treats an unprofiled BMP for this profile as
sRGB. Use `bmp-b8g8r8a8-icc-to-srgb` first when a BMP has a different
International Color Consortium (ICC) profile.

## Text, markup, and structured data

### Text and markup

QIP uses UTF-8 for all text pipelines.

| Format | Use it for | Tradeoff |
| --- | --- | --- |
| Plain UTF-8 text | Text that has no document structure. | The format cannot preserve structure that is not in the text itself. |
| `text/markdown` | Documents that people must read and edit. | Markdown has fewer document semantics than HTML. |
| `text/html` | Browser documents and structured document fragments. | A Document Object Model parser can allocate a large object tree. |
| `text/css` and `text/javascript` | Web source transformations. | Treat source text as code when it crosses a trust boundary. |
| `text/uri-list` | A sequence of resource identifiers. | The format carries a list, not resource metadata. |
| `text/vnd.mermaid` | Diagrams that must remain text. | A presentation system must render the diagram. |

The repository also uses registered `text/*` types for C, Swift, and Zig source
text. A streaming parser can process many text formats with bounded working
memory. A Document Object Model (DOM) parser allocates a tree instead.

### Structured data and databases

| Format | Use it for | Tradeoff |
| --- | --- | --- |
| `application/json` | Small structured messages and broad application interoperation. | Many JSON APIs allocate a complete value tree. |
| `application/xml` | Existing XML protocols, namespaces, or mixed text and elements. | XML has more syntax and processing rules than JSON. |
| `text/csv` | Flat records that consumers can process in sequence. | CSV loses nested structure and data types unless the application defines a schema. |
| `application/vnd.sqlite3` | Tables, indexes, transactions, and selective queries. | SQLite needs page access and a larger runtime than CSV. |

JSON and XML permit streaming parsers. Some APIs still build a complete tree
and increase peak memory. Check the parser API when working memory is limited.

SQLite can query a data set without loading the complete data set into memory.
Use SQLite when consumers need random access or relational operations. Do not
convert indexed or relational data to CSV when consumers still need those
features.

## Archives and forms

| Format | Use it for | Tradeoff |
| --- | --- | --- |
| `application/x-tar` | A file collection that a component reads or writes in order. | TAR does not include compression. |
| `application/zip` | A compressed archive for users and desktop tools. | Some ZIP operations must read the central directory at the end of the file. |
| `application/x-www-form-urlencoded` | Small named UTF-8 form fields. | The format is not suitable for file bodies. |
| `multipart/form-data` | Forms with files or separate metadata for each part. | Boundary parsing is more complex than URL-encoded form parsing. |

QIP uses TAR as the sequential archive inside pipelines and ZIP at external
boundaries. The ZIP-to-TAR component accepts bounded classic ZIP archives. It
supports stored and DEFLATE entries. It rejects ZIP64, encryption, split
archives, special file types, and unsafe extraction paths.

## WARC web snapshots

`application/warc` carries a complete routed site between whole-site
components. Each response record preserves its URI, status, headers, and body.
This lets one component check links across pages while another adds routes or
converts the finished site to a static TAR archive.

Use `qip router warc ...` to produce the archive. WARC is larger and less
widely supported than ZIP or TAR, so convert it at the boundary where another
system needs ordinary files.

## Documents and fonts

| Format | Use it for | Tradeoff |
| --- | --- | --- |
| `application/pdf` | Fixed page layout and vector artwork. | PDF is harder to edit than the source document or SVG. |
| `font/ttf` | SFNT fonts with TrueType `glyf` outlines. | Consumers need a font parser or an outline conversion step. |

QIP can extract text and images from PDF. QIP can also convert a strict SVG
subset to PDF/A-2b. Font components can convert TrueType outlines to SVG paths
or CSV data.

## WebAssembly components

`application/wasm` is both QIP's executable component format and a Content
format that other components can process. Components such as validators,
counters, translators, and instrumentation passes accept a Wasm module and
return facts, source code, or another module. This higher-level boundary lets a
component inspect or transform another component without adding that logic to
the host.

Wasm is executable input, not a general data format. Before you run an
untrusted module, apply the validation and execution policies in
[Hard Limits](/docs/hard-limits).

## Encodings and pipeline compatibility

A format defines file or container semantics. Examples include
`image/svg+xml`, `application/warc`, and `image/bmp`. An encoding defines the
representation of bytes or values in a processing stage.

QIP supports these processing encodings:

- UTF-8 for Content text through `input_utf8_cap` and `output_utf8_cap`.
- `RGBA32Float` for image filter tiles through `tile_rgba32float_64x64`.
- RGBA8 sRGB in canonical KTX2 for GUI component output. See
  [GUI Components](/docs/gui-components).

Valid UTF-8 is also valid raw byte input. Therefore, UTF-8 Content output can
feed a raw-byte Content input. Arbitrary raw bytes cannot feed a UTF-8 input
until the host validates the bytes.

RGBA32Float Tile data is not a subtype of Content bytes. The host uses the
image bridge to cross this boundary. The host decodes Content image bytes to
tiles before a contiguous Tile group. The host encodes the tiles as Content
image bytes after the Tile group.

## Validation and trade-offs

### Validate data at an untrusted boundary

A content type is a component precondition or guarantee. An `image/png`
component can rely on its documented PNG profile. It does not have to repeat
complete validation before processing starts.

A file extension or an HTTP `Content-Type` value does not prove that the bytes
are valid. Validate untrusted data before another component relies on the
format:

```text
untrusted bytes -> validate PNG -> valid image/png -> transform PNG
```

A pass-through validator can reject malformed data and return accepted bytes
as `image/png`. A recipe must not infer validation from a claimed content type.

### When not to use these formats

Use an application-specific format when the formats on this page cannot
preserve the required semantics. Keep a simple format between QIP components,
and add an adapter at system ingress or egress.

Do not use an uncompressed working format for downloads when transfer size is
the main constraint. Do not use QIP's narrow KTX2 profiles when another system
needs general KTX2 features such as compressed textures or mipmaps. Do not
replace a normal application database or object model only to use a QIP
pipeline.
