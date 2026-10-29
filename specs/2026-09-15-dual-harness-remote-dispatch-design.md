# Dual-harness skills and remote worker dispatch — design

**Date:** 2026-09-15
**Status:** approved design, implementation in progress
**Supersedes in part:** the harness-specific wording introduced by the 2026-09-11 omp port

## 1. Problem

The brain skills were ported from macOS + Claude Code to Linux + oh-my-pi (omp) on
2026-09-11. Since then the user runs **two harnesses on the Linux desktop** (omp and
Claude Code) and keeps the **Mac (`workmac`)** as a second machine running Claude
Code only. The skills currently hard-code omp: invocation prefixes (`/skill:x`), the
`task` subagent tool, omp's composer chrome for ready/idle detection, `omp
--auto-approve` as the worker launch, the pi-automode guardrail preflight, and
GNU-only `df` flags.

Two things are wanted:

1. **Both harnesses supported**, and an agent using a skill under one harness must not
   have to read the other harness's instructions.
2. **Remote dispatch**: a session on the Linux desktop can dispatch a worker that runs
   on the Mac (tmux and repos on the Mac, coordinated from Linux).

## 2. Decisions already taken

| Question | Decision |
|---|---|
| Remote-dispatch shape | One coordinator (Linux) → two execution hosts (local, Mac). The Mac never dispatches. |
| Harness map | Linux: omp **and** Claude Code. Mac: Claude Code **only**. |
| Vault on the Mac | Same path (`~/Obsidian/vault`), kept in sync by **Syncthing** (preserves mtimes). |
| Containment of Claude Code workers | None to build. Claude Code runs with the user's auto-mode default; the user controls it. |
| Default worker harness | Per host: `omp` on Linux, `claude` on the Mac. Overridable per dispatch with `--harness`. |
| Compartmentalisation | **Scripts absorb mechanics wherever possible** (approach 2). **Prose reference files only where scripting is impossible** (approach 1). No template generation. |
| Mac's stale skill checkout | Updated **afterwards**, not in this change (see §9). |
| Where this change lands | One jj change on top of the omp-port commit, described at the end. |

## 3. Facts verified on 2026-09-15

- Mac SSH alias: `workmac`. Non-interactive `ssh host cmd` gets a bare PATH
  (no Homebrew, no `~/.local/bin`); **`zsh -lc` is required** to see `claude`
  (`~/.local/bin/claude`, v2.1.272), `tmux` 3.6b, `jj`, `glab` (all Homebrew). `omp` is
  not installed on the Mac.
- On the Linux desktop `ssh` is shadowed by kitty's SSH kitten in interactive zsh
  (`STDIN must be a terminal`). Scripts must call **`command ssh`**, exactly as they
  already call `command tmux` to bypass the oh-my-zsh tmux plugin.
- macOS `df` is BSD (`df -g`); Linux is GNU (`df -BG --output=avail`).
- The Mac still holds the pre-port Claude Code wiring: `~/.claude/hooks/obsidian-session-start.sh`,
  `~/.claude/hooks/obsidian-session-end.sh`, and a `SessionStart` hook entry in
  `~/.claude/settings.json`. Those scripts were **never committed to this repo**.
- The Mac's `~/projects/brain` checkout is at a pre-port revision; `~/.claude/skills/brain-*`
  are symlinks into it.
- omp discovers skills via `skills.customDirectories` scanning one level for
  `<name>/SKILL.md`; a directory without a `SKILL.md` is ignored.
- Harness-specific tokens today, per skill (counts of `omp`/`claude`/`/skill:`/`tmux`/subagent
  mentions): dispatch 8/1/12/21/16, collect 0/0/11/8/0, persist 4/1/9/0/9, dream 3/2/1/0/8,
  status 0/0/5/5/1, sync-meetings 2/2/2/0/0, orient 2/0/0/0/0, plan-day 0/0/5/0/1,
  plan-week 0/0/2/0/1, post-standup 0/0/3/0/1.

## 4. Architecture

Two independent axes, handled by two different mechanisms:

- **Harness axis** (omp | claude): differences in *what the agent types and reads*.
  Handled by (a) neutral wording in every SKILL.md, (b) a per-harness table inside one
  shared shell library for everything a script types or pattern-matches, and (c) two
  short prose reference files for the handful of things that cannot be scripted.
- **Host axis** (local | mac): differences in *where commands run*. Handled entirely by
  one shared shell library that wraps every remote-capable command, plus a hosts file.
  No SKILL.md prose ever branches on host.

The **worker note** is the single carrier of both facts for a running worker
(`host`, `harness`, `attach`). Dispatch writes them once; status, collect and persist
read them and pass them to scripts verbatim.

### 4.1 Directory layout after the change

```
skills/
  _shared/                       # ignored by omp discovery (no SKILL.md); not symlinked for Claude Code
    hosts.conf                   # host registry (§4.2)
    harness/
      omp.md                     # prose reference — read only under omp
      claude-code.md             # prose reference — read only under Claude Code
    lib/
      host.sh                    # run_on_host, tmx, host_field, ssh/tmux wrappers (§4.3)
      harness-chrome.sh          # per-harness launch cmd + chrome patterns + persist text (§4.4)
      host.test.sh
      harness-chrome.test.sh     # fixture-driven, one fixture set per harness
  brain-dispatch/
    SKILL.md                     # thinned; mechanics moved to scripts
    scripts/
      preflight.sh               # §5.7
      wait-for-brief.sh          # §5.7
      launch-worker.sh           # §5.7
  brain-collect/
    SKILL.md
    scripts/
      teardown-worker.sh         # gains --host/--harness; sources _shared/lib
      teardown-worker.test.sh    # second fixture set (Claude Code chrome)
  brain-*/SKILL.md               # neutral wording (§5)
