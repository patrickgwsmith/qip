(module $HexToRGB
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

  ;; Convert hex character to value (0-15), returns -1 if invalid
  (func $hex_to_value (param $c i32) (result i32)
    ;; 0-9 (48-57)
    (if (result i32)
      (i32.and
        (i32.ge_u (local.get $c) (i32.const 48))
        (i32.le_u (local.get $c) (i32.const 57)))
      (then
        (i32.sub (local.get $c) (i32.const 48))
      )
      (else
        ;; A-F (65-70)
        (if (result i32)
          (i32.and
            (i32.ge_u (local.get $c) (i32.const 65))
            (i32.le_u (local.get $c) (i32.const 70)))
          (then
            (i32.sub (local.get $c) (i32.const 55))
          )
          (else
            ;; a-f (97-102)
            (if (result i32)
              (i32.and
                (i32.ge_u (local.get $c) (i32.const 97))
                (i32.le_u (local.get $c) (i32.const 102)))
              (then
                (i32.sub (local.get $c) (i32.const 87))
              )
              (else
                ;; Invalid
                (i32.const -1)
              )
            )
          )
        )
      )
    )
  )

  ;; Write decimal number to output buffer, returns number of bytes written
  (func $write_decimal (param $value i32) (param $output_pos i32) (result i32)
    (local $divisor i32)
    (local $digit i32)
    (local $started i32)
    (local $pos i32)

    (local.set $pos (local.get $output_pos))

    ;; Handle 0 specially
    (if (i32.eq (local.get $value) (i32.const 0))
      (then
        (i32.store8 (i32.add (global.get $output_ptr) (local.get $pos)) (i32.const 48))
        (return (i32.const 1))
      )
    )

    ;; Start with divisor 100
    (local.set $divisor (i32.const 100))

    (block $break
      (loop $continue
        (br_if $break (i32.eq (local.get $divisor) (i32.const 0)))

        (local.set $digit (i32.div_u (local.get $value) (local.get $divisor)))

        ;; Write digit if we've started or digit is non-zero
        (if (i32.or (local.get $started) (i32.gt_u (local.get $digit) (i32.const 0)))
          (then
            (i32.store8
              (i32.add (global.get $output_ptr) (local.get $pos))
              (i32.add (local.get $digit) (i32.const 48)))
            (local.set $pos (i32.add (local.get $pos) (i32.const 1)))
            (local.set $started (i32.const 1))
            (local.set $value (i32.rem_u (local.get $value) (local.get $divisor)))
          )
        )

        (local.set $divisor (i32.div_u (local.get $divisor) (i32.const 10)))
        (br $continue)
      )
    )

    (i32.sub (local.get $pos) (local.get $output_pos))
  )

  (func $render_size (param $input_size i32) (result i32)
    (local $start i32)
    (local $end i32)
    (local $hex_len i32)
    (local $r i32)
    (local $g i32)
    (local $b i32)
    (local $h1 i32)
    (local $h2 i32)
    (local $output_idx i32)
    (local $byte i32)
    (local $bytes_written i32)

    ;; Return 0 if input is empty or too short
    (if (i32.lt_u (local.get $input_size) (i32.const 3))
      (then (return (i32.const 0)))
    )

    ;; Trim trailing whitespace (newline, space, tab, etc.)
    (local.set $end (local.get $input_size))
    (block $break_trim
      (loop $continue_trim
        (br_if $break_trim (i32.eq (local.get $end) (i32.const 0)))
        (local.set $byte (i32.load8_u (i32.add (global.get $input_ptr) (i32.sub (local.get $end) (i32.const 1)))))
        ;; Check if whitespace (space=32, tab=9, newline=10, cr=13)
        (br_if $break_trim (i32.and
          (i32.ne (local.get $byte) (i32.const 32))
          (i32.and
            (i32.ne (local.get $byte) (i32.const 9))
            (i32.and
              (i32.ne (local.get $byte) (i32.const 10))
              (i32.ne (local.get $byte) (i32.const 13))
            )
          )
        ))
        (local.set $end (i32.sub (local.get $end) (i32.const 1)))
        (br $continue_trim)
      )
    )

    ;; Check if starts with #, skip it
    (local.set $start (i32.const 0))
    (local.set $byte (i32.load8_u (global.get $input_ptr)))
    (if (i32.eq (local.get $byte) (i32.const 35))  ;; '#'
      (then
        (local.set $start (i32.const 1))
      )
    )

    ;; Calculate hex length (remaining characters)
    (local.set $hex_len (i32.sub (local.get $end) (local.get $start)))

    ;; Must be 3 or 6 characters
    (if (i32.and
          (i32.ne (local.get $hex_len) (i32.const 3))
          (i32.ne (local.get $hex_len) (i32.const 6)))
      (then (return (i32.const 0)))
    )

    ;; Parse based on length
    (if (i32.eq (local.get $hex_len) (i32.const 3))
      (then
        ;; Short format: #RGB → each digit is doubled
        (local.set $h1 (call $hex_to_value (i32.load8_u (i32.add (global.get $input_ptr) (local.get $start)))))
        (if (i32.eq (local.get $h1) (i32.const -1)) (then (return (i32.const 0))))
        (local.set $r (i32.add (i32.shl (local.get $h1) (i32.const 4)) (local.get $h1)))

        (local.set $h1 (call $hex_to_value (i32.load8_u (i32.add (global.get $input_ptr) (i32.add (local.get $start) (i32.const 1))))))
        (if (i32.eq (local.get $h1) (i32.const -1)) (then (return (i32.const 0))))
        (local.set $g (i32.add (i32.shl (local.get $h1) (i32.const 4)) (local.get $h1)))

        (local.set $h1 (call $hex_to_value (i32.load8_u (i32.add (global.get $input_ptr) (i32.add (local.get $start) (i32.const 2))))))
        (if (i32.eq (local.get $h1) (i32.const -1)) (then (return (i32.const 0))))
        (local.set $b (i32.add (i32.shl (local.get $h1) (i32.const 4)) (local.get $h1)))
      )
      (else
        ;; Long format: #RRGGBB
        (local.set $h1 (call $hex_to_value (i32.load8_u (i32.add (global.get $input_ptr) (local.get $start)))))
        (if (i32.eq (local.get $h1) (i32.const -1)) (then (return (i32.const 0))))
        (local.set $h2 (call $hex_to_value (i32.load8_u (i32.add (global.get $input_ptr) (i32.add (local.get $start) (i32.const 1))))))
        (if (i32.eq (local.get $h2) (i32.const -1)) (then (return (i32.const 0))))
        (local.set $r (i32.add (i32.shl (local.get $h1) (i32.const 4)) (local.get $h2)))

        (local.set $h1 (call $hex_to_value (i32.load8_u (i32.add (global.get $input_ptr) (i32.add (local.get $start) (i32.const 2))))))
        (if (i32.eq (local.get $h1) (i32.const -1)) (then (return (i32.const 0))))
        (local.set $h2 (call $hex_to_value (i32.load8_u (i32.add (global.get $input_ptr) (i32.add (local.get $start) (i32.const 3))))))
        (if (i32.eq (local.get $h2) (i32.const -1)) (then (return (i32.const 0))))
        (local.set $g (i32.add (i32.shl (local.get $h1) (i32.const 4)) (local.get $h2)))

        (local.set $h1 (call $hex_to_value (i32.load8_u (i32.add (global.get $input_ptr) (i32.add (local.get $start) (i32.const 4))))))
        (if (i32.eq (local.get $h1) (i32.const -1)) (then (return (i32.const 0))))
        (local.set $h2 (call $hex_to_value (i32.load8_u (i32.add (global.get $input_ptr) (i32.add (local.get $start) (i32.const 5))))))
        (if (i32.eq (local.get $h2) (i32.const -1)) (then (return (i32.const 0))))
        (local.set $b (i32.add (i32.shl (local.get $h1) (i32.const 4)) (local.get $h2)))
      )
    )

    ;; Write output: "R,G,B"
    (local.set $output_idx (i32.const 0))

    ;; Write R
    (local.set $bytes_written (call $write_decimal (local.get $r) (local.get $output_idx)))
    (local.set $output_idx (i32.add (local.get $output_idx) (local.get $bytes_written)))

    ;; Write comma
    (i32.store8 (i32.add (global.get $output_ptr) (local.get $output_idx)) (i32.const 44))
    (local.set $output_idx (i32.add (local.get $output_idx) (i32.const 1)))

    ;; Write G
    (local.set $bytes_written (call $write_decimal (local.get $g) (local.get $output_idx)))
    (local.set $output_idx (i32.add (local.get $output_idx) (local.get $bytes_written)))

    ;; Write comma
    (i32.store8 (i32.add (global.get $output_ptr) (local.get $output_idx)) (i32.const 44))
    (local.set $output_idx (i32.add (local.get $output_idx) (i32.const 1)))

    ;; Write B
    (local.set $bytes_written (call $write_decimal (local.get $b) (local.get $output_idx)))
    (local.set $output_idx (i32.add (local.get $output_idx) (local.get $bytes_written)))

    ;; Return output size
    (local.get $output_idx)
  )
  (func (export "render") (param $input_size i32) (result i64)
    (i64.or
      (i64.shl (i64.extend_i32_u (global.get $output_ptr)) (i64.const 32))
      (i64.extend_i32_u (call $render_size (local.get $input_size)))))
)