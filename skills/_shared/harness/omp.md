# Harness reference — omp

You are in omp; the other harness's file is `skills/_shared/harness/claude-code.md` — do not read it.

## Invoking a skill

`/skill:<name> [args]` — e.g. `/skill:brain-persist worker`.

## Subagents

omp's subagent primitive is the `task` tool. Dispatch multiple subagents by
batching **all** of them into one `task` call's `tasks[]` array; each
report auto-delivers as its agent settles — no naming needed, no polling,
no nudging.

## Fan-out subagents

Same mechanism, for a fan-out over independent batches (e.g. brain-dream's
session-note readers, or its writers): issue every one of them in **one**
`task` call's `tasks[]` array. Naming a subagent in omp is harmless but
pointless — batch the tasks and let the reports arrive.

## Asking the user

Use the `ask` tool. It can time out if the user is AFK — see the worker
brief's AFK-parking rule for what to do while unanswered.

## MCP servers

`/mcp list|enable|reauth|reconnect <server>`. Server definitions live in
`~/projects/brain/omp/mcp.json`, symlinked to `~/.omp/agent/mcp.json`, so
the repo is the source of truth. Authentication is hosted OAuth; the
credential persists in omp's agent directory, reused across sessions.

## Session id

The session-start wiring (the `brain-vault` omp extension,
`omp/brain-vault.ts`) injects the line:

```
This session's id is <id> (harness: omp)
```

Read it from the injected vault context.

## Shell quirks

omp's bash tool always sets `CI=true`. Under that, plain `qmd vsearch`
aborts ("LLM operations are disabled in CI") instead of returning no hits.
Use `env -u CI qmd vsearch ...` whenever a vector search is needed.

## Skills discovery and refresh

Skills are discovered directly from this repo's `skills/` via
`skills.customDirectories` in `~/.omp/agent/config.yml` — no symlinks. A
skill added or edited mid-session is picked up on the **next** omp start.

## Scheduling

omp has no in-session cron. A skill that must run periodically (e.g.
brain-sync-meetings) needs an external trigger — a reminder, or a systemd
user timer driving a headless `omp -p` run — and stays manual for anything
that pauses to ask the user mid-run.

## Workers launched by brain-dispatch

Workers are launched as `omp --auto-approve "…"`, forcing `yolo` for that
worker session only (interactive sessions keep their configured
`tools.approvalMode` (`write`)). Containment comes from the globally-installed `pi-automode`
guardrail extension: it intercepts every tool call pre-execution (before
the approval gate, so active under `yolo` too), blocking on hard-deny
rules plus a local model classifier (Qwen3.5-4B via `llama-server`).
`--auto-approve` removes the prompt; the classifier supplies the judgement
and does not depend on the worker obeying its brief.

The classifier fails closed, so a stopped `llama-classifier` blocks every
tool call. Preflight with `systemctl --user is-active llama-classifier`
(expect `active`); if not, `systemctl --user start llama-classifier` and
re-check. If it still won't come up, launch anyway but warn that tool
calls stay blocked until the classifier is reachable.

omp has no Remote Control, so an omp worker is reported `rc=n/a` by the
launcher and is steerable only from its tmux pane.
