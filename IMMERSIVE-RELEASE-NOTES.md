# Quicktick 0.6.24 build 4 changes

Immersive uses fixed viewport-sized pages with paging snap, a truly centered header, a vertical right-side Like/Less/Comments/Download/Mute rail, manually frosted surfaces and a thin elapsed-progress timeline. Dragging seeks to an absolute position and shows time labels; a wider invisible touch target keeps the track usable. Double tap likes idempotently and shows a heart pulse, while single tap pauses. Native GIFs respect pause.

A bounded shared preview cache warms the previous and next three posters. The actual poster is blurred across the viewport while the video awaits its first frame; black remains the fallback if the provider has no usable poster. No preview can be guaranteed when the source supplies none or the network has not fetched it.

Audio uses AVAudioSession playback/moviePlayback so the hardware silent switch does not mute video. Sound defaults on. The first upgrade clears the older implicit mute value; subsequent explicit choices persist.

Opening Immersive preserves the current page and no longer resets the feed to page one. Home and Immersive share a consistent provider page size/cursor. Pagination starts before the last post, deduplicates inside/across batches (including removed posts), skips up to five duplicate/filtered pages per attempt, and offers Load more on stalled/error responses. There is no ten-post cap. Available provider pages are followed until the server reports exhaustion; the app cannot manufacture more upstream posts.

Normal feed images prefer the larger sample preview; other media prefer an image preview over the small thumbnail, avoiding video URLs as posters. Loaded media preserves its natural aspect ratio instead of being forced into a 4:3 frame. Very tall strips use a bounded preview of the top panels, with a Comic preview label. Empty/loading placeholders alone use 4:3.

Home cards play videos and GIFs inline when Play is tapped. Only one card owns inline playback; pausing, scrolling away, switching tabs and entering Immersive release or stop it. Video dimensions are loaded independently after playback starts and retain the natural aspect ratio.

Tap an image or View full to load its original resolution in a full-screen comic viewer. The viewer fits to width, scrolls vertically, supports pinch zoom, and has a persistent X close button. ImageIO keeps the source uncached; CATiledLayer draws visible regions rather than one whole-strip backing bitmap. Large original-image memory and responsiveness still need physical-device verification.

Verification for this build is recorded in GITHUB-BUILD-STATUS.md. Physical sound, source-specific stream quality and network latency still require an iPhone check. Existing account-dependent and unavailable upstream providers are documented in IOS-PORT-STATUS.md.

## Black design and icon - build 4

The native canvas is black, with subtle near-black surfaces and white borders. Gradients are limited to buttons. Bottom navigation has four evenly distributed icon buttons in screenshot order: Home, Immersive, Favorites, Downloads. Settings opens from the top-right sliders button on the main screens. Home includes Recommended/Popular/Recent ordering, Refresh, and a persistently available floating scroll-to-top button; the floating-search layout no longer changes automatically as the scroll offset crosses a threshold. Immersive uses individual frosted circular controls on the right. Tags remain hidden behind View tags.

A new opaque 1024px Quicktick Q/checkmark icon is included in the app asset catalog, with a violet-to-blue mark and white check on black. It is generated from simple code-defined geometry, and the compiled icon is checked in the IPA.
