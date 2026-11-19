# QuickTick premium UI review notes

## Rollout and data safety

The pre-existing `quicktick-modern-ui-v1` preference now selects **New UI**
(`true`) or **Original UI** (`false`). It remains in `UserDefaults`; there is no
schema migration, database reset, provider credential change or new account
storage. Both interfaces use the same `AppStore`, collections and player APIs.
The selection is available in Settings → Appearance.

## Visual system

- New UI defaults to a neutral ink/panel/raised-panel palette, with the user's
  selected accent used sparingly for active controls. Original UI retains the
  existing palette behavior.
- New UI uses opaque navigation and media controls. It never invokes live
  frosted `Material` or dynamic backdrop blur. Optional user-supplied background
  artwork remains available, with a dark matte overlay for legibility.
- Shared `PremiumPageHeader` and `PremiumSectionHeading` support consistent
  hierarchy. The main tabs retain identifiers and gestures for compatibility.
- Native `Button`, `Picker`, `ShareLink` and SwiftUI accessibility semantics
  are retained, including Reduce Motion support.

## Screens and flows

| Surface | New UI treatment | Preserved behavior |
| --- | --- | --- |
| Home and discovery | Editorial header, matte chips and cards | Provider switching, niches, feed pagination, recommendations |
| Search | Editorial heading, flat inputs/actions | Per-provider filters, autocomplete, search history |
| Immersive/media | Opaque media chrome, active actions | AVPlayer, seeking, fullscreen, gestures, PiP |
| Favorites | Library header, matte collection rows | Filtering, sorting, export, immersive |
| Downloads | Offline library header, transfer status and progress | HLS/MP4 background sessions, pause, retry, cancel, export |
| Settings/profiles | Matte groups and persistent style picker | Account fields, visual profiles, original themes |
| Create | Matte editor backdrop and controls | Local generation, imports, progress, previews |
| Wrapped | Kinetic introduction, real video spotlights and a share image | Recorded stats and favorites only; opt-in sharing |

## Hanime background downloads

- Full video downloads still require a real first-party MP4 or downloadable HLS
  stream. Preview images can never complete a Hanime video record.
- Cancellation during signed URL preparation cancels the pending task, clears
  its generation identifier and prevents a later URL response from starting a
  background transfer. Errors do not overwrite a user-cancelled state.
- New progress labels distinguish preparing a video, saving HLS, paused,
  failed and cancelled. The existing bounded alternate-stream retry remains.
- Provider authentication, geo-restrictions and DRM are not bypassed. If the
  official stream is unavailable, QuickTick must show a recoverable error.

## Verification

- `testInterfaceSwitchUsesExistingPersistentKeyWithoutTouchingPersonalData`
- `testInterfaceStylePersistsAcrossSettingsPresentation`
- `testCancelQueuedHanimePreparationNeverRestartsDownload`
- Existing playback, offline export and Wrapped regression tests

Run the existing `ios.yml` Actions workflow against the feature branch, then
verify both interface modes on physical iPhone hardware for frame pacing,
memory pressure, VoiceOver and provider-dependent playback.
