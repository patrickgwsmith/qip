# PlayStation 2 Menu

An interactive menu sketch inspired by the PlayStation 2 Browser and System Configuration UI.

Controls:

- `Up` / `Down`: move row selection
- `Left` / `Right`: change values (System Configuration)
- `X` or `Enter`: select
- `O` or `Esc`: back
- Pointer hover and click are also supported

<qip-play>
  <source src="/gui/ps2-menu.wasm" type="application/wasm" />
</qip-play>

The menu pulse and temporary flash follow update time. `finish_update`
schedules the next update, while only `render` replaces the published KTX2
image.
