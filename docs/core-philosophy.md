# Slate: core philosophy

## Software you can shape.

Software shouldn’t be a finished box you have to fit into. It should be something you can build on, work with, and keep reshaping as your needs change.

Slate is a terminal for that way of working: **a blank canvas with a solid foundation.** A well-built, native macOS terminal from the start, with a powerful plugin system and CLI that let you and your AI agents extend it.

Build a panel for your current project. Give a command-line workflow a visual interface. Develop a more substantial app inside Slate. Keep your tools alongside the terminal or give one the room to become the focus of your workspace.

Start with something small. Use it in real work. Ask your agent to change it. **Building, using, and refining become one continuous process.**

The goal isn’t customization for its own sake. It’s the ability to quickly turn an idea into something useful—and develop your own workflow as you go.

**A solid terminal. Yours to shape. Open source.**

This is the intended product positioning, not a release-readiness statement. See the publication checks below.

## Product principles

| Principle | What it means for Slate |
| --- | --- |
| A great terminal first. | Dependable behavior, thoughtful design, and native macOS integration. Useful before you extend anything. Terminal quality is a commitment, not a performance claim. |
| A canvas, not a fixed shape. | Panels, tools, and apps let you change what your environment can do—not just how it looks. A blank canvas means room to build, not mandatory setup. |
| Build where you work. | The plugin system and CLI let you and your agents create and integrate tools alongside your existing workflow. |
| Make iteration everyday. | Trying an idea, using it, and changing it should be a short, natural loop. Your first version is a starting point. |
| Keep the choices yours. | Bring your preferred agents and command-line tools. Extend as much or as little as you need. |
| An open foundation. | Open source is a product commitment: transparency, contribution, and independence for a tool people rely on. |

## Who it is for

Developers, AI engineers, and hands-on AI users who want to build and adjust their working environment. Terminal familiarity is useful; wanting to maintain an entire platform is not a prerequisite.

Personal workflows are an outcome, not an exclusivity claim. A tool can be useful to one person or many. The important part is being able to build, try, and refine it without treating every change as a separate product-development project.

## How we explain it

Lead with the possibility, then explain the product:

> **Software you can shape.**
>
> A native macOS terminal and a canvas for your ideas. Build tools with your AI agents, bring them into your workflow, and refine them as you go.

The terminal is the foundation. The plugin system and CLI make it extensible. Your agents help turn ideas into tools. Your workflow takes shape through use.

- Show specific possibilities instead of claiming people can “build anything.”
- Treat agents as collaborators people bring, not intelligence Slate claims to provide itself.
- Explain extensibility through plugins and the CLI. Keep “yours to shape” before “open source” so everyday extension is not confused with modifying the host.
- Use “blank slate” or “canvas” sparingly, and pair it with a useful foundation.
- Avoid “super app,” “limitless potential,” autonomy hype, and unsupported speed or compatibility claims.
- Do not lead with “it only has to work for you.” Lead with building and iteration.

## Website content direction

The [HTML content wireframe](mockups/website.html) is a standalone, dependency-free draft. Open it directly in a browser. It establishes hierarchy, copy length, and media requirements—not branding or final design.

Reference content patterns:

- [VMPal](https://vmpal.com/): name the product category and platform early; give the product demonstration room; explain agent integration concretely.
- [AppView](https://appview.dev/): show tangible examples early; use short, outcome-oriented sections rather than a manifesto on the homepage.

Proposed sequence:

1. **Promise:** “Software you can shape,” one short explanation, and download/source CTA placeholders.
2. **Proof:** one prominent demo. Open Slate, start Claude Code, time-compress building a substantial tool, then show it being used and revised. End with three different examples. Mark time compression; do not imply real-time generation.
3. **Range:** three clips or screenshots showing an agent-workflow panel, a visual interface for a script, and a larger plugin app. These are proposed demos, not claims of bundled features.
4. **Foundation:** a good terminal before any customization.
5. **Mechanism and iteration:** plugins, CLI, and agents; build → use → refine.
6. **Close:** repeat the concise positioning and primary action. No invented testimonials, user counts, pricing, or release promises.

Keep production notes visibly distinct from draft public copy. The homepage should demonstrate the philosophy, not reproduce this entire document.

## Current capabilities and publication checks

Keep the ambition above separate from claims about today’s implementation:

- **Terminal:** the [README](../README.md) documents AppKit windows, libghostty, tabs, split panes, and pane zoom. Preserve its development status, platform requirements, and verification caveats.
- **Extensibility:** [plugins](plugins.md) provide commands, panels, and manual background services. The [CLI and control API](control.md) and [agent skill](../skills/slate-terminal/SKILL.md) support agent-driven interaction. Plugins are trusted code, not a sandbox for arbitrary downloads.
- **App-like workflows:** [saved layouts](saved-layouts.md) can be reopened through locally created `.app` Spotlight launchers. These shortcuts require Slate and its saved layout; they are not independently distributable applications. Say “open your workspace from a launcher,” not “export a standalone app.” Broader app packaging remains product intent unless separately verified.
- **Open source:** retain it as the agreed positioning. No project license file or public Git remote was found during this draft. Confirm the license and public source URL before presenting it as a published open-source release; this document does not choose a license.
- **Availability:** no release download is established here. Wireframe download/source controls are explicitly disabled placeholders. Confirm the release artifact, supported macOS version, signing/notarization, and source URL before enabling them.
- **Media:** record and verify the proposed examples before publishing their captions as product proof. Do not imply the demo tools ship with Slate or that every agent has been tested.
