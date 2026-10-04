# GitHub iOS build delivery

Repository: https://github.com/Robertloggiar34yyeeez/QuickTick
Default branch: main
Pre-replacement HEAD: 79dde743f5aad6bf98eba29ab57756c3578ce28e
Native-build commit: 3c61acb33c7350e3340dc50ad04d64284bc6c13a
Workflow: https://github.com/Robertloggiar34yyeeez/QuickTick/actions/runs/37215246057

PASS: simulator build, 20 unit tests, 1 navigation UI test, actual iPhoneOS device archive and unsigned IPA packaging on Xcode 26.6. Native tree replaced as authorized; original Git history preserved.

The corrected IPA contains the existing Vercel API origin and an arm64 iPhoneOS executable. SHA-256: 55ef499a1fba23421c96b491e5eb549514902dbf496a4dc80cabad9ceb383cb6 (362363 bytes). It needs AltStore/Sideloadly signing before installation, as explicitly selected by the user.

Earlier attempts identified missing Debug testability and omission of the custom API URL from generated plist. Both were fixed and re-tested; the earlier configuration-defective IPA was withheld. Current physical-device/provider/offline limits are in IOS-PORT-STATUS.md.

Delivery artifacts and hashes are recorded in the Google Drive revision folder's manifest and DELIVERY-VERIFICATION.json. The final report commit updates only documentation and delivery tooling; native app/test files match the successful build commit.

