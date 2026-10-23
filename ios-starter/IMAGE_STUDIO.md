# QuickTick Create — local image studio

The central **+** in QuickTick opens the image studio. Its first-run guide is
stored in app preferences, so an IPA upgrade does not show onboarding again.

## Running locally

1. Install the app on iOS 17 or later. Generation is intended for a physical
   iPhone or iPad with enough available memory and disk space; a simulator is
   useful for UI tests but is not a representative inference device.
2. Open **Create → On-device engine**, then choose **Apple SD 1.5** or
   **Anima Metal**. Apple's Stable Diffusion 1.5 6-bit Core ML ZIP is
   approximately 1.57 GB compressed. The recommended mobile-ready Anima Q4
   bundle is approximately 2.07 GB total: Anima diffusion GGUF (~1.42 GB),
   Qwen3-0.6B GGUF (~397 MB), and Qwen-Image VAE (~254 MB).
   Unpacking temporarily requires additional space. The compact transfer
   panel shows real transferred bytes and progress (when the host provides a
   length), and offers **Pause / Resume / Stop**. Pausing suspends the current
   transfer, while Stop cancels it. Transfers only continue while Create is open;
   they are cancelled if Create is dismissed, and cannot resume after app exit.
3. Alternatively, import a ZIP or folder containing *compiled* Core ML model
   resources (`TextEncoder.mlmodelc`, `Unet.mlmodelc` or both UNet chunks,
   `VAEDecoder.mlmodelc`, `vocab.json`, and `merges.txt`).
4. Type a prompt into the centered canvas, or tap **Generate something I'd
   love** to immediately fill an idea from prominent saved characters, artists,
   actions/attributes, and scenes and start rendering if a model is installed.
5. Pick an output **aspect ratio** (1:1, 3:4, 4:3, or 9:16). Apple's compiled
   model has a fixed native canvas, so non-square output is a **center crop**,
   not a wider or taller diffusion render. Anima Metal generates directly at
   those aspect ratios (up to 512px long edge by default). Select **Native** or
   download the approximately 8.5 MB **Real-ESRGAN X4+ Anime** Core ML
   upscaler, then choose **Anime 4×** for offline enhancement after generation.
   The 522px fixed-input conversion handles native Core ML generations up to
   512px per side; it is not a generic unlimited-size photo upscaler.
6. Tap **Advanced render settings** to choose DPM++ or PNDM scheduler for Core ML,
   steps, guidance, seed, and negative prompt. Anima currently uses the native
   sampler exposed by its Metal engine. Tap the glowing **Generate** button. Generation,
   progress reporting, and PNG encoding happen locally. Generated PNG files
   remain in Application Support and are exportable through the share sheet.

The renderer uses Apple's `StableDiffusionPipeline` with reduced memory usage
and the CPU/Neural Engine compute option. Actual performance and memory limits
depend on the device and converted model. It does not run on a backend server.

## Anima and CivitAI

Tap **Explore LoRAs & models** to open the separate searchable model library,
where LoRAs and checkpoints have their own search modes. Results show the
reported file size when CivitAI provides one, and downloads use the same
progress, pause/resume, and Stop controls as the starter model. The library
prefers `civitai.red` and can switch to `civitai.com`.
An optional API key stays in iOS Keychain and is sent in a bearer header to
the selected host. Suggested searches include **Anima** and the user's top
favorite characters and credited artists. Assets must be explicitly downloaded;
they may be exported or deleted in the studio.

**Anima checkpoints use a different architecture from SD 1.5** (Qwen3 text
encoder and Qwen-Image VAE). The Anima chip uses an embedded Mirage/
stable-diffusion.cpp Metal engine with its own three-model bundle. It is a
*separate renderer*: Apple Core ML cannot load raw Anima checkpoints.

If you already downloaded an Anima `.safetensors` checkpoint from CivitAI,
open the model library, find that checkpoint in **Downloaded CivitAI assets**,
and select **Try Anima**. QuickTick fetches just the Qwen3/VAE support files
and attempts to load your existing checkpoint; compatibility depends on the
checkpoint's actual internal architecture. If the checkpoint cannot load,
choose the pretested quantized Anima GGUF bundle instead. Ordinary LoRA files
are not yet surfaced by the native engine's Swift adapter and cannot be
applied. Large models require substantial physical RAM and free memory; the
engine checks available memory before loading to avoid predictable jetsam.

Mirage Swift adapter and its embedded binary distribution are pinned to the
maintainer's August 2026 release. The adapter's MIT license and third-party
notices are under `MirageRuntime/LICENSE`. Full Anima generation and output
quality still require real-device verification.

## Recommendation updates and user data

The current ranking state is version 5. Updating an older IPA migrates the
saved state once, resets stale candidate search cursors and unviewed offers,
but **preserves** favorites, explicit dislikes, learned terms, quick skips,
viewed-history de-duplication, and persistent blocked tags. The visual
metadata revision also queues saved favorites for background reanalysis when
the system permits it. **Settings → Rescan Recommended** manually rebuilds the
candidate pool without wiping preferences.

Candidate acquisition now requires an identifiable favorite character/artist
anchor after enough independent saved identity examples are present. An action
like `looking_at_viewer` can qualify an otherwise relevant identity but cannot
search for arbitrary unrelated characters by itself. Contextual discovery and
special 3D artist queries are subject to this invariant too; broad exploration
continues separately. This is a precision-first stopgap, not proof that the
recommender meets a personalized-feed precision@K target on real user history.

Action concepts currently include aliases for looking at the viewer/camera,
eye contact, looking away/up/down, leaning forward/back, and common poses.
Provider tags and high-confidence anime WD-Tagger signals map into shared
pose/gaze dimensions. No attempt is made to infer actions from arbitrary
video titles or to assume that an untagged image contains a particular action.

## Verification

Unit/UI coverage includes ranking migration, action aliases and conflicts,
strong favorite-medium preferences, favorites-to-prompt extraction, visual
tagger mappings, and Create-tab navigation. Device-level generation and
Apple ZIP download must be smoke-tested on a real iPhone/iPad after the
repository's macOS Xcode build succeeds.
