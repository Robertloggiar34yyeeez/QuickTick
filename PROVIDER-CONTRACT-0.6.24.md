# Provider Contract — 0.6.24

## Rule34
Use Vercel `/api/rule34` and `/api/comments`. Send `x-r34-user` + `x-r34-key` only when configured. Preserve tag semantics and suggestions.

## RedGIFs
Playback must prefer Quicktick `/api/redgifs-media`; do not use the raw CDN URL as the normal player source. The server route handles temporary auth/header requirements and Range requests.

## Pornhub
Use the existing Quicktick routes and `x-ph-session` supported session state. Passwords stay device-only/transient and are never synced. Do not fake authentication or bypass provider restrictions.

## Eporner
Use `/api/eporner` and `/api/eporner-media`. Resolve/prewarm upcoming media before it becomes active in Immersive.

## Hanime.tv
Use the current server-first public search/catalog path and `/api/hanime-media`. Do not reintroduce blocked browse probes as the primary flow and do not add anti-bot/CAPTCHA/access-control bypass logic.
