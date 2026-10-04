# Current GitHub build delivery

Repository: https://github.com/Robertloggiar34yyeeez/QuickTick
Default branch: main
Pre-replacement HEAD: 79dde743f5aad6bf98eba29ab57756c3578ce28e

2026-10-04: GitHub plugin authorization is now confirmed with read/write permission. Shell Git has no credentials; the authenticated GitHub Git-data API is being used to preserve the old HEAD as the new commit's parent while replacing the tracked tree with the native handoff. No force push or history rewrite is needed.

User explicitly requested an unsigned IPA for AltStore/Sideloadly. The workflow runs native iOS simulator XCTest/UI tests, archives the actual iPhoneOS arm64 app without signing, verifies the platform/executable and packages Payload/QuicktickNative.app as an unsigned IPA. It is not directly installable; the sideload tool must sign it.

Current build status: pending push/run. No IPA yet. See IOS-PORT-STATUS.md for inherited source feature status; this report supersedes its earlier repository-access limitation.
