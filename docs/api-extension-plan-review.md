# API extension plan — independent review

Document: [API extension plan, revision 3](api-extension-plan.md).
Baseline: `0d12f34`. Scope: planning and source inspection only; no API implementation, builds or runtime tests.

## Outcome

An independent read-only reviewer reviewed the initial proposal against production source, reviewed the revised contracts, and performed a final bounded verification of the remaining corrections. Final verdict: **no actionable findings in that final verification**. Earlier findings were resolved at proposal level. This is not implementation approval or evidence that proposed behavior passes tests.

## Findings and disposition

| Finding | Correction |
| --- | --- |
| P2: inherited terminal session could follow an explicit sibling/tab/active target | Added a target/session matrix, explicit guard precedence, separate launching-anchor preconditions, same-app checks and old-server negotiation. Listed existing terminal and command wrappers affected by the CLI safety change. |
| P2: current settings updater does not support arbitrary nested plugin paths | Separated Phase 2a application settings from Phase 2b plugin writes. Required a shared path-aware writer; specified set/delete, subtree replacement versus merge, null rejection, quoted paths, bounds and conflict semantics. |
| P2: built-in `plugin.service.start` would collide with a valid contributed command | Changed administrative namespace to plural `plugins.*`; retained singular `plugin.<id>.<command>` exclusively for contributions and required collision fixtures. |
| P2: plugin bridge document IDs and browser automation epochs are not interchangeable | Defined one helper-owned public automation view/document identity across inspection, snapshot and action preconditions, independent of bridge initialization; added no-bridge-call and lifetime round-trip tests. |
| Phase sequencing: Phase 1 revisions must reflect legacy/native mutations before Phase 3 semantic events | Required a full mutation-path audit and shared revision tracker in Phase 1. |
| Pagination: pages must not silently mix workspace revisions | Bound cursors to epoch/query/revision/order; require restart on conflict and retain the initial event boundary. Mark live fields as independently sampled. |
| Follow-up P2: tab-scoped services export tab identity without a pane | Added validated inherited-tab-only routing. A stale supplied pane still fails rather than falling back to its old tab hint; truly unanchored callers retain documented fallback. |
| Follow-up compatibility gate: the current native settings editor rejects arrays-of-tables headers | Required every supported settings-write path, including native Settings and appearance commands, to use the extended editor before Phase 2b can emit those structures. |

## Remaining gates

- User approval of the contracts, surface exposure and first implementation slice.
- Actual routing/guard tests, exhaustive native/legacy mutation tracking and pagination recovery tests.
- Configuration failure/conflict tests and plugin-table/array edits followed by native appearance edits.
- Shared WebKit conformance, BFCache, replacement, origin and bridge-isolation tests.
- Separate service protocol/security review before that phase. The originally proposed hidden-pane phase was subsequently canceled by the user; no lifetime review or implementation is pending for it.
- After implementation, targeted tests and the documented sequential full verification suite; no prior baseline test result certifies these proposed extensions.

The reviewer made no edits and ran no builds/tests. Concurrent `docs/mockups/saved-layouts.html` and `docs/mockups/saved-layouts.md` work was excluded and preserved. No commit, push or implementation is part of this planning deliverable.
