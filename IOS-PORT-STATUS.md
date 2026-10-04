# IOS-PORT-STATUS — Quicktick native iOS 0.6.24

2026-10-04, Europe/Berlin. Native simulator build/tests and iPhoneOS archive succeeded on GitHub Actions. A real unsigned arm64 IPA was produced and independently verified. User explicitly selected AltStore/Sideloadly signing; re-signing is required before installation.

## Repository/history
- Repository: https://github.com/Robertloggiar34yyeeez/QuickTick
- Branch: main.
- Pre-replacement branch: main.
- Pre-replacement HEAD: 79dde743f5aad6bf98eba29ab57756c3578ce28e.
- Replacement commit: d44da263005edc949e7b99212e50a99860ceedb2; original HEAD retained as parent.
- Tested/native-build commit: 3c61acb33c7350e3340dc50ad04d64284bc6c13a.
- Push result: SUCCESS through authenticated GitHub Git-data API, fast-forward main; history preserved. Old tracked project tree replaced by native project, tests, documentation and build scripts. No alternative repository or fork created.
- The earlier GitHub access failure is resolved. Shell Git still lacks credentials; plugin/API access works.
- Final report/delivery commit is recorded in the delivered manifest; its changes are documentation and delivery tooling only, with no changes to the tested native app/tests.

## Build and tests — actually executed
- GitHub run: https://github.com/Robertloggiar34yyeeez/QuickTick/actions/runs/37215246057
- Runner: macos-latest; Xcode 26.6, build 17F113. Source minimum iOS 17, Swift 6.
- Test command: `xcodebuild -project ios-starter/QuicktickNative.xcodeproj -scheme QuicktickNative -destination "platform=iOS Simulator,id=$DEVICE" CODE_SIGNING_ALLOWED=NO -parallel-testing-enabled NO -resultBundlePath logs/QuicktickTests.xcresult test`
- DEVICE is the available iPhone selected by the workflow; the resolved exact command/UDID is in logs/github-xcodebuild-test.txt.
- Result: TEST SUCCEEDED. 20 unit tests and 1 navigation UI test; zero failures.
- Archive command: `xcodebuild -project ios-starter/QuicktickNative.xcodeproj -scheme QuicktickNative -configuration Release -destination 'generic/platform=iOS' -archivePath build/QuicktickNative.xcarchive CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES=YES archive`
- Result: ARCHIVE SUCCEEDED. Actual iPhoneOS arm64 executable packaged into Payload/QuicktickNative.app; archive was produced on the runner, IPA downloaded locally. Archive package itself is not included in delivery.
- Unit coverage: packaged API URL; query parser; QT6 generation/parse and web AES-GCM vector; Sync merges/tombstones/timestamps; Samus positives, one Less/co-tag protection, recurring negatives, hard Not Into versus Gorse; pseudonymous identity and unavailable-Gorse fallback; provider fixtures; local/download persistence/deletion and migration.
- UI coverage: Home / Immersive / Home / Downloads / Favorites navigation.
- First attempt exposed missing Debug testability; fixed. Post-download verification of attempt 2 exposed omitted API URL in generated plist; fixed with explicit Config/Info.plist plus bundle configuration test and packaging assertions. That earlier IPA was withheld from delivery.
- Remaining log warnings are Apple's skipped AppIntents metadata extraction because this app has no AppIntents dependency; no native compile errors remain.
- Portable crypto, Swift syntax and OpenStep project audits also pass. They supplement the now-executed Xcode checks.

## IPA/config verification
- File: QuickTick-0.6.24-unsigned.ipa.
- Size: 362363 bytes.
- SHA-256: 55ef499a1fba23421c96b491e5eb549514902dbf496a4dc80cabad9ceb383cb6.
- Downloaded GitHub artifact ZIP SHA-256: f45099144074a418e3499f2fdd7229eddb4092a729fb36d148b0a1a51187c184, matches GitHub's artifact digest.
- Bundle identifier: com.quicktick.QuicktickNative; version 0.6.24; minimum OS 17.0.
- Verified actual Mach-O arm64 executable and iPhoneOS supported platform, valid ZIP, matching runner checksum, embedded QUICKTICK_API_BASE_URL=https://quick-tick-webb.vercel.app.
- Signing: unsigned, explicitly requested by user for AltStore/Sideloadly. No certificate/profile/private key supplied or committed; no signing/access-control bypass implemented.

## Native features and remaining verification
- Native SwiftUI Home, vertical Immersive, provider switching, pagination, sticky floating search, multi-term/negative search and Rule34 suggestions.
- Favorites, Less, tag Add/Exclude menus, provider-aware comments, suggested learned interests, per-provider Into/Not Into onboarding with available thumbnails and persistent exclusions.
- AVPlayerLayer surface with poster until readiness, original/fill framing, single-tap pause, exclusive double-tap Like, mute, wide scrub, resume positions, completion/replay/watch feedback and bounded neighbor player/prewarm pool.
- Hanime default 180-second seek only with no saved position and sufficient duration; saved positions take precedence.
- Provider-specific local 0.6.24 recommendation state persists; Gorse uses only Vercel /api/recommend and pseudonymous identity. Tests prove local fallback and hard filters; live Gorse behavior remains untested.
- QT6 remains in Keychain; AES-GCM compatibility vector and merge tests now pass in CryptoKit/XCTest. Encrypted pull/merge/push is implemented. Live web/native Sync round trip remains untested.
- Remembered provider credentials/session use Keychain. No provider passwords or Gorse server secrets in native config/source. Ordinary local state omits credential/session material. Sync excludes local file URLs, downloads, media bytes and recommendation state.
- Direct background URLSession downloads and ordinary permitted HLS via AVAssetDownloadURLSession are implemented with progress/metadata/thumbnails, pause/resume/cancel/retry/delete and completion feedback. Metadata tests pass; background relaunch and HLS/device playback still need a physical-device test.
- Offline Immersive uses local files/packages and posters, with no remote resolution or passive training. Actual airplane-mode/device playback remains unverified.
- Real-device-only work remains: sideload/re-sign/install, gesture/playback quality, anti-black-flash behavior, resolver timing, provider account/session checks, background/HLS operation and full offline flow. No real-device success is claimed.

## Provider checks on existing deployment
- Rule34: HTTP 401 requiring user ID/API key. Native credential/header wiring exists; real account checks pending.
- RedGIFs: HTTP 200, 26 items, hasMore true. Video resolution forces validated Vercel media proxy; native playback/Range/download checks pending.
- Pornhub: HTTP 200 with zero items. Supported session header exists; no fake login or password flow. Catalog availability unresolved.
- Eporner: HTTP 200, 40 items, hasMore true. Resolver/prewarm path exists; native live media checks pending.
- Hanime: HTTP 502, Hanime feed failed: fetch failed. Server-first route retained; upstream failure unresolved. No CAPTCHA/Cloudflare/account/DRM/geo/premium bypass logic added.
- These read-only probes are documented separately from deterministic tests in logs/provider-live-probes.json.

## Drive delivery
- Required mounted destination: E:\Meine Ablage\QuickTick iOS Revisions, unique revision folder.
- Contains corrected IPA, exact GitHub source tree/ZIP, effective r3 master prompt, status/build logs and Git/SHA-256 manifest.
- The exact revision path, final repository tip and successful source/destination size/hash checks are recorded in the manifest and DELIVERY-VERIFICATION.json; actual verified path/hashes are appended to the local/delivered report after copy.
- Mounted-folder copy verification does not prove that Google Drive Desktop finished synchronization to Google's servers.

