# brain-dashboard — a reusable manager dashboard (design + plan)

Date: 2026-10-06. Agreed with the user in the `brain-dashboard-skill` worker session.

## Goal

Any manager (coordinator) session can publish, or re-adopt, a private "<Project> Control"
artifact: a live board of its tasks, its workers and what is waiting on the user, plus a
message box that reaches the manager. The pattern was started by Budgebell Control and
copied by toxic-news and agent-pawl; this skill packages it once, with one page template.

## Decisions (settled with the user)

1. **One template, the superset of the three live pages:** "Waiting on you" first, then
   the message box, a status summary strip, and Tasks / Workers / Messages tabs. Tasks
   reorder by drag (and ↑/↓ on the handle); the order is written back as `order`.
   Waiting items show `needsYouSince` as "3h ago".
2. **Messages are always saved.** Every send attempt is logged to `messages`, with `delivered` true/false, and the
   Messages tab lists the latest 50.
3. **One colour parameter drives the whole theme**, light and dark: background, surface,
   lines, ink, muted, accent, accent-soft and the header glyph. Only the input's OKLCH
   **hue** is kept. Lightness/chroma per role are fixed by the script, so contrast holds
   for any input. Status colours (ok/run/warn/bad/idle) stay fixed: they carry meaning.
   The accent targets 4.5:1 against bg, surface and on-accent text (stricter than 3:1).
   The icon always uses the page accent; no separate icon colour (an anti-pattern).
   Near-grey input (low chroma) gives a neutral slate theme. Computed at render time by
   the script, so the page ships literal colours and the contrast is testable.
4. **Long-term, one dashboard per project.** The URL, the thread and the backlog carry
   across weeks. Pruning keeps it tidy: the page hides done tasks and collected workers
   older than 7 days (by `updatedAt`); weekly history lives in the vault, not here.
5. **Registry, so a project re-uses its dashboard:** `~/Obsidian/vault/dashboards.md`, a
   markdown table `| project | url | colour | created |`. Looked up and written only via
   the script. The three existing dashboards are seeded as rows (no migration: their pages
   are republished from the template only if the user asks).
6. **brain-dispatch / brain-collect are not edited.** The dashboard skill says what a
   manager does to the db when it dispatches or collects.
7. **omp: ignored.** Artifact/ArtifactData/ArtifactComments are Claude Code tools; the
   skill says so in one line and does not try to degrade.
8. **Out of scope:** auto-clearing a Waiting item when its PR merges. The manager handles
   that by hand for now. `task.path` (toxic-news only, unused in its data) is dropped.

## Taking over an existing dashboard (verified)

[verified: ArtifactComments tool description, 2026-10-06] Watches are session-local. A
restarted manager starts watching with `ArtifactComments action:"watch" url:<url>`. Comments
sent to Claude wake the session **only while the watch row says "auto-replies armed"**.
A publish arms them. A `watch` arms them only when the user gave the link in their own message.
So on adopting a dashboard the manager:
1. watches it, then lists its watches (`action:"watch"` with no url);
2. if not armed, it reads the live page (`Artifact action:"read"`) and republishes **that
   same HTML** to the same `url` (a no-op publish that arms replies), or asks the user to
   paste the link. The page shows "manager session isn't running" (`no_session`)
   until then.

## db schema (collections)

