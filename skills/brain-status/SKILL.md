---
name: brain-status
description: Lightweight, read-only "where am I at" — read top-of-mind, today's diary note, and the worker notes, then report Today actions, this week's goals, and (its distinctive job) flag any dispatched worker that has finished and is waiting to be collected. Use when you want a quick status check, ask "where am I at", "what's my status", "what are my workers doing", "anything finished", or "what needs collecting" — without the heavy re-hydration of the brain-orient skill.
---

# Status — Lightweight "Where Am I At"

> **Harness.** If you have a `task` tool you are in omp: read `~/projects/brain/skills/_shared/harness/omp.md`. If you have an `Agent` tool you are in Claude Code: read `~/projects/brain/skills/_shared/harness/claude-code.md`. Read one, never both.

A fast, **read-only** status check. It sits between the brain-orient skill (heavy re-hydration with qmd search) and just opening the file yourself. No qmd search, no re-hydration, **no writes**.

**How this runs:** inline in the main session. It reads its three vault inputs and reports tersely — keep it fast. Do **not** dispatch a subagent, do **not** run a qmd search, do **not** edit anything (no writes).

## Vault facts

- Vault: `~/Obsidian/vault`
- Top of mind: `00-home/top-of-mind.md` — **Today** (checkbox actions: `[ ]` to do · `[/]` in progress · `[x]` done · `[-]` dropped) and **This week** goals (grouped Team / Personal).
- Private top of mind: `private/private.md` — private **Today** / **This week** (private actions carry a `[private]` marker). **Read-only here, and only** when `brain-scope includes "$(brain-scope norm)" private` succeeds; otherwise skip it and print one line: "private items hidden — run from an all-scoped session (BRAIN_SCOPE=all)". Never write it.
- Today's diary note: `diary/YYYY-MM-DD.md` — determine today's date with `date +%Y-%m-%d`; the note may not exist yet (that is fine).
- Worker notes: `workers/*.md` (plus `private/workers/*.md`, only when private is in scope) — one note per dispatched worker, with `status` frontmatter (`primed` → `working` → `blocked` → `done` → `collected`, plus `parked`), an optional `blocker` field (present when `blocked`/`parked`), `tmux_session`, `host` (the real `hosts.conf` name), `harness` (`omp`|`claude`), `attach` (the full attach command for the worker's pane), and the originating `today_action`. The folder may not exist yet (no workers dispatched); treat that as "no workers". A note with `host: local` or no `host` is legacy — read it as this machine and warn, naming the slug; if its `project_dir` does not exist here it probably belongs to another host, so say so rather than reporting it as this machine's worker. A note with no `harness` predates the dual-harness change — default `omp`, with a warning. Compose the attach command as `tmux attach -t <tmux_session>` for this machine's workers.

## Steps

1. **Read** `00-home/top-of-mind.md` (and `private/private.md` when the private gate above allows), today's `diary/YYYY-MM-DD.md` (skip if absent), and every `workers/*.md` (and `private/workers/*.md` when in scope; skip a folder that is absent). Nothing else — no qmd search, no writes.
2. **Report Today + this week** — a terse list of the current **Today** actions with their statuses, and this week's goals (private items marked `[private]` when in scope; the one-line "private items hidden" notice otherwise). Keep it short; this is a glance, not a briefing.

   **Stale-tick check.** For each `[/]`/`[ ]` Today item that names a worker (`dispatched worker brain-worker-<slug>` / `Collected from brain-worker-<slug>`), read `workers/<slug>.md`; if `status` is `collected` (or `done` for a non-code worker; `collect_state` is irrelevant — teardown sets `persisted` even on park), flag: `<item> — worker finished — offer to tick` plus the note's `## Result` headline. Report only; the main session ticks it on the user's yes.
3. **Bucket the workers into three groups**, reading each note's `status` (and `blocker`). Surface them in this order:
   - ✅ **Draft awaiting review (the distinctive job).** Any worker with `status: done` that is **not** `collected` is waiting to be reaped. Only a **non-code** worker reaches `done`, and its `done` means it *says* it produced a draft nobody has looked at — so render it as **draft exists, unreviewed**, never as "ready to collect", which reads as a finished result:
     > **N worker(s) with an unreviewed draft — run the brain-collect skill to verify and close:** `<slug-a>`, `<slug-b>`

     A **code** worker at `done` is a convention violation (code workers finish `blocked`, awaiting review/merge) — flag it as such rather than presenting it as finished.
   - ⏳ **Blocked — needs you to unblock.** Any worker with `status: blocked` or `status: parked`. Show each one's `blocker` verbatim — note that the blocker may be **awaiting review/merge of a PR** (the common code case: the work is complete and the PR is up, a human just has to merge it) as well as a mid-work external dependency. When the blocker names a PR, show the PR link.
     - For `blocked`, the tmux session is still live — give the note's `attach` command verbatim so the user can jump in and drive it:
       > blocked: `<slug>` — waiting on <blocker> (show the PR link if present) — `<attach>`
     - For `parked`, the session was torn down; it resumes via re-dispatch, so note that instead of an attach command:
       > parked: `<slug>` — waiting on <blocker> — resume with the brain-dispatch skill on its Today action
   - 🔄 **In flight.** Workers still `primed` or `working`, each with the note's `attach` command verbatim so the user can attach:
     > working: `<slug>` — `<attach>`
4. **Say nothing else.** No suggestions to persist, no re-orientation, no file edits.

## Done looks like

A short block the user can read in a glance:

- any uncollected `done` workers, flagged first as **unreviewed drafts** (not as finished results);
- any blocked/parked workers, each with its blocker (and an attach command for `blocked`, a resume hint for `parked`);
- in-flight workers with their attach commands;
- the current Today actions + this week's goals;

*Provenance: the unreviewed-draft rendering came from `brain-dream 2026-07-30`.*
