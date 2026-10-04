# Quicktick Sync Compatibility Contract

The native app must read/write the same encrypted cloud record as web Quicktick 0.6.24.

## Sync ID

`QT6-<recordId>.<secret>`

- `recordId`: 16 random bytes encoded base64url without `=` → 22 chars.
- `secret`: 32 random bytes encoded base64url without `=` → 43 chars.
- Full regex: `^QT6-([A-Za-z0-9_-]{22})\.([A-Za-z0-9_-]{43})$`

Treat the full Sync ID like a password.

## Key derivation

No PBKDF is used in the existing web format. Compatibility requires these exact SHA-256 inputs:

- AES key = `SHA256( UTF8("quicktick-sync-encryption-v1:") || rawSecret32 )`
- verifier = base64url-no-padding(`SHA256( UTF8("quicktick-sync-verifier-v1:") || rawSecret32 )`)

## AES-GCM

- Algorithm: AES-256-GCM
- Nonce/IV: 12 random bytes
- AAD: UTF8(`Quicktick:<recordId>:v1`)
- Envelope:
  - `v: 1`
  - `alg: "A256GCM"`
  - `iv`: base64url 12-byte nonce
  - `data`: base64url(`ciphertext || 16-byte authenticationTag`)

CryptoKit exposes ciphertext/tag separately; concatenate them for web output and split the final 16 bytes when reading a web envelope.

## Vercel API

POST `<QUICKTICK_API_BASE_URL>/api/sync` JSON:

Get: `{ "action":"get", "id":recordId, "verifier":verifier }`

Put: `{ "action":"put", "id":recordId, "verifier":verifier, "payload":envelope }`

The server only receives record ID, one-way verifier and encrypted payload. It never receives the raw secret.

## Snapshot schema v1

Keep the existing top-level fields: `version`, `updatedAt`, `favorites`, `favoriteMeta`, `rule34`, `pornhub`, `exclusions`, `preferences`.

Downloads are intentionally not part of v1 cloud sync. Do not add local paths or media bytes to this snapshot.

## Merge behavior

- Favorites: merge per post using `favoriteMeta[key].updatedAt`; newer metadata wins, including unlikes.
- Rule34 auth: compare `rule34.updatedAt`; remote can also populate an empty local credential state.
- Pornhub session: compare `pornhub.updatedAt`; remote can populate empty local state. Password is never present.
- Exclusions: newer `exclusions.updatedAt` wins.
- Preferences/onboarding: newer `preferences.updatedAt` wins.

Use `reference-tests/sync-vector-v1.json` as a deterministic cross-language test vector.
