(module $LuhnValidator
  (memory (export "memory") 3 3)
  (global $input_ptr i32 (i32.const 0x10000))
  (func (export "input_ptr") (result i32)
    (global.get $input_ptr))
  (global $input_utf8_cap i32 (i32.const 0x10000))
  (func (export "input_utf8_cap") (result i32)
    (global.get $input_utf8_cap))
  (global $output_ptr i32 (i32.const 0x20000))
  (global $output_utf8_cap i32 (i32.const 0x10000))
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
    (local $out_i i32)
    (local $c i32)
    (local $digit i32)
    (local $doubled i32)
    (local $sum_even_len i32)
    (local $sum_odd_len i32)

    (if (i32.gt_u (local.get $input_size) (global.get $input_utf8_cap))
      (then unreachable))

    (global.set $failure_offset (i32.const -1))

    (block $finish
      (if (i32.eqz (local.get $input_size))
        (then
          (local.set $out_i (call $reject (i32.const 0)))
          (br $finish)))

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

      (if (i32.ge_u (local.get $start) (local.get $end))
        (then
          (local.set $out_i (call $reject (local.get $input_size)))
          (br $finish)))

    (local.set $i (local.get $start))
    (block $done_normalize
      (loop $normalize
        (br_if $done_normalize (i32.ge_u (local.get $i) (local.get $end)))
        (local.set $c (i32.load8_u (i32.add (global.get $input_ptr) (local.get $i))))

        (if
          (i32.and
            (i32.ne (local.get $c) (i32.const 32))
            (i32.ne (local.get $c) (i32.const 45)))
          (then
            (local.set $digit (i32.sub (local.get $c) (i32.const 48)))
            (if (i32.ge_u (local.get $digit) (i32.const 10))
              (then
                (local.set $out_i (call $reject (local.get $i)))
                (br $finish)))

            (i32.store8
              (i32.add (global.get $output_ptr) (local.get $out_i))
              (local.get $c))

            (local.set $doubled
              (i32.sub
                (i32.shl (local.get $digit) (i32.const 1))
                (i32.mul (i32.gt_u (local.get $digit) (i32.const 4)) (i32.const 9))))

            (if (i32.and (local.get $out_i) (i32.const 1))
              (then
                (local.set $sum_even_len
                  (i32.add (local.get $sum_even_len) (local.get $digit)))
                (local.set $sum_odd_len
                  (i32.add (local.get $sum_odd_len) (local.get $doubled))))
              (else
                (local.set $sum_even_len
                  (i32.add (local.get $sum_even_len) (local.get $doubled)))
                (local.set $sum_odd_len
                  (i32.add (local.get $sum_odd_len) (local.get $digit)))))

            (local.set $out_i (i32.add (local.get $out_i) (i32.const 1)))))

        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $normalize)))

      (if (i32.lt_u (local.get $out_i) (i32.const 2))
        (then
          (local.set $out_i (call $reject (local.get $input_size)))
          (br $finish)))

      (if
        (i32.rem_u
          (select
            (local.get $sum_odd_len)
            (local.get $sum_even_len)
            (i32.and (local.get $out_i) (i32.const 1)))
          (i32.const 10))
        (then
          (local.set $out_i (call $reject (local.get $input_size)))
          (br $finish)))
)

    ;; Every normal exit, including provisional rejection, crosses the same
    ;; statically recognizable output-capacity proof.
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
