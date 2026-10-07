# QuickTick production pass — audited baseline

Baseline: main 285c8a1b0239d01a9cb62f34df4d072d39b0353b, build 4.

## Architecture and state owners
- Native SwiftUI navigation stacks inside RootView TabView; UIKit AVPlayerLayer and tiled UIScrollView comic reader. iOS 17+, Swift 6, device families 1/2.
- AppStore (MainActor) owns current posts, provider, sort, paging cursor/generation, favorites, credentials/preferences and recommendation bridge. Root previously owned tab selection; moved to AppStore so media can observe tab changes.
- Home previously had only user-selected inlinePlaybackID, no visibility calculation. Immersive owns its scroll-position ID/index locally. These are distinct presentation cursors over AppStore.posts, not two feed datasets.
- RecommendationEngine is an actor with bounded tag/phrase evidence, recent-seen history, interaction statistics and Gorse fallback. Persistence stores bounded private local state.
- PlayerPool existed only for Immersive. Home allocated a new AVPlayer for every activation, used intent-only playing flags and had no prepared window. URL reuse was keyed by post ID without checking changed URLs.
- NativePlayerSurface KVO captured an outdated ready binding and could publish a replaced layer's readiness. No dismantle invalidation existed.
- MediaResolver coalesces provider resolution, but direct Rule34/image/GIF URLs bypassed absolute-URL normalization. Separate AsyncImage, comic, GIF and Immersive downloads/decodes overlapped. Immersive ImageIO work ran on MainActor. Home giant-comic preview constructed a full-resolution CGImage before downsampling.
- Feed-sort changes relied on a Home onChange task. Old posts/playback remained visible until refresh completed. Generation checks rejected some stale results, but obsolete transport tasks weren't cancelled and provider/sort reads after awaits were inconsistent.
- iPad used the same unconstrained full-width card as iPhone. No dimensions existed in Post; previews/AVAsset dimensions were not consistently retained. Dynamic geometry and orientation changes were not accounted for by a shared sizing policy.
- Tests: 29 unit + 6 UI on previous build. Home and Immersive DEBUG prepare paths returned without playing media; Play assertions only verified state labels. Existing screenshots do not constitute live-media verification.

## Focused changes and verification contract
Use one AppStore active feed identity and home playback selection; one bounded player pool, real visibility and actual first-frame tests. Keep native media aspect, adopt optional actual metadata, center a capped adaptive feed. Shared bounded preview transport/decoded cache and cancellation. Pinned bge-micro-v2 -> Core ML with native WordPiece, persistent bounded embeddings, incremental centroids and conservative hybrid/diversity ranking; no MLX dependency or generative LLM. Immediate tag fallback always available. Model conversion and parity tested before packaging.

Figma visual source: https://www.figma.com/design/y3ViOhQjwaaZ6gbGBfKLxq?node-id=1-17 . Black canvas, 8/16/24 spacing, 14/22 radii, 44pt controls, 680pt feed cap, explicit Home/Recommended/Popular identities. Existing four tabs and top-right Settings remain. MagicPath is not used: the selected focused native direction does not require competing layout prototypes.

Physical AV network latency, scrolling frame drops, battery/thermals and long-run iPad memory must be measured on hardware; simulator fixture results will be labeled as such.
