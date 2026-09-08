(module $RGBToHex
  ;; Input occupies page 1 and the seven-byte output starts in page 2.
  ;; Parser positions travel in i64 results, so no fourth scratch page is used.
  (memory (export "memory") 3 3)
  (global $input_ptr i32 (i32.const 0x10000))
  (global $output_ptr i32 (i32.const 0x20000))
  (func (export "input_ptr") (result i32) (global.get $input_ptr))
  (func (export "input_utf8_cap") (result i32) (i32.const 0x10000))
  (func (export "output_utf8_cap") (result i32) (i32.const 7))

  ;; Return channel << 32 | next_position, or -1 for invalid input.
  (func $parse_channel
    (param $pos i32) (param $end i32) (param $last i32) (param $wrapped i32)
    (param $first_c i32) (param $has_first_c i32)
    (result i64)
    (local $c i32) (local $value i32)

    (if (local.get $has_first_c)
      (then (local.set $c (local.get $first_c)))
      (else
        (block $leading_done
          (loop $leading
            (br_if $leading_done (i32.ge_u (local.get $pos) (local.get $end)))
            (local.set $c (i32.load8_u (i32.add (global.get $input_ptr) (local.get $pos))))
            (br_if $leading_done (i32.eqz
              (i32.or
                (i32.eq (local.get $c) (i32.const 32))
                (i32.and
                  (i32.le_u (i32.sub (local.get $c) (i32.const 9)) (i32.const 4))
                  (i32.ne (local.get $c) (i32.const 11))))))
            (local.set $pos (i32.add (local.get $pos) (i32.const 1)))
            (br $leading)))))

    ;; The leading-whitespace scan already loaded the first non-whitespace
    ;; byte. Consume it here instead of loading it a second time.
    (if
      (i32.or
        (i32.ge_u (local.get $pos) (local.get $end))
        (i32.gt_u (i32.sub (local.get $c) (i32.const 48)) (i32.const 9)))
      (then (return (i64.const -1))))
    (local.set $value (i32.sub (local.get $c) (i32.const 48)))
    (local.set $pos (i32.add (local.get $pos) (i32.const 1)))

    (block $digits_done
      (loop $digits
        (br_if $digits_done (i32.ge_u (local.get $pos) (local.get $end)))
        (local.set $c (i32.load8_u (i32.add (global.get $input_ptr) (local.get $pos))))
        (br_if $digits_done
          (i32.gt_u (i32.sub (local.get $c) (i32.const 48)) (i32.const 9)))
        (local.set $value
          (i32.add
            (i32.mul (local.get $value) (i32.const 10))
            (i32.sub (local.get $c) (i32.const 48))))
        (if (i32.gt_u (local.get $value) (i32.const 255))
          (then (return (i64.const -1))))
        (local.set $pos (i32.add (local.get $pos) (i32.const 1)))
        (br $digits)))
    (block $trailing_done
      (loop $trailing
        (br_if $trailing_done (i32.ge_u (local.get $pos) (local.get $end)))
        (br_if $trailing_done (i32.eqz
          (i32.or
            (i32.eq (local.get $c) (i32.const 32))
            (i32.and
              (i32.le_u (i32.sub (local.get $c) (i32.const 9)) (i32.const 4))
              (i32.ne (local.get $c) (i32.const 11))))))
        (local.set $pos (i32.add (local.get $pos) (i32.const 1)))
        (if (i32.lt_u (local.get $pos) (local.get $end))
          (then
            (local.set $c
              (i32.load8_u (i32.add (global.get $input_ptr) (local.get $pos))))))
        (br $trailing)))

    (if (local.get $last)
      (then
        (if (local.get $wrapped)
          (then
            (if (i32.or
                  (i32.ge_u (local.get $pos) (local.get $end))
                  (i32.ne (local.get $c) (i32.const 41)))
              (then (return (i64.const -1))))
            (local.set $pos (i32.add (local.get $pos) (i32.const 1)))
            (block $end_ws_done
              (loop $end_ws
                (br_if $end_ws_done (i32.ge_u (local.get $pos) (local.get $end)))
                (local.set $c (i32.load8_u (i32.add (global.get $input_ptr) (local.get $pos))))
                (br_if $end_ws_done (i32.eqz
                  (i32.or
                    (i32.eq (local.get $c) (i32.const 32))
                    (i32.and
                      (i32.le_u (i32.sub (local.get $c) (i32.const 9)) (i32.const 4))
                      (i32.ne (local.get $c) (i32.const 11))))))
                (local.set $pos (i32.add (local.get $pos) (i32.const 1)))
                (br $end_ws)))))
        (if (i32.ne (local.get $pos) (local.get $end))
          (then (return (i64.const -1)))))
      (else
        (if (i32.or
              (i32.ge_u (local.get $pos) (local.get $end))
              (i32.ne (local.get $c) (i32.const 44)))
          (then (return (i64.const -1))))
        (local.set $pos (i32.add (local.get $pos) (i32.const 1)))))

    (i64.or
      (i64.shl (i64.extend_i32_u (local.get $value)) (i64.const 32))
      (i64.extend_i32_u (local.get $pos))))

  (func $write_hex_byte (param $value i32) (param $pos i32)
    (local $digit i32)
    (local.set $digit (i32.shr_u (local.get $value) (i32.const 4)))
    (i32.store8 (i32.add (global.get $output_ptr) (local.get $pos))
      (i32.add (i32.add (local.get $digit) (i32.const 48))
        (select (i32.const 39) (i32.const 0)
          (i32.ge_u (local.get $digit) (i32.const 10)))))
    (local.set $digit (i32.and (local.get $value) (i32.const 15)))
    (i32.store8
      (i32.add (i32.add (global.get $output_ptr) (local.get $pos)) (i32.const 1))
      (i32.add (i32.add (local.get $digit) (i32.const 48))
        (select (i32.const 39) (i32.const 0)
          (i32.ge_u (local.get $digit) (i32.const 10))))))

  (func $render_size (param $input_size i32) (result i32)
    (local $pos i32) (local $c i32) (local $wrapped i32)
    (local $channel i32) (local $parsed i64) (local $rgb i32)
    (if (i32.eqz (local.get $input_size)) (then (return (i32.const 0))))

    (block $leading_done
      (loop $leading
        (br_if $leading_done (i32.ge_u (local.get $pos) (local.get $input_size)))
        (local.set $c (i32.load8_u (i32.add (global.get $input_ptr) (local.get $pos))))
        (br_if $leading_done (i32.eqz
          (i32.or
            (i32.eq (local.get $c) (i32.const 32))
            (i32.and
              (i32.le_u (i32.sub (local.get $c) (i32.const 9)) (i32.const 4))
              (i32.ne (local.get $c) (i32.const 11))))))
        (local.set $pos (i32.add (local.get $pos) (i32.const 1)))
        (br $leading)))
    (if (i32.ge_u (local.get $pos) (local.get $input_size))
      (then (return (i32.const 0))))

    (if
      (i32.le_u (i32.const 3) (i32.sub (local.get $input_size) (local.get $pos)))
      (then
        (if
        (i32.and
          (i32.eq
            (i32.or (local.get $c) (i32.const 32))
            (i32.const 114))
          (i32.and
            (i32.eq
              (i32.or (i32.load8_u
                (i32.add (i32.add (global.get $input_ptr) (local.get $pos)) (i32.const 1)))
                (i32.const 32))
              (i32.const 103))
            (i32.eq
              (i32.or (i32.load8_u
                (i32.add (i32.add (global.get $input_ptr) (local.get $pos)) (i32.const 2)))
                (i32.const 32))
              (i32.const 98))))
        (then
        (local.set $wrapped (i32.const 1))
        (local.set $pos (i32.add (local.get $pos) (i32.const 3)))
        (block $rgb_ws_done
          (loop $rgb_ws
            (br_if $rgb_ws_done (i32.ge_u (local.get $pos) (local.get $input_size)))
            (local.set $c (i32.load8_u (i32.add (global.get $input_ptr) (local.get $pos))))
            (br_if $rgb_ws_done (i32.eqz
              (i32.or
                (i32.eq (local.get $c) (i32.const 32))
                (i32.and
                  (i32.le_u (i32.sub (local.get $c) (i32.const 9)) (i32.const 4))
                  (i32.ne (local.get $c) (i32.const 11))))))
            (local.set $pos (i32.add (local.get $pos) (i32.const 1)))
            (br $rgb_ws)))
        (if (i32.or
              (i32.ge_u (local.get $pos) (local.get $input_size))
              (i32.ne (local.get $c) (i32.const 40)))
          (then (return (i32.const 0))))
          (local.set $pos (i32.add (local.get $pos) (i32.const 1)))))))

    (block $channels_done
      (loop $channels
        (local.set $parsed
          (call $parse_channel
            (local.get $pos) (local.get $input_size)
            (i32.eq (local.get $channel) (i32.const 2))
            (local.get $wrapped)
            (local.get $c)
            (i32.and
              (i32.eqz (local.get $wrapped))
              (i32.eqz (local.get $channel)))))
        (if (i64.eq (local.get $parsed) (i64.const -1))
          (then (return (i32.const 0))))
        (local.set $pos (i32.wrap_i64 (local.get $parsed)))
        (local.set $rgb
          (i32.or
            (i32.shl (local.get $rgb) (i32.const 8))
            (i32.wrap_i64 (i64.shr_u (local.get $parsed) (i64.const 32)))))
        (local.set $channel (i32.add (local.get $channel) (i32.const 1)))
        (br_if $channels (i32.lt_u (local.get $channel) (i32.const 3)))))

    ;; Seven store8 instructions write exactly the seven returned bytes.
    (i32.store8 (global.get $output_ptr) (i32.const 35))
    (call $write_hex_byte
      (i32.and (i32.shr_u (local.get $rgb) (i32.const 16)) (i32.const 255))
      (i32.const 1))
    (call $write_hex_byte
      (i32.and (i32.shr_u (local.get $rgb) (i32.const 8)) (i32.const 255))
      (i32.const 3))
    (call $write_hex_byte (i32.and (local.get $rgb) (i32.const 255)) (i32.const 5))
    (i32.const 7))

  (func (export "render") (param $input_size i32) (result i64)
    (i64.or
      (i64.shl (i64.extend_i32_u (global.get $output_ptr)) (i64.const 32))
      (i64.extend_i32_u (call $render_size (local.get $input_size)))))
)
