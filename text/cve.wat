;; Validates one CVE ID and returns it in canonical form.
;;
;; Accepts `CVE-YYYY-NNNN...` with ASCII whitespace around it. The prefix is
;; case-insensitive. The year is four digits, 1999 or later. The sequence
;; number has 4 to 19 digits, as in the CVE JSON 5 `cveId` pattern
;; `^CVE-[0-9]{4}-[0-9]{4,19}$`. The output is the ID with an uppercase
;; `CVE` prefix and no surrounding whitespace.
;;
;; Rejection reports the offset of the first byte that cannot continue a CVE
;; ID, the year's offset for a year before 1999, or the input size when the
;; input ends too soon.
(module $CveValidator
  (memory (export "memory") 3 3)
  (data (i32.const 0) "CVE")
  (global $input_ptr i32 (i32.const 0x10000))
  (func (export "input_ptr") (result i32)
    (global.get $input_ptr))
  (global $input_utf8_cap i32 (i32.const 0x10000))
  (func (export "input_utf8_cap") (result i32)
    (global.get $input_utf8_cap))
  (global $output_ptr i32 (i32.const 0x20000))
  (global $output_utf8_cap i32 (i32.const 32))
  (func (export "output_utf8_cap") (result i32)
    (global.get $output_utf8_cap))
  (func (export "failure_modes_per_input_offset") (result i32)
    (i32.const 1))
  (global $failure_offset (mut i32) (i32.const -1))

  (func $reject (param $offset i32) (result i32)
    (global.set $failure_offset (local.get $offset))
    (i32.const 0))

  (func $is_trim_whitespace (param $c i32) (result i32)
    (i32.or
      (i32.eq (local.get $c) (i32.const 32))
      (i32.or
        (i32.eq (local.get $c) (i32.const 9))
        (i32.or
          (i32.eq (local.get $c) (i32.const 10))
          (i32.or
            (i32.eq (local.get $c) (i32.const 12))
            (i32.eq (local.get $c) (i32.const 13)))))))

  (func (export "render") (param $input_size i32) (result i64)
    (local $start i32)
    (local $end i32)
    (local $i i32)
    (local $k i32)
    (local $out_i i32)
    (local $c i32)
    (local $upper i32)
    (local $digit i32)
    (local $year i32)

    (if (i32.gt_u (local.get $input_size) (global.get $input_utf8_cap))
      (then unreachable))

    (global.set $failure_offset (i32.const -1))

    (block $finish
      (block $done_leading
        (loop $trim_leading
          (br_if $done_leading (i32.ge_u (local.get $start) (local.get $input_size)))
          (local.set $c (i32.load8_u (i32.add (global.get $input_ptr) (local.get $start))))
          (br_if $done_leading (i32.eqz (call $is_trim_whitespace (local.get $c))))
          (local.set $start (i32.add (local.get $start) (i32.const 1)))
          (br $trim_leading)))

      (local.set $end (local.get $input_size))
      (block $done_trailing
        (loop $trim_trailing
          (br_if $done_trailing (i32.le_u (local.get $end) (local.get $start)))
          (local.set $c
            (i32.load8_u
              (i32.add (global.get $input_ptr) (i32.sub (local.get $end) (i32.const 1)))))
          (br_if $done_trailing (i32.eqz (call $is_trim_whitespace (local.get $c))))
          (local.set $end (i32.sub (local.get $end) (i32.const 1)))
          (br $trim_trailing)))

      ;; Check each byte against its position: k 0-2 is the prefix, k 3 and
      ;; k 8 are hyphens, k 4-7 is the year, and k 9-27 is the sequence number.
      (local.set $i (local.get $start))
      (block $done_scan
        (loop $scan
          (br_if $done_scan (i32.ge_u (local.get $i) (local.get $end)))
          (local.set $k (i32.sub (local.get $i) (local.get $start)))
          (if (i32.ge_u (local.get $k) (i32.const 28))
            (then
              (local.set $out_i (call $reject (local.get $i)))
              (br $finish)))
          (local.set $c (i32.load8_u (i32.add (global.get $input_ptr) (local.get $i))))

          (if (i32.lt_u (local.get $k) (i32.const 3))
            (then
              ;; Clearing bit 5 maps only `c` and `C` to `C`, and so on.
              (local.set $upper (i32.and (local.get $c) (i32.const 0xDF)))
              (if (i32.ne (local.get $upper) (i32.load8_u (local.get $k)))
                (then
                  (local.set $out_i (call $reject (local.get $i)))
                  (br $finish)))
              (local.set $c (local.get $upper)))
            (else
              (if
                (i32.or
                  (i32.eq (local.get $k) (i32.const 3))
                  (i32.eq (local.get $k) (i32.const 8)))
                (then
                  (if (i32.ne (local.get $c) (i32.const 45))
                    (then
                      (local.set $out_i (call $reject (local.get $i)))
                      (br $finish))))
                (else
                  (local.set $digit (i32.sub (local.get $c) (i32.const 48)))
                  (if (i32.ge_u (local.get $digit) (i32.const 10))
                    (then
                      (local.set $out_i (call $reject (local.get $i)))
                      (br $finish)))
                  (if (i32.lt_u (local.get $k) (i32.const 8))
                    (then
                      (local.set $year
                        (i32.add
                          (i32.mul (local.get $year) (i32.const 10))
                          (local.get $digit)))))))))

          (i32.store8
            (i32.add (global.get $output_ptr) (local.get $k))
            (local.get $c))
          (local.set $i (i32.add (local.get $i) (i32.const 1)))
          (br $scan)))

      ;; `CVE-YYYY-NNNN` is the shortest valid ID.
      (if (i32.lt_u (i32.sub (local.get $end) (local.get $start)) (i32.const 13))
        (then
          (local.set $out_i (call $reject (local.get $input_size)))
          (br $finish)))

      (if (i32.lt_u (local.get $year) (i32.const 1999))
        (then
          (local.set $out_i (call $reject (i32.add (local.get $start) (i32.const 4))))
          (br $finish)))

      (local.set $out_i (i32.sub (local.get $end) (local.get $start))))

    ;; Every normal exit, including rejection, crosses the same statically
    ;; recognizable output-capacity proof.
    (if (i32.gt_u (local.get $out_i) (global.get $output_utf8_cap))
      (then unreachable))
    (if (result i64) (i32.ge_s (global.get $failure_offset) (i32.const 0))
      (then
        (i64.or
          (i64.const -9223372036854775808)
          (i64.extend_i32_u (global.get $failure_offset))))
      (else
        (i64.or
          (i64.shl (i64.extend_i32_u (global.get $output_ptr)) (i64.const 32))
          (i64.extend_i32_u (local.get $out_i))))))
)
