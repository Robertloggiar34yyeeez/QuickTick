# Native Download / Offline Feed Requirements

The web app records downloads but cannot provide the same persistent in-app experience as a native app. The iOS port should make this a first-class native feature.

## Direct files

Resolve an accessible direct media URL through the same provider/media endpoints used by web. Use background-capable URLSession downloads where practical. Move successful files from the temporary URL into an app-owned persistent directory such as `Application Support/Quicktick/Downloads/<provider>/<postKey>/`.

Persist a local thumbnail copy in the same record/directory so the Downloads feed works offline.

## HLS

For non-DRM HLS that the provider permits to be stored normally, use `AVAssetDownloadURLSession` / `AVAggregateAssetDownloadTask`. Persist the asset package location. Never attempt to remove DRM or bypass access restrictions.

## Offline UI

Downloads must be viewable inside Quicktick in two ways:

1. **Downloads Feed** — normal scrolling cards with thumbnail, provider, tags/title, progress/state, play, retry/delete.
2. **Offline Immersive** — TikTok-style vertical feed backed exclusively by downloaded local file URLs / HLS asset packages. It must work in airplane mode.

Use the same pause/resume/double-tap-like/scrub/mute behavior where meaningful. Likes should still update Favorites and recommendations while offline, then cloud-sync those supported fields later.

## Sync boundary

Cloud sync should continue to sync Favorites/exclusions/preferences/supported auth state only. Do not upload local video files, local URLs or downloaded HLS packages. Keep download metadata local unless a future versioned, backwards-compatible cloud schema is explicitly introduced.
