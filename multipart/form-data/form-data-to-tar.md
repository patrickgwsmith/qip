# Multipart form data to TAR

`form-data-to-tar.wasm` converts a bounded `multipart/form-data` body into a
deterministic POSIX ustar archive. Each part becomes a regular file. Its
`Content-Disposition` `name` parameter is the archive path; `filename` is
metadata and does not change that path.

The input declaration contains the contract's writable UUID boundary slot:

```text
multipart/form-data;boundary=uuid-00000000-0000-0000-0000-000000000000
```

A host may replace the 36 UUID bytes in place before calling `render`. The body
must use that live boundary value.

The component accepts `Content-Disposition` and optional `Content-Type` headers.
It rejects transfer encodings, unknown or folded headers, duplicate names,
absolute and traversal paths, more than 256 parts, and names longer than the
ustar name field's 100 bytes. Quoted parameter escapes are not decoded.
Bodies use CRLF framing with no preamble or epilogue.

TAR entries use mode `0644`, uid/gid `0`, timestamp `0`, and input order. The
component does not infer filenames, create directories, or interpret part
content.

```sh
make multipart/form-data/form-data-to-tar.wasm
qip run multipart/form-data/form-data-to-tar.wasm < body.multipart > files.tar
```
