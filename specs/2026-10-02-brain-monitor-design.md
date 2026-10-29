# brain-monitor — worker-fleet monitor for coordinator sessions (design + plan)

Date: 2026-10-02. Agreed with the user in the `worker-monitor` worker session.

## Goal

A coordinator session (first user: `budgebell-manager`) runs
`Monitor(worker-monitor.sh <slug>...)` and gets **one stdout line whenever the set of
waiting workers changes** — each line summarising **all** the watched workers, with what
is happening and what is needed. Deterministic: no LLM call anywhere.

## Decisions (settled with the user)

1. **Print only on change.** A line is emitted when the waiting set, or any waiting
   worker's wait (kind + its detail key), differs from the last emitted line. No repeats,
   no reminders. Busy workers' durations ticking never trigger a line.
2. **Workers are named explicitly** as positional args (`worker-monitor.sh log-utc …` by
   full slug). No project filter, no self-exclusion logic.
3. **Blocked-for-review counts as waiting.**
4. **Poll every 60 s** by default (`--interval <s>`).
5. **Standalone skill** `skills/brain-monitor/` — not wired into brain-status.
6. **Pane-based detection** via the existing `skills/_shared/lib/harness-chrome.sh`
   (`pane_question`, `pane_busy`, `pane_idle`), not hooks. Hooks and a plugin-declared
   persistent monitor (`experimental.monitors`, no 30-min expiry) are v2 candidates.

## Monitor tool facts the design rests on

