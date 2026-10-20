# Offline concepts v0.9

`TasteConcepts` is a small reviewed mapping, versioned independently of model
features. Explicit character/franchise/artist metadata takes precedence. Bare
Shelly, Colette and Raven are ambiguous; no fuzzy identity matching is performed.
Crossovers retain multiple associations. Explicit unknown franchise names are
retained without inventing character membership. Uploaders are provider scoped
and are not assumed to be artists or performers. A real person's visual similarity
is never identity evidence.

Reviewed sources:
- Street Fighter / Chun-Li and Fortnite crossover: https://www.fortnite.com/news/round-one-street-fighters-ryu-and-chun-li-square-off-in-fortnite
- Brawl Stars / Shelly and Colette: https://supercell.com/en/games/brawlstars/blog/release-notes/welcome-to-starr-park/
- Shelly: https://supercell.com/en/games/brawlstars/blog/release-notes/release-notes-june-2026/
- Fishstick: https://www.fortnite.com/item-shop/offers/fishstick-53733be9

The existing pinned DeepGHS credited-tag snapshot supplies additional Rule34
artist and character names, not franchise relationships or photographic identity.
Its provenance and CC BY 4.0 attribution remain in `scripts/prepare-visual-taxonomy.py`.
It is loaded off the startup path. No runtime taxonomy downloads occur.

Evidence origins distinguish explicit metadata, contextual aliases, reviewed
relationships and high-confidence WD v3 predictions. Confidence expresses a
conservative ranking weight, not a calibrated identity probability. Unknown and
mixed media have their own profiles. Old provider-derived visual profiles are
archived locally and favorites are relearned incrementally under content-derived
classification; user favorites/history are preserved.
