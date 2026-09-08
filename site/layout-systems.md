<title>Flexbox and SwiftUI layout explainer</title>

# Flexbox and SwiftUI layout explainer

Increase child widths and compare how Flexbox and SwiftUI arrange the same items. This explainer is a QIP GUI component written in Zig; the page only mounts it.

Mode and slider changes are retained as component state. The component does
not schedule wakes because it has no animation, and only `render` publishes a
new KTX2 frame.

<qip-play>
  <source src="/interactive/layout-systems.wasm" type="application/wasm" />
</qip-play>

## What to notice

- Flexbox with `flex-wrap: wrap` creates new flex lines when the next child does not fit.
- Flexbox with `flex-wrap: nowrap` behaves more like an `HStack`: one row, possible overflow.
- SwiftUI `HStack` is not a wrapping layout. It asks children for sizes, places them horizontally, and reports the resulting stack size.
- SwiftUI wrapping is usually modeled explicitly with another layout, such as `LazyVGrid`, a custom `Layout`, or a flow layout.
