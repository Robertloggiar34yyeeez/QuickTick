# Codex Master Prompt — Quicktick Native iOS 0.6.24

Continue this project from the supplied handoff. **Do not restart the architecture, do not replace it with a WKWebView wrapper, and do not discard working starter code.** The goal is a genuinely native iPhone/iPad Quicktick app that matches the effective Quicktick web behavior through **0.6.24**.

The handoff contains:
- `reference-web/` — reconstructed effective Quicktick web source through 0.6.24. This is the behavior/API source of truth.
- `ios-starter/` — native SwiftUI starter with API, Sync crypto, recommendation engine, optional Gorse bridge, downloads scaffolding and tests.
- `reference-tests/` — deterministic cross-language Sync vector and recommendation contract notes.
- architecture/provider/sync/download/Gorse documentation.

## Primary goal

Build and finish a native Swift/SwiftUI app using SwiftUI, AVFoundation/AVKit, URLSession, CryptoKit, Security/Keychain and normal Apple persistence APIs. Preserve the existing Quicktick Vercel backend and API contracts. The native app must work when Gorse is not configured and automatically gain collaborative hints when Vercel `/api/recommend` has Gorse configured.

## Non-negotiable backend boundary

1. The iOS app talks to the existing Quicktick Vercel deployment configured by `QUICKTICK_API_BASE_URL`.
2. **Never embed `GORSE_API_KEY`, `GORSE_ENDPOINT`, Vercel private environment variables, provider passwords, or other server secrets in the iOS binary.**
3. iOS recommendation collaboration goes only through `POST /api/recommend`. Vercel owns the Gorse secret and contacts Gorse.
4. If `/api/recommend` is unavailable, disabled, times out or returns `available:false`, keep the local 0.6.24 recommender working without a fatal error.
5. Do not invent a second incompatible backend.

## Quicktick Sync compatibility — do not break existing web IDs

Keep the existing `QT6-<recordId>.<secret>` format exactly compatible with `reference-web/app.js` and `/api/sync`.

Required crypto contract:
- recordId = 16 random bytes, base64url without padding (22 chars)
- secret = 32 random bytes, base64url without padding (43 chars)
- AES key = SHA256(UTF8(`quicktick-sync-encryption-v1:`) || rawSecret32)
- verifier = base64url-no-padding(SHA256(UTF8(`quicktick-sync-verifier-v1:`) || rawSecret32))
- AES-256-GCM, 12-byte nonce
- AAD = UTF8(`Quicktick:<recordId>:v1`)
- envelope `data` = ciphertext || 16-byte GCM tag, base64url without padding
- envelope fields remain `v`, `alg`, `iv`, `data`
- `/api/sync` JSON contract remains unchanged

Treat the full Sync ID like a password. Store it in Keychain and never log it. Keep snapshot schema version 1 and preserve existing merge semantics for `favorites`, `favoriteMeta`, `rule34`, `pornhub`, `exclusions`, and `preferences`. Never sync provider passwords. Do not add downloaded media bytes or local file paths to Sync v1.

Use `reference-tests/sync-vector-v1.json` to prove web/iOS crypto compatibility.

## Recommendation system — Quicktick 0.6.24 behavior

Do not replace this with a generic random/category feed. Use the supplied `RecommendationEngine.swift` as the starting point and align it with `reference-web/app.js` functions around `signalTerms`, `themeSignatures`, `recordTermEvidence`, `recordExplicitSearchPreference`, `effectiveTermScore`, `isHardDisliked`, `recommendationScore` and `rankRecommendedPosts`.

Required semantics:
- recommendation profile is provider-specific;
- Like and Download are strong positives;
- Replay and completion are positive;
- watch time contributes progressively;
- explicit searches strengthen positive query terms;
- `-excluded` searches strengthen negative evidence;
- Less and fast skip are negative, but negative evidence is distributed across the post terms so one Less does **not** hard-blacklist every incidental co-tag;
- repeated common negative denominators accumulate until they can become hard Recommended filters;
- one-time onboarding `Not Into` is a hard filter;
- repeated strong negative theme evidence is a hard filter;
- seen posts are heavily suppressed;
- consecutive posts sharing too many terms get a strong anti-clumping penalty;
- controlled exploration/related terms should remain small, not random flooding;
- Favorites browsing must not passively train recommendations.

Concrete acceptance behavior:
- repeated positive interactions/searches around `samus_aran` should increase Samus-like posts;
- repeated Less on posts whose shared denominator is `scat` should suppress `scat` more strongly than unrelated co-tags;
- a single Less on `scat + blue_hair + outdoors` must not by itself hard-ban all `blue_hair` or `outdoors` content.

Persist local recommendation state across restarts. Keep local recommendation state local unless a future backwards-compatible sync schema is explicitly designed.

## Optional Gorse hybrid layer

`reference-web/server/routes/recommend.js` is the API contract. `RecommendationBridge.swift` already derives the same pseudonymous Gorse identity as web:

`qtg_` + first 43 base64url chars of SHA256(UTF8(`quicktick-gorse-user-v1:<recordId>`))

