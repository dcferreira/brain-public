---
name: brain-plan-day
description: Optional, short start-of-day reset for the day's coordinator session (brain-<YYYY-MM-DD>) — check yesterday's coordinator persisted and remind to close it, run brain-sweep, roll unfinished Today actions over, pick today's few actions from This week's goals, and remind to re-arm brain-monitor for live workers. Use at the start of the day, or when the user says "plan my day", "what should I do today", "start the day", or "sort out my Today list".
argument-hint: "[optional: focus or context for today]"
---

# Plan Day — a short start-of-day reset

Run at the start of the day's coordinator session `brain-<YYYY-MM-DD>`. **Optional and short:** skipping it costs nothing — `brain-sweep` also runs in the Monday brain-plan-week and the SessionStart hook warns when top-of-mind grows past 40 KB. Inline: do the reading and writing yourself; do **not** delegate to a subagent. Aim for a few minutes, not a briefing.

## Vault facts

- Vault: `~/Obsidian/vault`. Top of mind: `00-home/top-of-mind.md` — **Today** (checkbox actions), **This week** (goals per track: learning, personal projects, health, life admin), **Previously this week** (done items, dated).
- Private top of mind: `private/private.md` — same layout, private actions carry a `[private]` marker. Read and write it only when `brain-scope includes "$(brain-scope norm)" private` succeeds; otherwise work on shared only and print one line: "private items hidden — run from an all-scoped session (BRAIN_SCOPE=all)".
- Status vocabulary, **Today only**: `[ ]` to do · `[/]` in progress · `[x]` done · `[-]` dropped.

## Conventions

- **British English.** **Determine today's date with `date +%Y-%m-%d`** — never assume it.
- **Editing tracked vault files.** Mutate top-of-mind through the harness `read` → `edit` flow only — never shell text-rewrites (`sed -i`/`awk`/`>`). The one exception is `brain-sweep` (an atomic, re-reading tool): run it **before** you `read` the file, and `read` again after it if you edited earlier.
- **Link references.** Any issue / PR is a markdown link to its full URL, never a bare `#12`.

## Steps

1. **Close out yesterday's coordinator.** Run `date +%Y-%m-%d` and find yesterday's `brain-<date>` session in ListAgents. If it is still alive, check `sessions/` for a note dated yesterday from it (its session id in `session_ids:`); if none, message it to run the brain-persist skill. Then remind the user to close it once persisted.
2. **Sweep.** Run `brain-sweep` (and `brain-sweep --file private/private.md` when private is in scope). It moves `[x]` items out of Today into Previously this week and archives last week's (or, above 40 KB, all) Previously entries to `planning/YYYY-Www.md`. Quote its output in one line.
3. **Roll over.** `read` top-of-mind (and private.md when in scope). Unfinished `[ ]`/`[/]` actions stay. **Exception:** if one names a worker (`dispatched worker brain-worker-<slug>` / `Collected from brain-worker-<slug>`) whose `workers/<slug>.md` is `status: collected` (or `done` for a non-code worker; ignore `collect_state`), offer to tick it `[x]` with the worker's `## Result` headline, and tick on the user's yes. Offer to drop (`[-]`, then delete) anything stale.
4. **Pick today's actions.** From **This week**'s goals, propose two or three concrete `[ ]` actions for today (weighted to the focus argument, if given) and add the agreed ones under **Today** — private ones to private.md with `[private]`. Keep Today short.
5. **Re-arm the worker watch.** brain-monitor's watch died with yesterday's session. Run the brain-status skill's worker list; for every `primed`/`working`/`blocked` worker, remind the user (or offer) to re-arm brain-monitor with those slugs in this session.
6. **Report** in a few lines: yesterday's coordinator (persisted / closed?), sweep result, carried-over and new Today actions, workers to watch. Then `qmd update && qmd embed` (and `qmd --index private update` if private.md changed).