[verified: Monitor tool schema + https://code.claude.com/docs/en/tools-reference#monitor-tool]
Each stdout line = one notification (lines within 200 ms batch); noisy monitors are
auto-stopped; every watch expires after ≤ 30 min and must be re-armed by re-running the
same command; stderr does not notify. ⇒ the script persists last-emitted state and is
idempotent across restarts; it reports its own failures on stdout (silence ≠ success).

## Interface

```
worker-monitor.sh [--interval <s>] [--label <name>] [--stuck-after <min>]
                  [--vault <dir>] [--state-dir <dir>] [--once] <slug>...
```

- `--label` (default: longest common `-`-terminated prefix of the slugs minus the `-`,
  else `workers`) names the state file and is the 2nd field of every line.
- Display names: each slug with that common prefix stripped (`budgebell-log-utc` → `log-utc`).
- `--once`: one poll, **always** print the full current line (snapshot), do not touch state.
- `--stuck-after` default 30 (minutes).
- State: `${XDG_STATE_HOME:-$HOME/.local/state}/brain/worker-monitor/<label>-<cksum>.state`
  (`<cksum>` = `cksum` of the C-sorted slug list, so two monitors sharing a label never
  clobber each other; fix wave after review),
  written atomically (tmp + mv). Holds per worker: last state, its detail key, and the
  epoch it entered that state; plus the last emitted waiting-signature.
- `--help` documents the exact Monitor invocation.
- Env overrides for tests: `BRAIN_TMUX`/`BRAIN_SSH`/`BRAIN_HOSTS` (host.sh),
  `MONITOR_NOW` (fake epoch), `MONITOR_MAX_POLLS` (stop the loop after N polls).

## Per-worker classification (each poll, first match wins)

Inputs: note frontmatter (`status`, `blocker`, `host`, `harness`, `tmux_session`,
`session_id`, `project_dir` — strip trailing ` # comment`, as revive-workers.sh `fm_get`);
pane capture of the VISIBLE screen (`tmx <host> capture-pane -p $(pane_capture_flags) -t
<session>`) for every state predicate — scrollback prose such as `Do you want to proceed?`
must never read as an open question — plus, only for the question/last-message detail
text, a history capture (`… -S -60`); claude transcript mtime = the newest of
`~/.claude/projects/*/<session_id>.jsonl` and `~/.claude/projects/*/<session_id>/subagents/*.jsonl`
(via `run_on_host` for remote hosts).

| # | Condition | state | needs | detail |
|---|---|---|---|---|
| 1 | note missing/unreadable | `unknown` | `CHECK` | `no note` |
| 2 | status `collected` | `collected` | — (not waiting) | |
| 3 | status `done` | `done` | `COLLECT` | |
| 4 | tmux session absent, status not `parked` | `gone` | `REVIVE` | `note=<status>` |
| 5 | `pane_question` | `question` | `ANSWER` | question text + options |
| 6 | status `blocked`, blocker contains `awaiting review` | `review` | `REVIEW` | `PR#<n>` from blocker URL, else blocker |
| 7 | status `blocked` | `blocked` | `UNBLOCK` | blocker verbatim |
| 8 | status `parked` | `parked` | — (not waiting) | |
| 9 | `pane_idle`, status `primed`/`working`, idle on ≥ 2 consecutive polls | `idle` | `NUDGE` | `note=<status> said:"<last message>"` (last line of the last assistant text message in the transcript; pane fallback) |
| 10 | `pane_busy`, claude transcript mtime older than `--stuck-after` | `stuck` | `INSPECT` | `busy <N>m, transcript silent <N>m` |
| 11 | otherwise | `busy` | — | |

Detail text: whitespace collapsed, `"` removed, truncated to 160 characters (not bytes —
the cut runs under a UTF-8 locale even when the host's is C) with `…`.

Host unreachable (tmux over ssh fails, not "session absent"): a worker with earlier state
keeps it, rendered `<name> <state>? <dur> … (stale: host <h> unreachable)`; its signature
entry is unchanged, so going stale emits nothing beyond the host's one `monitor-error`.
Without earlier state it is `unknown`/`CHECK` `host <h> unreachable`.
Question text extraction and last-message extraction are **harness chrome** and so live in
`harness-chrome.sh` (new functions `pane_question_text`, `pane_last_message`), tested
against the existing fixtures — claude `question.txt` shows the shape: `☐ <header>`,
`│ <question>` lines, numbered options `❯ 1. Yes` / `  2. No`, dropping "Type something"/
"Chat about this". Last message = for a claude worker with a `session_id`, the last
non-blank line of the last non-sidechain assistant entry with a text block in its MAIN
transcript `~/.claude/projects/*/<id>.jsonl` on its host (only the last 200 lines are read,
parsed by `jq` on that host; a leading `- `/`* `/`#`/`>` marker dropped) — the pane has no
scrollback, so a long final message's `●` line is often off-screen. With no transcript, no
`jq` or no text there, and always for omp, it falls back to the pane: the last `●`-led
block's first line.

## Output line

```
<iso-utc-ts> <label> <W>/<N> waiting · <worker> · <worker> …
```
Waiting workers first (in argument order), then the rest. A waiting worker whose wait is
new or changed since the last emitted line: `<name> <NEEDS> <dur> <detail>` (NEEDS in
capitals). One already reported: `<name> <state-lowercase> <dur> <detail>`. Non-waiting:
`<name> <state> <dur>`. Durations are time in current state (`<N>m`, `<N>h`).
When the waiting set becomes empty, emit one line `0/N waiting · …`.
First run with no state file: emit iff anything is waiting.
Script-level failure (vault dir missing, tmux server unreachable, state dir unwritable):
`<ts> <label> monitor-error <message>`, once per distinct message; keep polling.

Examples:
```
2026-10-02T10:04:00Z budgebell 1/3 waiting · log-utc ANSWER 2m "Find brief: Rewrite existing log rows too? [1 Yes / 2 No]" · linux-quiet-probes busy 14m · nudge-cooldown busy 3m
2026-10-02T10:31:00Z budgebell 2/3 waiting · log-utc REVIEW 0m PR#12 · nudge-cooldown review 40m PR#9 · linux-quiet-probes busy 1m
2026-10-02T11:10:00Z budgebell 0/3 waiting · log-utc busy 1m · linux-quiet-probes busy 9m · nudge-cooldown busy 1m
```

## Known limitations (accepted for v1)

- **omp workers are best-effort only.** v1 targets Claude Code workers. For omp:
  `pane_last_message` always returns rc 1 (no fixture shows a finished omp reply), so idle
  lines carry no `said:"…"`; question text is extracted only from the `╭─ … ─╮` approval
  box (other omp dialog wordings were never captured); `stuck` is never detected (no
  transcript-mtime lookup for omp). The user agreed (2026-10-02) to defer omp support.
- **Pre-existing, out of scope:** `strip_dim_ghost` uses `\x1b` in `sed -E`, which BSD sed
  doesn't honour — 4 ghost tests fail on macOS on unmodified `main` too, so a ghost
  autosuggestion may read as a typed draft on the Mac host. Separate fix.

## Plan (TDD, subagent-executed, one jj change)

- **T1 (opus)** — `harness-chrome.sh`: `pane_question_text <harness> <pane>` and
  `pane_last_message <harness> <pane>` for claude and omp, red-green in
  `harness-chrome.test.sh` against the existing fixtures (add an omp shape only from the
  existing omp fixture; never invent chrome). Update the header function list.
- **T2 (opus)** — `skills/brain-monitor/scripts/worker-monitor.sh` +
  `worker-monitor.test.sh`: offline tests with a temp vault, stub `BRAIN_TMUX` serving
  fixture captures per session, `MONITOR_NOW`/`MONITOR_MAX_POLLS`; cover every table row,
  debounce, change-only emission, restart idempotence, `--once`, monitor-error, comment-
  stripped status.
- **T3 (sonnet)** — `skills/brain-monitor/SKILL.md` (coordinator usage: the exact Monitor
  call, re-arm on expiry, reading lines, the needs table) and a README entry.
- **T4 (haiku)** — gates: all `*.test.sh` in the repo green; a read-only live `--once`
  against the Budgebell workers.

## PR watch (2026-10-19)

Added for the PM + tech-lead coordinator pair, whose bottleneck is PR state (merge, CI,
new heads), not pane state. Settled with the user: it lives **in** worker-monitor.sh (one
Monitor, one line), not a second script; GitHub only, behind a small forge interface.

- **Forge seam** — `skills/_shared/lib/forge.sh`: `pr_ref_parse` normalises a PR URL or
  `owner/repo#n` to `github:<owner>/<repo>#<n>` (anything else rc 1); `pr_status` prints
  `<OPEN|DRAFT|MERGED|CLOSED> <head7> <MERGEABLE|CONFLICTING|UNKNOWN> <pass|fail|pending|none>`
  from one `gh pr view --json state,isDraft,headRefOid,mergeable,statusCheckRollup`.
  `BRAIN_GH` stubs gh (as `BRAIN_TMUX`/`BRAIN_SSH` stub tmux/ssh). A GitLab backend = a
  `gitlab:` prefix in both functions; callers never branch on the forge. gh runs on the
  coordinator's machine, never over ssh.
- **Which PRs** — `--pr` (repeatable; slugs become optional, label `prs`) plus GitHub PR
  URLs in each watched worker's note **frontmatter** (`blocker:`, optional `pr:`), never
  the body (stale links). Deduplicated by normalised ref. A non-GitHub URL: one stderr
  `warning:` per slug+ref per run.
- **Rows** — after the worker rows, `#<n>` (or `<repo>#<n>` across repos),
  `<word> @<head7> checks=<c> <mergeable>`. **Change-triggered**, unlike worker rows: the
  signature carries every PR's (state, head, mergeable, checks), so any change prints a
  line; changed rows are CAPITALS (`MERGED` `CLOSED` `RED` `CONFLICT` `HEAD` `GREEN` `CI`
  `DRAFT` `OPEN`), unchanged lowercase. RED beats CONFLICT; HEAD = an open PR's head
  differs from the last printed line and it is neither red nor conflicting. MERGED/
  CLOSED/RED/CONFLICT count as waiting. Worker rows, and lines with no PR named, are
  unchanged.
- **Noise control** — mergeable `UNKNOWN` (GitHub recomputing after a push) is replaced
  by the last printed value, so it never triggers a line alone — on the same head only
  (after a rebase the old `CONFLICTING` no longer holds, so the row reads `HEAD`). A
  MERGED PR is never re-queried. Rows have no duration (they are change events).
  Changes are compared per PR, so the order PRs are named in never matters.
- **Checks** — only the latest run per (workflow, job name) / status context counts
  (startedAt, then completedAt, then array position), so a cancelled duplicate left by a
  re-push is not RED while the same job name in two workflows stays two checks.
  `checks=none` is not green: a brand-new PR reads `OPEN` until its checks register (for
  a repo with no CI, `OPEN … checks=none MERGEABLE` is the ready state).
- **Names / refs** — owner/repo lowercased in the normalised ref (GitHub names are
  case-insensitive); `owner/repo#n` names when two owners' repos share a name; URLs are
  split at commas; `pr:` is one line (no YAML multi-line lists).
- **Failures** — gh failing (or timing out: `timeout`/`gtimeout` when present, 30 s,
  `BRAIN_GH_TIMEOUT`) for a PR: one `monitor-error gh <owner/repo#n>: <msg>`, deduped on
  a key with the message's digits folded (rate-limit reset times vary per poll; the text
  printed is verbatim); the last good tuple carried as `<word>? … (stale: gh)`; with
  none, `unknown? (stale: gh)` and no change recorded, so going stale never prints a line.
- **State** — PR state lives in a per-LABEL file `<label>.prs.state` (last good tuple per
  PR + the tuples last printed), not the per-slug-set file: the PM re-arms with a changed
  slug list after every dispatch/collect, and that must not re-announce every PR (a
  re-announced MERGED invites a duplicate collect). Default labels collide (`pawl-pm
  pawl-tl` and `pawl-feat pawl-fix` are both `pawl`), so the file is MERGED, never
  replaced: a run writes only the PRs it watched and keeps all others' records (a PR
  named again resumes from its last printed tuple — a collected worker's merged PR
  re-added via `--pr` stays silent); a run watching no PR never writes it; the
  read-modify-write holds a mkdir lock (no flock on macOS) taken over when older than a
  minute; a PR unseen for 30 days (`MONITOR_PR_TTL_DAYS`) is dropped. The derived label
  shifts with the slug set, so coordinators pass an explicit `--label`. The slug-set hash
  still covers the normalised `--pr` refs (no `--pr` → the same hash as before).
- **Out of scope** — a persistent monitor (`experimental.monitors`), GitLab, review
  comments/approvals.
