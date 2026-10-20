# QuickTick v0.9 / build 22

Scans select only items without a current content/model analysis revision. Cached
work survives restarts and transport signature changes; new evidence updates the
existing combined profiles. Manual progress counts pending items, and unchanged
favorites do not repeat inference. Analysis revision markers are bounded at 8192.

Continues e382489 on feature/v0.9-recommendation-relevance. No main changes.

Implemented provider + medium scoped metadata, semantic and visual learning,
bounded confidence-weighted identity/presentation relationships, reviewed offline
franchise aliases, contextual discovery, conservative dislikes, durable feedback
outbox and semantic deferral, and a bounded single visual analysis worker.
Cached pixel attributes can run during browsing; models/network preview analysis
require an uncontended window. Startup and first-post publication never wait for
models. Only unseen content is adapted; explicit exclusions apply before requests
and locally across initial pages and pagination.

Retains bundled WD Tagger v3 for declared 2D content, Apple Vision feature prints
and limited scene labels, and BGE-Micro. WD is not used for 3D/photographic/mixed
or uncertain media. Medium classification currently uses explicit content tags,
not provider identity. Missing or conflicting metadata remains uncertain/mixed;
there is no validated pixel medium classifier. MobileCLIP2 is deferred: no device
accuracy/cost benchmark demonstrates a benefit, so no new model is bundled.
No runtime model downloads, cloud inference, or full-video analysis downloads.

Limits: visual queue 64, feedback outbox 128, event ledgers 2048, feature cache
512, dimensions 512 and relationships 2048 per provider/medium. Metadata shortlist
scores at most 512 items; diversity ranks at most 128 with 48-item lookahead.
Low battery, thermal pressure, Low Power Mode, memory pressure, backgrounding,
feed loading and playback contention throttle/cancel analysis. In-flight Core ML
predictions may finish before cancellation; results are checked before learning.

Validation status: source syntax/project checks only until CI executes. Native
tests must remain behind the private Drive IPA upload/readback marker. Never
label an IPA VERIFIED before the corresponding native checks pass.

Tests include metadata fixture precision@5 versus the legacy scorer, taxonomy
ambiguity/crossovers, classification, contextual negatives, separate profiles,
persisted deduplication and bounded queue priority. Existing image/color/Vision/WD
tests remain. Synthetic metadata fixtures do not measure NSFW visual accuracy or
real-user relevance. No curated licensed NSFW accuracy dataset was supplied.

Opt-in `--measure-performance` reports first-post/ranking/inference stages,
display-link scheduling gaps, RSS, cache counters and battery/thermal state.
Display-link scheduling is not measured GPU presentation FPS. Simulator launch
figures and RSS cannot establish physical-device battery impact or 60/120 Hz
smoothness. Device cold/warm baseline and personalized user evaluation remain
required before asserting improvement or absence of observable regressions.
