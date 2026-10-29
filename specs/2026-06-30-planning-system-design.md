# Design: Daily / Weekly / Long-term planning in the vault

Date: 2026-06-30
Status: design approved (sections confirmed in brainstorming); pending implementation plan.

## Problem & goal

Keep **daily actions, weekly goals, and long-term goals** organised in the vault, always current, with Claude recognising when work starts/finishes and updating it — plus light rituals around the user's cadence: a morning **standup** (meeting), a Friday **all-hands**, and **weekly planning** (Friday afternoon or Monday morning).

## Model

Goals are translated into daily actions, across three horizons:

- **Long-term goals** — big aims. A mix of **team** and **personal**. Live in a **backlog file**, not on the always-injected page.
- **This week goals** — higher-level outcomes for the week. A mix of **team** and **personal**. Plain-bullet outcomes, not tasks.
- **Today actions** — concrete things to do today that move this week's goals forward. **Personal** (your individual contributions). Checkbox todos.

Goals are plain-bullet *outcomes*; only Today's actions are checkbox todos.

## 1. top-of-mind (the always-injected page)

`00-home/top-of-mind.md` is auto-injected at the start of every session by the SessionStart hook — that is its value. It holds the **near-term** horizons only, so it stays short:

```
# Top of Mind

## Today                  — today's concrete actions (personal todos)
- [/] in progress
- [ ] to do

## This week              — weekly goals (mix of team + personal)
**Team**
- a team outcome for the week
**Personal**
- a personal outcome for the week

## Recently completed
- recent done actions (cleared each week by /plan-week)
```

- **Status vocabulary, Today only (plain text, no plugins):** `[ ]` to do · `[/]` in progress/ongoing · `[x]` done · `[-]` dropped. A convention Claude maintains and qmd reads; Obsidian rendering is an optional nicety (no Tasks plugin).
- **This week is plain bullets** grouped under **Team** / **Personal** — outcomes, not tick-off items.
- **Today is personal only** — team work appears as the goal it serves, not as a Today item.
- **Migration:** the current "Current focus" content (two agent-platform MRs) moves into this structure; the two MR references get proper links (via `glab`).

## 2. backlog (long-term goals)

New file `00-home/backlog.md` — the home for **long-term goals** (mix of team + personal) and anything parked for later. Plain bullets, grouped **Team** / **Personal**. Not auto-injected; it's consulted during `/plan-week` and searchable via qmd (already covered by the `vault` collection's `**/*.md`).

## 3. Ambient "recognise work" behaviour

Wired via the vault `CLAUDE.md`; applies to **Today's actions** (This week / backlog goals are plain bullets, not status-tracked):

- Start work on a listed Today action → flip `[ ]` → `[/]`.
- Action finishes → `[/]` → `[x]`.
- Work begins on something **not** listed → add it under **Today** as `[/]`.
- Claude states briefly what it changed — never silent edits.

Flips happen without asking (low stakes, reversible; `/plan-day` and `/persist` reconcile the page).

## 4. Conventions

- **Link references.** Any MR / issue / ticket / PR is written as a markdown link to its full URL (e.g. `[agent-platform !123](https://gitlab.com/example-group/example-project)`), resolved from the repo's GitLab remote or `glab` — never a bare `!787`. Applies on the page, in the backlog, and in session notes. (Already added to `/persist`.)
- British English throughout.

## 5. Cadence skills

All three are **inline** skills (no subagent — they converse with you). `/post-standup` and `/plan-week` are **interactive**: they draft, confirm with you, and only then write to the page. They edit top-of-mind / backlog and read `sessions/` / `meetings/`.

### `/plan-day` — before standup
- Roll yesterday's **Today** over: keep unfinished `[ ]`/`[/]` actions, sweep `[x]` into **Recently completed**.
- **Decide today's actions:** review **This week**'s goals and write concrete personal `[ ]` actions under **Today** that move them forward (a planning step, not a mechanical move).
- Draft **did / doing / blockers** talking points from recent session notes + completed items, for the standup meeting.

### `/post-standup` — after standup (interactive)
- Gather candidate updates: what the user reports from standup, and — if the standup was Krisp-recorded — its action items (run `/sync-meetings` to refresh meeting notes, then read the standup note).
- Present a **provisional list** of proposed changes (new Today actions, reprioritisations, This week goal changes, blockers) and **confirm it with the user**; iterate until it's correct.
- **Only after confirmation, publish** to top-of-mind. Nothing is written before the user signs off.

### `/plan-week` — Friday afternoon or Monday morning (interactive, run whenever)
Starts by asking **whether a plan already exists**:

- **Plan already exists** (e.g. discussed in a call): ask the user to name the call if there was one. If so, run `/sync-meetings` to refresh meeting notes, then pick up the planning details from that call's note and draft This week's goals from it. Present the draft and confirm.
- **No plan yet:** do interactive planning — review the backlog (long-term) + carried-over This week goals, propose **a few options** for the week's focus, **recommend one with reasoning**, and **iterate with the user** until there's an agreed plan.

Once a plan is agreed:
- Set the new **This week** goals — a mix of team and personal outcomes, grouped Team / Personal.
- **Archive the finishing week:** snapshot This week goals + Recently completed into `planning/YYYY-Www.md`, then clear Recently completed.

## 6. History / archival

`/plan-week` writes a weekly snapshot to `vault/planning/YYYY-Www.md` (ISO week): that week's goals, what was completed, optional one-line retro. Plain markdown under the vault, indexed automatically by the existing qmd `vault` collection — no qmd config change.

## 7. Changes to existing pieces

- **Vault `CLAUDE.md`** — document the top-of-mind structure (Today / This week / Recently completed), the backlog file, the status vocabulary, and the ambient flip rules.
- **`/persist` skill** — maintain the new structure (not the old free-form "Current focus"); link references (done).
- **Migrate** current top-of-mind content into the new structure; backfill the two existing MR links via `glab`.
- **New files/folders:** `00-home/backlog.md`, `vault/planning/`.
- **Brain README** — document the planning system and the three skills.

## 8. Out of scope (YAGNI)

- No Shortcut sync (planning is vault-local).
- No Obsidian Tasks plugin / task queries.
- No dedicated all-hands skill (capture via `/sync-meetings` or a note).
- No automated scheduling — skills are run manually around the relevant meetings.

## 9. Possible later extensions

- `/plan-day` could pull today's calendar (meetings) into context via the Calendar MCP.
- A weekly retro could be auto-drafted from the week's session notes during `/plan-week`.
