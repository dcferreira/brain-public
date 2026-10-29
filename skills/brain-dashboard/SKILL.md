---
name: brain-dashboard
description: Publish, re-adopt, or keep in sync a manager's long-term "<Project> Control" dashboard artifact (tasks, workers, what is waiting on the user, plus a message box that reaches the manager). Use when the user says "publish a dashboard", "set up a control page", "manager dashboard", "<project> Control", "keep my dashboard in sync", or when you are a coordinator/manager session (e.g. budgebell-manager) that must open its project's dashboard or mirror brain-monitor lines into it.
argument-hint: <project>
---

# Dashboard — A Manager's Live Control Page

> **Harness.** Claude Code only: `Artifact`, `ArtifactData` and `ArtifactComments` are Claude Code tools. Under omp this skill does not apply; stop. In Claude Code, read `~/projects/brain/skills/_shared/harness/claude-code.md`.

The dashboard is a private artifact, **one per project, long-term**: the URL, comment thread and backlog carry across weeks. It shows **Waiting on you** first, a message box, a status strip, and Tasks / Workers / Messages tabs. The user's messages go through the page's comment box (`sendToClaude`) and wake this session; every send attempt is also logged to `messages` (`delivered` true or false). State lives in the artifact's db, so you update it with `ArtifactData`, never by republishing. Script: `python3 ~/projects/brain/skills/brain-dashboard/scripts/dashboard.py`.

## Open or create

1. `dashboard.py lookup <project>` prints the registered url (exit 1 if none).
2. **Found: adopt it.** `ArtifactComments action:"watch" url:<url>`, then list watches with a bare `ArtifactComments action:"watch"`. Comments wake you only while the row says "auto-replies armed". If it does not: `Artifact action:"read"` the url and republish **that same HTML** to the same `url` (a no-op publish that arms replies), or ask the user to paste the link in chat. Until then the page shows "manager session isn't running". Do not change the page unless the user asks.
3. **Not found: create.** Ask the user for a colour (one hex) and optionally a glyph and subtitle. Render: `dashboard.py render --title "<Project> Control" --colour <hex> [--glyph G] [--subtitle-url U --subtitle-text S] [--owner the user] -o <scratchpad>/dashboard.html`. Load the `artifact-capabilities` skill, then publish with the `Artifact` tool and `capabilities: {"db":{}, "comments":{}, "user":{}}`. Finally `dashboard.py register <project> <url> <colour>`. Publishing is outward-facing: get the user's go-ahead in-session first.

## db schema

