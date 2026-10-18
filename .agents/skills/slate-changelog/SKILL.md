---
name: slate-changelog
description: Maintain Slate Terminal's detailed change ledger when completing meaningful repository changes, or reconcile it before a release. Public release notes belong to slate-release.
---

# Slate changelog

Work from the repository root. Read `AGENTS.md` and `CHANGELOG.md`, then inspect the task-owned diff and relevant checks.

`CHANGELOG.md` is the durable agent record. Keep `Unreleased` at the top with these categories:

- **Added:** new capabilities.
- **Changed:** changed behavior, defaults, compatibility, or distribution.
- **Fixed:** corrected failures or regressions.
- **Internal:** meaningful implementation, tooling, tests, or workflow changes without a direct user-facing result.

Record meaningful completed changes in the same task-owned commit as their implementation. If committing is not authorized, prepare the entry with the code changes without making a commit. Do not create entries for every refactor, formatting edit, or test invocation.

Write concrete behavior and scope, with affected subsystems or paths when they help the next agent trace the change. Explain a non-obvious reason or compatibility consequence. Include relevant verification and its limits where they affect confidence; a build or unit test does not establish native behavior. Do not describe planned work, a draft release, or an unperformed test as completed.

Preserve unrelated entries, including entries added by other worktrees. Resolve overlapping edits by retaining each distinct change and deduplicating only genuinely equivalent entries. Update the task's existing entry when follow-up work changes its outcome rather than adding contradictory bullets. Keep breaking changes, security implications, compatibility changes, and known limitations explicit.

For reconciliation, compare the last published release's commit with the intended release commit, including the actual diff. Add missing completed work and correct unsupported claims. Unmerged worktree changes are not part of that release. Never infer released history from a current checkout or create fictional past versions.

Use `.agents/skills/slate-release/SKILL.md` to curate public notes and archive a version. The ledger may retain detail that is combined or omitted from public notes. Before finishing, check that the entries match the task-owned changes and that no unrelated history was removed.
