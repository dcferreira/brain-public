# Harness reference — Claude Code

You are in Claude Code; the other harness's file is
`skills/_shared/harness/omp.md` — do not read it.

## Invoking a skill

`/<name> [args]`, or invoke it via the Skill tool.

## Subagents

Claude Code's subagent primitive is the Agent tool. **Do not name** reader
or writer agents you dispatch — naming one caused a relay hazard on
2026-07-30: a named agent's report is not relayed back automatically, and
that run spent 8 nudges and 11 idle notifications chasing reports an
unnamed agent would have delivered directly. Dispatch every batch of
independent subagents in **one message** with multiple Agent tool calls so
they run concurrently, and let their reports arrive unprompted.

## Fan-out subagents

Same rule as above: when fanning out several reader or writer subagents
over independent batches (e.g. brain-dream's session-note readers, or its
writers), issue them all as Agent tool calls in a single message, leave
every one unnamed, and let each report arrive on its own — do not poll or
nudge.

## Asking the user

Use the AskUserQuestion tool. It can time out if the user is AFK — see the
worker brief's AFK-parking rule for what to do while a question is
unanswered.

## MCP servers

`/mcp` shows server status and lets you reauthenticate. Servers are
configured in Claude Code's own settings — see `claude/README.md` in the repo
for how brain's MCP servers are wired here.

## Session id

The SessionStart hook (`claude/hooks/brain-session-start.sh` in this repo)
reads `session_id` from the hook's stdin JSON and injects the line:

```
This session's id is <id> (harness: claude-code)
```

Read it from the injected vault context.

## Shell quirks

None. Some harnesses set `CI=true` in their shell tool, under which
`qmd vsearch` aborts — that does not apply here (this bash tool does not
set `CI=true`), but keeping `env -u CI` in front of `qmd vsearch` anyway is
harmless.

## Skills discovery and refresh

Skills are symlinks: `~/.claude/skills/<name>` →
`~/projects/brain/skills/<name>`, created by `claude/install.sh`. Re-run
that script after adding a new skill directory; editing an existing
skill's file is picked up immediately, since it is a symlink.

## Scheduling

Claude Code has in-session scheduling (the CronCreate tool), so a skill
like brain-sync-meetings *could* run on a schedule here — but it stays
manual: it pauses per meeting to ask the user to assign speakers in Krisp,
which is a poor fit for a scheduled run.

## Workers launched by brain-dispatch

Workers are launched as plain `claude "…"` — no permission flags — and run
under the user's own auto-mode default, whatever it is set to. There is
nothing to preflight: no guardrail extension, no classifier, no separate
contained mode for a worker versus an interactive session.

Every launch and resume line carries `--remote-control <slug>`, so the worker
connects to Remote Control at startup under its slug (winning over a host's
`remoteControlAtStartup`) and is steerable from claude.ai/code and the mobile
app as well as from its tmux pane; nothing is typed afterwards, because `/rc`
on an already-connected session only opens a blocking "already connected"
dialog. If that dialog is ever on a worker's pane, the launcher answers it
with `Escape` (never Enter, which could pick Disconnect) and reports
`rc_dialog=`; a resume that reattaches keeps the session's original title.
