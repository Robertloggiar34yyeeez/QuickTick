# Recommended Native Architecture — 0.6.24

**App / Navigation** — SwiftUI entry, tabs/navigation, environment store.

**Models** — normalized Post/provider, sync snapshot, recommendation evidence/state, downloads.

**API** — one `QuicktickAPIClient` targeting the existing Vercel deployment. Provider quirks remain server-side where current web already solves them.

**Sync** — `QuicktickSyncCrypto` + `QuicktickSyncService`; exact web-compatible QT6/AES-GCM contract. Keychain stores the full Sync ID.

**Recommendations** — `RecommendationEngine` is the authoritative local filter/reranker. It learns recurring term/common-denominator evidence, themes, related terms, seen history and anti-clumping. `RecommendationBridge` optionally asks Vercel `/api/recommend` for Gorse collaborative scores and sends feedback. The bridge is additive and soft-failing; local hard filters always win.

**Media** — provider media resolution through Vercel + bounded `AVPlayer` pool. RedGIFs must use its Quicktick media proxy. Pre-resolve upcoming Eporner/Pornhub/Hanime/RedGIFs items instead of blocking the active swipe.

**Downloads** — background URLSession for direct files, AVAssetDownloadURLSession for permitted non-DRM HLS, persistent metadata/thumbnails, local-only media bytes.

**Persistence** — versioned Codable/SwiftData/Core Data for ordinary state; Keychain for secrets. Recommendation and download state survive app restarts.

## Main online feed flow

Vercel provider route → normalize Post → explicit exclusions/hard dislike filter → optional `/api/recommend` collaborative hints → local 0.6.24 score → anti-clump selector → Home/Immersive.

## Interaction flow

Interaction → local RecommendationEngine update + persistence → optional Vercel `/api/recommend` feedback. Favorites/exclusions/preferences/auth changes separately queue encrypted Quicktick Sync.

## Download flow

Post → Vercel media resolver → native download → app-owned file/HLS package → metadata + thumbnail → Downloads / Offline Immersive.

## Source of truth

When starter code conflicts with current behavior, `reference-web/app.js`, `reference-web/server/routes/*`, and current API routes win unless the change is intentionally native-only.