- `tasks/<id>`: `title`, `status` ∈ proposed|approved|dispatched|in-progress|in-review|
  blocked|parked|done, `order` (number; drag writes multiples of 10), `worker` (slug, or
  the owner name for the user's own items), `note`, `link`, `linkLabel`, `updatedAt` (ms).
- `workers/<full-slug>`: `slug`, `status` (the worker note's status), `task`, `host`,
  `harness`, `attach`, `mr`, `mrLabel`, `blocker`, `outcome`, `needsYou`,
  `needsYouSince` (ms), `needsYouLink`, `needsYouLinkLabel`, `updatedAt` (ms).
  The Waiting link is `needsYouLink`, falling back to `mr`.
- `messages/<auto>`: `text`, `at` (ms), `by` (user id), `delivered`, `source:"dashboard"`.
- `meta/thread`: `threadId`, the comment thread the message box posts into.

A task is "waiting on you" when `worker == <owner>` and status is not done/parked.

## Monitor line → worker-doc writes

The script parses one brain-monitor line (`<ts> <label> W/N waiting · seg · seg …`). Names
in the line have the label prefix stripped, so it is given the full slugs and maps each
name back by `<label>-<name>` or exact match. Per segment:

| segment | `status` | `needsYou` | link |
|---|---|---|---|
| `ANSWER … "<q>"` | — | `Has a question for you: <q>` | — |
| `REVIEW … PR#n` / `"<text>"` | — | `PR #n ready for review` / `<text>` | add `needsYouLink` (the PR) by hand |
| `UNBLOCK … "<blocker>"` | `blocked` | `<blocker>` | — |
| `COLLECT` | `done` | `Finished: collect it` | keep `mr` fallback |
| `NUDGE` | — | `Idle for <dur>` (+ ` — last said: <text>` if given) | — |
| `INSPECT` | — | `Stuck: <detail>` | — |
| `REVIVE` | — | `Session gone: revive or collect` | — |
| `CHECK` | — | `Check: <detail>` | — |
| lowercase (already reported) | no write | | |
| not waiting (`busy`, `parked`, …) | `needsYou*` deleted, only for known docs that have `needsYou`; `blocked` → `working` | | |

Each write in a capital-letters segment also sets `needsYouSince` (= line ts) and `updatedAt`,
and deletes stale `needsYouLink*` (UNBLOCK also sets `status` blocked, COLLECT `done`).
Output: an ArtifactData `batch` `writes` array (op `update`). Doc ids are full slugs.
`--docs <json>` is a map `doc_id → {"version": int, "needsYou": bool, "status": str}` built from
a fresh ArtifactData `list` of `workers`; it adds `if_version` to each write. ArtifactData
refuses an unpinned write to an existing doc, so the manager always lists first. A capitals
write to a slug absent from the map creates the doc (unpinned, `slug` added). Non-waiting
segments never write for a `collected` segment, never create stub docs, and write nothing without
`--docs`. Exit 3 with `[]` means no writes: the manager skips the batch (it needs ≥1 write).
The manager adds `needsYouLink`/`Label` afterwards when there is one (e.g. the PR for REVIEW).

## Dispatch / collect rules (described in SKILL.md, not wired)

- **Dispatch:** set `workers/<slug>` {slug, status:"primed", task, host, harness, attach,
  updatedAt}; move its task to `dispatched` with `worker:<slug>`.
- **Worker note flips** (seen via the monitor or a status read): mirror `status`, `mr`,
  `blocker`.
- **Collect:** worker `status:"collected"`, `outcome`, clear `needsYou*`; task → `done`
  with `link` to the MR/result.
- **Message arrives** (comment wake): act on it, reply in the thread, resolve the thread when done.

## Interface

`skills/brain-dashboard/scripts/dashboard.py` (python3 stdlib only; python3 is present on
all three hosts [verified: `python3 --version` on linux 3.14.7, mac 3.14.6, homeserver 3.13.13]):

```
dashboard.py theme  <colour>                      # print the theme CSS block (debug)
dashboard.py render --title T --colour C [--glyph G] [--subtitle-url U --subtitle-text S]
                    [--owner <name>] [--placeholder P] -o page.html
dashboard.py lookup   <project> [--registry F]    # print url, exit 1 if absent
dashboard.py register <project> <url> <colour> [--registry F]   # idempotent upsert
dashboard.py needs  --slugs s1 s2 … [--docs F] [--now-ms N] --line <monitor-line>   # or positional; exit 3 = no writes
```

Template: `skills/brain-dashboard/assets/dashboard.template.html` with `{{…}}`
placeholders; `render` HTML-escapes every value and fails on any unfilled placeholder.

## Tests

`skills/brain-dashboard/scripts/dashboard.test.sh` runs `python3 -m unittest` over
`dashboard_test.py`. Covers: hue extraction; contrast ≥ 4.5:1 for ink/muted on bg and
surface and for accent vs bg, surface and on-accent text (stricter than 3:1), plus every
status chip pair (fg on its soft bg) ≥ 4.5:1, across 36 hues × light/dark plus
grey/black/white inputs; render escapes values and leaves no `{{`; registry lookup/
register/upsert round-trip and a missing file; every monitor segment kind in the table
above, prefix-stripped names, lowercase no-op, the clear case, `--docs` pinning and exit 3 on no writes.

A root `.gitignore` excludes `__pycache__/` and `*.pyc` (test runs create them).

## Plan

1. Script + tests (TDD): theme, render, registry, needs. (opus: colour maths + parser)
2. Template: merge the agent-pawl page (Messages tab, `needsYouSince`, logging) with the
   toxic-news drag reorder; placeholders; 7-day pruning; no `path`. (sonnet)
3. `SKILL.md`: publish/adopt flow (registry, watch/arm), schema, monitor mapping, dispatch/
   collect rules, pruning, omp line. README skill list + inventory. (sonnet)
4. Seed `~/Obsidian/vault/dashboards.md` with the three existing dashboards (vault write,
   after landing).
5. Review the whole change at a fixed revision; one fix wave; describe; land on the user's go.
