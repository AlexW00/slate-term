# Slate plugin UI (maintainers)

Agents start at [INDEX.md](INDEX.md). This file covers viewing, editing and packaging.

## View

Open `gallery.html` in a browser. It is self-contained. Pick any bundled terminal palette, then switch the pane width between narrow, medium and full, or drag a preview's right edge. Each entry shows its guidance, a live preview inside a mock pane header, and the copyable code.

To view it inside Slate Terminal, register this folder as a panel plugin:

```sh
cat > /tmp/slate-ui-gallery.json <<EOF
{"id": "slate-ui-gallery", "title": "UI Gallery", "scope": "global",
 "source": {"kind": "directory", "path": "$PWD", "entry": "gallery.html"}}
EOF
slate-term plugins register --manifest /tmp/slate-ui-gallery.json
```

When the host implements `appearance.get`, the palette menu gains a **Terminal (live)** option that follows the real palette.

## Edit

- Recipes live in `components/{controls,patterns,templates}/*.html`. Each starts with a metadata comment; `build.py` documents the fields.
- After any change, run `python3 build.py`. It regenerates `gallery.html` and the component table in `INDEX.md`. `python3 build.py --check` fails when either is stale.
- `preview/palettes.json` holds the bundled palettes for the gallery, extracted from the Ghostty theme files.
- Keep recipes copyable: tokens from `slate.css` only, no external assets, no build step, and inline SVG icons.

## Package into the skill

Copy this folder into the future Slate Terminal skill as `references/design-system/`, without `build.py`, `preview/`, `gallery.html` and this README. Agents read the recipe files, not the gallery. The skill's `SKILL.md` should point at `references/design-system/INDEX.md` for any panel UI work.

The host-side theme contract is in [../docs/theme-api.md](../docs/theme-api.md).