The full QT6 secret must never be sent to Gorse. The native app sends only the pseudonymous `userId` to Vercel `/api/recommend`.

Required actions:
- `rank`: send up to 40 candidate items plus top positive/negative terms; use returned `scores` only as a collaborative hint;
- `feedback`: map impression→`impression`, Like→`like`, Unlike→`unlike`, Download→`download`, replay→`replay`, completion→`complete`, quick skip→`skip`, Less→`less`, watch→`watch` with seconds;
- `reset`: reset the pseudonymous Gorse profile through Vercel as well as local recommendation state.

Collaborative scores are never allowed to override explicit exclusions, Not Into, recurring hard negative filters or seen suppression. If Gorse is down, use the local engine.

## Native product requirements

Implement/finish:
- native X/Twitter-style Home feed;
- native TikTok-style vertical Immersive feed;
- native Home ↔ Immersive transition/animation;
- provider switcher for Rule34, RedGIFs, Pornhub, Eporner, Hanime.tv;
- endless pagination/infinite scroll;
- multi-term search and `-excluded_tag` syntax;
- floating search while scrolled;
- Immersive search remains a vertical Immersive results feed;
- tapping a tag offers Add to search and Exclude from search;
- Favorites;
- Less;
- comments sheet;
- Suggested Topics;
- persistent exclusions;
- prominent learned interests in Settings;
- one-time per-provider Into / Not Into onboarding with preview images;
- Original / Immersion framing modes;
- Immersive single-tap pause/resume;
- double-tap Like;
- no Stop button;
- wide scrub gesture;
- mute/unmute;
- anti-black-flash playback transition: retain poster/current rendered frame until replacement is ready;
- bounded player/item pool around the active Immersive index.

Hanime behavior: when a new Hanime item has no saved resume position and duration allows it, start around 3:00; a saved resume position always wins. Never bypass CAPTCHA, Cloudflare challenges, age verification, geo restrictions, premium restrictions, account restrictions, DRM or other provider controls.

## Provider rules from current web 0.6.24

Use Vercel provider routes as the default integration layer so the iOS app inherits web fixes.

### Rule34
- `/api/rule34`
- `/api/comments`
- send `x-r34-user` and `x-r34-key` when configured;
- preserve Rule34 tag semantics and autocomplete where available.

### RedGIFs
- Do **not** prefer a raw RedGIFs CDN URL for playback.
- Use the Quicktick/Vercel RedGIFs media path (`/api/redgifs-media`) because 0.6.23 fixed playback by routing validated media requests through the server proxy.
- Keep Range-compatible playback/download behavior.

### Pornhub
- use Quicktick Vercel routes;
- use `x-ph-session` only for supported saved session state;
- never fake login success or bypass provider restrictions;
- never sync passwords.

### Eporner
- use `/api/eporner` and `/api/eporner-media`;
- pre-resolve/prewarm upcoming Immersive items to reduce delay;
- do not mark media ready until a real resolver result exists.

### Hanime.tv
- use the current server-first public search/catalog flow from `reference-web/server/routes/hanime.js`;
- use `/api/hanime-media` for playback resolution;
- do not restore old blocked `/api/v8/browse*` probes as a normal path;
- do not add anti-bot/access-control bypass logic;
- if a public route is blocked, report it honestly and keep other providers functional.

## Native downloads / offline feed

Downloads must be actual app-owned files/packages, not a browser link.

Direct media:
- use a background-capable `URLSession` download configuration;
- move completed media into app-owned persistent storage;
- persist progress/state/metadata and thumbnail locally.

HLS:
- for ordinary non-DRM HLS where offline storage is permitted, implement `AVAssetDownloadURLSession` / `AVAggregateAssetDownloadTask`;
- persist the resulting package URL;
- never circumvent FairPlay/DRM/provider restrictions.

UI:
- Downloads feed;
- Offline Immersive feed using only local files/packages;
- pause/resume/cancel/retry/delete where supported;
- offline thumbnails;
- delete removes both metadata and local media;
- successful download emits the normal positive recommendation signal;
- local video bytes and local paths never go into Quicktick Sync.

## Persistence/security

Use Keychain for:
- full Quicktick Sync ID;
- Rule34 credentials when user chooses remember;
- supported provider session material.

Use durable versioned app storage for:
- favorites metadata and timestamps;
- exclusions and timestamps;
- onboarding/preferences and timestamps;
- recommendation profiles/evidence/seen history;
- settings;
- playback resume positions;
- download metadata.

Add migration handling rather than silently deleting older local state.

## Tests that must exist/pass

Unit tests:
- query parser: positives + `-exclusions`;
- QT6 parsing/generation;
- deterministic AES-GCM web compatibility vector;
- sync merge semantics;
- recommendation Samus/common-positive behavior;
- one Less does not poison unrelated co-tags;
- recurring negative common denominator becomes hard-filterable;
- collaborative Gorse score cannot override Not Into;
- stable pseudonymous Gorse user ID does not contain the QT6 secret;
- provider response normalization using fixtures;
- local download metadata persistence/deletion.

