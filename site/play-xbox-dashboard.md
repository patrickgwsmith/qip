# Original Xbox Dashboard

An interactive dashboard sketch inspired by the original Xbox menu flow.

Controls:

- `Up` / `Down`: move selection
- `Enter` or `A`: open category
- `Esc` or `B`: back
- Pointer hover and click are also supported

<qip-play>
  <source src="/gui/xbox-dashboard.wasm" type="application/wasm" />
</qip-play>

The dashboard pulse follows update time. `finish_update` schedules the next
update, while only `render` replaces the published KTX2 output.
