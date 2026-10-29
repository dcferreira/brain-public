# Second Brain — Setup Documentation

> This is the wiring document from the private repo, scrubbed for publication: host names, client and employer names, and personal details are placeholders (see the README). Elsewhere in the repo, "the README" means this file.

A personal knowledge-management system: a markdown vault, local search (qmd), and oh-my-pi (`omp`) wiring that loads context at the start of every session and captures it back on demand.

This directory documents **how the system is wired**, so changes are easy to make. The authoritative artefacts live elsewhere (the vault, `~/.omp`, `~/.config/qmd`) — this is the map, not the territory. When you change a real file, update this doc.

Modelled on a former colleague's private second-brain setup, **core-only** at the outset: no permission gate, no AWS/webhook meeting pipeline, no daily briefing. Set up 2026-06-29. Since then a local **execution layer** has been added on top of the core (see [The execution layer](#the-execution-layer)) — the brain can now *run* a Today action in a primed worker session, not just plan and record it. **Ported from macOS + Claude Code to Linux + oh-my-pi on 2026-09-11** — see [§3](#3-file--path-inventory) for the new wiring and [§8](#8-how-to-make-common-changes) for how to re-create it on another machine. **Since 2026-09-15 the skills run under both harnesses** (omp on this machine, Claude Code on this machine *and* on the remote host, the Linux box `homeserver`), and the execution layer can dispatch a worker to any host in `hosts.conf` — see [`specs/2026-09-15-dual-harness-remote-dispatch-design.md`](specs/2026-09-15-dual-harness-remote-dispatch-design.md) for the design. **Since 2026-10-15 the vault is scoped** into `work` / `projects` / `private` areas, so a session sees private material only when its scope allows — see [Scopes](#scopes-work--projects--private) and the design in [`specs/2026-10-15-vault-topic-scoping-design.md`](specs/2026-10-15-vault-topic-scoping-design.md).

---

## 1. What it is, in one loop

```
session start ─► session-start wiring (omp extension | Claude Code hook) injects top-of-mind
                  + latest session note + qmd hits (all filtered by BRAIN_SCOPE)
                                   │
                                 (you work; decisions become notes as they happen)
                                   │
            brain-persist ─► writes a session note, updates top-of-mind, captures knowledge notes, reindexes
                                   │
session end ─► session-end wiring runs `qmd update` (reindex only — writes nothing)
                                   │
            next session ─► session-start wiring re-hydrates from the files brain-persist wrote
```

