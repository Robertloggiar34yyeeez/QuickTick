# QuickTick native iOS status — 25 October 2026

Current source on `main`: **v0.9.9 (build 29)**, commit `d4decb3f59c2afa01d102d40239aaadf5baec6b9`.

The [Native iOS build and IPA workflow](https://github.com/Robertloggiar34yyeeez/QuickTick/actions/runs/40188749487) completed successfully on October 25, 2026. It archived the iPhone application, packaged an unsigned IPA and ran iPhone/iPad automated tests. Its `native-test-results` artifact supplied synthetic iOS Simulator screenshots for the public README.

Status and caveats:
- SwiftUI/UIKit application targeting iOS 17+; current project settings identify version 0.9.9, build 29.
- Home, Immersive, Downloads, Visual Taste, Rhythm, floating playback, theming, profile export and Create features are present in source.
- This workflow does not prove real-device memory use, inference speed, model/LoRA compatibility or live third-party provider availability. Test those on physical iPhone/iPad hardware.
- The packaged IPA is unsigned and requires end-user signing/sideloading. CI artifacts have a limited retention period.
- Credentials, personal profile data, private media and local export paths are intentionally excluded from this status document.
