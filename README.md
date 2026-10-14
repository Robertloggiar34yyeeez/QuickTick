# Current native build: 0.6.25

Direct provider APIs and on-device recommendations; website Sync is optional and off by default. See [native architecture](ARCHITECTURE.md) and [0.6.25 changes](DIRECT-API-0.6.25.md). Packaging uses the verified xtool source supplied on Drive. Historical 0.6.24 notes below describe the previous website-proxy implementation.

# Quicktick Native iOS Codex Handoff — Web 0.6.24

This package continues the existing native iOS port against the effective Quicktick web behavior through **0.6.24**. It is not a WebView wrapper.

Start with `CODEX-MASTER-PROMPT.md`. `reference-web/` is the API/behavior source of truth, reconstructed by applying the 0.6.20 → 0.6.21 → 0.6.22 → 0.6.23 → 0.6.24 patches in order. `dist/` is intentionally excluded because Vercel builds it.

The iOS starter now includes the 0.6.24 local common-denominator recommendation model and an optional `RecommendationBridge` that talks only to Vercel `/api/recommend`. The native binary must never contain Gorse credentials. If Gorse is unavailable, the local recommender remains functional.

The package also carries current provider behavior: RedGIFs playback via the Quicktick media proxy, Hanime server-first public catalog/media resolution, Eporner resolver prewarming expectations, Pornhub supported session handling, Rule34 credentials/comments, exact QT6 cloud Sync compatibility, and native/offline download requirements.

Before live testing, set `QUICKTICK_API_BASE_URL` in the xcconfig files to the existing Quicktick Vercel deployment. If Gorse is desired, configure it on the Vercel/server side only; no additional iOS secret is required.

## Required Codex delivery workflow

The bundled `CODEX-MASTER-PROMPT.md` now requires Codex to use the user's connected GitHub account for native iOS source control and, when the Windows Google Drive desktop mount is accessible, copy each completed revision to `E:\Meine Ablage\QuickTick iOS Revisions` with hash verification. Codex must report honestly when either destination is unavailable.


## Required GitHub destination (r3)

Codex must replace the current tracked contents of `https://github.com/Robertloggiar34yyeeez/QuickTick` with the native iOS project while preserving repository history. Do not create a separate iOS repository. Final revision artifacts must also be copied to `E:\\Meine Ablage\\QuickTick iOS Revisions` when that mounted Drive path is available.
