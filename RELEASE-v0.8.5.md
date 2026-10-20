# QuickTick v0.8.5 — Home action hit bounds (build 21)

Fixes a reported Home bug where tapping Dislike could open the image in the next card. SwiftUI clipping hides overflowing image pixels but does not constrain their hit targets. Media rendering now ignores touches; a separate, frame-bounded image tap overlay opens full view, while action buttons retain independent hit targets. The fix applies to Home, Favorites and Downloads cards without changing media loading, playback, saved data or recommendation signals.

Adds a coordinate-tap UI regression with a video above a tall image: Dislike must remove the upper post and must not open the lower image. Existing visual taste and playback regression coverage remains. See v0.8 notes for WD Tagger v3, Vision and model limitations. Previous v0.7.5/v0.8 names and artifacts remain intact.

The v0.8.5 IPA must be uploaded privately before this revision's simulator tests, then replaced in place after validation passes. Runtime and physical-device performance are not inferred from syntax or archive checks.
