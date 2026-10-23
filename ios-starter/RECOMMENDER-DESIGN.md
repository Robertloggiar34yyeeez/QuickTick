# QuickTick's TikTok-inspired local recommender

This document describes QuickTick's own implementation, not TikTok's private production algorithm.

## Serving pipeline
1. **Parallel retrieval.** Rotate explicit interests, previously liked topics, creators, and bounded broad discovery. Fetch separate candidate pools concurrently and retain independently advancing page cursors.
2. **Eligibility.** Remove explicit disliked tags/terms, denied artists, previously served/seen duplicates, and provider-ineligible formats before scoring.
3. **Fast ranking.** Score metadata, saved favorites, on-device cached visual affinity, and short-term session intent. Cache per-candidate topic sets for diversification; do not load ML models or download images during ranking.
4. **Bounded diversity.** Choose from a 20-item look-ahead window and penalize repeated topical near-duplicates. Exploration cannot override hard exclusions or user-selected relevance.
5. **Idle refinement.** Perform semantic/visual inference only away from scrolling/playback, and rerank the *unseen tail* while preserving active and visible posts.

## SessionPreferenceModel
- On-device, ephemeral; source-separated; maximum 80 topic weights per provider.
- Like, download, replay, and completion add positive evidence. Explicit Less/Unlike add negative evidence.
- Impressions and quick skips do **not** add persistent session dislike; quick skip evidence remains separately reversible.
- Watched progress counts only over 55% completion. Incremental progress is monotonically credited per post to avoid repeated 10-second samples multiplying one watch into many likes.
- Each update decays previous session weights by 6%; magnitude is clipped, and the entire model lives alongside (not in place of) persisted long-term preferences.
- Strong recent topics help rank/retrieve likely matches; strict explicit exclusions always win.

## Performance invariants
- Feed uses CDN preview images when available. Full-screen loads the original with a bounded decoded resolution and shows the already decoded preview immediately.
- Asset requests are deduplicated in MediaImagePipeline, with bounded decoded caches.
- First paint uses only cached metadata and appearance scores; never await heavy Core ML inference.
- Network video buffering is conservative; the next player and poster are warmed from an adjacent-item window.
- Do not reorder already-visible media, and do not treat opening/closing viewers as disinterest.

## Verification and experiment plan
- XCTest: session reward/penalty, feedback deduplication, explicit exclusions, full-bleed geometry, preview/original quality, cursor rotation and ranking latency.
- Native CI: iPhone archive, unsigned IPA, iPhone XCTest and iPad automated UI suites all must pass before merging.
- Offline chronological evaluation using consented anonymized interactions: Recall@20, NDCG@10, negative leak rate, coverage, first-frame time, scroll frame consistency, and memory pressure.
- Run A/B comparisons against the previous metadata-and-favorites baseline, logging *why* candidates were selected and the model confidence. Never infer production accuracy from unit tests alone.

## References
- TikTok: How TikTok recommends content (TikTok Newsroom).
- ByteDance Monolith real-time recommendation framework: https://github.com/bytedance/monolith
- Google's recommendation system retrieval/scoring/reranking architecture.
- YouTube's *Deep Neural Networks for YouTube Recommendations* (2016).
