---
name: brain-collect
description: Reap a finished worker — verify its work against reality (not its self-report), mark the Today action done with the PR link or result reference, append a Shipped entry to today's diary, mark the worker collected, and offer to tear down the tmux session and jj workspace. Use when the user says "collect the finished worker", "reap <slug>", "close out that worker", "the worker's done — bring it back", or after the brain-status skill flags a finished worker.
argument-hint: [slug]
---

# Collect — Reap a Finished Worker

**Harness.** If you have a `task` tool you are in omp: read `~/projects/brain/skills/_shared/harness/omp.md`. If you have an `Agent` tool you are in Claude Code: read `~/projects/brain/skills/_shared/harness/claude-code.md`. Read one, never both.

Bring a finished worker's verified result back into the vault and mark the Today action done. It trusts **reality**, not the worker's self-report.

**How this runs:** inline in the main session. The brain-dispatch and brain-collect skills are the coordinator that touches Today statuses — the main session remains the sole writer of top-of-mind and private.md (except a coordinator worker collecting its own workers, which acts as their main session for their top-of-mind Today lines only, never private.md — see brain-dispatch's coordinator exception). Collect does its own authoritative writes (verify → `[x]`/annotate → `## Shipped`/`## Blocked` diary line), then **runs the `teardown-worker.sh` tool as a background task and returns immediately — persist-and-teardown is fire-and-forget** (see [persist-then-teardown](#persist-then-teardown)). The tool triggers the worker's **own** scoped persist (the brain-persist skill in worker mode, so its session note and knowledge notes are written from full context), waits out-of-process, and tears the session down only when its conjunction gate holds, so the main session never blocks and a worker is never killed mid-write. Collect no longer defers knowledge to a later main-session persist; the driving session's persist now covers only the user's own session.

## Vault & path facts

- Vault: `~/Obsidian/vault`
- Top of mind: `00-home/top-of-mind.md` — **Today** actions (`[ ]`/`[/]`/`[x]`/`[-]`). Private Today actions (`[private]` marker) live in `private/private.md`; `brain-scope today-file <area>` prints the right file for a worker's `area`.
- Worker notes: `workers/<slug>.md`, or `private/workers/<slug>.md` for a private worker — locate either with `brain-scope find-worker <slug>` (it prints the path). Frontmatter `slug`, `area` (`work` | `projects` | `private`; absent on older notes — treat as `work`), `project`, `today_action`, `task_type`, `project_dir`, `tmux_session`, `jj_workspace` (code), `host` (a real `hosts.conf` name, e.g. `desktop`, `homeserver`), `harness` (`omp` or `claude`), `attach` (the full attach command for the worker's session), `status` (`primed` → `working` → `blocked` → `done` → `collected`, plus `parked`), an optional `blocker` (present when `blocked`/`parked`), and an optional `collect_state` (set by the teardown tool to `collecting`, flipped to `persisted` by the worker's scoped persist — on park as well as done, so it only acknowledges one collection's persist; it has no `collected` value) with its `collect_started:` stamp. The authoritative "finished" signal is **`status: collected`**, never `collect_state`. Body `## Result` section. A note with `host: local` or no `host` is **legacy**: it is read as this machine, with a warning (teardown prints `warning: <slug>: legacy host 'local' read as <name>`, or `'unset'` for no `host`). For such a note **omit `--host`** in the teardown (or pass `--host local`) — never invent a host name. If the warning adds `— project_dir <dir> is not on this machine; it probably belongs to another host (fix its host:)`, **STOP: do not tear down** — check with the user which host the worker ran on and fix the note's `host:` first (a teardown aimed at the wrong machine is the failure this guards). A note with no `harness` field predates the dual-harness change — the harness defaults to `omp`, with a warning; pass **`--harness omp`** to the teardown for it (`--harness` is always required). Compose the attach command as `tmux attach -t <tmux_session>` for this machine's workers; the teardown invocation below uses the resolved host and harness.
- Today's diary note: `diary/YYYY-MM-DD.md` (`private/diary/YYYY-MM-DD.md` when the worker note's `area` is `private`) — determine today's date with `date +%Y-%m-%d`.
- **Editing tracked vault files.** Mutate top-of-mind, private.md, the diary and worker notes through the harness `read` → `edit`/`write` flow only — **never** with shell text-rewrites (`awk`/`sed -i`/`cp`/`mv`/`>` redirection). An out-of-band write changes the file behind the harness and makes the next edit fail with a stale-read error (this stalled the planning skills on 21 Aug 2026). If an out-of-band write is ever genuinely unavoidable, `read` the file again immediately, before any further `edit`. (The `teardown-worker.sh` tool — see [persist-then-teardown](#persist-then-teardown) — is a detached shell process, **not** the harness agent; it may flip `collect_state` in the worker note out of band precisely because the agent never re-`Edit`s that note after launching it.)

## Step 1 — identify the worker

By the `slug` argument (resolve its note with `brain-scope find-worker <slug>`), or list every `workers/*.md` and `private/workers/*.md` (the latter only when `brain-scope includes "$(brain-scope norm)" private`) with `status: done` **or** `status: blocked` and pick/confirm with the user which to collect. If nothing is `done` or `blocked`, say so and stop.

**Branch on the worker's status:**
- `status: done` → follow the **done path** (Steps 2–6 below), the standard reap. A **code** worker (`task_type: code`) should never be `done` (the brain-dispatch skill finishes code as `blocked`, awaiting merge); if one is, the done path still runs but Step 2 requires its PR(s) **MERGED**.
- `status: blocked` → follow the **blocked path** (Step B below) instead — do **not** verify-as-done and do **not** mark the Today action `[x]`.
- **Any other value** (a worker invented one, e.g. `complete`, `handed-over`) → **unknown, not an error**: verify against reality (Step 2) and route by what you find; never stop on the word alone.

**Before verifying:** if `## Result` is empty, nudge the worker in its pane to write it (and wait) before reaping. For a **long-lived / coordinator / manager** worker, or one whose Result is older than its last activity, first send a final-handover nudge, wait for it, then collect from that:
- **non-code:** *"write a FINAL HANDOVER into the Result section and set status: done"*;
- **code** (`task_type: code`): *"write a FINAL HANDOVER into the Result section; keep/set status: blocked with blocker: awaiting review/merge of <PR link(s)>"* — never `done`; it then goes down the blocked path.

## Step 2 — verify against reality (not the worker's self-report)

- **Code task:** in the jj workspace, check that the change/commits exist, that the bookmark was **pushed**, and that a **PR was raised** — resolve and capture the PR URL. For example:
  ```bash
  jj -R <jj_workspace> log -r 'trunk()..@'          # the change exists
  jj -R <jj_workspace> bookmark list                # bookmark present
  gh pr list -R <owner>/<repo> --head <bookmark> --state all --json url,state   # PR raised → capture URL
  gh pr view <PR URL> --json state,mergedAt                                      # must be MERGED
  ```
  Then check the PR is **merged** (every PR, if several): only `state: MERGED` lets you tick `[x]`. A PR that is still open is **not** a failure but not done either — set the note `status: blocked` with `blocker: awaiting review/merge of <PR link(s)>` and continue on the **blocked path** (Step B) instead of Steps 3–6.
- **Non-code task:** check the result recorded in the worker note's `## Result` section (artefact drafted, message sent/ready, decision recorded).

**If verification fails** (unpushed work, no PR, no recorded result): report exactly what is missing and **STOP** — do not mark the action done, do not change any status.

## Step 3 — mark the Today action `[x]`

In the Today file matching the worker note's `area` (`$(brain-scope today-file <area>)`: `00-home/top-of-mind.md`, or `private/private.md` for `private`), flip the originating `today_action` from `[/]` to `[x]` — for code only once Step 2 saw the PR(s) MERGED — with the **PR link** (code) or a short **result reference** (non-code) appended, per the vault convention (any PR/issue/ticket written as a markdown link to its full URL). State briefly what changed.

## Step 4 — append a `## Shipped` entry to today's diary

In `diary/YYYY-MM-DD.md` — or `private/diary/YYYY-MM-DD.md` when the worker's `area` is `private` — (create the note with minimal frontmatter if absent), append under a `## Shipped` heading a one-line entry: what shipped + the link.

```markdown
## Shipped

- <what shipped, with its state word> — [<repo>#NNN](<PR URL>)   # or the artefact/result reference for non-code
```

**Every shipped claim carries a state word** — **merged**, **tagged**, **deployed** or **enabled** — never a bare "shipped", which conflates "a PR exists" with "users have it". Write the state you actually verified, and say where it stops (e.g. "merged `#787`, not yet deployed"). This applies to the diary line, the Today-action annotation, and anything you report to the user. **If a human process change depends on the code** — a runbook, an SOP, a message telling someone to use it — the state you must verify is **deployed**, not merged: hit the live endpoint or check the deploy. A runbook once told internal staff to use an endpoint that was still returning 500 two hours after the PR merged.

## Step 4b — follow-up sweep (same pass, before teardown)

A worker's `## Result` almost always ends in next-steps that are **not** part of this action, and they die inside the session note unless they are written out now — six follow-ups in a fortnight existed only in session notes. So in this **same** pass, read the `## Result` next-steps (and any `⚡` flags), list them back to the user, and ask for each which home it needs:

- a **GitHub issue** on the project's repo (`gh issue create`) — concrete work someone will pick up; or
- a line in `00-home/backlog.md` — a longer-term thread with no owner yet; or
- **nothing** — already covered elsewhere, or deliberately dropped.

Write the approved ones **immediately, in this pass**. Do not defer them to a later persist or a "next time". Report what was written and where.

## Step 5 — mark the worker `collected`

Set `status: collected` in the worker note (`workers/<slug>.md` or `private/workers/<slug>.md`). Leave the `## Result` body intact — the worker's own scoped persist (the brain-persist skill in worker mode, triggered by [persist-then-teardown](#persist-then-teardown) at teardown) reads any `⚡ worth a knowledge note` flags to write its knowledge notes from full context.

## persist-then-teardown

The shared procedure used everywhere this skill tears a worker's session down (the done-path Step 6, the blocked-path **park**, and the blocked-path **resolved & complete → close**). It runs **after** collect's own authoritative writes (verify + `[x]`/annotate + the `## Shipped`/`## Blocked` diary line). It is **fire-and-forget**, and the whole mechanical sequence is a single CLI tool — `scripts/teardown-worker.sh` — so this skill no longer spells out the `tmux`/`send-keys`/`jj` dance on every collect. The main session runs that one command as a **background task and returns to the user immediately** (the old inline ~10-min poll is gone). The tool triggers the worker's own persist, then tears the session down out-of-process, and only when a **conjunction gate** holds — never on the `collect_state` flag alone, which previously missed flips (leaving finished workers un-reaped) and once flipped early and killed a worker mid-write.

**Run it — one background task, then return:**

```bash
bash ~/projects/brain/skills/brain-collect/scripts/teardown-worker.sh \
  --slug <slug> --host <host> --harness <harness> --project-dir <project_dir> --mode <done|park> \
  --vcs <jj|git> --jj-workspace <jj_workspace>     # omit --vcs and --jj-workspace for a non-code worker
```

- **`--mode done`** for the done-path / resolved-close (drops the workspace on teardown); **`--mode park`** to keep the workspace for a later resume (kills only the tmux session). `<host>`, `<harness>`, `<mode>`, `<jj_workspace>` and `<vcs>` values all come from the worker-note frontmatter.
- **Legacy note (no `host:` / `host: local`):** leave `--host` out (or pass `--host local`); the tool reads it as this machine and warns on stderr. **No `harness:`:** pass `--harness omp`. Because the tool runs in the background, check this **before launching it**: if `test -d <project_dir>` (with `~` expanded) fails here — the same condition behind the tool's `project_dir <dir> is not on this machine` warning — **STOP**: do not tear down; check with the user which host the worker is on and fix the note's `host:` first. If that warning ever shows up in the background task's output anyway, stop the task and do the same.
- A host this machine has no ssh route to (`hosts.conf` alias `-`, e.g. `desktop` from `homeserver`) is refused up front with rc 2 and `no ssh route from <self> to <host>` — run the collect/teardown on that host itself.
- Launch it, **do not wait on it**, and hand control straight back to the user. Do **not** trigger the persist or kill the session by hand — the tool owns the whole sequence so it alone enforces the gate.

**What the tool does** (for reference — you do not perform these steps yourself):

1. **Triggers the worker's own persist** if the session is alive: flips `collect_state: collecting` (resetting any stale value) and stamps `collect_started:` in the worker note (it is a detached process, not the harness agent, so this out-of-band edit is safe — the agent never re-`Edit`s the note after launching it), then sends the harness's own scoped-persist text into the pane (text and `Enter` as two `send-keys` calls, so a running TUI's bracketed-paste cannot swallow the `Enter`). It never types over a dialog: Remote Control's "already connected" dialog is dismissed with `Escape`; any other open question holds the prompt back (stderr `reason=question`, retried each poll; unanswered, it ends `STALLED … reason=question`). A dead session skips the persist — the worker's `## Result` note still stands.
2. **Reaps on the conjunction gate:** **(A)** the persist finished (`collect_state: persisted` after the tool reset it — no new `sessions/*.md` needed, since an unchanged worker rightly writes none — or a session note written since whose frontmatter `session_ids` carries the worker's `session_id`; no `session_id`, no fallback), **(B)** the pane is idle on two consecutive polls (no running tool, no unanswered question — this is what stops a mid-write kill), and **(C)** no uncommitted/undescribed work would be lost. Then it kills the tmux session and, for **done**, `jj workspace forget` + removes the workspace dir.
3. **On its cap (~30 min) it re-checks the gates once; still unmet, it does NOT kill** — it leaves the session running and exits `STALLED … (persisted=… idle=no reason=<why> unpushed_clear=…)`. Either way its final `REAPED …` / `STALLED …` line reaches you through the background-task completion notification. It is idempotent: re-running never re-sends the persist prompt once this collection's persist landed (a `collect_started:` older than the cap + 1 h is stale, so a much later collect persists afresh). A never-created workspace or an `@` already in trunk counts as clear; other jj workspaces under the slug are listed, not removed.

**`--force` (after a STALLED).** When A and C hold and only idle fails, the STALLED output prints the same command plus `--force`: it reaps at once, skipping only gate B. It is refused (rc 3) without a live `collect_started:` — i.e. always run the tool normally first. Run it only after checking `reason=`: `background-shell`/`background-agents` left over from the worker's own persist (e.g. `qmd embed`) → fine; `unsent-composer-text`/`busy`/`question` → attach and look first.

## Step 6 — persist-then-teardown (only after explicit confirmation)

Offer teardown, and act **only** on an explicit yes. On yes, run the [persist-then-teardown](#persist-then-teardown) procedure above with **`--mode done`** (trigger the worker's persist if the session is alive → launch the detached reaper → return to the user immediately). The reaper enforces the conjunction gate and, for a done code task, does the `jj workspace forget` + workspace-dir removal itself; it never tears down with uncommitted work.

## Step B — blocked path (worker `status: blocked`)

A `blocked` worker is **not** done, so **never** mark its Today action `[x]` on the strength of the worker's self-report alone. `blocked` now covers two situations, distinguished by the `blocker` text:

- **awaiting review/merge** (the common code case) — the work is complete and the PR(s) are up (`blocker: awaiting review/merge of <PR link(s)>`), but a human still has to merge. Raising a PR is not shipping it.
- **stuck mid-work on an external dependency** — the worker did everything it could and is waiting on a person's reply, a deploy, or a decision.

Show the worker's `blocker` and ASK the user to choose **leave**, **park**, or **resolved & complete → close**:

- **leave** — do nothing except report. Keep the tmux session running so the user can use the note's `attach` command and finish it themselves once unblocked. Make no writes: the worker note stays `blocked` and the Today action stays `[/]`.
- **park** — tear the session down but preserve the work-in-progress so a later re-dispatch resumes it:
  1. **Capture findings-so-far into today's diary.** In `diary/YYYY-MM-DD.md` (`private/diary/…` for a private worker; create with minimal frontmatter if absent), append the worker note's `## Result` findings under a `## Blocked / parked` heading (**not** `## Shipped`), noting the blocker:
     ```markdown
     ## Blocked / parked

     - <slug>: <findings-so-far summary> — blocked on <blocker>
     ```
  2. **Keep the Today action in its Today file (top-of-mind, or private.md for a private worker) as `[/]`** (do **not** flip to `[x]`) and annotate it with `⏳ blocked on <blocker>`.
  3. **Set the worker note `status: parked`** (keep its `blocker` field and its `## Result` intact).
  4. **Persist-then-teardown (`--mode park`).** Run the [persist-then-teardown](#persist-then-teardown) procedure with **`--mode park`** so the parked worker's partial journey/friction is captured — the worker's own scoped persist (the brain-persist skill in worker mode) still fires, and the reaper's gate A ensures it completes before the kill. In **park** mode the reaper kills only the tmux session and **keeps** the jj workspace (and the worker note) intact, so a later re-dispatch resumes the work-in-progress. Fire-and-forget as usual: launch the reaper and return.
- **resolved & complete → close** — the blocker has cleared and the work is genuinely complete (e.g. the PR merged). This is the normal close, but **verify against reality first**:
  1. **If the `blocker` references a PR, confirm it is actually MERGED before closing**, live, this turn: `gh pr view <PR URL> --json state,mergedAt`. If it shows **MERGED** → proceed. If it is still **open** → tell the user it is not merged yet and offer **leave** or **park** instead of closing; do not close. If there are **multiple** PRs, **all** must be merged before closing. For a non-GitHub link (or no `gh`), state that and ask the user to confirm the merge before closing.
  2. **Then do the normal close:** mark the Today action `[x]` in the Today file matching the note's `area` with the PR link / result reference appended (per the vault convention); append a `## Shipped` entry to today's diary (`diary/` or `private/diary/` by area, per Step 4 above, **with a state word**); run the Step 4b **follow-up sweep**; set the worker note `status: collected` (leaving `## Result` intact); then offer gated [persist-then-teardown](#persist-then-teardown) with **`--mode done`** exactly as in Step 6 (act only on an explicit yes; the worker's own scoped persist — the brain-persist skill in worker mode — fires, the reaper enforces the conjunction gate before the kill, and for a done code task the reaper does the `jj workspace forget` + workspace removal; it never tears down with uncommitted work).

A `parked` worker is resumed by re-running the brain-dispatch skill on the same Today action: dispatch detects the existing note and relaunches from it (re-using the kept jj workspace for code tasks) rather than starting fresh.

## Notes

- Durable knowledge is now promoted by the **worker's own** scoped persist (the brain-persist skill in worker mode), triggered by [persist-then-teardown](#persist-then-teardown) at collection — it writes the worker's session note and knowledge notes from full context, but never top-of-mind, private.md or the diary (collect owns those). The main session's own persist covers only the user's own session.
- Both **done-close** and **park** persist before teardown, so a parked worker's partial journey/friction is captured too.
- Only the brain-collect skill claims the `[/]` → `[x]` transition for a dispatched worker; the ambient status-flip rules must not double-handle it.
- **Provenance:** the Step 4b follow-up sweep and the state-word rule in Step 4 came from brain-dream (2026-07-30) — respectively six follow-ups that lived only in session notes, and a runbook published against an endpoint that was merged but not deployed. The **fire-and-forget reaper** (detached teardown, conjunction gate replacing the flag-only gate) came from brain-dream (2026-08-21) — the old inline poll blocked the user for minutes on an unreliable flag that missed flips and once killed a worker mid-write.
