# Design: Brain worker execution layer

Date: 2026-07-06
Status: design approved (sections confirmed in brainstorming); pending implementation plan.

> **Partly superseded (2026-09-11 port to Linux + oh-my-pi).** The worker *model* in this design still
> holds — a primed detached tmux session driving one Today action, vault-only coordination state, the
> worker note's `status` field, and persist-then-teardown. Three *mechanisms* have since moved on:
> skills are now discovered by omp through `skills.customDirectories` instead of being symlinked into
> `~/.claude/skills/` (see §"Skill storage"), workers are launched with `omp --auto-approve` instead of
> `claude`, and Claude Code's Remote Control (`/rc`) is gone. `detect-vcs` is now a direct `.jj`/`.git`
> check rather than a `team-engineer` plugin script. See the README for the current wiring.

## Problem & goal

The brain currently *knows about* tasks and *records* them, but it has no way to *run* them. A **Today** action sits on top-of-mind as a `[ ]` checkbox; turning it into work still means opening a fresh session by hand, re-hydrating context, and driving it yourself.

This feature adds an **execution layer**: three new commands — `/brain-status`, `/brain-dispatch`, `/brain-collect` — that turn a Today action into a primed worker session, let you work in it, and reap the verified result back into the vault.

It is **purely additive**. The six existing brain-* skills and the vault/qmd substrate are unchanged. The design is adapted from an external "cmux-worker" framework, but rebuilt for this setup: **jujutsu (jj)** instead of git, **plain tmux** instead of cmux, and **vault-only** coordination state.

## Core principles (carried over from the existing system)

- **Nothing lives only in a conversation.** Everything is captured to files in the vault — including a worker's brief and its result.
- **The Today status vocabulary is reused.** `[ ]` to do · `[/]` in progress · `[x]` done — with an MR link on completion for code tasks. No new statuses are introduced. Note that for code, `[x]` means the MR was **merged**, not merely raised: a code worker can only raise an MR (a human merges it later), so it terminates at `blocked` (awaiting review/merge) and the action reaches `[x]` only once the MR is merged; non-code tasks have nothing to merge and terminate at `done`.

## 1. The three commands

### `/brain-dispatch <today action> [base directory]` — prepare and launch a worker

