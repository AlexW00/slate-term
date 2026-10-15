#!/usr/bin/env python3
"""Builds the design-system gallery and the component table in INDEX.md.

Usage: python3 design-system/build.py [--check]

The agent-facing files live in the skill, skills/slate-terminal/references/ui/.
This script reads recipes, slate.css and slate-theme.js from there, rewrites the
table in that INDEX.md, and writes gallery.html next to this script.

Component recipes are the source of truth. Each starts with a metadata comment:

    <!--
    name: List
    summary: One line.
    use: When to reach for it.
    avoid: Common misuse.
    notes: Optional extra guidance.
    script: Optional note about included behaviour.
    styles: Set to slate.css when all styles live in the foundation.
    preview-height: Optional fixed preview height in pixels.
    preview-padding: Optional; true pads the preview like a control.
    -->

--check fails when INDEX.md or gallery.html is out of date, without writing.
"""

import html
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parent
UI = REPO / "skills" / "slate-terminal" / "references" / "ui"
CATEGORIES = [("controls", "Controls"), ("patterns", "Patterns"), ("templates", "Templates")]
INDEX_START = "<!-- components:start -->"
INDEX_END = "<!-- components:end -->"
FIELDS = {"name", "summary", "use", "avoid", "notes", "script", "styles", "preview-height", "preview-padding"}


def parse_component(path):
    source = path.read_text(encoding="utf-8")
    match = re.match(r"\s*<!--(.*?)-->\s*", source, re.S)
    if not match:
        raise SystemExit(f"{path}: missing metadata comment")
    meta = {}
    for line in match.group(1).strip().splitlines():
        key, sep, value = line.partition(":")
        key = key.strip()
        if not sep or key not in FIELDS:
            raise SystemExit(f"{path}: unexpected metadata line {line!r}")
        meta[key] = value.strip()
    for required in ("name", "summary", "use", "avoid"):
        if required not in meta:
            raise SystemExit(f"{path}: missing {required}")
    meta["body"] = source[match.end():].strip() + "\n"
    meta["path"] = path.relative_to(UI).as_posix()
    meta["id"] = path.stem
    return meta


def load_components():
    groups = []
    for folder, title in CATEGORIES:
        directory = UI / "components" / folder
        if directory.is_dir():
            items = [parse_component(path) for path in sorted(directory.glob("*.html"))]
            groups.append((folder, title, items))
    return groups


def index_table(groups):
    lines = []
    for _, title, items in groups:
        lines += [f"### {title}", "", "| Component | Summary |", "| --- | --- |"]
        lines += [f"| [{c['name']}]({c['path']}) | {c['summary']} |" for c in items]
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def updated_index(groups):
    path = UI / "INDEX.md"
    text = path.read_text(encoding="utf-8")
    start, end = text.index(INDEX_START) + len(INDEX_START), text.index(INDEX_END)
    return path, text[:start] + "\n" + index_table(groups) + text[end:]


def gallery(groups):
    template = (ROOT / "preview" / "gallery.template.html").read_text(encoding="utf-8")
    data = {
        "setup": {name: (UI / name).read_text(encoding="utf-8") for name in ("slate.css", "slate-theme.js")},
        "palettes": json.loads((ROOT / "preview" / "palettes.json").read_text(encoding="utf-8")),
        "groups": [
            {"id": folder, "title": title, "items": items}
            for folder, title, items in groups
        ],
    }
    # Escape "</" and "<!--" so recipe markup cannot close or confuse the inline script element.
    payload = json.dumps(data).replace("</", "<\\/").replace("<!--", "<\\u0021--")
    replacements = {
        "/*@slate.css@*/": (UI / "slate.css").read_text(encoding="utf-8"),
        "/*@data@*/null": payload,
        "<!--@count@-->": html.escape(str(sum(len(items) for _, _, items in groups))),
    }
    for marker, value in replacements.items():
        if marker not in template:
            raise SystemExit(f"gallery template is missing {marker}")
        template = template.replace(marker, value)
    return template


def main():
    check = "--check" in sys.argv[1:]
    groups = load_components()
    outputs = [updated_index(groups), (ROOT / "gallery.html", gallery(groups))]
    stale = [path for path, text in outputs if not path.exists() or path.read_text(encoding="utf-8") != text]
    if check:
        for path in stale:
            print(f"out of date: {path.relative_to(REPO)}")
        sys.exit(1 if stale else 0)
    for path, text in outputs:
        path.write_text(text, encoding="utf-8")
    count = sum(len(items) for _, _, items in groups)
    print(f"built {(ROOT / 'gallery.html').relative_to(REPO)} and {(UI / 'INDEX.md').relative_to(REPO)} from {count} components")


if __name__ == "__main__":
    main()