- `tasks/<id>`: `title`, `status` (proposed|approved|dispatched|in-progress|in-review|blocked|parked|done), `order` (number; drag writes multiples of 10), `worker` (slug, or the owner name for the user's own items), `note`, `link`, `linkLabel`, `updatedAt` (ms).
- `workers/<full-slug>`: `slug`, `status` (the worker note's status), `task`, `host`, `harness`, `attach`, `mr`, `mrLabel`, `blocker`, `outcome`, `needsYou`, `needsYouSince` (ms), `needsYouLink`, `needsYouLinkLabel`, `updatedAt` (ms).
- `messages/<auto>`: `text`, `at` (ms), `by`, `delivered`, `source:"dashboard"`.
- `meta/thread`: `threadId`, the comment thread the message box posts into.

## Keeping it in sync with brain-monitor

The manager stays current on its workers by arming the **brain-monitor** skill; this skill mirrors its lines.

- Arm `Monitor(command: "bash ~/projects/brain/skills/brain-monitor/scripts/worker-monitor.sh <slug> <slug> ...", description: "<project> worker waits", timeout_ms: 1800000)`, naming every worker you own by its full slug, not yourself. (A worker's note may live in `workers/` or `private/workers/`; the monitor script handles both, so just name the slug.)
- Each line it prints is a notification: mirror it into the dashboard with the steps below.
- A watch expires after at most 30 minutes: re-run the identical command. State persists, so nothing is re-emitted.
- After a dispatch or collect, re-arm with the updated slug list.
- On opening or adopting the dashboard, run `worker-monitor.sh --once <slugs>` once and feed that line through the same steps to bring the db up to date.

On each monitor line:

1. `ArtifactData list workers`; write a `{doc id: {"version": int, "needsYou": bool, "status": str}}` JSON map to a scratch file (the `--docs` file).
2. `dashboard.py needs --slugs <all watched full slugs> --docs <file> --line "<line>" > writes.json`.
3. Exit code 3 (output `[]`) means no writes: skip. Otherwise `ArtifactData batch` with `writes` from the file (a batch needs at least one write).

| Monitor segment | `status` | `needsYou` |
|---|---|---|
| `ANSWER` | unchanged | `Has a question for you: <q>` |
| `REVIEW` | unchanged | `PR #n ready for review` (or the quoted text); `mr` is the link fallback |
| `UNBLOCK` | `blocked` | `<blocker>` |
| `COLLECT` | `done` | `Finished: collect it` |
| `NUDGE` | unchanged | `Idle for <dur>`, plus ` — last said: <text>` when the monitor gives one |
| `INSPECT` | unchanged | `Stuck: <detail>` |
| `REVIVE` | unchanged | `Session gone: revive or collect` |
| `CHECK` | unchanged | `Check: <detail>` |

Capitals write `needsYou`, `needsYouSince` (line ts) and `updatedAt` (UNBLOCK also `status:"blocked"`, COLLECT `status:"done"`) and delete stale `needsYouLink*`; a write to an unknown doc creates it (adds `slug`). Afterwards add a `needsYouLink`/`needsYouLinkLabel` yourself when there is one (e.g. the PR for REVIEW). Lowercase (already reported) writes nothing. A non-waiting segment (`busy`, `parked`, ...) clears `needsYou*` only for known docs that currently have `needsYou` (a `blocked` status goes back to `working`); it never writes for a `collected` segment and never creates stub docs. Without `--docs`, non-waiting segments write nothing.

## What the manager does by hand

`brain-dispatch` and `brain-collect` do **not** touch the dashboard; do these right after running them.

- **Dispatch:** set `workers/<slug>` `{slug, status:"primed", task, host, harness, attach, updatedAt}`; move its task to `dispatched` with `worker:<slug>`.
- **Worker note flips** (seen via the monitor or a status read): mirror `status`, `mr`, `blocker`.
- **Collect:** worker `status:"collected"`, `outcome`, clear `needsYou*`; task `done` with `link` to the MR or result.
- **Message arrives** (comment wake): act on it, reply in the thread, resolve the thread when done.

**Every write pins `if_version` from a fresh read** (the script does this from `--docs`): ArtifactData refuses unpinned writes to existing docs. Prefer one `batch`.

## Waiting on you

Every waiting item carries a clickable link when one exists: workers use `needsYouLink`/`needsYouLinkLabel`, falling back to `mr`/`mrLabel`; tasks use `link`/`linkLabel`. The user's own to-dos are tasks with `worker` set to the owner (`The user`); a task is waiting when `worker == <owner>` and status is not done/parked. Clearing a waiting item when its PR merges is manual for now: do it when you see the merge.

## Pruning

The page hides done tasks and collected workers older than 7 days (by `updatedAt`). You may delete very old docs; weekly history lives in the vault, not the dashboard.

## Script reference

- `render --title T --colour C [--glyph G] [--subtitle-url U --subtitle-text S] [--owner O] [--placeholder P] -o page.html`: page from the template; one hex drives the whole theme.
- `theme <colour>`: print the theme CSS block (debug).
- `lookup <project> [--registry F]`: print the registered url, exit 1 if absent.
- `register <project> <url> <colour> [--registry F]`: idempotent upsert into `~/Obsidian/vault/dashboards.md`.
- `needs --slugs s1 s2 ... [--docs F] [--now-ms N] --line "<monitor-line>"`: print the ArtifactData `batch` writes array; exit 3 with `[]` when there are no writes. Pass the line with `--line`: a bare positional line right after the `--slugs` list is read as another slug.

Design: `specs/2026-10-06-brain-dashboard-design.md`.
