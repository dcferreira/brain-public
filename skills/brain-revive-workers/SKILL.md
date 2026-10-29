---
name: brain-revive-workers
description: After a reboot or crash, bring back exactly the brain worker tmux sessions that were alive at shutdown — by resuming their SAME harness conversation by id, never priming a fresh one. Runs a dry-run report first (slug/host/harness/verdict/session_id), lets you confirm, then applies. Use when the user says "I restarted my computer", "bring the workers back", "revive/restore/resume the workers", or "the workers were lost after a reboot or crash".
argument-hint: [--host <name|all>] [--apply] [--only <slug,...>]
---

# Revive Workers — Restore Sessions Lost to a Reboot or Crash

> **Harness.** If you have a `task` tool you are in omp: read `~/projects/brain/skills/_shared/harness/omp.md`. If you have an `Agent` tool you are in Claude Code: read `~/projects/brain/skills/_shared/harness/claude-code.md`. Read one, never both.

A reboot kills every `brain-worker-<slug>` tmux session — and so does anything that takes the tmux server down without one (a gnome-shell crash that logs you out, `tmux kill-server`). This skill brings back exactly the ones that were **live at shutdown**, by resuming their existing harness conversation by id — never by starting a new one from the brief.

**How this runs:** inline in the main session, via `skills/brain-revive-workers/scripts/revive-workers.sh`. Dry run is the default and the always-first step; nothing is launched until you've seen the table and confirmed.

## HARD RULES

- **Never** use the brain-dispatch skill or run `launch-worker.sh` without `--resume <id>` to bring a worker back. That primes a **fresh** conversation from the brief and discards the worker's accumulated context — this exact mistake has happened before. Revival only ever goes through `revive-workers.sh --apply`, which always passes `--resume`.
- **Never** kill or touch an existing tmux session. A worker already running (`already-running`) is left alone. The one exception is `resurrected-shell` (below): `--apply` types the resume line into that bare-shell pane — it never kills or recreates the session.
- **Never** change a worker note's `status` — revival is a transport-layer fix, not a status transition. The note's status still reflects wherever the worker's own progress left it.
- **Ambiguous or no-transcript rows are reported to the user, not guessed.** Don't pick a transcript, don't infer a session id — surface it and let the user decide (typically: attach manually, or add `session_id:` to the note by hand and re-run).

## Flow

