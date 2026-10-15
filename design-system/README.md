# Slate plugin UI (maintainers)

The design system's agent-facing files live in the Slate Terminal skill at [`skills/slate-terminal/references/ui/`](../skills/slate-terminal/references/ui/INDEX.md). That folder is the source of truth; agents read it directly. This folder holds only maintainer tooling: `build.py`, `preview/` and the generated `gallery.html`.

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

- Recipes live in `skills/slate-terminal/references/ui/components/{controls,patterns,templates}/*.html`, next to `slate.css`, `slate-theme.js`, `guidelines.md` and `INDEX.md`. Each recipe starts with a metadata comment; `build.py` documents the fields.
- After any change, run `python3 design-system/build.py` from the repository root (or `python3 build.py` here). It regenerates `gallery.html` in this folder and the component table in the skill's `INDEX.md`. Add `--check` to fail when either is stale.
- `preview/palettes.json` holds the bundled palettes for the gallery, extracted from the Ghostty theme files.
- Keep recipes copyable: tokens from `slate.css` only, no external assets, no build step, and inline SVG icons.

## Skill packaging

There is no copy step. The skill folder is the source, and `SKILL.md` routes panel UI work to `references/ui/INDEX.md`. Agents read the recipe files, not the gallery, so the gallery and this tooling stay out of the skill.

The host-side theme contract is in [../docs/theme-api.md](../docs/theme-api.md).
