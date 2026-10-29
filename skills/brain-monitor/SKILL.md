---
name: brain-monitor
description: Watch a named set of dispatched workers (and their GitHub PRs) from a coordinator session and get ONE notification line whenever a worker starts needing you (question dialog, blocked, awaiting review, done, idle, stuck, session gone) or a watched PR changes (merged, closed, CI red, conflict, new head, green). Deterministic and read-only. Use when the user says "monitor my workers", "watch the workers", "tell me when a worker needs me", "watch this PR", or when you are a coordinator/manager session (e.g. budgebell-manager) that has dispatched workers and must react to them.
argument-hint: [--pr <url|owner/repo#n>]... <slug>...
---

# Monitor — Tell a Coordinator When Its Workers Need It

> **Harness.** If you have a `task` tool you are in omp: read `~/projects/brain/skills/_shared/harness/omp.md`. If you have an `Agent` tool you are in Claude Code: read `~/projects/brain/skills/_shared/harness/claude-code.md`. Read one, never both.

`skills/brain-monitor/scripts/worker-monitor.sh` polls the workers you name every 60 s and prints **one stdout line only when the set of waiting workers, or any waiting worker's wait, changes**. Each line summarises **all** named workers. Run under the Monitor tool, every line is a notification. No LLM call anywhere; busy workers' durations ticking never trigger a line.

It also watches **pull requests** (see *PR watch* below): the GitHub PRs named in the workers' note frontmatter, plus any given with `--pr`.

It is **read-only**: only `tmux has-session` / `capture-pane`, worker-note reads, transcript mtime and `gh pr view`. It never sends keys, attaches, or edits a pane or note (it writes only its own state file).

## Start it

Name **every worker explicitly by its full slug**. Do not include yourself. A worker's note may live in `workers/` or `private/workers/` — the script finds it either way, so name the slug only.

```
Monitor(command: "bash ~/projects/brain/skills/brain-monitor/scripts/worker-monitor.sh budgebell-log-utc budgebell-nudge-cooldown", description: "budgebell worker waits", timeout_ms: 1800000)
```

To also watch a PR no worker's note names (a release PR, an item on the dashboard's *Waiting on you* list), add `--pr` (repeatable; a PR URL or `owner/repo#n`). With only `--pr` and no slugs it watches just those PRs (label `prs`):

```
Monitor(command: "bash ~/projects/brain/skills/brain-monitor/scripts/worker-monitor.sh --label pawl-pm-watch --pr https://github.com/example-user/agent-pawl/pull/40 pawl-cli-flags pawl-docs", description: "pawl workers + release PR", timeout_ms: 1800000)
```

Use a specific `description` (it labels each notification). A watch expires after at most 30 minutes: **when it does, re-run the identical command.** State is persisted, so nothing already reported is re-emitted and durations and the idle debounce carry over.

## Reading a line

```
<iso-utc-ts> <label> <W>/<N> waiting · <worker> · <worker> …
```

`W/N waiting` counts waiting workers among the N named. Waiting workers come first. Per worker:

- `<name> NEEDS <dur> <detail>` — **CAPITALS: a new or changed wait. Act on it.**
- `<name> needs-state <dur> <detail>` — lowercase: already reported, still waiting.
- `<name> <state> <dur>` — not waiting (`busy`, `parked`, ...).
- `<name> <state>? <dur> … (stale: host <h> unreachable)` — the worker's host could not be reached this poll, so this is its **last known** state carried forward, not a fresh reading. Going stale never emits a line by itself (the host's `monitor-error` line already did); treat the row as unverified until the marker clears.

A `0/N waiting` line means everything has cleared. `<label> monitor-error <message>` means the monitor itself failed (vault missing, tmux unreachable, state dir unwritable); it keeps polling, but silence is not success, so fix or report it.

