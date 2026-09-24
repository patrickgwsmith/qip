<title>Browser security explainers</title>

# Browser security explainers

Use this Zig QIP component to build intuition for CORS, CSRF, and XSS. The diagrams focus on what the browser sends, what JavaScript is allowed to read, and where attacker-controlled input crosses a trust boundary.

Topic and scenario selections are retained as component state. The component
has no timed animation and publishes a new KTX2 frame only from `render`.

<qip-play>
  <source src="/gui/browser-security.wasm" type="application/wasm" />
</qip-play>

## What to notice

- CORS is a browser read-permission system for JavaScript, not a server-side firewall.
- A JSON `POST` usually pays for an `OPTIONS` preflight before the real request.
- New domains can add DNS and connection setup before any CORS behavior happens.
- CSRF abuses authenticated browser requests; the attacker often does not need to read the response.
- XSS means attacker code runs inside your origin, so escaping must match the output context.
