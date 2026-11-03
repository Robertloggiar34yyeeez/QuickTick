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
- Each deliberate update decays previous session weights by 6%; in addition, a 60-minute wall-clock half-life fades temporary interests even during long passive viewing sessions. Impressions and quick skips do not refresh the clock.
- Magnitude is clipped and the entire session model remains alongside (not in place of) persisted long-term preferences; explicit Into/Not Into choices do not expire.
- Strong recent topics help rank/retrieve likely matches; strict explicit exclusions always win.

## Monolith (arXiv:2209.07663) adaptation
- **Online feedback, no distant retraining loop:** the actor updates in-memory short-term tastes immediately from deliberate actions; scoring reads the current state. A server-scale Kafka/Flink/parameter-server architecture is intentionally unnecessary for a single-user private iOS app.
- **Concept drift:** ephemeral interest scores age by elapsed time as well as incoming interaction count. A later action starts from the aged weight instead of reviving an old impulse.
- **Collision-free identity:** canonical topic strings and distinct stable item identifiers are kept as dictionary keys; do not compress disparate item IDs into shared embedding buckets.
- **Frequency and size control:** do not infer durable dislike from a single passive skip. Keep existing per-provider 80-term session caps, bounded persistent terms, novelty limits, and eviction of near-zero session weights.
- **Safe incremental serving:** changes should affect newly ranked candidate tails without blocking media rendering or shuffling posts already visible to the user.
- **Not yet adopted:** full online embedding training and persistent time-to-live expiration need separate offline evaluations and migration tests before any production rollout. This paper reports performance of ByteDance/Criteo workloads, not QuickTick.

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