claude/                          # Claude Code wiring, sibling of omp/ (§6)
  hooks/brain-session-start.sh
  hooks/brain-session-end.sh
  settings.snippet.json
  install.sh
omp/                             # unchanged except the session-id line (§4.5)
README.md                        # §3/§8 gain a harness column and a "worker host" row
specs/2026-09-15-dual-harness-remote-dispatch-design.md   # this file
```

### 4.2 Hosts file — `skills/_shared/hosts.conf`

Plain, `#`-commented, one host per line, parsed by `host.sh` with `awk`. Only facts that
cannot be probed live here.

```
# name   ssh_alias        harnesses    default_harness
local    -                omp,claude   omp
mac      workmac    claude       claude
```

Rules: `ssh_alias` `-` means local. A `--harness` not in `harnesses` for the chosen host
is refused **before any file is written**. Anything probeable (OS flavour, `df` style,
binary presence, systemd presence) is probed on the host by `preflight.sh`, never stored.

### 4.3 Host library — `skills/_shared/lib/host.sh`

Sourced by every script. Pure functions, unit-tested with a fake `ssh` on `PATH`.

| Function | Behaviour |
|---|---|
| `host_field <name> <field>` | Read a column from `hosts.conf`; non-zero exit for an unknown host. |
| `host_is_local <name>` | True when `ssh_alias` is `-`. |
| `run_on_host <name> <cmd...>` | Local: `bash -c "$cmd"`. Remote: `command ssh -o BatchMode=yes <alias> zsh -lc <quoted cmd>`. Always `zsh -lc` so Homebrew/`~/.local/bin` are on PATH. Quoting via `printf %q`. |
| `tmx <name> <tmux args...>` | `run_on_host <name> command tmux <args>` — the only way scripts touch tmux. |
| `remote_home <name>` | `$HOME` locally; `run_on_host <name> 'echo $HOME'` remotely (expands `~` paths for the other OS). |
| `attach_cmd <name> <session>` | Local: `tmux attach -t <session>`. Remote: `ssh -t <alias> tmux attach -t <session>`. |

`BRAIN_SSH` (default `command ssh`) and `BRAIN_TMUX` (default `command tmux`) are
overridable env vars so tests can stub them.

### 4.4 Chrome library — `skills/_shared/lib/harness-chrome.sh`

One function per fact, switching on `$harness` (`omp` | `claude`). **This is the only
place harness chrome strings exist**; both dispatch's `launch-worker.sh` and collect's
`teardown-worker.sh` source it.

