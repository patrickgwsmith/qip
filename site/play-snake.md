# Snake

Snake combines timestamp-free events with a fixed 120 ms simulation step. It
can finish scheduled updates without rendering while hidden, then present its
latest state as canonical KTX2 output. After a long pause, one update runs at
most eight steps before it drops the remaining backlog.

Controls:

- Arrow keys: move
- Space: pause / resume
- `R`: restart

<qip-play>
  <source src="/gui/snake.wasm" type="application/wasm" />
</qip-play>