UI/integration tests where feasible:
- Home → Immersive → Home;
- pause/resume;
- double-tap Like;
- Less;
- tag Add/Exclude menu;
- comments sheet;
- floating search;
- Immersive search remains vertical;
- onboarding runs once per provider;
- Downloads → Offline Immersive.

Run `xcodebuild` on macOS with a current Xcode/iOS SDK. Do not claim a build/test passes unless it actually ran. Fix correctness warnings. Provider live-network checks should be separate from deterministic unit tests.

## Build/project rules

You may use the supplied XcodeGen `project.yml`, generate `QuicktickNative.xcodeproj`, or replace it with an equivalent native Xcode project. Keep clean logical modules: Models, API/Networking, Sync/Crypto, Recommendations, Media/Player Pool, Downloads, Persistence, Views, Tests.

Only `QUICKTICK_API_BASE_URL` belongs in the app config. Gorse server credentials remain in Vercel/server environment variables.


## GitHub source-control workflow — required

Use this exact repository as the native iOS app repository:

`https://github.com/Robertloggiar34yyeeez/QuickTick`

Repository full name: `Robertloggiar34yyeeez/QuickTick`

This is an explicit destructive replacement of the repository's **current tracked contents**. Do not create a different Quicktick iOS repository and do not keep the old application files alongside the native iOS app. Preserve Git history, but make the repository's current/default-branch contents iOS-only.

Required workflow:
1. Clone/open `Robertloggiar34yyeeez/QuickTick` using my connected/authenticated GitHub access. Confirm the remote URL before changing files.
2. Record the pre-replacement branch name and HEAD commit SHA in `IOS-PORT-STATUS.md` so the previous state remains identifiable in Git history.
3. Remove the existing tracked project contents from the working tree, except `.git/` itself. Do not delete/recreate the GitHub repository and do not rewrite/purge historical commits.
4. Replace the working tree with the supplied native Quicktick iOS handoff and the finished native iOS project. The new default-branch tree should contain the iOS project/source, tests, documentation, `.gitignore`, status report and other iOS build files—not the previous web project.
5. Do not preserve stale web build artifacts or unrelated old app files just because they existed in the repo. The `reference-web/` folder from this handoff may remain only as a development/API behavior reference if useful to the native port; it must not become the shipped app implementation.
6. Use native Swift/SwiftUI/AVFoundation code as required by this prompt. A WKWebView wrapper is not acceptable.
7. Commit the destructive replacement clearly, for example: `Replace repository contents with native Quicktick iOS app`. Then make additional meaningful commits for completed iOS work as appropriate.
8. Push the completed native iOS revision to `Robertloggiar34yyeeez/QuickTick`. The final pushed default branch should represent the current native iOS app revision.
9. If permissions/authentication prevent deletion, commit, or push, do not claim success. Leave the local iOS project complete and report the exact GitHub limitation.
10. Never commit secrets: no full `QT6-...` Sync IDs, no Rule34 credentials, no Pornhub session secrets, no `GORSE_API_KEY`, no provider passwords, no signing certificates/private keys, and no local `.env` secrets. Add appropriate `.gitignore` entries.
11. Include the final repository URL, branch, pre-replacement HEAD SHA, final commit SHA, and push result in `IOS-PORT-STATUS.md`.

Do not fork the repository and do not create a separate `QuickTick-iOS` repository unless I explicitly change this instruction later.

## Google Drive revision delivery — required

After the native iOS revision is built/tested as far as the current machine allows, copy the final revision artifacts into this exact Google Drive-synced Windows folder:

`E:\Meine Ablage\QuickTick iOS Revisions`

Create the folder if it does not exist and the current machine has access to drive `E:`. Use a unique revision subfolder, for example:

`E:\Meine Ablage\QuickTick iOS Revisions\QuickTick-iOS-0.6.24-REV-YYYYMMDD-HHMMSS`

The revision folder should contain, when available:
- the complete native Xcode project/source tree;
- a source ZIP of that exact revision;
- `IOS-PORT-STATUS.md`;
- build/test logs;
- the effective Codex master prompt used for the revision;
- a manifest containing Git commit SHA, file sizes and SHA-256 hashes;
- any installable `.ipa`/archive only if it was actually produced and is legally/signing-wise usable; do not fabricate one.

After copying, verify the Drive destination actually exists, compare source/destination file sizes, and verify SHA-256 for the main ZIP and any produced app/archive. Report the exact Drive path and verified hashes in `IOS-PORT-STATUS.md`.

If the Codex environment does not have access to `E:` or the Google Drive desktop mount, **do not claim an upload/copy occurred**. Keep the deliverables ready locally/GitHub and report that Drive access is unavailable. Do not substitute a different cloud location unless I explicitly ask.

## Completion report

Before finishing, create/update `IOS-PORT-STATUS.md` from the template. Include exact build/test commands and results, real-device-only work, sync compatibility, recommendation mode/fallback status, download/offline status and provider-by-provider status. Clearly label placeholders or unresolved provider restrictions.

## Deliverable discipline

Work on the actual supplied files and produce a buildable project. Do not only describe code. Prefer a working vertical slice over fake placeholders. Preserve working contracts from `reference-web/`. Do not fabricate provider login/media availability. Do not bypass provider security/access controls.
