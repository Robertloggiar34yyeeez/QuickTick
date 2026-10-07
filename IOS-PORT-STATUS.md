# Native iOS status — 7 October 2026

QuickTick remains native SwiftUI/UIKit, iOS 17+, Swift 6, iPhone/iPad. Vercel API and Sync v1 contracts are preserved.

The latest completed Mac validation passed 44 unit tests and six of seven iPhone UI tests, including Home playback after returning from Immersive and Home/Recommended switching. The remaining rotation test now uses short directed drags instead of full-screen swipes that overshot the native-size video.

The immersive progress bar now has a transparent container and thin translucent track. Actual seeking, accessibility adjustments and the 44-point touch area are preserved.

Run 37642679045 failed at startup before a Mac runner was assigned. GitHub reported an unexpected internal error, and the failed-jobs retry API rejected the retry. No new IPA has been produced. A fresh workflow run must pass iPhone/iPad tests and unsigned release archiving before delivery.

The exact source for commit 311219792b1c3c4078029d52f1eec36cafd4869c was uploaded to the QuickTick iOS Revisions Drive folder, downloaded back and checksum verified. Real-device audio, slow provider networks and sustained memory/battery measurements remain pending.
