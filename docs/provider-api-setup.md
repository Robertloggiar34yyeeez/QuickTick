# Erome and Hanime provider access

QuickTick now offers **Erome** and **Hanime** alongside Rule34, RedGIFs,
Pornhub, Eporner, Coomer, Kemono and NHentai. Hentai Haven is retained only for
previously saved content and is no longer a new feed choice.

The app attempts each provider's public endpoints directly. Direct access can
be denied by the provider, including HTTP 403 and Cloudflare verification. It
does not bypass those restrictions.

Two optional provider packages were supplied with the integration:

- `QuickTick-3romeadeon.zip`: Erome read-only album/search API, default port 8787.
- `QuickTick-Hanime-API-v0.1.0.zip`: Hanime catalog and normal-browser HLS
  resolver, default port 8788. Stream resolution requires `HANIME_BROWSER=1`
  and your own legitimate browser verification/session when required.

For either package, unpack it on a machine you control, run `npm ci
--ignore-scripts`, then `npm start`. Follow its README for settings, prerequisites,
limits and tests. Its default `127.0.0.1` listener is local to that machine.
If an iPhone must reach the service, expose **only an authorized HTTPS origin**
with appropriate authentication, TLS and rate limits; do not publish an
unprotected public scraping endpoint. Set the resulting `https://...` address
under **Settings → Provider access → Erome API URL / Hanime API URL**.

Leaving these fields empty preserves direct mode. Provider-specific URLs and
session state are never shared between providers. The app preserves older
downloads and their original provider identities.

Hanime's suggested Home topics are keywords/tags; quoted phrases such as
`"dark skin"` search as one phrase, and `-"dark skin"` excludes it. The
generated API and the direct v11 catalog both apply the same filters locally.

Neither ZIP is a pre-deployed service. Native playback is still subject to the
provider's actual network and account access rules.
