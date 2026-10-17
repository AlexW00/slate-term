# Third-party notices

Slate Terminal's own source is licensed under GPL-3.0-or-later; see `PROJECT-LICENSE.txt` in the app or `LICENSE` in the repository. The components below retain their own copyright notices and license terms. Inclusion here does not relicense those components.

Release builds include the complete texts from `licenses/` in `Contents/Resources/ThirdPartyLicenses/`, alongside this document and the project license. `manifest.json` records each copied text's SHA-256 and source URL, source revision, or pinned Zig package hash. Some upstream source packages omit their license files; the inventory includes those texts from the corresponding upstream revision instead.

| Component | Version or source | License texts |
| --- | --- | --- |
| Ghostty | `554ea65867ffe34bb3e51e09bd016e154a1f9d7a` | `ghostty/LICENSE` (MIT) |
| Swift Argument Parser | 1.5.0, `41982a3656a71c768319979febd796c6fd111d5c` | `swift-argument-parser/LICENSE.txt` (Apache 2.0 with Swift exception) |
| TOMLDecoder | 0.4.5, `a2bbd2796fe3064e107de18cb56031052c4fa899` | `TOMLDecoder/LICENSE.md` (MIT) |
| FreeType | 2.13.2 | `freetype/` (FreeType License option) |
| libpng, zlib, Oniguruma | Ghostty's pinned source archives | `libpng/`, `zlib/`, `oniguruma/` |
| glslang, SPIRV-Cross, Highway | Ghostty's pinned source archives | `glslang/`, `spirv_cross/`, `highway/` |
| simdutf | Vendored header identifies 9.0.0 | `simdutf/` (upstream terms and embedded Torch notice) |
| Wuffs and pixels | Ghostty's pinned source archives | `wuffs/`, `pixels/` |
| Dear ImGui and Dear Bindings | 1.92.5 docking / 0.17 | `imgui/`, `dear-bindings/` |
| libxev, libvaxis, zig-objc, zf, zigimg | Ghostty's pinned source archives | `libxev/`, `vaxis/`, `zig_objc/`, `zf/`, `zigimg/` |
| uucode and Unicode data | `9d55524551411b493cca41ca06363625d90aff1e` | `uucode/`, including Unicode and Hoehrmann notices |
| z2d | `7dbae85c81784dba9988320bf9543ed9a81350c8` | `z2d/COPYING` (MPL 2.0), `z2d/LICENSE` (additional notices) |
| stb image and resize | Sources in the pinned Ghostty revision | `stb/` (embedded dual-license texts) |
| JetBrains Mono | 2.304 | `jetbrains_mono/` (SIL OFL 1.1 and authors) |
| Nerd Fonts Symbols Only | 3.4.0 | `nerd_fonts_symbols_only/`, `nerd-fonts/`, `nerd-fonts-vendor/` |
| iTerm2 Color Schemes | `31756e77934045c66b28f59463ddb2870606d7ca` | `iterm2-themes/LICENSE` (MIT) |
| Zig and LLVM runtime libraries | Zig 0.16.0 distribution | `zig-runtime/` |

Portions of this software are copyright © 2023 The FreeType Project (www.freetype.org). All rights reserved.

The Nerd Fonts symbol font combines multiple glyph collections. Its release archive's MIT text only covers the base font. Additional glyph licenses and attribution are preserved under `nerd-fonts/`, together with the upstream license inventory and extracted font copyright metadata. Supplemental glyph notices retain their own source references in the manifest. Brand glyphs remain the trademarks of their respective owners. Fonts are bundled without modifications by Slate.

The macOS build uses CoreText; it does not enable HarfBuzz or Fontconfig. Ghostty's gettext internationalization and Sentry integration are disabled. The checked patch gates the otherwise unconditional Apple libintl build on internationalization, and the bootstrap verifies that the resulting archive contains no libintl/gettext/Sentry symbols. A build with different features needs a new dependency and license review. Platform SDKs and system libraries are supplied by macOS, rather than redistributed here.

## Building and reviewing releases

Run `python3 scripts/collect-release-licenses.py --check` to check dependency pins and every notice checksum. The collector is offline and resolves paths relative to its own checkout, so linked worktrees use their own inventory. Run it with `--app /path/to/Slate\ Terminal.app` before signing; use `--verify-app` to check every bundled file without changing the signed app. A manifest file alone is not proof that its license texts were packaged.

When a dependency changes, review its exact pinned source, transitive dependencies, embedded resources, and license files. Update the copied texts and their provenance/checksums in `licenses/manifest.json`. Run the collector and inspect the resulting app. Do not copy notices from an unrelated cached version. The simdutf package metadata currently says 5.2.8, but its vendored header says 9.0.0; this inventory follows the actual header.

Each public binary release must make the matching source and build inputs available under their applicable terms. This includes Slate's source and changes, the Ghostty patch, and the corresponding covered dependency sources. The unchanged z2d source is available at <https://github.com/vancluever/z2d/tree/7dbae85c81784dba9988320bf9543ed9a81350c8>; its source remains under MPL 2.0. Preserve that source access and the bundled notices when redistributing it. The inventory describes notices and provenance; its successful validation does not establish that a release's source-distribution requirements have been fulfilled.
