# Native Quicktick 0.6.24

Open `ios-starter/QuicktickNative.xcodeproj` on macOS with current Xcode. The shared QuicktickNative scheme includes the app, deterministic unit tests and navigation UI tests. Minimum deployment: iOS 17; Swift 6.

The API base URL is https://quick-tick-webb.vercel.app. Config xcconfig uses `https:/$()/` to preserve the URL through Xcode's comment parser. Rule34 credentials and supported Pornhub session material are entered in Settings and saved in Keychain. No passwords or Gorse server credentials belong in the app.

Build/test from the source root:

```sh
xcodebuild -project ios-starter/QuicktickNative.xcodeproj -scheme QuicktickNative -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project ios-starter/QuicktickNative.xcodeproj -scheme QuicktickNative -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGNING_ALLOWED=NO test
```

Choose a simulator actually installed in your Xcode if iPhone 17 is unavailable. GitHub Actions selects an available iPhone automatically. Workflow is supplied locally; it has not run or been pushed.

Project generation is optional: `python3 scripts/generate-xcode-project.py` regenerates the checked-in native project deterministically; XcodeGen's `ios-starter/project.yml` is also provided. No WebView implementation is shipped. `reference-web` is development/API reference only.

Portable checks:

```sh
python3 scripts/verify-sync-vector.py
python3 -m pip install --target scripts/parser-deps tree-sitter tree-sitter-swift
python3 scripts/check-swift-syntax.py
```

The crypto check requires Python cryptography. Syntax parsing does not replace Swift type checking or Apple tests. Live provider probes are separate (`scripts/probe-providers.py`). See IOS-PORT-STATUS.md for actual results, remaining verification and delivery limitations.