1. **Dry run.** `bash ~/projects/brain/skills/brain-revive-workers/scripts/revive-workers.sh --host <desktop|homeserver|all>` (hosts come from `hosts.conf`; `local` is a deprecated alias for this machine). Default `--host` is this machine's real name (`self_host`); use the named host, or `all`, when the user says a remote machine (e.g. `homeserver`) restarted (or you don't know which host). A file in `workers/` counts as a worker note only if its frontmatter has `tmux_session:` or `project_dir:`; anything else (pawl findings, reports) is skipped silently — a `status:` line alone does not make it a worker. A host this machine has no ssh route to (its `hosts.conf` alias is `-` and it is not this machine — e.g. `desktop` seen from `homeserver`) is skipped under `--host all` with an informational `revive-workers: skipping host <h>: no ssh route from <self> to <h> (hosts.conf alias -)` line (not an error; run revive on that host itself); asked for by name it is an error with the same reason. An uncollected note whose `host:` is not a `hosts.conf` row (a retired machine) is skipped with one `warning: <slug>: unknown host '<h>' (not in hosts.conf)` line, not an error; collected ones are ignored silently. If this machine is not in `hosts.conf`, legacy notes (no `host:` / `host: local`) cannot be placed and are skipped, summarised once as `N legacy notes skipped: this machine is not in hosts.conf (set BRAIN_SELF_HOST or add its hostname)`. When a worker has no transcript on the queried host, the dry run prints `hint: <slug>: no transcript on <host> — if it ran elsewhere, re-run with --host all`. This reads `<vault>/workers/*.md` **and `<vault>/private/workers/*.md`** (a private worker's note lives there; the script handles both locations — you do not pick) (read-only), queries each host, and prints a table: `slug host harness status verdict session_id mtime shutdown`, plus a `# <host>: boot=… shutdown=… shutdown_source=… window=… shutdowns=<n>` line per host and any `# <host>: cluster: …` lines (below).

2. **Show the table and explain the verdicts:**
   - `live` — the transcript's mtime falls in the window just before a shutdown (the `shutdown` column says which — not necessarily the latest) → resume it.
   - `idle-at-shutdown` — no clean exit, last activity some time before the **latest** shutdown, note `primed`/`working`/`blocked`: an idle worker writes nothing, so it was most likely still running when that shutdown killed it → resume it.
   - `idle-older-shutdown` — the same, but matched to an **older** shutdown: as likely a worker the user killed by hand (Ctrl-C ×2, `tmux kill-session` — no `/exit` record) as one an unrevived earlier shutdown took. `--apply` skips it; **ask the user**, and only if they want it back re-run with `--apply --only <slug>` (its `hint:` line says so).
   - `ended-before-shutdown` — the transcript records a clean exit (`/exit`; omp `session_exit` of kind `normal`), or it was idle before a shutdown with a note that is not `primed`/`working`/`blocked` (e.g. `done`); not revived.
   - `parked` — the note says `status: parked`; never offered as a crash victim, whatever the transcript says. `status: collected` notes are not listed at all (only `status:` counts — `collect_state: persisted` is set on every teardown, park included, and never means finished).
   - (`touched-since-boot`, find-live-sessions.sh's verdict for a transcript written after boot, never reaches the table: it becomes `already-running` or `dead-since-boot` below.)
   - `resurrected-shell` — the session exists but every pane is a bare shell (tmux-resurrect restored it without the harness) and the transcript says live/idle → `--apply` types the resume line into that pane.
   - `dead-since-boot` — the transcript was written after boot but the harness is gone (no `brain-worker-<slug>` session, or only a bare shell): it died after boot — a crash/logout that killed the tmux server, or the user closed/exited it. Never auto-revived. **Ask the user** what happened. Fallback for a crash: re-run with `--boot-time <epoch of the crash/re-login>` and `--shutdown-time <epoch just before the crash>` (from `journalctl --user -b`, `last -x`, or a `cluster:` line) so those sessions classify against the crash; show that table and confirm before `--apply`.
   - `already-running` — a `brain-worker-<slug>` tmux session already exists on that host with the harness in it; left alone.
   - `no-transcript` — no matching transcript found at all; report it, don't guess. (`-` in a column means "unknown".)
   - `ambiguous` — more than one transcript looks live; the row lists the candidate ids/paths so the user can pick, e.g. by hand-adding `session_id:` to the note.
   - A `cluster:` line names 2+ workers whose transcripts share one mtime minute — they were almost certainly killed together. Relay it; when it says they were not at a journalled shutdown, it carries a ready-made `--shutdown-time … --boot-time …` override for the case the user confirms a crash there.

3. **Confirm with the user** before doing anything — which slugs (if not all `live` ones), which host(s). This matters especially on hosts that use the proxy (Darwin), see below.

4. **Apply.** `bash ~/projects/brain/skills/brain-revive-workers/scripts/revive-workers.sh --host <same> --apply [--only <slug,...>]`. For each `live`/`idle-at-shutdown` row (and an `idle-older-shutdown` one only when `--only` names it) it calls `launch-worker.sh --host <h> --harness <x> --slug <s> --project-dir <p> --resume <id>` sequentially — the same launch dance as a fresh dispatch (shell-ready probe, typed-line verification, trust-prompt handling, composer poll, Remote Control connect for claude), but resuming the pinned conversation instead of typing the brief sentence. A `resurrected-shell` row gets the resume line typed into its existing pane instead (`mode=resume-in-pane`). Either way a row reports `verified=yes` only once the pane shows the composer ready — keys typed while a resumed conversation is still loading get lost. Remote Control's "already connected" dialog is closed with one Escape per sighting, never repeated (`rc_dialog=` as in brain-dispatch); `rc=no` is re-checked, never retyped. A worker note with a `model:` frontmatter value is resumed on that same model (`--model <id>` on both paths); with none, the harness default applies as before. Send any follow-up message to a revived worker only after its `verified=yes`, and check it landed.

5. **Relay every `note:` line** the launcher prints to stderr during a resume — these surface things like a turn that was interrupted by the old session ending (a message not-quite-delivered, work not-quite-finished). This is for the human to act on, not for the skill to act on. Also relay each launched worker's `rc=` status (Remote Control reconnected, or not — same meaning as in brain-dispatch).

## How liveness is decided (and why the confirm step matters)

A busy harness writes to its transcript as it dies, but an **idle one writes nothing**: a transcript's mtime is its *last activity*, not its death. `find-live-sessions.sh` (run per host, called by `revive-workers.sh`) therefore judges each transcript against the shutdown that **followed** its mtime, across every boot `journalctl --list-boots` lists (workers can die at an earlier shutdown that nobody revived after): in the window just before it → `live`; older without a clean-exit marker → `idle-at-shutdown`.

- On the Linux hosts (`desktop`, `homeserver`) the shutdowns come from the journal — the reliable case.
- Without a journal (Darwin) it falls back to a **proxy**: the newest transcript on that host older than boot time. This is a heuristic and **can false-positive**, which is why step 3 (confirm before `--apply`) is not optional there.
- `--shutdown-time`/`--boot-time` override all of this with one shutdown — a fallback for a crash the journal does not show as a boot (see `dead-since-boot`).

## Notes

- A worker note with `host: local` or no `host` is legacy: it is read as this machine, with a warning naming the slug (and a hint to fix the note's `host:` when its `project_dir` does not exist here). A note without `harness` defaults to `omp`, with a warning — same convention as brain-status and brain-collect.
- A note without a recorded `session_id:` still gets a liveness verdict via the fallback: the first user message of its transcript is matched against the worker's launch sentence. `session_id:` (written by brain-dispatch since it was added) makes the match exact instead of by content-sniffing.
- Never run `revive-workers.sh --apply` without having shown the dry-run table to the user first in this same turn.
