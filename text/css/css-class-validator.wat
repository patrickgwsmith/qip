(module $CSSClassValidator
  (memory (export "memory") 2 2)
  (global $input_ptr i32 (i32.const 0x10000))
  (global $input_utf8_cap i32 (i32.const 0x10000))
  (global $output_utf8_cap i32 (i32.const 0x10000))
  (global $failure_offset (mut i32) (i32.const -1))

  (func (export "input_ptr") (result i32)
    (global.get $input_ptr))
  (func (export "input_utf8_cap") (result i32)
    (global.get $input_utf8_cap))
  (func (export "output_utf8_cap") (result i32)
    (global.get $output_utf8_cap))
  (func (export "failure_modes_per_input_offset") (result i32)
    (i32.const 1))

  ;; HTML ASCII whitespace: tab, LF, FF, CR, and space.
  (func $is_whitespace (param $c i32) (result i32)
    (i32.or
      (i32.eq (local.get $c) (i32.const 32))
      (i32.or
        (i32.eq (local.get $c) (i32.const 9))
        (i32.or
          (i32.eq (local.get $c) (i32.const 10))
          (i32.or
            (i32.eq (local.get $c) (i32.const 12))
            (i32.eq (local.get $c) (i32.const 13)))))))

  ;; Reject invalid input and include its first known byte offset.
  (func $reject (param $offset i32) (result i32)
    (global.set $failure_offset (local.get $offset))
    (i32.const 0))

  ;; Accept one non-empty class token. The output is an immutable interior
  ;; slice with leading and trailing ASCII whitespace removed.
  (func (export "render") (param $input_size i32) (result i64)
    (local $start i32)
    (local $end i32)
    (local $len i32)
    (local $i i32)
    (local $c i32)

    (if (i32.gt_u (local.get $input_size) (global.get $input_utf8_cap))
      (then unreachable))

    (global.set $failure_offset (i32.const -1))

    (block $finish
      (if (i32.eqz (local.get $input_size))
        (then
          (local.set $len (call $reject (i32.const 0)))
          (br $finish)))

      (block $done_leading
        (loop $trim_leading
          (br_if $done_leading (i32.ge_u (local.get $start) (local.get $input_size)))
          (local.set $c
            (i32.load8_u (i32.add (global.get $input_ptr) (local.get $start))))
          (br_if $done_leading (i32.eqz (call $is_whitespace (local.get $c))))
          (local.set $start (i32.add (local.get $start) (i32.const 1)))
          (br $trim_leading)))

      (local.set $end (local.get $input_size))
      (block $done_trailing
        (loop $trim_trailing
          (br_if $done_trailing (i32.le_u (local.get $end) (local.get $start)))
          (local.set $c
            (i32.load8_u
              (i32.add (global.get $input_ptr) (i32.sub (local.get $end) (i32.const 1)))))
          (br_if $done_trailing (i32.eqz (call $is_whitespace (local.get $c))))
          (local.set $end (i32.sub (local.get $end) (i32.const 1)))
          (br $trim_trailing)))

      (if (i32.ge_u (local.get $start) (local.get $end))
        (then
          (local.set $len (call $reject (local.get $input_size)))
          (br $finish)))

      (local.set $i (local.get $start))
      (block $done_validate
        (loop $validate
          (br_if $done_validate (i32.ge_u (local.get $i) (local.get $end)))
          (local.set $c
            (i32.load8_u (i32.add (global.get $input_ptr) (local.get $i))))
          (if (call $is_whitespace (local.get $c))
            (then
              (local.set $len (call $reject (local.get $i)))
              (br $finish)))
          (local.set $i (i32.add (local.get $i) (i32.const 1)))
          (br $validate)))

      (local.set $len (i32.sub (local.get $end) (local.get $start)))
)

    ;; Every normal exit crosses the same output-capacity proof.
    (if (i32.gt_u (local.get $len) (global.get $output_utf8_cap))
      (then unreachable))
    (if (result i64) (i32.ge_s (global.get $failure_offset) (i32.const 0))
      (then
        (i64.or
          (i64.const -9223372036854775808)
          (i64.extend_i32_u (global.get $failure_offset))))
      (else
        (i64.or
          (i64.shl
            (i64.extend_i32_u (i32.add (global.get $input_ptr) (local.get $start)))
            (i64.const 32))
          (i64.extend_i32_u (local.get $len))))))

)
