<title>Page load waterfall explainer</title>

# Page load waterfall explainer

Visit a web page and watch the user-goal timeline change as the page shape changes. Toggle landing pages versus search results, server rendering versus SPA rendering, and then vary TLS, CDN assets, API domain/path, cache state, server distance, Wi-Fi quality, device speed, database latency, N+1 queries, chat widgets and UX interruptions.

Playback uses the Timed component contract. `finish_update` returns the next
frame time while playback is active, and the current update time when no wake
is needed.

<qip-play>
  <source src="/gui/page-load-waterfall.wasm" type="application/wasm" />
</qip-play>

## What to notice

- A server-rendered landing page can show content as soon as HTML, CSS, and the largest image are ready.
- A search results page moves TTFB later when server rendering waits on database queries, then loads multiple result images.
- SPA rendering often moves usable content later because JavaScript must load, execute, and then fetch API data.
- A cloud database with pooled connections still adds per-query latency; N+1 queries multiply that cost.
- TLS 1.3 reduces connection setup time compared with TLS 1.2.
- Cached CSS, images, and fonts can remove major waterfall bars without changing HTML TTFB.
- CDN assets are modeled as nearby even when the origin server is far away; a separate SPA API domain may still add DNS and connection setup on a cold visit.
- A far server or poor Wi-Fi stretches every origin round trip, which makes TLS and extra API calls more visible.
- A budget phone can move readable and usable milestones later even when the network bars look reasonable.
- Chat widgets often bring their own JavaScript and assets, which can delay when the interruption appears and when the user can proceed.
- Promo modals, cookie banners, and widgets are UX latency: the page may be loaded, but the user still cannot proceed.
