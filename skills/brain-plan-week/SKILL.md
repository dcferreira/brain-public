---
name: brain-plan-week
description: Monday weekly reset (~15 min, Sunday evening is fine) — review what moved last week per track, run brain-sweep to archive done items, propose 2–3 goals across personal tracks (learning, personal projects, health, life admin) with a recommendation, write the agreed This week goals and snapshot the finishing week to planning/YYYY-Www.md. Interactive. Use on Monday morning, or when the user says "plan my week", "plan the week", "weekly planning", or "set this week's goals".
---

# Plan Week — Monday review and goals

Review the finishing week, archive it, and agree this week's **This week** goals. **Inline** and **interactive**: converse, draft, confirm, and only then write. Do **not** delegate to a subagent. Monday by default (Sunday evening is fine); aim for ~15 minutes. If there was a planning call, use it as the starting point.

## Vault facts

- Vault: `~/Obsidian/vault`. Top of mind: `00-home/top-of-mind.md` — **Today**, **This week** (goals, plain bullets, grouped by track: learning, personal projects, health, life admin), **Previously this week** (dated done items).
- Private top of mind: `private/private.md` — same layout, `[private]` marker. **Scope gate:** read and write it only when `brain-scope includes "$(brain-scope norm)" private` succeeds; otherwise operate on shared only and print one line: "private items hidden — run from an all-scoped session (BRAIN_SCOPE=all)".
- Long-term goals: `00-home/backlog.md`. Weekly archives: `planning/YYYY-Www.md` (private: `private/planning/YYYY-Www.md`); `brain-sweep` appends done items under their `## Done` heading.

## Conventions

- **British English.** Determine the date with `date +%Y-%m-%d` and the ISO weeks with `date +%G-W%V` (this week) and `date -d '7 days ago' +%G-W%V` (the finishing week) — never assume them.
- **Editing tracked vault files.** Mutate top-of-mind and archives through the harness `read` → `edit`/`write` flow only — never shell text-rewrites. The one exception is `brain-sweep`: run it **before** you `read` the files it touches, and `read` again after it.
- **Link references.** Any issue / PR is a markdown link to its full URL, never a bare `#12`.

## Steps

1. **Review last week.** Read top-of-mind's **This week** and **Previously this week** (and private.md when in scope), the finishing week's `planning/<finishing week>.md` if it exists, and `00-home/backlog.md`. Summarise in a few lines **what moved per track** and which goals did not.
2. **Archive.** Run `brain-sweep` (and `brain-sweep --file private/private.md` when in scope); on a Monday it moves last week's done items into the finishing week's archive. Quote its output in one line.
3. **Propose goals.** Offer **2–3 goals across the personal tracks** (from carried-over goals, the backlog and what moved), as outcomes not tasks, and **recommend one set with reasoning**. Iterate until the user agrees.
4. **Write This week** — only once agreed: `read` top-of-mind, replace the **This week** section with the agreed goals grouped by track (private ones to private.md, when in scope). Plain bullets, no checkboxes. Leave **Today** and **Previously this week** alone.
5. **Snapshot the finishing week** into `planning/<finishing week>.md` (private goals into `private/planning/`, never the shared archive): add its goals and a one-line retro above the `## Done` section brain-sweep wrote (create the file if absent):

   ```markdown
   # Week <ISO-week>

   ## Goals
   - <track>: ...

   ## Retro
   <one line>

   ## Done
   (appended by brain-sweep)
   ```

6. **Re-index and report.** Run `qmd update && qmd embed` (and `qmd --index private update` if private files changed). Report briefly: the new goals, the archive file, the sweep result.
