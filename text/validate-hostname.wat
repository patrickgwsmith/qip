;; Accepts an RFC 1123 host name unchanged and rejects anything else.
;;
;; RFC 1123 section 2.1 keeps the RFC 952 label syntax but lets a label start
;; with a digit. A host name is one or more dot-separated labels. Each label is
;; 1 to 63 ASCII letters, digits, or hyphens, and does not start or end with a
;; hyphen. The whole name is at most 253 characters, which is the longest name
;; that fits the 255-octet DNS wire limit. Letters are case-insensitive, so
;; both cases are accepted. A trailing root dot is rejected.
;;
;; The rejection offset is the first byte that no valid host name can continue
;; through, or the input length when the input ends too early. For inputs of
;; up to 252 bytes these are the same offsets as the module `i-regexp-to-wasm`
;; compiles from the hostname pattern on site/regex.md. For example `a-.b`
;; rejects at 2 (the dot), because a label cannot end with a hyphen.
;;
;; The loop reads at most 253 bytes, whatever the input size. Its counter only
;; increases and the result epilogue traps above the output cap, so the module
;; passes wasm-bounded-loops and wasm-bounded-output.
(module $ValidateHostname
  ;; 4 MiB of input at address 0, the same input cap as i-regexp-to-wasm output.
  (memory (export "memory") 64 64)
  (func (export "input_ptr") (result i32) (i32.const 0))
  (func (export "input_utf8_cap") (result i32) (i32.const 0x400000))
  ;; Accepted output is the input itself.
  (func (export "output_utf8_cap") (result i32) (i32.const 0x400000))
  (func (export "failure_modes_per_input_offset") (result i32) (i32.const 1))

  (func (export "render") (param $n i32) (result i64)
    (local $i i32)      ;; byte index
    (local $len i32)    ;; chars in the current label
    (local $hyphen i32) ;; 1 when the last char was a hyphen
    (local $byte i32)
    (local $scan i32)   ;; min(n, 253)
    (local $size i32)   ;; output size, or the rejection offset
    (local $high i32)   ;; output pointer, or the failure bit

    ;; A host that exceeds the input cap violates the contract.
    (if (i32.gt_u (local.get $n) (i32.const 0x400000)) (then unreachable))
    (local.set $scan
      (select (local.get $n) (i32.const 253) (i32.lt_u (local.get $n) (i32.const 253))))

    (block $out
    (block $reject
      (block $scanned
        (loop $next
          (br_if $scanned (i32.ge_u (local.get $i) (local.get $scan)))
          (local.set $byte (i32.load8_u (local.get $i)))
          (if (i32.eq (local.get $byte) (i32.const 0x2e)) ;; '.'
            (then
              ;; A dot needs a label before it that does not end with a hyphen,
              ;; and cannot be at index 252, the last char a name can have.
              (br_if $reject
                (i32.or
                  (i32.or (i32.eqz (local.get $len)) (local.get $hyphen))
                  (i32.eq (local.get $i) (i32.const 252))))
              (local.set $len (i32.const 0)))
            (else
              (if (i32.eq (local.get $byte) (i32.const 0x2d)) ;; '-'
                (then
                  ;; Label positions 1 to 61 may hold a hyphen. Position 62 is
                  ;; the last a label can have, so it must be a letter or digit.
                  ;; len - 1 >= 61 also catches len == 0 by wrapping.
                  (br_if $reject
                    (i32.or
                      (i32.ge_u (i32.sub (local.get $len) (i32.const 1)) (i32.const 61))
                      (i32.eq (local.get $i) (i32.const 252))))
                  (local.set $hyphen (i32.const 1)))
                (else
                  ;; Letter or digit: setting bit 5 maps 'A'-'Z' onto 'a'-'z'.
                  (br_if $reject
                    (i32.eqz
                      (i32.or
                        (i32.lt_u (i32.sub (i32.or (local.get $byte) (i32.const 0x20)) (i32.const 0x61)) (i32.const 26))
                        (i32.lt_u (i32.sub (local.get $byte) (i32.const 0x30)) (i32.const 10)))))
                  (br_if $reject (i32.ge_u (local.get $len) (i32.const 63)))
                  (local.set $hyphen (i32.const 0))))
              (local.set $len (i32.add (local.get $len) (i32.const 1)))))
          (local.set $i (i32.add (local.get $i) (i32.const 1)))
          (br $next)))

      ;; The first 253 bytes form a complete name, so any byte after them fails.
      (local.set $i (i32.const 253))
      (br_if $reject (i32.gt_u (local.get $n) (i32.const 253)))
      ;; Input that ends in an empty label or after a hyphen ends too early.
      (local.set $i (local.get $n))
      (br_if $reject (i32.or (i32.eqz (local.get $len)) (local.get $hyphen)))
      ;; Accept: the output is the whole input, in place at address 0.
      (local.set $size (local.get $n))
      (br $out))
    ;; Reject at offset $i.
    (local.set $size (local.get $i))
    (local.set $high (i32.const 0x80000000)))

    ;; Output proof: the size never exceeds output_utf8_cap.
    (if (i32.gt_u (local.get $size) (i32.const 0x400000)) (then unreachable))
    (i64.or
      (i64.shl (i64.extend_i32_u (local.get $high)) (i64.const 32))
      (i64.extend_i32_u (local.get $size))))
)
