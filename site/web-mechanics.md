<title>Web mechanics explainers</title>

# Web mechanics explainers

Use this Zig QIP component to compare TLS handshakes, DNS resolution, browser page loading, and SameSite cookie behavior. These are the browser and network sequences that are easiest to misread when they are only described in prose.

Topic and scenario selections are retained as component state. The component
has no animation wake and publishes a new KTX2 frame only from `render`.

<qip-play>
  <source src="/gui/web-mechanics.wasm" type="application/wasm" />
</qip-play>

## What to notice

- TLS 1.3 starts application data sooner than TLS 1.2 because it needs fewer round trips.
- DNS answers are cached at several layers; changing an authoritative record does not erase existing cache entries.
- CSS, classic scripts, `defer`, and `async` affect different stages of loading and execution.
- SameSite is about whether cookies are attached to a request; CORS is about whether JavaScript can read the response.
