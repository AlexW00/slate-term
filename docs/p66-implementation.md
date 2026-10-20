# P66 TODO implementation

Source: Notes pane p66, 2026-10-20.

## Scope

- Website navigation: replace Star with GitHub; retain both Star on GitHub text links. Swap the panel-type and agent-activity bento cards, as requested in the follow-up.
- Appearance: remove slider tick marks and the dimming footer Apply sentence.
- AI Agents: edit known/custom agent accent colors, reset/remove overrides, persist through Apply/Revert and shared configuration API.

## Acceptance and milestones

1. Implement validated color overrides and shared source-preserving writes; verify parsing, round trips, reset, invalid values, and discovery parity.
2. Wire native settings and existing presence rendering; update the website button and dimming control.
3. Run host package tests, app build and whitespace checks. Extend existing VM regression gates, but do not run or acquire the busy VM.

No publishing, installed-app changes, host native UI launch, or VM interaction. Local commit and main integration were authorized after implementation. Native interaction and independent native rendered review remain pending VM availability.

## Verification (2026-10-20)

- Host package gate: 481 tests passed (115 Settings, 31 IPC, 305 Core, 30 CLI).
- Host app build passed, including the CLI and layout helper. Used copies of the existing pinned Ghostty build artifacts. Did not launch the development app.
- Changed VM scripts parse; whitespace check passed.
- Added VM checks for native Apply/Revert/reset, retained activity recoloring, and registered-plugin configuration parity. Not run while the VM is busy.
- Browser readback confirms the GitHub navigation link, both unchanged Star on GitHub text links, and swapped article order.
- Independent website review covered 1000px desktop and 390px iframe mobile header renders and static-preview bento cards. It confirmed the requested visible changes. A minor illustrated-menu transparency issue also reproduces in the unchanged baseline; the card styles were not modified by this task. A tighter mobile header gap was noted as an optional nit. Follow-up review at 1277px confirmed the wide whole-card swap and found no new issues. Evidence is in `artifacts/p66-todos/`.
- Native Settings appearance, color-picker interaction, and live native presence behavior remain unverified. Run `python3 scripts/verify-vm.py settings-window api-settings presence` once the VM is available, then independently review fresh Settings and indicator screenshots. This is not full-suite certification.

Agent parity uses the existing shared `config.get`/`config.patch` catalog and CLI/page/service routes. The complete `agents.colors` map uses source-revision guards and shared native validation/writing. No new parameterless picker action or shortcut is appropriate for choosing arbitrary names and colors.