Governing rule (from the original setup): **nothing important lives only in a conversation.** Capture to files; recall automatically next session. Capture (`brain-persist`) is a deliberate action — see [Known limitations](#7-known-limitations).

---

## 2. Components

| Component | What it does |
|---|---|
| **Vault** (`~/Obsidian/vault`) | The personal markdown knowledge base. A jj-colocated repo. |
| **Shared store** (`~/Obsidian/shared`) | Shareable team artefacts, indexed alongside the vault. **Not present on this machine** — it was never copied over from the Mac, so the `shared` qmd collection is gone too. Re-create the store and its collection to search team artefacts again. |
| **qmd** | Local hybrid search (keyword + embeddings). Fully local, no API. Two indexes: the default one holds the `vault` collection (everything except `private/**`, plus the shared store when it exists); a second index, `private`, holds `private/` only — see [Scopes](#scopes-work--projects--private). |
| **Scopes** | Every note belongs to an area (`work` / `projects` / `private`) and a project. `BRAIN_SCOPE` (`shared` by default, `private`, `all`) decides what a session sees; private notes live in a physical `private/` subtree with their own qmd index. Tooling: `bin/brain-scope`, `bin/brain-search`, `bin/brain-migrate-scope`. See [Scopes](#scopes-work--projects--private). |
| **Session wiring** | Two harness-specific wirings, both injecting the same content: the `brain-vault` omp extension (`omp/brain-vault.ts`) under omp, and the `claude/hooks/brain-session-*.sh` hooks under Claude Code. Both inject vault context at session start and reindex with qmd at session end — see [Claude Code wiring](#claude-code-wiring-claude) and [Worker hosts](#worker-hosts). |
| **Skills** | `brain-orient` (load context), `brain-persist` (save context), `brain-sync-meetings` (pull Krisp meetings), `brain-dream` (cross-session review); the planning cadence `brain-plan-day`, `brain-plan-week` (with the `bin/brain-sweep` tool); and the execution layer `brain-dispatch`, `brain-status`, `brain-collect`, `brain-revive-workers`, `brain-monitor`, `brain-dashboard`; and `brain-pm-tech-lead`, a process skill for running a project with a PM + tech lead coordinator pair on top of them. All scope-aware (see [Scopes](#scopes-work--projects--private)). Discovered from this repo by both harnesses, each its own way — see [Skill storage](#skill-storage-the-repo-is-the-source-of-truth). |
| **Planning system** | Daily actions, weekly goals, and long-term goals kept current in the vault, across three horizons (Today / This week / backlog). Maintained by the cadence skills, `brain-sweep`, and the agent's ambient status updates. |
| **Execution layer** | Turns a Today action into a primed, detached `tmux` worker session (a jj workspace for code tasks), lets you drive it, then reaps the verified result back into the vault. Runs via `brain-dispatch`, `brain-status`, `brain-collect`; each worker is tracked by a note at `workers/<slug>.md`. After a reboot kills the tmux sessions, `brain-revive-workers` resumes exactly the ones that were live at shutdown, by conversation id — never a fresh launch. |
| **AGENTS.md nudge** | User-level instruction (`~/.omp/agent/AGENTS.md`) telling the agent to offer `/skill:brain-persist` when wrapping up substantive work. |

---

## 3. File & path inventory

Everything the system touches. Edit these to change behaviour.

### Vault (`~/Obsidian/vault`)
| Path | Holds | Written by |
|---|---|---|
| `00-home/top-of-mind.md` | **Today** (checkbox actions for `work` and `projects` areas only — private items live in `private/private.md`), **This week** (team goals), and **Previously this week**. Auto-injected every session. **Machine-maintained — do not hand-edit.** | `brain-persist`, the cadence skills, ambient status flips |
| `00-home/backlog.md` | Long-term goals (team + personal) and anything parked for later. Plain bullets, grouped Team / Personal. **Not** auto-injected; reviewed during `brain-plan-week`. | `brain-plan-week` |
| `planning/YYYY-Www.md` (private: `private/planning/`) | Weekly snapshot (ISO week): that week's goals, optional one-line retro, and a `## Done` list of the week's archived done items. | `brain-plan-week` (goals, retro), `brain-sweep` (Done) |
| `diary/YYYY-MM-DD.md` (private: `private/diary/`) | Daily note (Obsidian daily-notes folder). Holds a `## Shipped` section appended when a dispatched worker's result is reaped (or a `## Blocked / parked` section when a blocked worker is parked); the rest is free-form diary space. **Not** auto-injected. | `brain-collect` (Shipped / Blocked-parked) |
| `workers/<slug>.md` (or `private/workers/<slug>.md` for a private worker) | One note per dispatched worker, with `area:` / `project:` frontmatter (find it with `bin/brain-scope find-worker <slug>`): brief, gathered context, jj-workspace/tmux-session pointers, a `session_id` (the harness conversation id, from launch-worker's `session_id=` field — used by `brain-revive-workers` to resume this exact conversation after a reboot), a `status` field (`primed` → `working` → `blocked` → `done` → `collected`, plus `parked`), an optional `blocker` (present when `blocked`/`parked`), an optional `collect_state` (the persist-then-teardown handshake — `collecting` → `persisted`), and the worker's `## Result`. Non-code workers finish at `done`; code workers finish at `blocked` (PR raised, awaiting review/merge). "Done" is this status field, not a filesystem sentinel. | `brain-dispatch` (creates; sets `session_id` at launch), the worker itself (result + `done`/`blocked`, and its own scoped persist), `brain-collect` (`collect_state`, `collected`) |
| `00-home/scopes.md` | Shared project registry (`work` + `projects` areas): one table row per project — slug, area, aliases, slug prefixes. Seeded from `bin/seed/scopes.shared.md`. See [Scopes](#scopes-work--projects--private). | `brain-migrate-scope apply` (seed); `brain-dispatch` / `brain-persist` (new rows) |
| `private/` | The private subtree (excluded from the default qmd index): `private/workers/`, `private/sessions/`, `private/knowledge/`, `private/diary/`, `private/learning/` (moved from `learning/`), plus `private/private.md` (the private **Today** / **This week**) and `private/scopes.md` (the private project registry, seeded from `bin/seed/scopes.private.md`). A missing `private/` is treated as empty everywhere. | the scope-aware skills (by area); `brain-migrate-scope apply` |
| `dashboards.md` | project → dashboard artifact URL registry. | `brain-dashboard` (`dashboard.py register`) |
| `sessions/YYYY-MM-DD <desc>.md` (private: `private/sessions/`) | Per-session notes: what happened, decisions, next steps. Carry `area:` / `project:` frontmatter. | `brain-persist` |
| `knowledge/graph/` (private: `private/knowledge/graph/`) | Atomic notes named as *claims*, wiki-linked. Carry `area:` / `project:` frontmatter. | `brain-persist` |
| `inbox/` | Proposals to review before promoting to durable memory. | (future feeders) |
| `meetings/YYYY-MM-DD <title>.md` | Krisp meeting captures (Krisp's own notes, verbatim). | `brain-sync-meetings` |
| `CLAUDE.md` | The vault's operating protocol (loaded when working inside the vault). | manual |

### Search (qmd)

qmd is required on every machine that runs brain sessions or workers — the session hooks/extension and most skills call it. Same version and layout everywhere:

| Path | Purpose |
|---|---|
| `~/.config/qmd/index.yml` | Collections config: a `vault` collection (`~/Obsidian/vault`, `**/*.md`, with `ignore: ["private/**"]`), plus a `shared` collection wherever `~/Obsidian/shared` exists (see [§2](#2-components)). qmd appends a `models:` block here automatically. |
| `~/.nodenv/shims/qmd` | The qmd binary (`@tobilu/qmd` v2.8.3, needs Node ≥ 22). The Claude Code hooks resolve it as `BRAIN_QMD` → `PATH` → `~/.nodenv/shims/qmd` → `~/.local/bin/qmd`; the `brain-vault` extension uses `BRAIN_QMD`, else `~/.nodenv/shims/qmd`; the skills call plain `qmd`, so it must also be on the login-shell `PATH`. |
| `~/.config/qmd/private.yml` | Config of the second index, `private` (`qmd --index private …`): one `private` collection over `~/Obsidian/vault/private`. Created by `claude/install.sh`. |
| `~/.cache/qmd/index.sqlite`, `~/.cache/qmd/private.sqlite` | The two search indexes (per machine — not synced, even though the vault is). Re-index **both** on each host: `qmd update` and `qmd --index private update`. |
| `~/.cache/qmd/models/` | Local embedding model (embeddinggemma-300M, ~333 MB, downloaded once on first `qmd embed`). |

**Installing qmd on a machine** (user-level, no sudo):

```sh
git clone --depth 1 https://github.com/nodenv/nodenv.git ~/.nodenv
git clone --depth 1 https://github.com/nodenv/node-build.git ~/.nodenv/plugins/node-build
export PATH="$HOME/.nodenv/shims:$HOME/.nodenv/bin:$PATH"   # also add this to ~/.zprofile
nodenv install 24.18.1 && nodenv global 24.18.1
npm install -g @tobilu/qmd@2.8.3 && nodenv rehash
cd ~/Obsidian/vault && qmd collection add . --name vault --mask '**/*.md'
# then run claude/install.sh: it adds `ignore: ["private/**"]` to `vault` and writes ~/.config/qmd/private.yml
env -u CI qmd embed --timeout 0   # CPU-only machines need --timeout 0 (default 30-min cap); first run downloads the model
```

### oh-my-pi (omp) wiring (`~/.omp`)

There are **no symlinks for skills**: omp is pointed straight at this repo, which stays the single source of truth. `~/.omp` holds machine-local configuration only.

| Path | Purpose |
|---|---|
| `~/projects/brain/skills/` | The skill files — source of truth, version-controlled in jj. Exposed to omp by `skills.customDirectories`; one level of `<name>/SKILL.md` is scanned. |
| `~/projects/brain/omp/brain-vault.ts` | The session-wiring extension: injects vault context at session start, reindexes at shutdown. Loaded by the `extensions` setting. |
| `~/projects/brain/omp/mcp.json` | MCP server definitions (`krisp` only). Symlinked into omp's agent dir. **Ships `"enabled": false`** — Krisp is not in use here; the definition is kept so the meeting-sync skill works unchanged the moment a source is wanted. See [§6](#6-key-decisions-and-why). |
| `~/.omp/agent/config.yml` | Global omp settings. The brain is wired in by two keys: `skills.customDirectories: [~/projects/brain/skills]` and `extensions: [/home/user/projects/brain/omp/brain-vault.ts]`. |
| `~/.omp/agent/mcp.json` | Symlink → `~/projects/brain/omp/mcp.json`, so the repo owns the MCP definitions. |
| `~/.omp/agent/AGENTS.md` | User-level context for every session; holds the "Knowledge Vault" nudge. **This file shadows every other user-level context file** (including `~/.claude/CLAUDE.md`), so anything omp must see belongs here. |
| `~/.omp/plugins/` + `omp plugin list` | **Installed omp plugins.** Currently one: `@czottmann/pi-automode` — the tool-call guardrail (see §6/§7). Installed with `omp plugin install @czottmann/pi-automode`; it declares its extension via `package.json` `pi.extensions`, which omp's manifest resolver accepts. |
| `~/.pi/agent/extensions/pi-automode/config.json` | pi-automode's **own** settings — notably `classifierModel`. It hardcodes this `.pi/...` path (not `.omp`), so a small `.pi` tree exists alongside `~/.omp`. |
| `~/.config/systemd/user/llama-classifier.service` | The local classifier model server (`llama-server`, Qwen3.5-4B) on `127.0.0.1:8080` that pi-automode calls. `~/.omp/agent/models.yml` exposes it to omp as the `local-classifier` provider. |
| `~/Obsidian/vault/CLAUDE.md` | The vault's operating protocol, auto-loaded whenever the working directory is inside the vault (omp's `claude-md` provider walks up to the repo root). |

The Mac-era per-skill symlinks (`~/.claude/skills/<name>` → this repo) are gone; `skills.customDirectories` replaces them. Note the `extensions` path must be **absolute** — a `~/...` entry is not expanded by that loader.

### Claude Code wiring (`~/.claude`)

Claude Code has no `skills.customDirectories`-style discovery, so it needs per-skill symlinks and its own session-start/session-end hooks — the `claude/` directory in this repo (sibling of `omp/`) is the source of truth for both.

| Path | Purpose |
|---|---|
| `~/.claude/skills/<name>` | Symlinks → `~/projects/brain/skills/<name>`, one per skill directory that has a `SKILL.md` (`_shared` is skipped — it has none). Created by `claude/install.sh`, which is idempotent. |
| `claude/hooks/brain-session-start.sh` | `SessionStart` hook: reads `session_id`/`cwd` from the hook's stdin JSON, applies `BRAIN_SCOPE` / `BRAIN_PROJECT`, and prints the session-id line first, then the same vault-context blocks as `omp/brain-vault.ts`'s `buildContext()` (top of mind, latest session note, qmd hits) (see [Session start](#session-start-automatic)). |
| `bin/brain-*` → `~/.local/bin` | Also linked by `claude/install.sh` (executables only, not `*.py`): `brain-scope`, `brain-search`, `brain-migrate-scope`, `brain-sweep`. `~/.local/bin` must be on `PATH`. |
| `claude/hooks/brain-session-end.sh` | `SessionEnd` hook: runs `qmd update` to reindex. Writes nothing. |
| `claude/settings.snippet.json` | The `hooks.SessionStart` / `hooks.SessionEnd` entries (plus `attribution.sessionUrl: false`, which keeps claude.ai session links out of commits/PRs) to merge by hand into `~/.claude/settings.json` (Claude Code has no config-merge command). |
| MCP servers | Configured directly in Claude Code's own settings, not via a repo-owned `mcp.json` symlink as under omp — see `claude/README.md`. |

See `claude/README.md` for install/test instructions (`bash ~/projects/brain/claude/install.sh`, `bash ~/projects/brain/claude/install.test.sh`). Besides the skill symlinks (and pruning dangling ones left by a retired skill, e.g. `brain-post-standup`), `install.sh` now links `bin/brain-*` and edits the qmd configs (see [Scopes](#scopes-work--projects--private)).

### Worker hosts

The execution layer can launch a worker on more than one machine. `skills/_shared/hosts.conf` is the registry — one line per host: name, SSH alias (`-` = no ssh route to that host, so it can only be used from itself), the harnesses that host allows, its default harness, and its machine hostnames (comma-separated, case-insensitive, a trailing `.local` ignored). Hosts are always named by their real `hosts.conf` name — `desktop`, `homeserver` — never by where the command happens to run.

| Host | SSH alias | Harnesses | Hostnames | Notes |
|---|---|---|---|---|
| `desktop` | `desktop` | omp, claude | `desktop-pc` | The desktop. Default harness `omp`. |
| `homeserver` | `homeserver` | claude | `homeserver` | Always-on Linux box (openSUSE, zsh login shell). Default (and only) harness `claude`; no omp. |
| `laptop` | `laptop` | claude | `laptop`, `My-Air`, `My-MacBook-Air` | MacBook Air (macOS 27, arm64), Claude Code only, no omp; reached at ssh alias `laptop`. |

Every host reaches every other one by ssh alias: each machine has one key per target, named after the target (`~/.ssh/<alias>`, comment `example-user@<from> -> <alias>`), and a matching `~/.ssh/config.d/<alias>` entry.

Historic worker notes say `host: old-mac` (the retired Acme Mac, wiped 2026-10-16) or `host: mac`; neither is in `hosts.conf`, so they are records only — readers skip or warn on them and never ssh.

A machine finds its own row (`self_host` in `skills/_shared/lib/host.sh`) from `BRAIN_SELF_HOST` if set, otherwise by matching `hostname -s` / `hostname` (and, on macOS, `scutil --get LocalHostName`) against the hostnames column; `claude/install.sh` prints `self host: <name>` (or a warning when no row matches). `local` is a **deprecated alias** for "this machine": it is no longer a row, it is only accepted on input and normalised to the real name. A worker note with `host: local` (or no `host:`) is legacy — the readers (collect, status, revive, monitor) treat it as the machine running them and print a warning naming the slug, so a note written on one machine and read on another is flagged rather than silently misread.

`homeserver`'s prerequisites: the vault at `~/Obsidian/vault` (there a symlink to the dockerised Syncthing data dir `~/sync/data/Obsidian`); the brain checkout at `~/projects/brain`, updated from GitHub (see [Repository and landing flow](#repository-and-landing-flow)); the hooks from `claude/settings.snippet.json` merged into `~/.claude/settings.json`; and `claude` on the zsh login `PATH` (so `zsh -lc` finds it).

<a id="laptop-prerequisites"></a>`laptop`'s prerequisites: Homebrew on the login `PATH` (`/opt/homebrew`, via `eval "$(/opt/homebrew/bin/brew shellenv)"` in `~/.zprofile`); `tmux`; `jj`; `gh` (code workers finish their PRs with it); `jq` (the hooks merge uses it); Claude Code at `~/.local/bin/claude`; nodenv and `qmd` per the [Search](#search-qmd) section; the vault at `~/Obsidian/vault`, synced by Syncthing; the brain checkout at `~/projects/brain`, cloned from the GitHub `origin`; the hooks from `claude/settings.snippet.json` merged into `~/.claude/settings.json`; and `claude/install.sh` printing `self host: laptop`. A non-interactive `ssh laptop cmd` has a bare PATH, which is why commands run under `zsh -lc`, and why the brew shellenv line must be in `~/.zprofile` (read by login shells) and not `~/.zshrc` (interactive only).

On a remote host a non-interactive `ssh host cmd` has a bare PATH (no Homebrew, no `~/.local/bin`), so every remote command the scripts run is wrapped in `zsh -lc` to pick up the login shell's PATH. On the Linux desktop, interactive `ssh` is shadowed by kitty's SSH kitten and `tmux` by an oh-my-zsh plugin, so the scripts always call `command ssh` / `command tmux` to reach the real binaries — see `skills/_shared/lib/host.sh`.

### Repository and landing flow

The canonical copy of this repo is the private GitHub repo [`example-user/brain`](https://github.com/example-user/brain), remote `origin` on every host; trunk is `main`, and there is no PR flow. Every host's `origin` is the SSH URL `git@github.com:example-user/brain.git`. On `homeserver` the GitHub key is `~/.ssh/github`, selected for `github.com` by `~/.ssh/config.d/github` (`IdentityFile ~/.ssh/github`, `IdentitiesOnly yes`). The oh-my-zsh `ssh-agent` plugin there loads only default-named keys, so without that entry a fetch fails outside a shell with a forwarded agent.

To land a change:

1. Move `main` to the reviewed change and push it: `jj bookmark set main -r <change>` then `jj git push --remote origin --bookmark main`.
2. On every host that runs the brain (desktop, `homeserver`): `jj git fetch --remote origin`, `jj new main`, `bash claude/install.sh`. For `homeserver`, from the desktop: `command ssh homeserver "zsh -lc 'cd ~/projects/brain && jj git fetch --remote origin && jj new main && bash claude/install.sh'"` (the outer double quotes keep the `zsh -lc` script one argument on the remote side).

A new host clones from GitHub (`jj git clone git@github.com:example-user/brain.git ~/projects/brain`; the host needs a GitHub SSH key that non-interactive ssh picks up, as on `homeserver`), then runs `claude/install.sh`.

---

## 4. How the pieces work

### Session start (automatic)
Under omp: `~/.omp/agent/config.yml` → the `brain-vault` extension's `before_agent_start` handler builds the context once per session and injects it ahead of the first turn. Under Claude Code: `claude/hooks/brain-session-start.sh`, wired via the `SessionStart` hook in `~/.claude/settings.json` (see [Claude Code wiring](#claude-code-wiring-claude)). Both carry, in order:
1. first, a `This session's id is <id> (harness: omp|claude-code)` line — the same wording from both wirings, so `brain-persist` can read it identically regardless of harness, and it is never buried under a large payload. When top-of-mind exceeds 40 KB, a one-line `⚠ top-of-mind.md is <N> KB — run brain-sweep …` warning follows it.
2. `00-home/top-of-mind.md` (shared — never contains private text), and, only when the scope includes private, `private/private.md`
3. the newest dated note in `sessions/` (under `private`/`all`: the newer of `sessions/` and `private/sessions/` — under `shared` a newer private note is never the injected one)
4. up to 3 hits from `brain-search`, scope-applied, for `BRAIN_PROJECT` when set, otherwise the current working directory (skipped when cwd basename is `vault` or `example-user`).
5. a line stating the active scope and project and how to search (`brain-search "<q>"`). A missing `private/`, registry or index is treated as empty, never an error.

Anything injected becomes context. This fires in **every** project, not just the vault — which is why the scope filter lives here.

### Session end (automatic)
Under omp: the extension's `session_shutdown` handler spawns a detached `qmd update` and `qmd --index private update`. Under Claude Code: `claude/hooks/brain-session-end.sh`, wired via the `SessionEnd` hook, runs both directly. Both harnesses therefore reindex both indexes. **Reindex only — neither writes or updates any note.** Ending a session never persists content.

### Scopes: work / projects / private

Goal: an agent working on one project finds that project's notes cleanly, and an agent that is not in the user's private sphere does not see private material through **search or startup context**. This is clean separation by default, **not access control** — a determined agent can still `cat private/`. Design: [`specs/2026-10-15-vault-topic-scoping-design.md`](specs/2026-10-15-vault-topic-scoping-design.md).

**Areas and scopes.** Every worker, session and knowledge note carries `area:` and `project:` frontmatter (meetings carry `area`, default `work`, and `project` when known). The areas are exactly `work` (Acme), `projects` (side projects: agent-pawl, budgebell, toxic-news, brain) and `private` (everything of the user's own: `learning`, `business`, `finance`, `health`, `home`). A session's **scope** is the env var `BRAIN_SCOPE`:

| `BRAIN_SCOPE` | Sees |
|---|---|
| `shared` (default) | `work` + `projects` |
| `private` | all three areas (a private worker may still need work context) |
| `all` | all three areas |

Unset or unknown values mean `shared` — it **fails closed**. `BRAIN_PROJECT=<slug>` is optional and only narrows focus (a filter, not a wall). `brain-dispatch` sets both on the workers it launches (`all` for `project: brain`, which is a `projects`-area project; `private` for private work, `shared` otherwise).

**Where things live.** Work/projects notes stay in `workers/`, `sessions/`, `knowledge/`, `diary/` and `00-home/top-of-mind.md`. Private notes live in the `private/` subtree, which mirrors them: `private/workers/`, `private/sessions/`, `private/knowledge/`, `private/diary/`, with `private/private.md` as the private Today / This-week file (so the shared top-of-mind never contains private text) and `learning/` moved to `private/learning/`. `meetings/`, `inbox/` and `planning/` stay shared. The **path** is what enforces privacy; the `area: private` frontmatter is written as well. Vault root is `$BRAIN_VAULT`, else `~/Obsidian/vault`.

**Registries.** Two markdown tables, one row per project (`project | area | aliases | slug prefixes`): `00-home/scopes.md` (work + projects) and `private/scopes.md` (private — so even private project *names* stay out of shared context). A candidate value resolves by exact slug, then alias, then slug prefix. When nothing fits, the session (dispatch or persist) adds a row and says so in one line. The vocabulary is open and living; aliases stop drift.

**Search.** qmd has **two indexes**: the default one (`vault` collection, which ignores `private/**`) and `qmd --index private` (a `private` collection over `private/`). A plain `qmd search` therefore cannot return a private note. Use the wrapper instead:

```sh
brain-search [--scope shared|private|all] [--project <slug>] [-n N] [--json] "<query>"
```

Scope defaults to `$BRAIN_SCOPE` and project to `$BRAIN_PROJECT` (`--project ''` turns the filter off). It queries the default index, plus the private index when the scope includes private, drops hits whose `project:` frontmatter does not match, and merges. It degrades to fewer results (with a warning on stderr) when qmd returns junk or the private index is missing. The helper `brain-scope norm|includes|note-dir|find-worker|today-file|field|qmd-config` is what skills and hooks use to resolve areas, paths and worker notes (e.g. `brain-scope find-worker <slug>` checks both `workers/` and `private/workers/`).

**Coordinator scope.** the user's own coordinator session (plan-day, dispatch, collect, status) needs to see everything. That comes from `~/projects/brain/.claude/settings.json` (`{"env": {"BRAIN_SCOPE": "all"}}`), so any Claude Code session started in `~/projects/brain` is `all`-scope. This setting **overrides an inherited `BRAIN_SCOPE`** (verified: the project `env` reaches the SessionStart hook and wins over the process env). Limitation: omp does not read `.claude` settings, so an omp session in the brain dir stays `shared` and fails closed — coordinate in Claude Code. Anywhere else, a plain session runs as `shared` and the planning skills say that private items are hidden.

**Worker cwd.** Because of that override, ANY session rooted in `~/projects/brain` is `all`, including a worker launched with `-e BRAIN_SCOPE=shared`. So `~/projects/brain` is for workers whose `project:` is `brain` only, and `launch-worker.sh` refuses a fresh launch rooted there with a scope other than `all` (rc 2; a `--resume` only warns). Project-less non-code workers use `~/projects/workbench`, a plain non-repo directory that `claude/install.sh` creates on each host; a code worker always uses its repo (ask the user if none can be found).

Dispatched workers never inherit a scope: `launch-worker.sh` always passes `-e BRAIN_SCOPE=<scope>` explicitly (`shared` when `--scope` is omitted), and `brain-revive-workers` always passes `--scope` per worker (`shared` for non-private notes, with `--project` when the note has one), because tmux inherits its server's global environment and a server started from a `BRAIN_SCOPE=all` coordinator would otherwise leak `all` into every worker.

**Migration (one-time backfill, dry-run first).** `bin/brain-migrate-scope` classifies existing notes into areas/projects and, after the user signs off, moves private ones into `private/`. Nothing writes to the vault until step 5.

1. `brain-migrate-scope classify --out <dir>` — **read-only**. Writes `migration-report.csv` plus a markdown summary `migration-report.md` into `<dir>`. Rules, first hit wins: existing frontmatter, `learning/` folder, registry slug prefix on the filename, registry aliases against `tags:`/`week_goal:`/`customer:`, the matching Today line for worker notes, else unclassified. (`--vault` picks another vault; `--registry-from-seed` classifies from `bin/seed/scopes.*.md` before the registries exist.)
2. An LLM pass over the **unclassified** rows: a cheap subagent proposes values, marked `[inferred]`, and the user reviews them. LLM-proposed values only take effect once the user has signed off the CSV row. **Mixed** notes — detected in `diary/`, `sessions/`, `meetings/` and `inbox/` when the body matches both private and non-private terms — stay put as `work`; the user decides per note. Mixed detection uses only project slugs plus aliases that contain a space or are at least 6 characters long, minus the `MIXED_STOPWORDS` list in `bin/brain_migrate.py` (common words such as `running`, `access`, `home`). A note whose `tags:`/`week_goal:` alias resolves to private stays private (and moves) but is flagged `mixed-private` for review; `apply` leaves mixed `work` rows completely untouched (no frontmatter written) so a later `classify` can still re-decide. `classify` refuses an `--out` inside the vault (the report lists private paths). Notes whose area is already fixed (by frontmatter, or by living under `private/`) keep it. Private items found in `meetings/` or `inbox/` are flagged "move by hand" rather than moved.
3. Registry and rule edits come **first**: adjust the registries (and re-run `classify`, with a fresh `--out`, until the proposals look right). `classify` regenerates the CSV from scratch, so never re-run it over a CSV you have already edited. The CSV (including the LLM-pass proposals) is reviewed and edited **last**, then passed straight to `apply`.
4. `brain-migrate-scope apply --report <dir>/migration-report.csv` prints a **dry run** and exits 3.
5. Re-run with `--yes`. It first takes a verified tarball snapshot into `~/Obsidian/backups` (`--backup-dir` overrides), then writes frontmatter, moves private notes into `private/…`, splits the `[personal]` Today/This-week lines out of top-of-mind into `private/private.md` as `[private]` (a `[personal]` line labelled `Personal project — <X>` where X resolves to a work/projects entry stays in top-of-mind with the `[personal]` marker dropped; the dry run lists both sets), and seeds the two `scopes.md` files (if absent; if present, seed rows whose project is missing are appended, existing rows untouched). On the machine where it runs it also runs `qmd update` and `qmd --index private update` (skip with `--no-qmd`).
6. On **each host** run `qmd update` and `qmd --index private update`. The vault syncs via Syncthing, but the qmd index is per host. After `claude/install.sh` on each host, also check that `qmd --index private collection list` shows the `private` collection (an empty or missing one means `private.yml` was not populated) and that `command -v brain-scope brain-search` resolves.

Exit codes of `apply`: `0` ok; `1` it continued past per-row errors (OS errors, or a collision it refused to act on); `2` bad usage or a bad report — invalid rows are refused and **nothing is written**; `3` dry run, i.e. `--yes` was missing. `1` is also returned when the verified backup fails (nothing is written). It never overwrites an existing `private/…` file of the same name: a collision is listed as `refused` in the dry run and skipped. A re-run after `apply` proposes zero changes.

**Window hazard.** Between deploying the skills and running the migration, a worker still on old skills can write a private note to its old path. Re-running `classify` / `apply` picks it up. Deploy order: land on `main` and roll it out to every host (see [Repository and landing flow](#repository-and-landing-flow)), then migrate.

### `brain-orient` (manual)
Read-only. Reports current focus (top-of-mind, plus `private/private.md` when the scope allows), last session, and `brain-search` hits for the current topic. Useful mid-session.

### `brain-persist` (manual — the only writer of top-of-mind & sessions)
Writes a session note, reconciles top-of-mind with what actually happened this session (flips **Today** action statuses and adds any action worked on but not yet listed), captures reusable insight as claim-named notes in `knowledge/graph/`, then runs `qmd update && qmd embed` (and the same with `--index private` when it wrote into `private/`). Notes get `area:`/`project:` frontmatter and private ones are routed into `private/`. **It deliberately does not sweep completed `[x]` actions** — those stay in **Today**; sweeping finished actions into **Previously this week** is `brain-plan-day`'s job. **Nothing else updates top-of-mind.** Safe to run as a mid-task checkpoint — repeated runs in a session (or same-day/same-topic) update the existing note rather than creating duplicates; multi-day work gets one note per day. **Structure:** the main agent distils what to persist (it has the session context); a subagent does the file writes + re-index (keeping that noise out of the main thread) and determines the date with `date +%Y-%m-%d` rather than assuming it. **Two modes:** the default (no argument) is this full persist for the user's own driving session; `brain-persist worker` runs a **scoped** persist for a dispatched worker (session note + knowledge notes + re-index only — **never** top-of-mind, **never** the diary), used by workers as a checkpoint and triggered by `brain-collect` at teardown (see [The execution layer](#the-execution-layer)).

### `brain-sync-meetings` (manual)
Pulls recent Krisp meetings via the Krisp MCP and renders each into `meetings/`. See [Meeting sync](#5-meeting-sync-krisp).

### The planning cadence (manual)

The user runs **one coordinator session per day, named `brain-<YYYY-MM-DD>`**: start it each morning (optionally with `brain-plan-day`), and close the previous day's once it has run `brain-persist`. Workers whose `dispatcher` session has gone message the newest `brain-<date>` session instead. Two inline skills (no subagent — they converse with you) keep the horizons current; neither has to run for the vault to stay small, because `brain-sweep` does the cleanup and the SessionStart hook warns when top-of-mind passes 40 KB.

- **`brain-plan-day` — optional, start of the day's coordinator session.** Checks yesterday's `brain-<date>` session persisted and reminds you to close it, runs `brain-sweep`, rolls unfinished Today actions over (offering to tick ones whose worker was collected), picks two or three Today actions from This week's goals, and reminds you to re-arm `brain-monitor` for live workers (its watch dies with yesterday's session).
- **`brain-plan-week` — Monday (~15 min, interactive).** Reviews what moved last week per track, runs `brain-sweep` to archive it, proposes 2–3 goals across the personal tracks (learning, personal projects, health, life admin) with a recommendation, writes the agreed **This week**, and snapshots the finishing week's goals and retro to `planning/YYYY-Www.md`.
- **`bin/brain-sweep`** (`--dry-run`, `--file private/private.md`, `--max-kb N`) moves `[x]` Today items (dated) into **Previously this week**, and archives Previously entries from earlier ISO weeks — or all of them once the file exceeds 40 KB — under `## Done` in `planning/YYYY-Www.md` (`private/planning/` for private.md). It never touches `[ ]`/`[/]` items or **This week**, and writes atomically after re-reading the file.
- `brain-post-standup` was **retired** in Oct 2026 (no standup any more); `claude/install.sh` prunes its dangling `~/.claude/skills/` link.

### Ambient status updates (automatic)

Wired via the vault `CLAUDE.md`, applying to **Today's actions** only (This week / backlog goals are plain bullets, not status-tracked). As work starts and finishes, Claude flips statuses without asking — `[ ]` → `[/]` when work begins, `[/]` → `[x]` when it finishes — and adds anything started but not listed under **Today** as `[/]`. It always states briefly what it changed; never silent edits. The flips are low-stakes and reversible; `brain-plan-day` and `brain-persist` reconcile the page.

**Status vocabulary (Today only, plain text — no Tasks plugin):** `[ ]` to do · `[/]` in progress · `[x]` done · `[-]` dropped. **Convention:** any issue / PR is written as a markdown link to its full URL, never a bare reference.

### The execution layer

Three commands turn a **Today** action into work and bring the verified result back — the brain can *run* a task, not just record it. The design is adapted from an external "cmux-worker" framework but rebuilt for this setup: **jujutsu (jj)** instead of git, **plain tmux** instead of cmux, and **vault-only** coordination state.

- **`brain-dispatch <today action> [base directory] [--host <name>] [--harness omp|claude]`** — gathers context (a qmd search + relevant meeting notes + the **This week** goal the action serves), classifies the task **code** vs **non-code**, writes a worker note at `workers/<slug>.md`, creates a `jj workspace` (code tasks only, rooted on trunk — the jj equivalent of a git worktree, so parallel workers don't collide), launches a **detached `tmux` session** (`brain-worker-<slug>`) running the chosen harness primed from its brief note, verifies it actually started, then flips the Today action `[ ]` → `[/]`. Omitted `--host` defaults to this machine's real host name (`self_host`); omitted `--harness` defaults to that host's default (see [Worker hosts](#worker-hosts)); a disallowed host/harness pair is refused before anything is written. The launch script (`launch-worker.sh`) pins a session id at launch (claude: `--session-id`; omp: discovered after readiness) and records it on the worker note as `session_id` — this is what lets a later reboot recovery resume the exact conversation instead of starting a fresh one.
- **`brain-status`** — a fast, read-only "where am I at": reads top-of-mind, today's `diary/` note, and the worker notes; reports Today actions and this week's goals; and (its distinctive job) buckets workers into three groups — **ready to collect** (`done`, not yet collected, flagged prominently), **blocked/parked** (each shown with its `blocker`, an attach command for `blocked`, a resume hint for `parked`), and **in flight** (`primed`/`working`). It sits between `brain-orient` (heavy re-hydration) and just opening the file.
- **`brain-collect [slug]`** — reaps a worker; it branches on the worker's `status`. A **`done`** (non-code) worker takes the standard path: verify its work **against reality** (a pushed jj change + a raised PR for code; the recorded result for non-code) rather than its self-report, flip the Today action `[/]` → `[x]` with the PR link or result reference, append a `## Shipped` entry to today's `diary/` note, mark the worker `collected`. A **`blocked`** worker (the usual code case — PR raised, awaiting a human's review/merge — or stuck mid-work on an external dependency) is **not** closed on its self-report: collect shows the `blocker` and offers a three-way choice — **leave** (keep the live session so you can finish it), **park** (tear down but preserve the work-in-progress for a later re-dispatch), or **resolved & complete → close** (which first verifies the PR is actually merged via `gh pr view` before marking `[x]`). Either way, before killing the session collect triggers the worker's own scoped persist and waits for its completion signal (see [worker self-persist](#the-execution-layer)), then offers to tear down the tmux session and jj workspace.
- **`brain-revive-workers [--host <name|all>] [--apply] [--only <slug,...>]`** — after a reboot kills every `brain-worker-<slug>` tmux session, brings back exactly the ones that were **live at shutdown**, by resuming their existing harness conversation **by `session_id`** (`claude --resume <id>` / `omp --resume <id>`) — never by priming a fresh one from the brief, which would silently discard the worker's context. Dry run (the default) reports a verdict per worker note (`live` / `ended-before-shutdown` / `touched-since-boot` / `already-running` / `no-transcript` / `ambiguous`) for confirmation before `--apply` resumes the `live` ones. Never touches worker-note `status`, never kills a session. See `skills/brain-revive-workers/SKILL.md`.
- **`brain-monitor <slug>...`** — for a coordinator session watching its dispatched workers: `worker-monitor.sh`, run under the Monitor tool, polls the named workers every 60 s and prints **one line only when the set of waiting workers (or a wait) changes** — `ANSWER` / `REVIEW` / `UNBLOCK` / `COLLECT` / `NUDGE` / `INSPECT` / `REVIVE` / `CHECK`, each paired with the action to take. It also watches the GitHub PRs named in the workers' note frontmatter (and any `--pr <url>`), printing a line whenever one changes — `MERGED` / `CLOSED` / `RED` / `CONFLICT` / `HEAD` / `GREEN` (via `skills/_shared/lib/forge.sh`, one `gh pr view` per PR per poll). Deterministic and read-only (tmux `has-session`/`capture-pane`, note reads, transcript mtime, `gh pr view`; never sends keys); Claude Code workers only for v1. See `skills/brain-monitor/SKILL.md`.
- **`brain-dashboard <project>`** — for a coordinator session: publishes, or re-adopts from the `dashboards.md` registry, its long-term private "<Project> Control" artifact (Waiting on you, tasks, workers, a message box that reaches the manager) and keeps it in sync by turning `brain-monitor` lines into `ArtifactData` writes via `dashboard.py`. Claude Code only. See `skills/brain-dashboard/SKILL.md`.
- **`brain-pm-tech-lead <project> [--repo <owner/repo>]`** — the process for running a project with two long-lived, non-coding coordinator sessions: a **tech lead** (opus: technical direction, design rulings before code, a fidelity check on each PR's final head) and a **PM** (sonnet: dispatch, `brain-monitor` with PR watch, the Control dashboard, Today lines, collect, a readiness check on each PR), while the user sets direction and merges. It composes the four skills above and ships role texts, a worker base brief and a FINAL HANDOVER template under `assets/`. Claude Code only. See `skills/brain-pm-tech-lead/SKILL.md`.

A worker is interactive by default: the session gathers its own context, greets you with a concise proposed action list, then behaves as a normal interactive session you drive. It starts autonomously only when dispatched with `start_autonomously: true`. Coordination state is **vault-only**: no brief, result, or sentinel ever lands in the jj workspace, so nothing pollutes the change history. Status lives in the worker note's `status` field (`primed → working → blocked → done → collected`, plus `parked`), not a filesystem sentinel. **A code worker terminates at `blocked`, not `done`:** it can raise a PR but cannot merge it (a human does), so it sets `status: blocked` with `blocker: awaiting review/merge of <PR>`; a non-code worker has nothing to merge and sets `done`. The Today action reaches `[x]` only when the work is genuinely complete — a non-code artefact done, or a code PR actually merged. `brain-dispatch` (`[ ]` → `[/]`) and `brain-collect` (`[/]` → `[x]`) are the sole coordinators of Today statuses for dispatched work — the main session stays the only writer of top-of-mind, and workers write only their own note. The one exception is a coordinator worker (e.g. a `brain-pm-tech-lead` PM) that dispatches and collects its own workers: it acts as their main session for those workers' Today lines only. A dispatch can also pin the worker's `model` and carry task-specific instructions verbatim into its brief.

**Worker self-persist, orchestrated by collect.** Each worker persists its own journey via a **scoped `brain-persist worker`** — a session note (including any harness workflow friction) + knowledge notes + re-index, but **no** top-of-mind reconciliation and **no** diary. On collection (done-close, park, or resolved-close), `brain-collect` does its own authoritative writes, then — before teardown — triggers `brain-persist worker` **inside the still-running worker session** (setting `collect_state: collecting` as the trigger), waits for the worker's scoped persist to flip it to `persisted`, and only then kills the session. A worker may also run `brain-persist worker` mid-session as a checkpoint. Durable knowledge is thus promoted by the worker's own scoped persist at collection, **not** by a later main-session persist; the main-session `brain-persist` (no argument) now covers only the user's own driving session and top-of-mind reconciliation.

A **code** worker launched by `brain-dispatch` pushes its `<slug>` branch, opens a PR with the repo's own tooling (the repo's PR workflow if it has one, else `gh pr create`), waits for CI green with `gh pr checks --watch`, and stops — the user merges.

### Skill storage (the repo is the source of truth)

The skill files live **in this repo** under `skills/<name>/` and are version-controlled in jj. The two harnesses find them two different ways:

- **omp** discovers them directly: `skills.customDirectories` in `~/.omp/agent/config.yml` points at `~/projects/brain/skills`, and omp scans one level deep for `<name>/SKILL.md`. There are **no symlinks**. Because discovery happens at startup, a skill added or edited mid-session appears on the next omp start, not immediately.
- **Claude Code** has no such directory setting, so `claude/install.sh` symlinks `~/.claude/skills/<name>` → `~/projects/brain/skills/<name>` for every directory with a `SKILL.md` (see [Claude Code wiring](#claude-code-wiring-claude)).

Either way the repo *is* the source of truth, and the wiring is also what makes the skills portable to a new machine.

`skills/_shared/` holds everything that is not itself a skill: `hosts.conf` (the worker-host registry, [above](#worker-hosts)), `harness/*.md` (prose reference files, one per harness), and `lib/` (the shell libraries every dispatch/collect script sources, plus their fixtures and tests). It has no `SKILL.md`, so omp's scanner ignores it, and `claude/install.sh` explicitly skips it.

---

## 5. Meeting sync (Krisp)

**Design: pull, not push.** the original setup's system received Krisp *webhooks* via AWS Lambda + S3. We dropped all of that — instead `brain-sync-meetings` **pulls** from the Krisp MCP on demand. No AWS, no webhook endpoint. **Currently dormant:** the `krisp` server is defined but disabled in `omp/mcp.json`, so `brain-sync-meetings` stops at its auth check. The skill is kept deliberately — it is the verbatim renderer for whatever meeting-notes source replaces Krisp.

**Pure renderer.** Krisp generates the summary / key points / action items itself, server-side. The skill renders Krisp's own content **verbatim** into the note — no per-meeting LLM derivation. (Cross-meeting synthesis is reserved for a future `digest` step that would write a *proposal* to `inbox/` — not built.)

**Key behaviours of the skill:**
- Dedupe by `meeting_id` (in note frontmatter), so re-runs are safe.
- `notes_pending: true` — if Krisp hasn't generated notes yet (transcript only), the note is flagged; the next sync re-fetches and upgrades it.
- Does **not** depend on Krisp's `outline` (its "Generate Outline" often stays manual).
- Stops and asks you to authenticate (`/mcp reauth krisp`) when the Krisp tools aren't connected, rather than reporting a misleading "0 meetings".

**Krisp MCP tools used:** `date_time`, `search_meetings` (list + metadata), `get_multiple_documents` (full rendered notes + transcript).

**Krisp auto-generation:** to make Krisp produce notes automatically (so syncs always find them), set a default template in **Krisp → Settings → AI Note Taker → Templates**. The Free plan caps at 2 notes/day; Pro is unlimited.

---

## 6. Key decisions (and why)

- **Approval policy instead of a permission gate** — the machine runs `tools.approvalMode: yolo`, so nothing prompts and containment comes entirely from **`pi-automode`** (installed 11 Sep 2026 as the omp plugin `@czottmann/pi-automode`). **The ordering is the thing to get right:** the plugin's `tool_call` hook fires *before* omp's approval gate, so the plugin can only **block**, never **grant**. Under the original `write` setting its allow was purely advisory and every `bash` call still prompted — which is what "auto mode isn't working" looked like. `yolo` is what makes the plugin's verdict *binding*. It blocks on deterministic hard-deny rules plus a **local** model classifier (Qwen3.5-4B via `llama-server`, ~28 ms/decision, no API spend). The original setup's L1/L2 gate stays dropped, and still no `ANTHROPIC_API_KEY` is needed. ⚠️ It **fails closed** — a stopped `llama-classifier` blocks every tool call — which is why dispatch preflights it. See §7. Dispatched workers additionally carry `--auto-approve` from `brain-dispatch`; that is now redundant (it forces the same `yolo`) but harmless, and worth keeping explicit for a worker launched with an overridden config.
- **No AWS / no webhooks** — Lambda+S3 existed only to give Krisp a public endpoint to push to. A pull model via the MCP removes the entire need.
- **Manual `brain-sync-meetings`, not scheduled** — the Krisp MCP is reachable from any omp session (its OAuth credential now persists in omp's agent dir, unlike the Mac's per-session auth), but the skill **pauses per meeting** for you to assign unidentified speakers in Krisp, so a headless run is the wrong primitive. omp also has no in-session cron.
- **Per-meeting note = Krisp verbatim** — matches the original setup's poller (a renderer, not a generator); keeps capture honest.
- **The Krisp MCP server ships disabled** — `omp/mcp.json` defines `krisp` with `"enabled": false`. It is not in use on this machine (Krisp is gone), but the definition and the consuming skill stay in place, so re-enabling is `/mcp enable krisp` + one `/mcp reauth`. Nothing in the vault flow depends on it: the meeting-sync skill simply stops at its auth check.
- **Vault indexed; shared store not** — on this machine qmd indexes the vault alone (default index, `private/**` excluded; the private index is separate), because `~/Obsidian/shared` was never copied across. Re-create the store and add a `shared` collection to restore one query spanning personal and team artefacts.

---

## 7. Known limitations

- **Capture is manual and lossy by design.** Only `brain-persist` writes session content; the `session_shutdown` handler merely reindexes. A session that ends abruptly, pauses on a question, or is a quick lookup captures nothing. The `AGENTS.md` nudge only fires on a *wrap-up*.
- **Krisp auth.** Managed OAuth, reused across sessions: once enabled, if the tools go missing, run `/mcp reauth krisp` once. (On the Mac this was per-session and needed `/mcp` every launch — that limitation is gone.)
- **No unattended meeting capture.** A headless `omp -p` run can reach the Krisp MCP, but the speaker-assignment pause makes it a poor fit for a schedule; cloud routines cannot reach the local vault at all.
- **Krisp Free plan caps notes at 2/day**, and the Outline block stays manual.
- **The tool-call guardrail is fail-closed and machine-local.** `pi-automode` blocks any action its classifier cannot vet, so if `llama-classifier` is stopped, **every** tool call in **every** omp session is blocked — not just workers. The systemd **user** unit is `enabled` but `Linger=no`, so it comes up at graphical login, not at boot. Recover with `systemctl --user start llama-classifier` (dispatch preflights this before launching a worker). Two adjacent notes: `pi-automode` keeps its own config at `~/.pi/agent/extensions/pi-automode/config.json` — a `.pi` tree on an omp machine — and its classifier is a vendored local model, so it is only as good as a 4B's judgement on the borderline. `/automode status|off` controls it per session.
- **The classifier's context window must stay at ≥ 32768 — this is a sizing constraint, not a tuning knob.** pi-automode charges its *entire* fixed input (a ~6.3 KB system prompt plus a transcript of up to ~8,000 tokens ≈ 32 KB) against the window, on top of a 4,096-token safety margin and a 1,200-token output reserve, and compares in **bytes**. At `-c 16384` that leaves only ~3.1 KB for the action, so the first message longer than a sentence drives the budget to zero and **every** tool call is denied with `conservative limit 0`. It is set to **65536** in both `~/.config/systemd/user/llama-classifier.service` and the `local-classifier` model's `contextWindow` in `~/.omp/agent/models.yml` — **change both together or not at all**; a declared window larger than the server's is a lie, and a smaller one reintroduces the outage. Observed 11 Sep 2026 (KV at 64 K costs ~1.6 GB VRAM).
- **The host/harness scripts require the real `ssh`/`tmux` binaries**, reached via `command ssh` / `command tmux` (`skills/_shared/lib/host.sh`). A machine where those are shadowed by something that cannot run non-interactively (or is missing) breaks every remote-capable script, not just dispatch.
- **Claude Code's permission-prompt chrome is unverified.** The folder-trust prompt (`pane_trust_prompt`) was captured from a real pane and is answered `Down` then `Enter` (default selection is "No, exit"). The tool-permission prompt could not be captured under auto mode, so `harness-chrome.sh`'s pattern for it is best-effort, not fixture-verified.
- **The omp fixture set is a version behind.** `skills/_shared/lib/fixtures/omp/{ready,busy,question}.txt` were lifted verbatim from `teardown-worker.test.sh` and are from omp 18.1.16; `omp/launch-typed.txt` was captured fresh against 18.1.19. If the composer chrome changed between those versions, recapture the older three (see `skills/_shared/lib/fixtures/README.md`).

---

## 8. How to make common changes

| Change | Do this |
|---|---|
| Add a project | Add one row to `00-home/scopes.md` (work/projects) or `private/scopes.md` (private): slug, area, aliases, slug prefixes. No code change; dispatch/persist also add rows themselves when nothing fits. |
| Change scope rules or the private/shared split | Edit `bin/brain_scope.py` (areas, scopes, paths); the hook `claude/hooks/brain-session-start.sh` and `omp/brain-vault.ts` apply it at session start. Run `bash bin/tests/bin.test.sh`. |
| Add a qmd collection | Edit `~/.config/qmd/index.yml`, add a collection block, run `qmd update && qmd embed`. (Private material belongs in the `private` index, `~/.config/qmd/private.yml`, not in the default one.) |
| Move/rename the vault | Update the path in `~/.config/qmd/index.yml`; the skills refer to it as `~/Obsidian/vault`, and the extension takes it from `BRAIN_VAULT` (or the `VAULT` default at the top of `omp/brain-vault.ts`). Re-run qmd. |
| Change what's injected at session start | Edit `buildContext` in `omp/brain-vault.ts`. |
| Change any skill's behaviour | Edit the skill in the repo (`skills/<name>/SKILL.md`) — omp discovers the repo directly, so there is no symlink to refresh. |
| Change persist/orient behaviour | Edit `skills/{brain-persist,brain-orient}/SKILL.md`. |
| Change planning-cadence behaviour | Edit `skills/{brain-plan-day,brain-plan-week}/SKILL.md`; the sweep/archive mechanics live in `bin/brain_sweep.py` (tests: `bin/tests/brain_sweep_test.py`). |
| Change execution-layer behaviour | Edit `skills/{brain-dispatch,brain-status,brain-collect,brain-revive-workers}/SKILL.md` and, for mechanics rather than prose, the scripts they call: `skills/brain-dispatch/scripts/{preflight,wait-for-brief,launch-worker}.sh`, `skills/brain-collect/scripts/teardown-worker.sh`, and `skills/brain-revive-workers/scripts/{find-live-sessions,revive-workers}.sh`. |
| Add a worker host / set up a new machine | Edit `skills/_shared/hosts.conf` — a new machine needs its hostname (`hostname -s`) in its row's hostnames column (or `BRAIN_SELF_HOST` set) or it cannot tell which host it is — install that host's prerequisites (see [Worker hosts](#worker-hosts), e.g. [`laptop`'s prerequisites](#laptop-prerequisites)) and qmd (see [Search](#search-qmd)), and run `claude/install.sh` there if it will run Claude Code workers. |
| Land a change on every host | Push `main` to `origin` (GitHub), then on each host `jj git fetch`, `jj new main`, `claude/install.sh` — see [Repository and landing flow](#repository-and-landing-flow). |
| Change harness chrome after an upgrade | Edit `skills/_shared/lib/harness-chrome.sh`, recapture the affected fixtures per `skills/_shared/lib/fixtures/README.md`, then run the `*.test.sh` files to confirm the new patterns still classify correctly. |
| Add a harness-specific instruction | Edit the matching file under `skills/_shared/harness/*.md` — never a `SKILL.md`, which must stay neutral between harnesses. |
| Change the tool-call guardrail (rules, classifier model) | Edit `~/.pi/agent/extensions/pi-automode/config.json` (global), then `/automode reload`; serve a different model by editing `~/.config/systemd/user/llama-classifier.service` + `~/.omp/agent/models.yml`. |
| Change the ambient status-flip rules | Edit the vault's `CLAUDE.md`. |
| Change meeting rendering | Edit `skills/brain-sync-meetings/SKILL.md`. |
| Tune the persist nudge | Edit the "Knowledge Vault" section of `~/.omp/agent/AGENTS.md`. |

---

## 9. Verify / health-check

```bash
qmd status                                   # collections + doc/vector counts
qmd search "<query>" -c vault                # sanity-check search (keyword)
qmd --index private status                   # the private index (per host)
brain-search --scope all "<query>"           # scope-aware search across both indexes
env -u CI qmd vsearch "<query>"              # vector search — plain `qmd vsearch` aborts under omp's injected CI=true
omp config get skills.customDirectories      # → ["~/projects/brain/skills"]
omp config get extensions                    # → ["/home/user/projects/brain/omp/brain-vault.ts"]
ls -l ~/.omp/agent/mcp.json                  # symlink → the repo's omp/mcp.json
omp -p 'quote the vault path from your VAULT context block'   # end-to-end: injection + skill discovery
```

Offline test suites (fixture-driven, no live harness or host needed):

```bash
bash skills/_shared/lib/host.test.sh
bash skills/_shared/lib/harness-chrome.test.sh
bash skills/_shared/lib/forge.test.sh
bash skills/brain-dispatch/scripts/dispatch-scripts.test.sh
bash skills/brain-collect/scripts/teardown-worker.test.sh
bash skills/brain-revive-workers/scripts/revive-scripts.test.sh
bash skills/brain-monitor/scripts/worker-monitor.test.sh
bash skills/brain-dashboard/scripts/dashboard.test.sh
bash claude/install.test.sh
bash claude/hooks/brain-session-start.test.sh
bash bin/tests/bin.test.sh
bash omp/brain-vault.smoke.sh                # needs bun; skips (exit 0) without it
```

---

## 10. Not built (possible future work)

- **Meeting digest** — a cross-meeting `omp -p` step writing a proposal to `inbox/` (the original setup has this).
- **Daily briefing** — sweep Calendar/Slack/GitHub into `inbox/`.
- **Scheduled sync** — omp has no cron primitive; this would need an external timer (`systemd --user`) driving a headless run, and is blocked by the same speaker-assignment pause.
- **`.obsidian/` gitignore** — once the vault is opened in Obsidian, ignore its config folder in the jj repo.
