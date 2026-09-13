# Bundled website fonts

These are original, unmodified desktop font files matching the three font
families used by https://www.try-holmes.com/ as checked on 2026-09-12.
They are app resources and must be registered for the process; they are not
installed into the user's system font directories.

## LT Remark

- Author: Daniel Lyons / LyonsType.
- Author's catalog: https://lyonstype.neocities.org/fonts
- The catalog's Remark download points to:
  https://drive.google.com/uc?export=download&id=16icjL0tEjjY-263Z0yATOvqKaI34uEKc
- Included file: `LTRemark-Regular.otf`, extracted unchanged from that archive.
- Website font reference: https://framerusercontent.com/assets/GHgDNReRtD7hzyHdOj1nqYKY.woff2
- License: SIL Open Font License **1.0**, with Reserved Font Name **LT Remark**.
  `LT-Remark-OFL.txt` is the complete copyright/license notice extracted verbatim
  from name ID 13 (Windows Unicode, English) of the original font. The archive
  contains no separate license file; the author's catalog also explicitly states
  that its fonts are licensed under the SIL Open Font License.

## Geist and Geist Mono

- Authors: The Geist Project Authors; Vercel, Basement Studio, Andrés Briganti,
  Guido Ferreyra, and Mateo Zaragoza (see the fonts' embedded notices).
- Official repository: https://github.com/vercel/geist-font
- Official release: https://github.com/vercel/geist-font/releases/tag/v1.7.2
- Download: https://github.com/vercel/geist-font/releases/download/v1.7.2/geist-font-v1.7.2.zip
- Included files: unmodified static desktop TTFs, weights 400, 500, 600, and 700,
  from `geist-font/Geist/ttf/` and `geist-font/GeistMono/ttf/` in the release archive.
- License: SIL Open Font License **1.1**. `Geist-OFL.txt` is copied unchanged from
  `geist-font/OFL.txt` in the release archive and covers both families.
- The release tag and embedded version numbers differ upstream; the table below
  records the original embedded values rather than rewriting them.

## Native font names

Use these PostScript names with `NSFont(name:size:)` or `Font.custom` after
registering the bundled fonts with Core Text. Choose the specific static face
instead of asking the system to synthesize a weight.

| File | PostScript name | Embedded version |
| --- | --- | --- |
| `Geist-Bold.ttf` | `Geist-Bold` | Version 1.800; ttfautohint (v1.8.4.16-eb64) |
| `Geist-Medium.ttf` | `Geist-Medium` | Version 1.800; ttfautohint (v1.8.4.16-eb64) |
| `Geist-Regular.ttf` | `Geist-Regular` | Version 1.800; ttfautohint (v1.8.4.16-eb64) |
| `Geist-SemiBold.ttf` | `Geist-SemiBold` | Version 1.800; ttfautohint (v1.8.4.16-eb64) |
| `GeistMono-Bold.ttf` | `GeistMono-Bold` | Version 1.700; ttfautohint (v1.8.4.16-eb64) |
| `GeistMono-Medium.ttf` | `GeistMono-Medium` | Version 1.700; ttfautohint (v1.8.4.16-eb64) |
| `GeistMono-Regular.ttf` | `GeistMono-Regular` | Version 1.700; ttfautohint (v1.8.4.16-eb64) |
| `GeistMono-SemiBold.ttf` | `GeistMono-SemiBold` | Version 1.700; ttfautohint (v1.8.4.16-eb64) |
| `LTRemark-Regular.otf` | `LTRemark-Regular` | Version 2.001 |

`SHA256SUMS` records each bundled font's SHA-256 checksum. No outlines, names,
formats, hinting, or font tables have been modified.
