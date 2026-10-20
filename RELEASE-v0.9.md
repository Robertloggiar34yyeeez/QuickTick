# QuickTick v0.9 – recommendation relevance (development)

Status: source-only draft based on v0.8.5 commit 74bf569776113b1e40c05efda5a0d2873430c69e. NOT VERIFIED, not an installable release.

- Acquires learned interests for the first personalized request, without waiting for idle.
- Uses cheap tag/negative-theme evidence to rank each newly fetched Recommended batch before publication.
- Does not wait for BGE, WD, Vision, image decoding, or remote inference; preserves provider ordering on cold start and for explicit searches.
- Retains deferred semantic/visual ranking, visible-row protection, provider fallback, and rate-limit safeguards.
- Adds focused unit and provider-fixture regression tests for first-page and pagination relevance.

Validation pending: GitHub native builds and UI/unit tests, device performance, and taste quality on personal favorites. This draft has NOT been verified.

The previous v0.8.5 run 39428498185 compiled and packaged but native tests were skipped at the private Drive IPA upload gate. It must not be labeled VERIFIED.

## Recommendation relevance / Dislike follow-up

- Pairs character/artist and medium when supported by explicit taste or co-liked tags, reducing unrelated broad 3D results.
- Canonical local exclusions catch chosen tag variants (including the furry family) in provider results, first-page, and pagination; no fuzzy blanket blocking.
- Dislike immediately removes the card and records negative tag evidence; a bounded queue analyzes the disliked still thumbnail later while idle, never during active playback. Existing cache is reused and fallback fetches are limited to small Wi-Fi thumbnails.
- Learned visual similarity and metadata attributes reduce future ranks. For liked characters/artists, negative image feature prints remain contextual to the disliked presentation, not an automatic character blacklist. This does not infer the user's exact reason for disliking a post.
- Regression tests cover interest pairs, variant exclusions, visual-context dislikes.
- Source only: NOT VERIFIED pending native Xcode tests, IPA gate, and personal taste accuracy/device performance.
