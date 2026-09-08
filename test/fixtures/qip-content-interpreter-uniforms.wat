(module
  (memory (export "memory") 1 1)

  (global $unsigned (mut i32) (i32.const 0))
  (global $signed (mut i64) (i64.const 0))
  (global $ratio (mut f32) (f32.const 0))
  (global $scale (mut f64) (f64.const 0))

  (func (export "output_bytes_cap") (result i32)
    i32.const 24)

  (func (export "input_ptr") (result i32)
    i32.const 32)

  (func (export "input_bytes_cap") (result i32)
    i32.const 1)

  (func (export "uniform_set_unsigned") (param $value i32) (result i32)
    local.get $value
    global.set $unsigned
    local.get $value)

  (func (export "uniform_set_signed") (param $value i64) (result i64)
    local.get $value
    global.set $signed
    local.get $value)

  (func (export "uniform_set_ratio") (param $value f32) (result f32)
    local.get $value
    global.set $ratio
    local.get $value)

  (func (export "uniform_set_scale") (param $value f64) (result f64)
    local.get $value
    global.set $scale
    local.get $value)

  (func (export "render") (param i32) (result i64)
    i32.const 0
    global.get $unsigned
    i32.store
    i32.const 4
    global.get $signed
    i64.store
    i32.const 12
    global.get $ratio
    f32.store
    i32.const 16
    global.get $scale
    f64.store
    i64.const 24))
