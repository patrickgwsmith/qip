# DNS messages

Two components convert between DNS questions in text and the RFC 1035 wire
format, which RFC 8484 DNS over HTTPS (DoH) sends as `application/dns-message`.

- `dns-query-to-dns-message.wasm` reads one question and writes a query
  message.
- `dns-message-to-text.wasm` reads a query or response and writes the text
  layout that `dig` prints.

Use them with `curl` to make a DoH request without base64 or `hexdump`:

```bash
printf 'cloudflare.com HTTPS' |
  qip run application/dns-message/dns-query-to-dns-message.wasm -u dnssec_ok=1 |
  curl -s --header 'content-type: application/dns-message' \
    --data-binary @- https://cloudflare-dns.com/dns-query |
  qip run application/dns-message/dns-message-to-text.wasm
```

The output has the header, the EDNS options, and each section, with one record
per line in master-file presentation format:

```text
;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 0
;; flags: qr rd ra ad; QUERY: 1, ANSWER: 2, AUTHORITY: 0, ADDITIONAL: 1

;; OPT PSEUDOSECTION:
; EDNS: version: 0, flags: do; udp: 1232

;; QUESTION SECTION:
;cloudflare.com.	IN	HTTPS

;; ANSWER SECTION:
cloudflare.com.	300	IN	HTTPS	1 . alpn="h3,h2" ipv4hint=104.16.132.229,104.16.133.229 ipv6hint=2606:4700::6810:84e5,2606:4700::6810:85e5
cloudflare.com.	300	IN	RRSIG	HTTPS 13 2 300 20261014024729 20261012004729 34505 cloudflare.com. 8Zqz…
```

## Question text

The encoder accepts the RFC 1035 master-file order, `www.example.com. IN A`.
The class and the type can come in either order after the name. The class
defaults to `IN` and the type defaults to `A`, so the `dig` argument order
`www.example.com AAAA` also works. The trailing dot is optional because every
name is absolute. Mnemonics are not case sensitive. `TYPE65` and `CLASS3` select
any code, as in RFC 3597. Names accept the `\.` and `\DDD` escapes.

The input is one line. The encoder rejects an empty label, a label longer than
63 bytes, a name longer than 255 wire bytes, an unknown mnemonic, a repeated
class or type, and any text after the line break. The failure gives the byte
offset of the rejected token or byte.

The encoder has these uniforms:

- `id`: the 16-bit message ID. The default is 0, which RFC 8484 recommends so
  that HTTP caches can share responses. Values above 65535 clamp to 65535.
- `recursion_desired`: 1 sets the RD flag, and 0 clears it. The default is 1.
- `dnssec_ok`: 1 adds an OPT record with the DO flag and a 1232-byte UDP size,
  which asks the server to include DNSSEC records. The default is 0, which sends
  no OPT record.

## Decoded records

The decoder has type-specific RDATA text for A, AAAA, NS, CNAME, PTR, DNAME,
MX, AFSDB, KX, SOA, RP, TXT, SPF, HINFO, SRV, NAPTR, DS, CDS, DNSKEY, CDNSKEY,
RRSIG, NSEC, NSEC3, NSEC3PARAM, TLSA, SMIMEA, SSHFP, OPENPGPKEY, ZONEMD, SVCB,
HTTPS, URI, and CAA. Other types use the RFC 3597 form, such as `\# 2 DEAD`.
SVCB and HTTPS parameters use the RFC 9460 names, such as `alpn`, `ipv4hint`,
`ech`, and `ipv6hint`.

The OPT record is shown before the question as `OPT PSEUDOSECTION`. Its
extended RCODE is included in `status`, so a server that sends BADVERS shows
`status: BADVERS`. The decoder names the NSID, CLIENT-SUBNET, COOKIE,
TCP-KEEPALIVE, PADDING, and Extended DNS Error (EDE) options. Other options are
shown in hexadecimal. An EDE line includes the RFC 8914 description and the
server text, for example `; EDE: 9 (DNSKEY Missing): "no SEP matching the DS
found for dnssec-failed.org."`.

Bytes outside printable ASCII print as `\DDD`, so the output is always ASCII.

## Limits on hostile input

A DNS response comes from the network, so the decoder treats every field as
untrusted. Compressed names are the main risk: a name can end with a pointer
to an earlier name, and a bad message can make those pointers loop. The decoder
uses three limits:

- A compression pointer must point to a byte before the pointer itself.
- A name has at most 255 wire bytes.
- One name follows at most 255 labels and pointers.

These limits stop every pointer loop. The decoder also rejects truncated
fields, RDATA that does not match its type or does not use its full length, an
OPT record outside the additional section, a second OPT record, and bytes after
the last record. The failure gives the byte offset of the rejected field.

Both components pass `wasm-strict-profile.wasm`, `wasm-bounded-loops.wasm`, and
`wasm-nontrapping-divides.wasm`. `test/dns-message.mjs` checks every truncation
of a sample response and 20,000 random corruptions, and none of them trap.

The decoder input is limited to 65,535 bytes, the largest DNS message over TCP
or HTTPS. Its output capacity is about 32 MiB because one 2-byte pointer can
expand to a 1,013-byte escaped name. The module reserves that memory when it
starts.

## When not to use these components

The components do not send or receive network traffic. Use `curl`, `kdig`, or
an HTTP client to make the request. They do not validate DNSSEC signatures, so
`ad` in the output only repeats the flag that the resolver set. The decoder does
not print JSON. For a resolver library, use a DNS library in your application
instead.
