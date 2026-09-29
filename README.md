# Quicktick

Native SwiftUI iPhone media browser (iOS 17+). Sources: Danbooru and RedGIFs. The app uses public browsing by default; optional Danbooru login and API key are stored in Keychain. RedGIFs browsing uses its temporary guest token. Likes are local.

## Build

The project is described in `project.yml` for [XcodeGen](https://github.com/yonaskolb/XcodeGen). On macOS with Xcode 16.4:

```sh
brew install xcodegen
xcodegen generate
xcodebuild test -project Quicktick.xcodeproj -scheme Quicktick -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.5' CODE_SIGNING_ALLOWED=NO
```

GitHub Actions runs the same build on `macos-15` and uploads test results and an unsigned archive. A signed IPA requires an Apple Developer team, a distribution certificate, a provisioning profile, and an export options plist supplied through GitHub Secrets. No credentials belong in the repository.

## Current limits

Danbooru limits anonymous tag search; exclusions are filtered locally. RedGIFs account login and remote favorites are not implemented because the verified guest API flow does not provide them. Downloads use URLSession temporary files but do not yet show incremental progress or resume across app termination. The app has not been compiled or tested on a Mac until the GitHub Actions job runs.
