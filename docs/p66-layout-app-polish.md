# p66 layout-app polish

Implement the seven notes read from p66 on 2026-10-20, plus the browser agent-indicator placement correction.

## Outcomes

- Create App wording, live icon preview, and native save dialog choosing the app name and location.
- Restore Original Layout through the shared API, CLI, plugin bridge and Cmd-K, available only within layout apps.
- Read-only layout recipe controls in layout apps; plugin enablement overrides private to each app.
- Per-site trash actions and Clear All website data action.
- Browser agent indicator aligned nearer the bottom bar.
- Bundled skill documents verified presence holds and correct actor flag placement.

## Acceptance

Exercise native flows and shared API parity in the test VM, including cancellation, stale identities, parent/child isolation, and restoration guards. Capture changed UI states and obtain independent visual review. Run relevant unit/build/VM gates, recording actual results below.

## Boundaries

Preserve unrelated main-worktree work. The user subsequently authorized committing to main and building/publishing the next release. No user-data reset or host native GUI tests. User p66 note text remains unchanged.

## Progress

- Implemented all seven p66 items plus browser indicator spacing and bundled skill correction.
- Creation retains the shared layouts.launcher operation; name/location are selected through NSSavePanel.
- Restore Original Layout replaces the layout app workspace using the latest parent source recipe. Existing running-process consent and workspace/recipe guards apply.
- Child plugin enablement is an atomic private registry override respected by live sync and restart.
- Layout editor mutation routes are guarded as well as visually disabled; browsing tabs/panes remains available.
- Browser deletion reuses the existing confirmed, frozen-target operation. No new API is needed for the per-row button.
- Native indicator spacing is presentational; presence operations and API behavior are unchanged.
- All 540 package tests and native builds passed. The 72 VM-runner tests passed after adding explicit external save-panel input.
- VM run `20261020T094502Z-e5a40a5c` passed settings-window, saved-layouts, layout-app-sync, browser-profiles, presence, and command-picker. Its two fixture failures were corrected and replaced by the following evidence.
- VM run `20261020T095526Z-cf6ec8fb` passed settings-window and layout-apps, including process consent/cancel, stale confirmation, CLI/service restoration, and private data preservation.
- VM run `20261020T100539Z-c3800e55` passed layout-apps-ui with actual VMPal Create clicks. Native stale-source rejection, destination collision, chosen filename/location, icon preview, and child Settings controls passed. macOS save-panel acceptance was not simulated.
- Native API response audits passed 1,247 responses from the first run and 259 from the restore rerun across CLI, socket, registered-page, bridge and service clients.
- Fresh independent reviews passed Browser Settings, Create App preview/save panel, and browser presence spacing. Child Settings and icon previews passed independent review after clarifying the disabled pane-bar switch and Save Changes button. The final rendered check noted only a nonblocking scroll-edge fade nit.
- VM run `20261020T100838Z-a128cfd1` passed the final layout-apps-ui rerun after that appearance correction.
- These selected checks are not a full-suite certificate. Signed release installation and production updater verification are separate release checks.
