(module
  (type $binary (func (param i32 i32) (result i32)))
  (type $unary (func (param i32) (result i32)))
  (type $render (func (param i32) (result i64)))

  (memory (export "memory") 1 1)
  (table 3 3 funcref)
  (elem (i32.const 1) $add $wrong-type)

  (func (export "input_ptr") (result i32)
    i32.const 0)
  (func (export "input_bytes_cap") (result i32)
    i32.const 3)

  (func $add (type $binary) (param $left i32) (param $right i32) (result i32)
    local.get $left
    local.get $right
    i32.add)

  (func $wrong-type (type $unary) (param $value i32) (result i32)
    local.get $value)

  (func (export "render") (type $render) (param $input-size i32) (result i64)
    i32.const 32
    i32.const 20
    i32.const 22
    local.get $input-size
    call_indirect (type $binary)
    i32.store
    i64.const 137438953476))
