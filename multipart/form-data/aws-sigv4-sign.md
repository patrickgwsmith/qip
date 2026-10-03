# AWS SigV4 sign

`aws-sigv4-sign.wasm` signs one HTTP request with AWS Signature Version 4 and
outputs the `text/plain` header lines to add to it. It never makes the request.

Input is `multipart/form-data` with the same writable UUID boundary slot as
`form-data-to-tar.wasm`. Fields:

| Field | Required | Notes |
| --- | --- | --- |
| `method` | yes | Uppercase, e.g. `GET` |
| `url` | yes | `https://` or `http://`; path and query already percent-encoded |
| `region` | yes | e.g. `us-east-1` |
| `service` | yes | e.g. `s3` |
| `access_key_id` | yes | |
| `secret_access_key` | yes | Never written to the output |
| `session_token` | no | Adds and signs `X-Amz-Security-Token` |
| `body` | no | Hashed for `X-Amz-Content-Sha256`; empty if omitted |
| `payload_sha256` | no | Lowercase hex or `UNSIGNED-PAYLOAD`, instead of `body` |

The signing time comes from the `timestamp` uniform in Unix seconds. A
component can't read the clock, so the same input always gives the same
signature. The component rejects the input if `timestamp` is unset; AWS
rejects signatures more than about 15 minutes from its clock.

It signs `host`, `x-amz-date` and, with a session token,
`x-amz-security-token`. For S3 (`s3` and `s3-*` services), or whenever
`payload_sha256` is given, it also outputs and signs `X-Amz-Content-Sha256`.
Other services only fold the payload hash into the signature, as the AWS SDKs
do.

The URL is canonicalized the way AWS checks it:

- The host is lowercased and a default port (`:443` for `https`, `:80` for
  `http`) is dropped, matching the `Host` header clients send.
- Percent-escapes are normalized to uppercase hex, and escaped unreserved
  characters are decoded. `+` is a literal plus; encode spaces as `%20`.
- S3 signs the path otherwise as given. Other services drop empty, `.` and
  `..` segments, then sign the path percent-encoded a second time.
- Query parameters are re-encoded the same way and sorted by key, then value.

Missing, empty, malformed, unknown or duplicate fields, and malformed escapes
or ports, are rejected as ordinary failures; it only traps if the input exceeds
its capacity.

Tests check it against the AWS S3 documentation examples and the AWS SigV4 test
suite (`get-vanilla`, the path normalization and query ordering cases).

```sh
make multipart/form-data/aws-sigv4-sign.wasm
qip run \
  -F method=GET \
  -F url='https://examplebucket.s3.amazonaws.com/?lifecycle' \
  -F region=us-east-1 -F service=s3 \
  -F access_key_id=AKIAIOSFODNN7EXAMPLE \
  -F secret_access_key=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY \
  multipart/form-data/aws-sigv4-sign.wasm -u timestamp=1369353600
```

```text
X-Amz-Date: 20130524T000000Z
X-Amz-Content-Sha256: e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
Authorization: AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature=fea454ca298b7da1c68078a5d1bdbfbbe0d65c699e0f91ac7a200a0136783543
```

Not supported yet: presigned URLs, signing extra headers, and inferring
`region`/`service` from the host.
