# Render Counts

This component shows the Eventful lifecycle as it runs. It counts begun and
finished updates, renders, key events, and pointer events. Key and pointer
times are the time passed to the enclosing `begin_update_at` call.

Only `render` publishes output. An update can finish without changing the
displayed KTX2 frame; the next render presents its state.

<qip-play>
  <source src="/gui/render-counts.wasm" type="application/wasm" />
</qip-play>