Prepares and launches a worker for a **Today** action. The optional **base directory** is the directory the worker session is rooted in (see [Base directory](#base-directory)).

**How this runs:** the **main session** does only two things — it identifies the target Today action (step 1 below), and, as the [sole writer of top-of-mind](#2-division-of-labour-for-persistence), performs the final status flip (step 8). Everything in between — the whole prepare-and-launch (steps 2–7) — is delegated to a **single launcher subagent** that returns only a concise summary (slug, task type, resolved project directory, tmux session name, verified yes/no, worker-note path, and the exact Today action text to flip; on failure, the reason and that nothing was launched). This keeps the qmd log, the worker-note body, and the tmux/capture-pane output out of the main thread, so the **main-session context cost is essentially one line in and one line out plus the top-of-mind flip**. The launcher subagent **must not** touch top-of-mind.

1. **Identifies the target Today action** (main session) — from the argument or by matching top-of-mind, disambiguating with the user, and noting any explicit base-directory argument. If a worker note already exists for the resolved slug with status `blocked` or `parked`, this is a **resume**: the launcher relaunches the session pointing Claude at the existing note (preserving its accumulated result and gathered context — never overwriting them), sets status back to `working` on verified relaunch, and for a `parked` code task the worker `cd`s back into the kept jj workspace rather than creating a new one.
2. **Gathers relevant context:** a qmd search of the vault + relevant meeting notes + the **This week** goal the action serves.
3. **Classifies** the task as **code** or **non-code**.
4. **Derives a short slug** from the action (e.g. `flaky-ui-suite`, `follow-up-sam-recordings`), used consistently for the tmux session name, the vault worker-note filename, and (for code) the jj workspace name — so all three are trivially linkable.
5. **Writes a worker note** in the vault (see [Data model](#3-data-model-the-worker-note)) containing the brief, the gathered context, a status field, and (later) the result. It **records the intended working directory**: the session is **always** initialised in the associated project's directory — for **both** code and non-code tasks — inferred from the Today action and gathered context (see [Base directory](#base-directory)); an explicit base-directory argument overrides the inference. `/brain-dispatch` **does not** create the `jj workspace`; it only records the *intended* workspace name/path in the worker note as the convention the worker will follow.
   - **Code task** — the session starts in the project directory (an already-trusted checkout); the **worker itself** creates its `jj workspace` (rooted on the trunk, the jj equivalent of a git worktree) as its first action, so parallel workers don't collide.
   - **Non-code task** — no workspace; the session simply runs in the project directory.
6. **Launches a detached `tmux` session** named `brain-worker-<slug>`, with cwd = the project directory for both task types. The launch command points Claude at its brief **in the vault** (a note path, **not** a long inline `--command` string) to avoid multi-line-prompt mangling.
7. **Verifies the session actually came up and Claude actually started**, and sets the worker note to `working`, before reporting it as dispatched — it never trusts "session created" as "agent ready".
8. **Flips the Today action to `[/]`** in top-of-mind (main session, sole writer) once the launcher subagent reports a verified launch — adding a `— dispatched worker brain-worker-<slug>` suffix — then reports one line to the user. If the subagent reports failure, the action is **not** flipped.

Steps 2–7 are the launcher subagent's work; steps 1 and 8 are the main session's.

#### Local repo location convention

`/brain-dispatch` resolves a bare repo name to a local path using a fixed convention that mirrors the **full** GitLab group hierarchy under gitlab.com

- **GitLab repos** (the common case) live at `~/projects/gitlab/<full/group/path>/<repo>`, mirroring the **complete** GitLab group nesting (groups can be several levels deep) — e.g. `gitlab.com/example-group/backend/example-project` resolves to `~/projects/gitlab/example-group/backend/example-project`, and `gitlab.com/example-group/agent-platform` to `~/projects/gitlab/example-group/agent-platform`.
- **GitHub repos** (the exceptions) live at `~/projects/<repo>`.

This is how a code task locates the repo on disk. After resolving the project directory (by inference or explicit argument), `/brain-dispatch` **verifies the directory exists on disk before launching**; if it does not exist, it reports that and does **not** launch the session or flip the Today action.

#### Base directory

The **base directory** is where the worker session is rooted. By default `/brain-dispatch` **infers the associated project/repo** from the Today action and gathered context and initialises the session in that project's directory — for **both** code and non-code tasks. The optional base-directory argument overrides the inference.

- **Rationale:** to keep the history of all sessions related to a given project co-located. Every agent-platform session — code or not — is initialised in `~/projects/gitlab/example-group/agent-platform`, so a non-code "design an agent-platform experiment" session (designing an experiment, no implementation) lives alongside the agent-platform code sessions and inherits that project's context and env (e.g. picking up a specific `.env`).
- **Code task** — the base directory is the repo the session starts in (inferred and resolved via the [location convention](#local-repo-location-convention), or given explicitly); the worker creates its `jj workspace` from there as its first action.
- **Non-code task** — the base directory simply sets the working directory of the tmux session.
- **Fallback** — the neutral dir (the brain repo) is the **last resort**, used only when no project can be associated with the action.

### Worker session behaviour (what the launched session does)

- **On start**, it gathers/absorbs the relevant context (its brief note is already populated), then greets you with a **concise proposed action list** — phrased as *intent* ("fix the flaky UI integration suite", "follow up with Sam on the recordings"), **not** step-by-step instructions ("open file X, change function Y").
- **After the proposal it becomes a normal interactive session** that you drive. Typically you just say "do that then" and it proceeds. This is the agreed autonomy model: it works out what needs doing, proposes, then behaves like a normal session — it is **not** fire-and-forget autonomous.
- **Code tasks** are primed to, **first**, create their own `jj workspace` from the project directory and `cd` into it (the session's Bash cwd persists between calls), doing all subsequent work inside that workspace; then to: do red-green TDD; use subagents wherever possible; and set appropriate model tiers per subtask (cheap mechanical work on cheaper tiers, judgement-heavy work on the top tier — per the Acme workflow model-tiering rubric).
- **Non-code tasks** (e.g. "follow up with A on topic B") are primed to gather the relevant context (who A is, what B is, from meeting notes / Slack), then prompt you with the concise action — often drafting the message or artefact so you just review and send.
- **On finishing**, the worker writes its outcome into **its own** vault worker note (the completion handshake): what shipped, the MR link(s) (code), key decisions, gotchas, and optionally a `⚡ worth a knowledge note: …` flag. Its terminal status **differs by task type**:
  - **Non-code** — the artefact/outcome is complete and there is nothing to merge, so it sets `done`.
  - **Code** — raising an MR is **not** shipping it; a human merges it later. So when the work is complete and the MR(s) are up, the worker sets `blocked` with `blocker: awaiting review/merge of <MR link(s)>` — **not** `done`. The task reaches `[x]` only later, once the MR is actually merged (via `/brain-collect`).
- **On being blocked mid-work**, the worker also sets `blocked` if it has done everything it can but cannot reach the goal because it is **waiting on an external event** (a person's reply, a deploy, a decision), adding a `blocker` field naming what/who it is waiting on and writing its findings-so-far into the result section, then stops — it does not spin or invent other status values. So `blocked` covers **both** "work complete, MR up, awaiting review/merge" (code) **and** "stuck mid-work on an external dependency", distinguished by the `blocker` text. The Today action reaches `[x]` only when the work is **genuinely complete** — a non-code artefact done, or a code MR actually merged — never at MR-raise time.
- **On resume** (re-dispatch of a `blocked`/`parked` worker), the worker is relaunched pointing at its **existing** note: its accumulated result and gathered context are preserved (never overwritten), it goes back to `working`, and for a `parked` code task it `cd`s back into the kept jj workspace rather than creating a new one.
- **Worker persistence is scoped, not blanket-forbidden.** A worker never *spontaneously* runs a full persist and never writes top-of-mind or knowledge notes as part of normal finishing (its `## Result` note is the handoff). But a worker session holds the full journey — decisions, reasoning, Claude Code friction — that the task-scoped result note doesn't capture, so the worker MAY run **`/brain-persist worker`**: a **scoped** persist that writes its own session note (`sessions/<date> <topic>.md`, with a `## Claude Code workflow friction` section when relevant) + knowledge notes + re-index, but **never** touches top-of-mind and **never** writes the diary. It can run this as a mid-session voluntary checkpoint, and — the primary path — **`/brain-collect` triggers it in the still-running session at teardown** (see [collect](#brain-collect--reap-a-finished-worker)). Top-of-mind stays single-writer (the driving session; `/brain-collect` owns the `[x]`), and the diary line is owned by collect, so a worker touching either would duplicate a completed action (observed in testing).
- **An explicit user command overrides brief defaults** — if the user types `/brain-persist` in the worker session, the worker honours it; the finishing-behaviour defaults do not override a direct instruction.
- **Concurrency.** Shared-file writes (top-of-mind, knowledge notes) may collide when several agents write at once; a write rejected as out-of-date is retried (re-read, re-apply) until it succeeds.

### `/brain-status` — lightweight "where am I at"

A lightweight, **read-only** command. It reads **only** top-of-mind + today's `diary/` note + the vault worker notes. No qmd search, no re-hydration, no writes.

It buckets the workers into **three** groups, reading each note's `status` (and `blocker`):

- ✅ **Ready to collect** — status `done` (not yet `collected`). Its distinctive job: **flag any finished-and-uncollected worker** ("N workers finished — run `/brain-collect`"), surfaced prominently.
- ⏳ **Blocked — needs you to unblock** — status `blocked` or `parked`, each shown with its `blocker`. For `blocked` there is still a live tmux session (give the `tmux attach -t brain-worker-<slug>` command); for `parked` the session was torn down and it resumes via re-dispatch.
- 🔄 **In flight** — status `working`/`primed`, each with its attach command.

It sits between `/brain-orient` (heavy re-hydration) and just opening the file.

### `/brain-collect` — reap a finished worker

Reaps a finished worker. It branches on the worker's status.

**Done path** (status `done`):

1. **Verifies against reality**, not the worker's self-report:
   - **code** — checks the jj change/commits, that the bookmark was pushed, and that an MR was raised;
   - **non-code** — checks the result recorded in the worker note.
2. **Marks the Today action `[x]`** in top-of-mind — with the MR link for code, or a result reference for non-code.
3. **Appends a `## Shipped` entry** to today's `diary/` note.
4. **Persist-then-teardown** (see [below](#persist-then-teardown)) — **only** after your confirmation, and **never** when there is unpushed work: before killing the session it triggers the worker's own scoped `/brain-persist worker` and waits for the file-based completion signal, then tears down the tmux session and (for code) the jj workspace.

#### persist-then-teardown

Everywhere `/brain-collect` tears a worker's session down — the done path above, and the blocked-path **park** and **resolved & complete → close** — it runs this shared procedure **after** its own authoritative writes (verify + `[x]`/annotate + the `## Shipped`/`## Blocked` diary line) and **before** killing the session, so the worker's journey/friction is captured from full context first:

1. **Dead-session guard** — if the worker's tmux session is not alive (`command tmux has-session` fails), skip the in-session persist (the `## Result` note still stands, but warn that the journey couldn't be captured) and go straight to teardown. (Reviving a dead session via `claude --resume` is out of scope.)
2. Set `collect_state: collecting` in the worker note.
3. Trigger the scoped persist in the live session: `command tmux send-keys -t brain-worker-<slug> '/brain-persist worker' Enter`.
4. **Wait for the file-based completion signal** — poll the worker note (not the tmux pane) until `collect_state` becomes `persisted`; poll generously (e.g. every ~10s up to ~10 min, as persist can take minutes).
5. **Only then tear down** — kill the tmux session; for a done/resolved code task also `jj workspace forget` + remove the workspace dir; for **park** keep the jj workspace (a resume re-uses it). Never with unpushed work.
6. If the signal never arrives within the timeout, **do not kill** — report that persist didn't complete and leave the session for inspection.

**Blocked path** (status `blocked`): a `blocked` worker is **not** shipped, so `/brain-collect` never closes the Today action to `[x]` on the strength of the self-report alone. `blocked` covers two situations, distinguished by the `blocker` text — **awaiting review/merge of an MR** (the common code case: work complete, MR up, a human still has to merge) and **stuck mid-work on an external dependency**. It shows the `blocker` and asks you to choose **leave**, **park**, or **resolved & complete → close**:

- **leave** — do nothing except report; keep the tmux session running so you can attach and finish it once unblocked (no writes: the note stays `blocked`, the action stays `[/]`).
- **park** — (1) capture the worker note's findings-so-far into today's `diary/` note under a `## Blocked / parked` heading (**not** `## Shipped`), noting the blocker; (2) keep the Today action `[/]` in top-of-mind, annotated `⏳ blocked on <blocker>`; (3) set the worker note status to `parked`; (4) **persist-then-teardown** — park also runs the scoped `/brain-persist worker` before teardown (see [persist-then-teardown](#persist-then-teardown)), so a parked worker's partial journey/friction is captured too — then tear down the tmux session but **keep** the worker note and (for code) the jj workspace intact. A `parked` worker resumes by re-running `/brain-dispatch` on the same action, which detects the existing note and relaunches from it (re-using the kept jj workspace).
- **resolved & complete → close** — the blocker has cleared and the work is genuinely complete (e.g. the MR merged). **Verify against reality first:** if the `blocker` references an MR, confirm it is actually **merged** before closing (`glab mr view <iid> -R <project-path>`, with the project path/IID taken from the MR URL); all MRs must be merged if there are several. If any is still open, `/brain-collect` reports that it is not merged yet and offers leave/park instead of closing; if `glab` is unavailable, it asks you to confirm the merge. Once verified, it does the normal close: marks the Today action `[x]` with the MR link / result reference, appends a `## Shipped` entry to today's `diary/` note, sets the worker note `status: collected`, and offers gated [persist-then-teardown](#persist-then-teardown) of the tmux session and (for code) the jj workspace.

## 2. Division of labour for persistence

- **Workers** own their per-worker vault note, and — via the scoped `/brain-persist worker` — their **own** session note and any knowledge notes. Because a worker holds the full journey (decisions, reasoning, Claude Code friction) that its task-scoped result note doesn't capture, it is best placed to persist that journey. `/brain-collect` orchestrates this at teardown: it does its authoritative writes, then triggers the worker's scoped persist in the still-running session and waits for the file-based `collect_state: persisted` signal before killing it (see [persist-then-teardown](#persist-then-teardown)). The scoped persist writes the session note + knowledge notes + re-index but **never** top-of-mind and **never** the diary.
- The **main session's** `/brain-persist` now covers **only the user's own driving session** — its single dated session note, top-of-mind reconciliation, and its own knowledge notes. It no longer sweeps collected workers' result notes for knowledge promotion; each worker persists its own knowledge at collection instead.
- **top-of-mind is single-writer** (the main/driving session). `/brain-dispatch` and `/brain-collect` are the coordinator touching Today statuses (`[ ]` → `[/]` on dispatch, `[/]` → `[x]` on collect); workers never write top-of-mind, even during their scoped persist.
- **Concurrency.** Shared-file writes (top-of-mind, knowledge notes) may collide when several agents write concurrently; a write rejected as out-of-date is retried until it succeeds.

## 3. Data model: the worker note

One vault note per worker, filename keyed by the slug. Proposed location: a `workers/` folder in the vault (`workers/<slug>.md`) — noted here as a **proposal to confirm during planning**.

Fields:

- **slug / id**
- **the originating Today action text**
- **the This week goal it serves**
- **task type:** `code` | `non-code`
- **gathered context** — qmd results, meeting-note links
- **jj workspace path** (the *intended* path the worker will create, not one dispatch created) **+ tmux session name** (for linkability)
- **status:** `primed | working | blocked | done | collected | parked`
- **blocker** (set only when status is `blocked` or `parked`): what/who the worker is waiting on (a person's reply, a deploy, a review, a decision)
- **collect_state** (optional; absent normally): the persist-then-teardown handshake between `/brain-collect` and the worker's scoped persist. `/brain-collect` sets it to `collecting` to trigger the worker's `/brain-persist worker`; the worker's scoped persist flips it to `persisted` as the file-based completion signal collect polls for before teardown. If `collect_state` is absent when a worker runs a voluntary mid-session `/brain-persist worker`, the worker leaves all status fields untouched.
- **result section** (filled at completion): outcome, MR link or artefact reference, decisions, gotchas, optional knowledge-note flags

The status enum is unchanged (`primed | working | blocked | done | collected | parked`); `blocked` now also covers "work complete, awaiting review/merge". The lifecycle is: `primed → working`, then **non-code** goes `working → done` (artefact complete, nothing to merge) while **code** goes `working → blocked` with `blocker: awaiting review/merge of <MR link(s)>` (the MR is up but a human merges it, not the worker); `working → blocked` also happens when a worker is stuck mid-work on an external dependency. A non-code `done` worker goes `done → collected` (via `/brain-collect`). A `blocked` worker has three onward routes via `/brain-collect`: `blocked → collected` ("resolved & complete → close", once the MR is verified merged / the blocker has genuinely cleared), `blocked → parked` ("park"), or it stays `blocked` ("leave", so the user drives it to completion in its live session). A `parked` worker returns to `working` when re-dispatched (resuming from its note). The Today action reaches `[x]` only on a genuine close — non-code `done`, or a code MR verified merged — never at MR-raise time.

## 4. jj / tmux specifics

- **jj workspaces** (not git worktrees), rooted on trunk, for code tasks — created by the **worker itself** (not by `/brain-dispatch`) as its first in-session action; parallel workers are isolated from one another.
- **Coordination state is vault-only.** No temporary files (brief, result, sentinel) ever land in the jj workspace, so nothing pollutes the jj change history. "Done" is a **status field** on the vault note, not a filesystem sentinel.
- **Plain tmux** (not cmux): detached sessions, predictable names (`brain-worker-<slug>`), and the launch-verification step above.

## 5. What stays unchanged

The vault, qmd, top-of-mind, This week goals, meeting notes, the status vocabulary, and the six existing brain-* skills (`/brain-orient`, `/brain-persist`, `/brain-sync-meetings`, `/brain-plan-day`, `/brain-post-standup`, `/brain-plan-week`).

## 6. Skill storage and versioning

Until now, skills have been *described* in this repo but *implemented* directly in `~/.claude/skills/`, so the actual skill files are not version-controlled. We are inverting this: the brain repo becomes the **single source of truth** for the skill files, version-controlled in jj, and `~/.claude` merely points at them.

### Mechanism

- Skills live in the brain repo under `skills/<skill-name>/` (e.g. `skills/brain-dispatch/SKILL.md`), as real, jj-tracked files.
- Each skill is exposed to Claude Code via a **symlink at the skill-directory level**: `~/.claude/skills/<skill-name>` → `~/projects/brain/skills/<skill-name>`. Symlinking the whole directory (not individual files) means bundled reference/script files travel with the skill.
- We do **not** symlink the entire `~/.claude/skills/` folder — it also holds skills from other sources (plugins, etc.); we create one symlink per brain skill.
- Result: the source of truth is versioned in the repo, while Claude Code still discovers the skills in their standard location.

### Applies to

- **The three new worker skills** (`brain-status`, `brain-dispatch`, `brain-collect`) are authored this way from the start.
- **The six existing brain-* skills** that currently live only in `~/.claude/skills/` — `brain-orient`, `brain-persist`, `brain-plan-day`, `brain-plan-week`, `brain-post-standup`, `brain-sync-meetings` — are **migrated** into the repo: move each directory from `~/.claude/skills/` into `skills/` in the repo, then replace the original location with a symlink pointing back. This migration must be **non-destructive** — verify each skill still resolves after symlinking, and take care not to lose any bundled files. It is an early implementation step (done before or alongside building the new skills), and it changes no behaviour — only the physical location of the files and the fact that they are now versioned.

### Implementation note

Confirm at implementation time that Claude Code **follows symlinks for skill discovery**. This is the standard dotfile-management pattern and is expected to work, but should be verified rather than assumed (see [Open questions](#8-open-questions)).

## 7. Documentation impact

- **Brain README** — the "core-only / Not built" framing is revised to document this execution layer: the three new commands, the worker-note data model, and the `## Shipped` diary section. It also documents the new repo `skills/` directory and the per-skill symlink arrangement into `~/.claude/skills/`.
- **Vault `CLAUDE.md`** — the status-flip reconciliation rules get a note about worker-driven `[/]` → `[x]` transitions, so they aren't double-handled (the ambient flip rules and `/brain-collect` must not both claim the same transition).

## 8. Open questions

- **Worker-note location/naming** — proposed `workers/<slug>.md`; confirm the exact vault location and naming during planning.
- **Project inference confidence** — how confidently the associated project can be inferred from the action and gathered context, and the fallback behaviour when the inference is ambiguous (before dropping to the neutral brain-repo dir).
- **Base-directory argument form** — whether the argument accepts a bare repo name (resolved via the [location convention](#local-repo-location-convention)) or an absolute path, or both.
- **Skill symlink discovery** — confirm Claude Code follows directory-level symlinks when discovering skills in `~/.claude/skills/`, so the repo-as-source-of-truth arrangement works as intended.
- **Launch-verification mechanism** — the precise way to confirm, under plain tmux, that Claude actually started (not merely that the session was created).
