# QuickTick Create — local image studio

The central **+** in QuickTick opens the image studio. Its first-run guide is
stored in app preferences, so an IPA upgrade does not show onboarding again.

## Running locally

1. Install the app on iOS 17 or later. Generation is intended for a physical
   iPhone or iPad with enough available memory and disk space; a simulator is
   useful for UI tests but is not a representative inference device.
2. Open **Create → On-device engine → Download model**. The Apple Stable
   Diffusion 1.5 6-bit Core ML ZIP is approximately 1.57 GB compressed.
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
5. Tap **Advanced render settings** to reveal steps, guidance, seed, and
   negative prompt, then tap the glowing **Generate** button. Generation,
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

**Raw `.safetensors`, `.ckpt`, `.pt`, and LoRA files are not directly compatible
with Apple's compiled Core ML pipeline.** Downloading them saves the original
asset but does not apply it to generated images. Conversion/fusion to a
compatible Core ML pipeline is a separate required step. The app surfaces this
limitation rather than pretending a downloaded LoRA is active.

## Recommendation updates and user data

The current ranking state is version 4. Updating an older IPA migrates the
saved state once, resets stale candidate search cursors and unviewed offers,
but **preserves** favorites, explicit dislikes, learned terms, quick skips,
viewed-history de-duplication, and persistent blocked tags. The visual
metadata revision also queues saved favorites for background reanalysis when
the system permits it. **Settings → Rescan Recommended** manually rebuilds the
candidate pool without wiping preferences.

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
