# Native Quicktick 0.6.24

Open `ios-starter/QuicktickNative.xcodeproj` on macOS with current Xcode. The shared QuicktickNative scheme includes the app, deterministic unit tests and navigation UI tests. Minimum deployment: iOS 17; Swift 6.

The API base URL is https://quick-tick-webb.vercel.app. Config xcconfig uses `https:/$()/` to preserve the URL through Xcode's comment parser. Rule34 credentials and supported Pornhub session material are entered in Settings and saved in Keychain. No passwords or Gorse server credentials belong in the app.

Build/test from the source root:

```sh
xcodebuild -project ios-starter/QuicktickNative.xcodeproj -scheme QuicktickNative -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project ios-starter/QuicktickNative.xcodeproj -scheme QuicktickNative -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual test
```

Choose a simulator actually installed in your Xcode if iPhone 17 is unavailable. GitHub Actions selects an available iPhone automatically. The workflow is pushed and has passed native simulator tests and an iPhoneOS archive. It produces an unsigned IPA for user-requested AltStore/Sideloadly signing. See IOS-PORT-STATUS.md for the exact tested commit and remaining device checks.

Project generation is optional: `python3 scripts/generate-xcode-project.py` regenerates the checked-in native project deterministically; XcodeGen's `ios-starter/project.yml` is also provided. No WebView implementation is shipped. `reference-web` is development/API reference only.

Portable checks:

```sh
python3 scripts/verify-sync-vector.py
python3 -m pip install --target scripts/parser-deps tree-sitter tree-sitter-swift
python3 scripts/check-swift-syntax.py
```

The crypto check requires Python cryptography. Syntax parsing does not replace Swift type checking or Apple tests. Live provider probes are separate (`scripts/probe-providers.py`). See IOS-PORT-STATUS.md for actual results, remaining verification and delivery limitations.


Revision build 4: black native design, gradient buttons, four tabs, Settings at top right and Home scroll-to-top. Includes the Q/checkmark icon, snapped frosted Immersive controls with blurred previews, elapsed scrubber and double-tap Like; inline Home video/GIF playback and full comic zoom/close; audio-session and pagination fixes; and populated Sync login fields. See IMMERSIVE-RELEASE-NOTES.md and the verified GitHub run in GITHUB-BUILD-STATUS.md. Simulator tests use ad hoc signing and Simulator.entitlements to exercise real Keychain storage. The device IPA remains unsigned.
