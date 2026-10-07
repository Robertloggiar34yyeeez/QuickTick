# Gorse Hybrid Contract for iOS

The iOS app never connects to Gorse directly and never stores a Gorse API key.

Flow:

`iOS app -> Quicktick Vercel /api/recommend -> Gorse (optional)`

Only Vercel has `GORSE_ENDPOINT` and `GORSE_API_KEY`.

The pseudonymous recommendation user ID must match web:

`qtg_` + first 43 base64url-no-padding characters of SHA256(UTF8(`quicktick-gorse-user-v1:<recordId>`))

`recordId` is the non-secret 22-character record portion of the QT6 Sync ID. The raw 32-byte QT6 secret is never sent to Gorse.

Actions are defined in `reference-web/server/routes/recommend.js`:
- `rank`: candidate items + top positive/negative terms -> optional score hints
- `feedback`: impression/like/unlike/download/replay/complete/skip/less/watch
- `reset`: delete/reset the pseudonymous recommendation user

Gorse score is additive only. Local explicit Not Into, excluded terms, recurring hard negatives and seen suppression must still filter first.

Failure is soft: disabled/unavailable/timeout must fall back to local 0.6.24 recommendation logic.
