---
name: brain-orient
description: Load context from the knowledge vault — read top-of-mind, latest session notes, and search for notes relevant to the current project. Use at the start of a session or when you need to re-orient.
---

# Orient — Load Vault Context

> **Harness.** If you have a `task` tool you are in omp: read `~/projects/brain/skills/_shared/harness/omp.md`. If you have an `Agent` tool you are in Claude Code: read `~/projects/brain/skills/_shared/harness/claude-code.md`. Read one, never both.

Re-orient by loading context from the knowledge vault. This is read-only — do not create or modify notes while orienting.

## Vault facts

- Vault: `~/Obsidian/vault`
- Top of mind: `00-home/top-of-mind.md` — current focus areas
- Session notes: `sessions/` — files named `YYYY-MM-DD <description>.md`
- Knowledge notes: `knowledge/graph/`
- Private notes (read **only** when `brain-scope includes "$(brain-scope norm)" private` succeeds — never from a shared-scope session): `private/private.md` (private Today / This week, `[private]` items) and `private/sessions/`.
- Search: `brain-search -n 5 "<query>"` (scope-aware wrapper over qmd: searches the shared index, plus the private one when your scope includes it; add `--project <slug>` to narrow to one project). For a semantic pass use `env -u CI qmd vsearch "<query>"` (the `env -u CI` is required: some harnesses set `CI=true` in their shell tool, under which `qmd vsearch` aborts rather than returning nothing) — shared index only; use `qmd --index private vsearch "<query>"` when private is in scope.

Use native file tools and the `qmd` CLI. The paths above are current; no need to verify or discover them.

## Done looks like

You can give the user a brief summary of:

1. **Current focus** — from top-of-mind (and `private/private.md` too when the scope includes private)
2. **Last session** — from the most recent note in `sessions/` (by filename date; `private/sessions/` too when private is in scope)
3. **Relevant knowledge** — `brain-search` for the current project or topic

The session-start wiring injects 1 and 2 automatically at the start of every session, as a `--- VAULT: TOP OF MIND ---` block followed by a `--- VAULT: LATEST SESSION ---` block. If that context is already present, skip re-reading those files and go straight to the relevance search.