| Needs | Meaning | What you do |
|---|---|---|
| `ANSWER` | question dialog open in the pane | Relay the question (detail has text + options) to the user, or answer it if within your remit |
| `REVIEW` | blocked, awaiting review (`PR#n`) | Tell the user the PR is ready for review |
| `UNBLOCK` | blocked (detail = blocker) | Resolve it if you can, otherwise relay to the user |
| `COLLECT` | status `done` | Run the **brain-collect** skill for that slug |
| `REVIVE` | tmux session gone, note not parked | Run the **brain-revive-workers** skill (dry run first) |
| `NUDGE` | pane idle on 2+ polls while primed/working; the worker ended its turn without updating its note | Read its pane and note (`said:"..."` shows the last line of its last assistant text message, from its transcript; the pane's last `●` message when there is no transcript) and decide whether to prompt it |
| `INSPECT` | busy but transcript (and its subagents' transcripts) silent past `--stuck-after` | Read the pane; it may be hung or in a long tool call |
| `CHECK` | no note, unknown host/harness in the note (a legacy `host: local`/unset note is read as this machine, and a note with no `harness:` as omp, with one `warning:` line on stderr per slug per run — never on the event stream), a host this machine has no ssh route to (`no ssh route from <self> to <host> (hosts.conf alias -)` — monitor it from that host), or host unreachable with no earlier state for that worker (once there is earlier state, the row is carried and marked `(stale: …)` instead) | Verify the slug, note and host |

For `ANSWER` and `UNBLOCK` (and `REVIEW`), things the user must act on, also send a `PushNotification` so they see it away from the terminal.

## PR watch

The PRs watched are every `--pr` plus every GitHub PR URL in a watched worker's note **frontmatter** — `blocker:` (a worker finishing as `blocked` / `awaiting review/merge of <PR URL>`) and an optional `pr:` field (URLs or `owner/repo#n` on **one line**, separated by spaces, commas, or both; a YAML multi-line list is not read). Never the note body: bodies hold stale links. The same PR named twice is one row (owner/repo compared case-insensitively). CI is judged on the **latest** run of each check (per workflow and job name; status contexts by context), so a cancelled duplicate superseded by a re-run is not `RED`. Each is read with one `gh pr view` per poll **on this machine** (gh must be logged in here), cut off after 30 s (`BRAIN_GH_TIMEOUT`) when `timeout`/`gtimeout` exists.

PR rows come **after** the worker rows, named `#<n>` (`<repo>#<n>` when they span repos; `<owner>/<repo>#<n>` when two owners' repos share a name):

```
<name> <WORD|word>[?] @<head7> checks=<pass|fail|pending|none> <MERGEABLE|CONFLICTING|UNKNOWN>
```

Unlike worker rows (printed when a wait starts), PR rows are **change-triggered**: a line prints whenever a PR's state, head commit, mergeability or checks verdict differs from the last line (the order PRs are named in does not matter). A **changed** row is in CAPITALS; an unchanged one lowercase. (GitHub briefly flipping mergeable to `UNKNOWN` while it recomputes on the same head is not a change.) `MERGED`, `CLOSED`, `RED` and `CONFLICT` count in `W`; every PR row counts in `N`.

PR state is kept **per label** (`<label>.prs.state` in the state dir), not per slug set, so re-arming with a changed slug list after a dispatch or collect re-announces no PR, `MERGED` included. A PR named again later (a collected worker's PR re-added with `--pr`) resumes silently from what was last printed. Monitors sharing a label merge their PR records under a lock instead of overwriting each other's, a monitor that watches no PR never writes the file, and a PR unseen for 30 days is forgotten.

**A coordinator should pass an explicit `--label`** (e.g. `--label pawl-pm-watch`). The default label is derived from the slugs (one slug → the slug itself; several → their common prefix), so it shifts as the worker list changes, and the no-re-announce guarantee holds only while the label stays the same.

| Word | Meaning | What you do |
|---|---|---|
| `MERGED` | merged | Verify with `gh`, collect the worker (**brain-collect**), clear the dashboard item. Not re-queried; the row stays (lowercase) until nothing names the PR |
| `CLOSED` | closed without merging | Find out why (the user's call?); update the worker / dashboard |
| `RED` | checks failed (wins over `CONFLICT`; the detail shows both) | Send the worker back to fix CI |
| `CONFLICT` | not mergeable (conflicts with the base) | Have the worker rebase |
| `HEAD` | a new commit on an open PR | Any earlier "OK on final head" is void: re-check (review, CI) on the new head before telling the user it is ready |
| `GREEN` | checks pass and mergeable | Re-check with `gh` in the same turn, then tell the user it is ready to merge |
| `CI` / `DRAFT` | checks running / draft | Nothing yet |
| `OPEN` | open, but no checks reported (`checks=none`: a new PR whose checks have not registered) or mergeability unknown | Nothing yet. For a repo with **no CI**, `open … checks=none MERGEABLE` is its ready state: treat it like `GREEN` |

When `gh` fails (or times out) for a PR you get one `monitor-error gh <owner/repo#n>: <message>` (a message differing only in its digits, e.g. a rate-limit reset time, is not repeated) and its row is carried as `<word>? … (stale: gh)` (never read yet: `unknown? (stale: gh)`); going stale prints no line by itself. A non-GitHub PR URL in a note (a GitLab MR) gets one `warning:` on stderr per run and is not watched.

## On-demand snapshot

`worker-monitor.sh --once [--pr …] <slug>...` does one poll (PR rows included), always prints the full current line, and never touches the state file. Use it to answer "what are the workers doing?" without arming a watch.

## Flags

`--interval <s>` (60) · `--label <name>` (common slug prefix, else `workers`; with a hash of the slug set, names the state file) · `--stuck-after <min>` (30) · `--vault <dir>` · `--state-dir <dir>` · `--once` · `--pr <url|owner/repo#n>` (repeatable; part of the state file's hash, so re-arm with the same `--pr` list). Run `--help` for the full text.

## Known limitations (v1)

- **Claude Code workers only.** omp is best-effort: no `said:"..."` on idle lines, question text only from the `╭─ … ─╮` approval box, and `stuck` is never detected.
- **macOS ghost autosuggestion.** `strip_dim_ghost` uses `\x1b` in `sed -E`, which BSD sed ignores, so on a macOS host a ghost suggestion may read as typed draft text. Pre-existing; separate fix.
- **30-minute expiry** means re-arming by hand.
- **PR watch is GitHub only** (`skills/_shared/lib/forge.sh` is the seam for a GitLab backend).
- v2 candidates: hook-driven detection instead of pane scraping, and a plugin-declared persistent monitor (`experimental.monitors`) with no 30-minute expiry.

Design: `specs/2026-10-02-brain-monitor-design.md`.
