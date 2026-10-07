# Native Xcode project

`QuicktickNative.xcodeproj` is already generated and includes a shared app/unit/UI-test scheme. Open it directly in a current Xcode on macOS. No project generator is needed to build.

To regenerate from the workspace root:

```sh
python3 scripts/generate-xcode-project.py
```

Alternatively, run `xcodegen generate` from this directory using `project.yml`.

The configured API is `https://quick-tick-webb.vercel.app`. xcconfig spells the protocol `https:/$()/` so `//` is not parsed as a comment. Only the API base URL belongs in these config files; provider access is entered in Settings, and Gorse secrets remain on Vercel.

See `NATIVE-README.md` and `IOS-PORT-STATUS.md` in the workspace/revision root for exact test commands and limitations.