| Function | omp (observed, omp 18.1.16) | claude (to be captured from a real pane in task 1) |
|---|---|---|
| `launch_cmd <brief_path>` | `omp --auto-approve "Read your worker brief at <brief_path> and follow its priming, then greet me."` | `claude "Read your worker brief at <brief_path> and follow its priming, then greet me."` (no permission flags — auto-mode is the user's default) |
| `launch_marker` | `omp --auto-approve "Read your worker brief` | `claude "Read your worker brief` |
| `pane_ready <pane>` | `π >` present and no spinner/`⚙ [1-9]` | captured |
| `pane_busy <pane>` | `⚙ [1-9]`, `esc to interrupt`, braille spinner | captured |
| `pane_question <pane>` | `Allow tool:`, `up/down navigate`, `esc cancel`, `Do you want`, `Select an option` | captured (permission prompt, `AskUserQuestion` dialog) |
| `pane_trust_prompt <pane>` | never | `trust this folder` / `Is this a project you created` — answer `Down` then `Enter` (the dialog defaults to "No, exit") |
| `pane_idle <pane>` | `pane_ready && !pane_busy && !pane_question` (moved here verbatim from teardown-worker.sh) | same composition, claude patterns |
| `persist_worker_text` | `/skill:brain-persist worker` | `/brain-persist worker` |

Fixtures: `skills/_shared/lib/fixtures/<harness>/{ready,busy,question,trust}.txt`,
verbatim `tmux capture-pane -p` output. The existing omp fixtures embedded in
`teardown-worker.test.sh` move here; Claude Code fixtures are captured on the Linux
desktop in a throwaway tmux session (`claude` is installed locally).

### 4.5 Session-id line (persist depends on it)

Both wirings must inject the **identical** line into the session-start context:

```
This session's id is <id> (harness: omp|claude-code)
```

`omp/brain-vault.ts` changes its current `This session's omp id is <id>` to this form.
`claude/hooks/brain-session-start.sh` reads `session_id` from the hook's stdin JSON and
prints the same line. `brain-persist` then says "the session id from the injected vault
context" with no harness name.

### 4.6 Worker note frontmatter (additions)

```yaml
host: mac                    # hosts.conf name; `local` for the desktop
harness: claude              # omp | claude
attach: ssh -t workmac tmux attach -t brain-worker-<slug>
```

Everything else in the note is unchanged. `jj_workspace` and `project_dir` are paths
**on the worker host**, written with `~` so they are valid on either OS.

## 5. Per-skill treatment

**Neutral wording rule (all skills).** Skill names appear as prose — "the brain-persist
skill (worker mode)", "run the brain-collect skill" — never with a `/` or `/skill:`
prefix. Subagents are "a subagent"/"one subagent". The question tool is "your question
tool". MCP administration is "re-authenticate the `shortcut` MCP server (see the harness
reference)". Exact typed text exists **only** in `harness-chrome.sh`.

**Harness pointer (only in skills that need it).** Two lines under the title:

> **Harness.** If you have a `task` tool you are in omp: read
> `~/projects/brain/skills/_shared/harness/omp.md`. If you have an `Agent` tool you are in
> Claude Code: read `~/projects/brain/skills/_shared/harness/claude-code.md`. Read one, never both.

### 5.1 brain-plan-day, brain-plan-week, brain-post-standup
Neutral wording only. No pointer, no scripts. "Do not delegate to a subagent" stays.

### 5.2 brain-orient
Neutral wording. `env -u CI qmd vsearch` **stays** (harmless under Claude Code); its
justification becomes "some harnesses set `CI=true` in their shell tool, under which
`qmd vsearch` aborts". "The `brain-vault` omp extension injects…" → "the session-start
wiring injects…". Pointer added (for the MCP re-auth command).

### 5.3 brain-status
Neutral wording. Attach commands are **no longer composed**: print the worker note's
`attach` field verbatim for `blocked` and in-flight workers. Pointer added (MCP).

### 5.4 brain-persist
Neutral wording; session id per §4.5 (no harness name); Step 2 says "dispatch one
subagent" and the pointer covers the tool name. Worker mode's handshake is unchanged.
The text collect types into a worker pane is **not** in this skill any more (it is
`persist_worker_text` in the chrome library).

### 5.5 brain-sync-meetings
Neutral wording; MCP definition location stays (`~/projects/brain/omp/mcp.json` is the
omp fact; Claude Code's equivalent is described in `claude-code.md`); the scheduling
paragraph moves into the two reference files. Pointer added.

### 5.6 brain-dream
The fan-out paragraph (omp `task` batching vs Claude Code's named-agent relay hazard)
moves to a **"Fan-out subagents"** section in each reference file; the skill says
"fan out the readers per the harness reference". The skills-discovery note moves to
README. Pointer added.

### 5.7 brain-dispatch (heaviest)

Argument grammar: `<today action> [base directory] [--host <name>] [--harness omp|claude]`.
Missing host → `local`; missing harness → the host's default; disallowed pair → refuse
before writing anything.

Scripts under `skills/brain-dispatch/scripts/`, all sourcing `_shared/lib`:

1. **`preflight.sh --host H --harness X --project-dir D`** → one `key=value` line:
   `dir_exists`, `vcs` (`.jj` → jj, else `.git` → git, colocated → jj), `free_gb`
   (GNU or BSD `df` chosen by `uname` on the host), `harness_bin` (present/missing),
   `guardrail` (omp on Linux: `systemctl --user is-active llama-classifier`, attempting a
   start if inactive; otherwise `n/a`). Exit non-zero only when the dir is missing or the
   harness binary is absent.
2. **`wait-for-brief.sh --host H --slug S [--timeout 90]`** → polls
   `test -f ~/Obsidian/vault/workers/S.md` on the host every 3 s until present (Syncthing
   lag). Local: immediate. Prints `synced=yes|no`.
3. **`launch-worker.sh --host H --harness X --slug S --project-dir D`** → the whole
   tmux dance, moved verbatim from today's steps 6–7 and made host/harness-neutral:
   `tmx new-session -d -s brain-worker-S -c D`; readiness probe with `RDY-S` marker and
   dotenv-prompt handling; type `launch_cmd` **without** Enter, verify with
   `launch_marker`, then Enter as a separate call; poll for `pane_trust_prompt` (answer
   `Down` then `Enter`) and `pane_ready` for up to 40 s. Prints `verified=yes|no attach=<attach_cmd>`.

The launcher-subagent prose shrinks to: gather context → classify → resolve host and
harness → `preflight.sh` → write the worker note (with §4.6 fields) → `wait-for-brief.sh`
→ `launch-worker.sh` → set `working` on `verified=yes`. The brief text keeps neutral
skill names ("raise the MR via the manage-mr skill", "run the brain-persist skill in
worker mode"); the worker harness knows its own invocation syntax. Step 3 (main
session) prints the `attach` field. The `--auto-approve`/pi-automode rationale moves to
`omp.md`.

### 5.8 brain-collect
`teardown-worker.sh` gains `--host H --harness X`, sources both libraries, and routes
**every** `tmux`, `jj`, `git`, `rm -rf`, `find`/`test` on workspace paths through
`run_on_host`/`tmx`. `pane_idle` and the persist trigger text come from the chrome
library. **Gate A stays local**: `collect_state` and the fresh `sessions/*.md` are read
from the local vault copy, which Syncthing populates with original mtimes, so
`-newer marker` remains valid. Collect's prose passes `host`/`harness` from the worker
note into the script and prints `attach` for the **leave** option. Tests gain a Claude
Code fixture set.

## 6. Claude Code wiring — `claude/`

Seeded from the Mac's existing scripts (`scp workmac:~/.claude/hooks/obsidian-session-*.sh`),
then adjusted:

- `hooks/brain-session-start.sh`: portable `~` paths, `qmd` resolved via `command -v`
  (not a hardcoded nodenv shim), and the §4.5 session-id line from stdin JSON. Output
  format matches `omp/brain-vault.ts` (`--- VAULT: TOP OF MIND ---`, `--- VAULT: LATEST SESSION ---`).
- `hooks/brain-session-end.sh`: `qmd update` only.
- `settings.snippet.json`: the `hooks.SessionStart` (matcher `startup|resume`) and
  `hooks.SessionEnd` entries, for the user to merge.
- `install.sh`: symlinks `~/.claude/skills/<name>` → `~/projects/brain/skills/<name>`
  for every `skills/*/SKILL.md` directory, **skipping `_shared`**; idempotent; prints
  what it linked.

`omp/` is unchanged except the session-id line (§4.5).

## 7. README changes

- §1 loop diagram: "session start ─► session-start wiring (omp extension | Claude Code hook)".
- §3: new subsection "Claude Code wiring (`~/.claude`)" mirroring the omp one; a
  "Worker hosts" table listing `hosts.conf` and the Mac's requirements (tmux, jj, glab,
  claude, repo at `~/projects/brain`, vault synced, skills symlinked).
- §8 rows: "Add a worker host" (edit `hosts.conf`, install prerequisites, run
  `claude/install.sh` there); "Change harness chrome after an upgrade" (edit
  `harness-chrome.sh`, recapture fixtures, run the tests); "Add a harness-specific
  instruction" (edit the matching `_shared/harness/*.md`, never a SKILL.md).
- §7 Known limitations: remote workers stall at teardown's cap until the Mac's skills are
  updated (§9); `ssh` must be the real binary in scripts.

## 8. Testing

- `_shared/lib/*.test.sh` and `teardown-worker.test.sh` run offline with fixtures and a
  stubbed `ssh`/`tmux`. All must pass before the change is described.
- Manual smoke (not automated): `preflight.sh --host mac --harness claude --project-dir ~/projects/brain`
  returns `dir_exists=yes vcs=git|jj harness_bin=present`; `launch-worker.sh` against a
  throwaway slug on `local` for **both** harnesses reaches `verified=yes`; the session is
  killed afterwards.
- A grep gate: after the change, `grep -rn '/skill:\|omp\b\|Claude Code' skills/brain-*/SKILL.md`
  returns nothing except the harness-pointer lines.

## 9. Out of scope / follow-ups

1. **Update the Mac's `~/projects/brain` checkout** and run `claude/install.sh` there.
   Until then a Mac worker runs the old brain-persist, never performs the `collect_state`
   handshake, and `teardown-worker.sh` exits `STALLED` at its cap. Documented as a known
   limitation.
2. Dispatching **from** the Mac; the Mac dispatching back to Linux.
3. Any containment/guardrail for Claude Code workers.
4. Scheduled runs of brain-sync-meetings under Claude Code (CronCreate) — mentioned in
   `claude-code.md` as available, not wired.
