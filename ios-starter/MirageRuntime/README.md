# QuickTick Mirage runtime (native LoRA support)

The upstream prebuilt Mirage XCFramework does not expose sd.cpp's LoRA array.
QuickTick builds a pinned Mirage native bridge with `mirage_lora` and `lora_count`
fields, then passes up to four selected `.safetensors` adapters with their
per-model weights. The C bridge forwards these through `sd_img_gen_params_t`
(`loras` and `lora_count`), rather than embedding ignored `<lora:...>` prompt tags.

On macOS with Xcode, CMake and Ninja:

```bash
bash scripts/build-mirage-lora.sh
```

Run this from the repository root before opening the Xcode project. CI builds
and caches `ios-starter/MirageRuntime/Frameworks/sdcpp.xcframework` before
`xcodebuild`; the generated binary is intentionally not committed. The exact
upstream Mirage commit and bridge patch are pinned in the build script.

The native image model and LoRA must share a compatible architecture. Anima
LoRAs are not interchangeable with SDXL or Illustrious LoRAs. Device testing
remains required for real model inference and memory behavior.
