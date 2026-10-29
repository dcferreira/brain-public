# brain

This is the setup I use to work with a fleet of Claude Code agents: a shared memory every session reads from and writes back to, and a set of skills for planning the day, launching a worker session per task, and collecting what they did.

It's a snapshot of my private repo, published alongside the post "How I work with agents". **Please don't install it as is.** It's built around my machines, my vault layout and my habits, and it changes every week. Read it, take the ideas you like, and build your own. A good way to start: point an agent at this repo and ask it to recommend one or two ideas that would fit your own workflow.

## The pieces

### The brain: vault + search + write-back

- **Vault.** An [Obsidian](https://obsidian.md/) vault, which is just a folder of markdown files (`~/Obsidian/vault`). It holds a short `top-of-mind.md` (today's actions and this week's goals), session notes, knowledge notes, worker notes, a diary, a backlog and meeting notes.
- **Search.** [qmd](https://github.com/tobi/qmd) indexes the vault locally (keyword + embeddings, no API).
- **Rules every session follows.** A `SessionStart` hook (`claude/hooks/brain-session-start.sh`) injects top-of-mind, the latest session note and relevant search hits into every Claude Code session. A `SessionEnd` hook re-indexes. The `brain-persist` skill writes a session note, updates top-of-mind and captures reusable knowledge. That write-back is what makes the rest work: tomorrow's sessions start where today's left off.
- **Orienting.** `brain-orient` loads deeper context on demand. `brain-status` gives a quick "where am I at".
- **Scopes.** Notes belong to an area (`work`, `projects`, `private`) and a project, and `BRAIN_SCOPE` decides what a session can see. Tooling: `bin/brain-scope`, `bin/brain-search`, `bin/brain-migrate-scope`.

### Workers: dispatch and collect

- **`brain-dispatch`** turns a Today action into a worker: it writes a brief (a worker note in the vault, with pointers to the relevant context) and launches a detached tmux session running Claude Code (or oh-my-pi) primed from that brief, on any host in `skills/_shared/hosts.conf`. Every worker starts with a premise check of its own brief before doing anything.
- **`brain-collect`** reaps a finished worker. It checks the work against reality rather than the worker's own report, marks the Today action done with the PR link, has the worker persist what it learned, then tears down the session and its workspace.
- **`brain-monitor`** watches a set of workers and their PRs, and emits one line whenever a worker needs you (a question, blocked, ready for review, idle, stuck) or a PR changes.
- **`brain-revive-workers`** brings the worker sessions back after a reboot by resuming the same conversations.
- **`brain-dashboard`** keeps a per-project "control" page with tasks, workers, what's waiting on you, and a message box back to the coordinating session.
- **`brain-pm-tech-lead`** runs a project with two long-lived coordinator sessions, a PM and a tech lead, that dispatch and review workers while the human sets direction and merges.

### Planning cadence

- **`brain-plan-week`**: a short Monday reset. Review what moved, archive done items (`bin/brain-sweep`), and agree 2–3 goals for the week.
- **`brain-plan-day`**: a start-of-day reset. Roll unfinished actions over and pick today's few actions from the week's goals.
- A backlog file in the vault catches follow-up work that sessions notice but shouldn't do right away.

### Meetings

**`brain-sync-meetings`** pulls meeting notes and transcripts from the [Krisp MCP](https://help.krisp.ai/hc/en-us/articles/25396920405148-Krisp-MCP) into `meetings/`, verbatim, so later sessions can go back to the source call. It also fixes names that the transcription always gets wrong, and flags recordings where two calls were fused into one.

### Dreaming

**`brain-dream`** reads across recent session notes and turns recurring friction, patterns and open threads into concrete proposals, usually changes to the setup itself. It also does some light vault hygiene.

### The 🔔 in tmux (described, not included)

Every session runs in its own tmux session. A couple of Claude Code hooks (`Notification` and `Stop`) add a 🔔 to the tmux session name when that session is waiting for me, and a `UserPromptSubmit` hook removes it again when I reply. The session list then shows at a glance which agents need attention. These hooks live in my dotfiles rather than in this repo. A minimal version:

```sh
# on Notification / Stop: mark the session
s=$(tmux display-message -p '#S'); case "$s" in "🔔 "*) ;; *) tmux rename-session -- "🔔 $s" ;; esac
# on UserPromptSubmit: clear the mark
s=$(tmux display-message -p '#S'); tmux rename-session -- "${s#🔔 }"
```

(If anything else addresses sessions by name, like `brain-monitor` does here, adapt it to strip the prefix, or put the bell in the window name instead.)

## Layout

| Path | What's there |
|---|---|
| `skills/` | The skills, one `SKILL.md` each, plus their scripts and tests. `skills/_shared/` holds the host registry, per-harness notes and shared shell libraries. |
| `claude/` | Claude Code wiring: session hooks, a settings snippet, and `install.sh`, which symlinks the skills into `~/.claude/skills` and `bin/brain-*` into `~/.local/bin`. |
| `omp/` | The same wiring for oh-my-pi, the other harness I've used. |
| `bin/` | Small CLI tools (scopes, search, weekly sweep, migration) and the seed project registries. |
| `specs/` | The design docs and plans each piece was built from, in date order. |
| `SETUP.md` | The detailed wiring document: every path, hook and decision. Skills and specs call this "the README". |

Tests are plain shell (`*.test.sh`) and Python `unittest` (`*_test.py`) files next to the code they test.

## About this snapshot

- Names were replaced with placeholders: `acme` is an employer, `clientco`, `carco` and `client-b`…`client-e` are clients, `desktop`, `homeserver` and `laptop` are my machines, and "the user" is me. A few personal projects (agent-pawl, budgebell, toxic-news) keep their real names because they're public.
- Paths assume my layout (`~/Obsidian/vault`, `~/projects/brain`). Expect to change them.
- It isn't maintained as a project: there's no support and no roadmap.
- No licence is attached.
