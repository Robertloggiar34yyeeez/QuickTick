# QuickTick native architecture - 0.6.25

AppStore remains the sole owner of provider, feed mode, posts, current playback identity, pagination and request generation. SwiftUI screens consume this state; the bounded AVPlayer pool retains active/prepared media.

QuicktickAPIClient owns direct provider requests through NativeProviderAPI and coalesced RedgifsAuthentication. Provider credentials are scoped to that provider. Native image/GIF/download pipelines use the provider/CDN URLs; legacy QuickTick media-proxy URLs are rejected or resolved again by provider ID. No feed, media, comments, autocomplete or recommendation call depends on the website. Public provider API availability and regional access still apply.

RecommendationEngine and SemanticRecommender own persistent local behavior, BGE embeddings, incremental interest vectors, hybrid ranking and diversity. Candidate acquisition rotates learned interests and broad discovery with independent cursors. A failed inferred-interest search may fall back to the provider's public browse feed; explicit searches never broaden silently. No engagement feedback goes to Vercel/Gorse.

QuicktickSyncService is the only optional website service. It retains the existing QT6 encryption contract. AppStore and the API transport require explicit cloudSyncEnabled opt-in, which defaults false when older files omit the flag. Existing IDs can be reconnected in Settings after enabling Sync. Download bytes remain local.

Xcode runs native unit/UI regression tests and builds the unsigned device archive in GitHub Actions. The current workflow packages the IPA from the Xcode archive; see .github/workflows/ios.yml for the active pipeline. Older architecture notes in this document are historical.
