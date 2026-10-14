# QuickTick native architecture - 0.6.25

AppStore remains the sole owner of provider, feed mode, posts, current playback identity, pagination and request generation. SwiftUI screens consume this state; the bounded AVPlayer pool retains active/prepared media.

QuicktickAPIClient owns direct provider requests through NativeProviderAPI and coalesced RedgifsAuthentication. Provider credentials are scoped to that provider. Native image/GIF/download pipelines use the provider/CDN URLs; legacy QuickTick media-proxy URLs are rejected or resolved again by provider ID. No feed, media, comments, autocomplete or recommendation call depends on the website. Public provider API availability and regional access still apply.

RecommendationEngine and SemanticRecommender own persistent local behavior, BGE embeddings, incremental interest vectors, hybrid ranking and diversity. Candidate acquisition rotates learned interests and broad discovery with independent cursors. A failed inferred-interest search may fall back to the provider's public browse feed; explicit searches never broaden silently. No engagement feedback goes to Vercel/Gorse.

QuicktickSyncService is the only optional website service. It retains the existing QT6 encryption contract. AppStore and the API transport require explicit cloudSyncEnabled opt-in, which defaults false when older files omit the flag. Existing IDs can be reconnected in Settings after enabling Sync. Download bytes remain local.

Xcode owns native unit/UI regression tests and compiles the icon catalog. The same Swift sources additionally build with SwiftPM; xtool from the user's verified Drive archive builds/packages the unsigned device IPA. See DIRECT-API-0.6.25.md and tools/xtool-source-manifest.json for provenance.
