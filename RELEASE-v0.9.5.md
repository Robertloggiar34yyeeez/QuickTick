# QuickTick v0.9.5 — build 24

Based on main 7610556, on feature/v0.9.5-immersive-delivery. Earlier v0.9 feature work remains on its separate branch.

- Immersive receives deferred BGE semantic/taste/diversity ranking while preserving the active and previously viewed prefix. Initial provider publication and pagination use metadata-only ranking.
- Watch/skip learning uses advancing media time; loading, pauses and seeks do not count. Playback uses buffered startup, bounded next/previous player reuse, guarded prerolls, validated resume positions and fresh URL retry.
- A single active video page has a small 250 ms timeline; offscreen pages have no 100 ms timer. Smaller bounded previews, opaque action controls and one bounded GIF prefetch reduce scrolling work.
- Native dark search opens only from the magnifying glass, closes explicitly, supports autocomplete, provider-supported sorting/filters, independently toggleable include/exclude chips and case-insensitive deduplication. Home/Immersive retain separate query, feed, pagination and scroll state. Search commit keeps existing cards until a response arrives.
- Existing providers, history, favorites, downloads and pinned verified xtool process are retained. No new models or runtime downloads are added in this main-based patch.

Validation: local project and Swift syntax checks pass; native compilation and simulator/UI tests pending CI. No device FPS, first-frame improvement or relevance gain has been measured or claimed.
Delivery: unsigned arm64 iPhone IPA; user signing is required. Upload privately before native regression testing; retain UNVERIFIED until actual test results exist.
