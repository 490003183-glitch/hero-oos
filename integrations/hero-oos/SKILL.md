---
name: hero-oos
description: Read or update a user-selected Hero OOS workspace for tasks, schedules, dependencies, waiting conditions, captures, and Current Truth. Use only when the user asks to manage those records; ordinary conversation does not authorize task mutations.
---

# Hero OOS

Use the user-selected Hero OOS workspace as the task and schedule source. Run this skill's `scripts/hero-oos` wrapper. Configure `HERO_OOS_REPO` for a source checkout or `HERO_OOS_CLI` for an executable, and `HERO_OOS_ROOT` for the intended workspace.

The default is `~/Library/Application Support/Hero OOS/local`. Never guess an account workspace or switch accounts automatically. Initialize a new empty workspace with `init` only when requested; it does not overwrite existing state.

Before a status or priority answer, inspect `meta`, `attention`, and relevant task records. For ongoing consumers, read `changes` with a stable consumer ID and acknowledge only after processing the records. Use an existing `CURRENT_TRUTH.md` as a derived summary, not a substitute for current task state.

For every mutation:

1. Confirm that the user's request authorizes the intended task or schedule change.
2. Read the current version with `meta`.
3. Save only the intended UTF-8 operation array to a temporary JSON file.
4. Run `op --expected-version <version> --file <file> --mutation-id <unique-id>`.
5. On `state_conflict`, reload and retry only the same intended action. Reuse a mutation ID only for an identical payload.
6. Use `--confirmed-major` only when the user has authorized that specific major change.

Never edit live `data/state.json` or `CURRENT_TRUTH.md` directly. Keep schedule completion distinct from task completion. Resolve a Worker capture only after applying the chosen task, schedule, note or no-action decision. Use actual track IDs from this workspace; a fresh workspace has no pre-created tracks.

Preserve explicit dates, and keep due dates, review dates and waiting conditions distinct. Deferral increments deferCount and priority by one, capped at 10, while preserving priorityBase. Do not close a parent with open children or create parent/dependency cycles.

Read [references/operations.md](references/operations.md) when composing operations. The code, documentation and this skill use the repository's mtgh noncommercial license; commercial use requires separate permission.
