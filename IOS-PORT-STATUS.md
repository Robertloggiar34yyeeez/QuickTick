# IOS-PORT-STATUS - Quicktick native iOS 0.6.24 build 4

2026-10-05, Europe/Berlin. Native simulator tests, real iPhoneOS archive and unsigned IPA packaging succeeded on GitHub Actions. Re-signing is required before installation using the user's chosen AltStore/Sideloadly.

## Final user-requested behavior
- Black native canvas and near-black surfaces. Gradients appear on buttons only; no gradient canvas, media placeholder or provider-label decoration remains.
- Four bottom icons: Home, Immersive, Favorites, Downloads. Settings opens from the top-right sliders button. Home has Recommended/Popular/Recent ordering, Refresh and scroll-to-top.
- Opaque 1024px Q/checkmark app icon, wired through an asset catalog and verified in the compiled IPA.
- Immersive has fixed viewport-sized pages, centered content/header and paging snap. Right-side Like/Less/Comments/Download/Mute controls have independent frosted circular surfaces. Tags stay hidden until View tags.
- Thin elapsed-progress track with a 44-point touch region, absolute seeking, drag time labels and accessible adjustments. Double tap likes idempotently with a heart pulse; single tap pauses; GIFs also respect pause.
- Bounded previous/next-three poster caching and player prewarming. A blurred actual poster covers the viewport before the video layer has a displayable frame; black remains the fallback if no poster is available. No universal network latency guarantee is made.
- Audio uses playback/moviePlayback so the silent switch does not silence video. The older implicit mute default is cleared once on upgrade, then explicit choices persist.
- Home video/GIF cards play inline when tapped and preserve natural aspect. One card owns playback; scrolling away, leaving Home or entering Immersive stops it.
- Normal previews prefer the larger sample over small thumbnails, preserve natural aspect and decode up to 2048 pixels for ordinary images. Very tall comics use a bounded preview of top panels; tapping opens the original image with width-fit vertical scrolling, pinch zoom and X to close. Tile drawing uses immutable image data on Core Animation worker threads; the simulator regression caught and verified the fix for the initial actor-isolation crash.
- No ten-post cap. Home and Immersive share a consistent page cursor, skip duplicate/filtered pages, deduplicate within/across batches including removed posts, and offer Load more on stalls. Opening Immersive preserves the current page; Less advances rather than returning to the first item. Pagination continues while the provider reports more data; it cannot create unavailable upstream posts.
- Sync credential imports populate live Settings fields, including Remember off. Remembered Pornhub username is restored. Sync remains encrypted and serialized, with actionable errors and no insecure fallback.

## Actually executed verification
- Repository https://github.com/Robertloggiar34yyeeez/QuickTick, main; tested native commit 94bb4e567e158584d80325c3ce8b18748e9c44d8.
- GitHub run https://github.com/Robertloggiar34yyeeez/QuickTick/actions/runs/37265988154.
- Xcode 26.6 (17F113), minimum iOS 17, Swift 6; 29 unit tests and 6 UI tests, zero failures.
- Simulator signing uses CODE_SIGNING_ALLOWED=YES, CODE_SIGNING_REQUIRED=YES, CODE_SIGN_IDENTITY=-, CODE_SIGN_STYLE=Manual and Simulator.entitlements. Real Keychain storage and encrypted login-fill are tested.
- Release archive uses generic/platform=iOS with signing disabled, as explicitly requested; actual arm64 executable packaged in the IPA.
- Provider pagination regression supplies ten items, a duplicate-only page and a new batch. It verifies advancement beyond ten without duplicate IDs. Preview selection avoids video URLs as poster images.
- UI fixtures validate controls and lifecycle; they do not validate live AV playback, sound or huge-image device memory. Passing screenshots, full Xcode test/archive logs and xcresult bundle are included.
- Portable project audit and Swift syntax checks pass. The independent AES-GCM vector and synthetic live API get/put/get round trip passed on 2026-10-04; the latter used no personal credentials/profile and is historical evidence, not a new 2026-10-05 account-authentication test.

## IPA and exact-source verification
- QuickTick-0.6.24-unsigned.ipa, 633999 bytes; SHA-256 a6e33737ab84afc3911ba81cf598b9b48df2f51c784a4b39d2f415499f45222d.
- ZIP integrity, runner checksum, artifact ZIP digest, iPhoneOS/arm64, bundle ID, configured API, build 4, compatibility flag and compiled app icon are independently checked.
- No Apple certificate, provisioning profile, private key, provider password or Gorse server secret is committed. Keychain stores the Sync identity and remembered credential/session material; ordinary state excludes secrets. DEBUG media/sync fixtures are excluded from Release.
- Original pre-replacement HEAD 79dde743f5aad6bf98eba29ab57756c3578ce28e remains in repository history. These changes continue that main branch; no fork or alternative repo was used.
- Final report tip is recorded in the delivery manifest; only docs/tooling differ from the tested native commit. Source files including binary icon bytes are checked against Git blob hashes.
- Unique revision in E:/Meine Ablage/QuickTick iOS Revisions includes the verified IPA, exact source/ZIP, master prompt, reports, screenshots and logs. Size and SHA-256 match for every copied file. Earlier revisions remain intact. Google's server-side synchronization is not observed.

## Practical limits
No physical iPhone was available. Sound, live stream quality, frame transitions, network latency, huge-comic memory, background/HLS downloads and full airplane-mode/offline playback require device verification. Gorse live behavior and real provider-account acceptance remain unverified. The previous read-only deployment probes returned Rule34 401 without credentials, RedGIFs 200 with 26 posts, Eporner 200 with 40 posts, Pornhub 200 with zero posts and Hanime 502 upstream failure; no server changes were made in this native revision. No CAPTCHA, DRM, account/access-control, geo or premium bypass was added.

## Delivery location and commands

Exact mounted Drive destination: E:/Meine Ablage/QuickTick iOS Revisions/QuickTick-iOS-0.6.24-REV-20261005-071305

The IPA hash above is verified at this destination by the delivery script. Source ZIP SHA-256 and final documentation commit SHA are recorded in manifest.json and DELIVERY-VERIFICATION.json, avoiding a self-referential source archive hash.

Executed workflow commands: `xcodebuild -project ios-starter/QuicktickNative.xcodeproj -scheme QuicktickNative -destination platform=iOS\ Simulator,id=$DEVICE CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual -parallel-testing-enabled NO -resultBundlePath logs/QuicktickTests.xcresult test`; `xcodebuild -project ios-starter/QuicktickNative.xcodeproj -scheme QuicktickNative -configuration Release -destination generic/platform=iOS -archivePath build/QuicktickNative.xcarchive CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES=YES archive`. The workflow uses shell-quoted destination values; see .github/workflows/ios.yml for exact executable syntax.
