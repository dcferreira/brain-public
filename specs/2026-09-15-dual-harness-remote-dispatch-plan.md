# Dual-harness skills + remote dispatch — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every brain skill run unchanged under omp and Claude Code without an agent reading the other harness's instructions, and let brain-dispatch launch (and brain-collect reap) a Claude Code worker on the Mac over SSH.

**Architecture:** Two axes, two mechanisms. Harness differences that are *typed or pattern-matched* live in one shell library (`harness-chrome.sh`); harness differences that are *prose* live in two reference files read on demand; SKILL.md text is harness-neutral. Host differences live entirely in `host.sh` (`run_on_host`/`tmx` wrappers + `hosts.conf`). The worker note carries `host`/`harness`/`attach` so downstream skills never reason about either axis.

**Tech Stack:** bash (scripts + fixture-driven `*.test.sh` in the style of the existing `teardown-worker.test.sh`), tmux, ssh, jj/git, omp 18.1.16, Claude Code 2.1.x, TypeScript (one-line change in `omp/brain-vault.ts`).

**Spec:** `specs/2026-09-15-dual-harness-remote-dispatch-design.md` — read it first; every task below cites the section it implements.

## Global Constraints

- **Single jj change.** The working copy is already an empty, undescribed jj change on top of the omp-port commit. **Do not run `jj new`, `jj commit`, `jj describe`, `git commit` or any VCS write.** jj snapshots the working copy automatically; the coordinator describes the change at the end.
- **Repo path is `~/projects/brain` on every host**; vault is `~/Obsidian/vault`. Write `~`, never `/home/...` or `/Users/...`.
- **`command ssh` and `command tmux`** always — interactive zsh shadows both (kitty ssh kitten; oh-my-zsh tmux plugin). Remote commands run under **`zsh -lc`** so Homebrew and `~/.local/bin` are on PATH.
- **British English** in all prose. Neutral wording rule (spec §5): no `/skill:` or `/brain-…` slash prefixes in any SKILL.md; skill names in prose ("the brain-persist skill (worker mode)"); "a subagent"; "your question tool".
- **Never edit vault files** (`~/Obsidian/vault/**`) from any task. Tests use temp dirs.
- Tests are plain bash: `bash <file>.test.sh` exits 0 on success and prints one `PASS`/`FAIL` line per case. Match the existing style in `skills/brain-collect/scripts/teardown-worker.test.sh`.
- `skills/_shared/` must contain **no `SKILL.md`** (omp discovery) and is skipped by `claude/install.sh`.

## Dependency graph / suggested parallelism

```
T1 capture claude chrome fixtures ─┐
T2 host.sh + hosts.conf ───────────┼─► T3 harness-chrome.sh ─► T4 dispatch scripts ─► T9 dispatch SKILL.md
                                    │                        └► T5 teardown-worker  ─► T10 collect SKILL.md
T6 harness reference files ─────────┤
T7 reword: plan-day/week, post-standup, orient, status ─┤
T8 reword: persist, sync-meetings, dream ───────────────┤
T11 claude/ wiring + brain-vault.ts session line ───────┘
                                                 T12 README ─► T13 grep gate + full test run
```
T1, T2, T6, T7, T8, T11 are independent and can run concurrently (disjoint files).

---

### Task 1: Capture Claude Code pane fixtures and relocate the omp ones

Spec §4.4. `claude` is installed locally (`command -v claude`). Fixtures are verbatim `command tmux capture-pane -p` output.

**Files:**
- Create: `skills/_shared/lib/fixtures/claude/{ready,busy,question,trust,launch-typed}.txt`
- Create: `skills/_shared/lib/fixtures/omp/{ready,busy,question,launch-typed}.txt`
- Modify: `skills/brain-collect/scripts/teardown-worker.test.sh` (only to note that fixtures now live under `_shared/lib/fixtures/`; the test is rewritten in T5)

**Interfaces:**
- Produces: fixture files consumed by T3 tests. Each is the raw pane text (no trailing edits) plus a first-line comment `# captured <date> <harness> <version> — <state>` **only in a sibling `README.md`**, never inside the fixture itself.

- [ ] **Step 1: Extract the omp fixtures** already embedded as heredocs in `teardown-worker.test.sh` (search for `π >`, `⚙ 1`, `up/down navigate`) into `fixtures/omp/ready.txt`, `busy.txt`, `question.txt`. Create `launch-typed.txt` holding a pane where the launch command has been typed but not run: a prompt line ending in `omp --auto-approve "Read your worker brief at ~/Obsidian/vault/workers/x.md and follow its priming, then greet me."`.
- [ ] **Step 2: Capture Claude Code `launch-typed` and `trust`.** In `cd $(mktemp -d)` (a never-opened dir triggers the trust prompt): `command tmux new-session -d -s fx-claude -c "$PWD"`; wait for the shell (`echo RDY` probe as in dispatch step 6); `send-keys 'claude "Read your worker brief at ~/Obsidian/vault/workers/x.md and follow its priming, then greet me."'` **without** Enter → `capture-pane -p > launch-typed.txt`; then `send-keys Enter`, sleep 3, capture → `trust.txt` (must contain the folder-trust wording, e.g. `trust this folder`).
- [ ] **Step 3: Capture `ready`.** Answer the trust prompt (`send-keys Enter`), poll every 2 s until the composer is up (the input box / `>` prompt with the status line), capture → `ready.txt`.
- [ ] **Step 4: Capture `busy`.** Type `run: sleep 20 && echo done` then Enter; within 3 s capture while the tool is executing → `busy.txt` (expect the spinner's token suffix `(<n>s · ↓ <n> tokens)`; Claude Code 2.1.272 has no "esc to interrupt" string). If a permission prompt appears instead, capture that as `question.txt` first, accept it, then capture busy.
- [ ] **Step 5: Capture `question`** if not already: type `ask me a yes/no question using your question tool` + Enter, wait, capture the dialog → `question.txt`.
- [ ] **Step 6: Kill the session** (`command tmux kill-session -t fx-claude`) and write `fixtures/README.md` listing each file, the harness version (`claude --version`, `omp --version`), the date, and the **distinguishing strings** you observed per state (these become the patterns in T3).
- [ ] **Step 7: Verify** each fixture is non-empty and that `ready.txt` does **not** contain the strings you chose for busy/question, and `busy.txt`/`question.txt` do not contain the ready string. Print the four distinguishing strings in your report.

---

### Task 2: `host.sh` and `hosts.conf`

Spec §4.2–4.3.

**Files:**
- Create: `skills/_shared/hosts.conf`
- Create: `skills/_shared/lib/host.sh`
- Create: `skills/_shared/lib/host.test.sh`

**Interfaces (produces — exact names used by T3–T5):**
```bash
BRAIN_ROOT="${BRAIN_ROOT:-$HOME/projects/brain}"        # repo root
BRAIN_HOSTS="${BRAIN_HOSTS:-$BRAIN_ROOT/skills/_shared/hosts.conf}"
BRAIN_SSH="${BRAIN_SSH:-command ssh}"                   # stubbed in tests
BRAIN_TMUX="${BRAIN_TMUX:-command tmux}"
host_field   <name> <ssh_alias|harnesses|default_harness>   # prints value; rc 1 if unknown host/field
host_is_local <name>                                          # rc 0 when ssh_alias == "-"
host_allows  <name> <harness>                                 # rc 0 when harness ∈ harnesses (comma list)
run_on_host  <name> <cmd-string>                              # local: bash -c; remote: $BRAIN_SSH -o BatchMode=yes <alias> zsh -lc <quoted>
tmx          <name> <tmux args...>                            # run_on_host name "$BRAIN_TMUX <args>"
remote_home  <name>                                           # $HOME locally, `echo $HOME` remotely
attach_cmd   <name> <session>                                 # "tmux attach -t S" | "ssh -t <alias> tmux attach -t S"
```

- [ ] **Step 1: Write `hosts.conf`** exactly:
```
# name   ssh_alias        harnesses    default_harness
local    -                omp,claude   omp
mac      workmac    claude       claude
```
- [ ] **Step 2: Write failing tests** in `host.test.sh`: (a) `host_field mac ssh_alias` → `workmac`; (b) `host_field nope ssh_alias` rc≠0; (c) `host_is_local local` rc 0, `host_is_local mac` rc 1; (d) `host_allows mac omp` rc 1, `host_allows local omp` rc 0; (e) with `BRAIN_SSH=$tmp/fake-ssh` (a script that echoes its argv), `run_on_host mac 'echo hi'` output contains `-o BatchMode=yes workmac zsh -lc` and a quoted `echo hi`; (f) `run_on_host local 'echo hi'` → `hi`; (g) `attach_cmd mac brain-worker-x` → `ssh -t workmac tmux attach -t brain-worker-x`; (h) `tmx local list-sessions` with `BRAIN_TMUX=echo` → `list-sessions`. Point the tests at a temp copy of hosts.conf via `BRAIN_HOSTS`.
- [ ] **Step 3: Run** `bash skills/_shared/lib/host.test.sh` → expect FAIL (file missing).
- [ ] **Step 4: Implement `host.sh`** with `awk` parsing (skip `#` and blank lines), `printf %q` quoting for the remote command, `set -u`-safe.
- [ ] **Step 5: Run the test** → all PASS. Also `bash -n host.sh` and `shellcheck host.sh` if available (warnings acceptable, errors not).

---

### Task 3: `harness-chrome.sh`

Spec §4.4. Depends on T1 fixtures.

**Files:**
- Create: `skills/_shared/lib/harness-chrome.sh`
- Create: `skills/_shared/lib/harness-chrome.test.sh`
- Read: `skills/_shared/lib/fixtures/**`, `skills/_shared/lib/fixtures/README.md`, `skills/brain-collect/scripts/teardown-worker.sh` (`pane_idle`, lines ~76–92, for the omp patterns)

**Interfaces (produces; every function takes `harness` = `omp|claude` as `$1`):**
```bash
launch_cmd         <harness> <brief_path>   # prints the full command line to type
launch_marker      <harness>                # prints the substring that proves the typed line arrived intact
pane_ready         <harness> <pane-text>    # rc 0 when composer chrome is up
pane_busy          <harness> <pane-text>    # rc 0 when a tool/turn is running
pane_question      <harness> <pane-text>    # rc 0 when a prompt/dialog awaits an answer
pane_trust_prompt  <harness> <pane-text>    # rc 0 only for claude folder-trust prompt; omp always rc 1
pane_idle          <harness> <pane-text>    # ready && !busy && !question
persist_worker_text <harness>               # "/skill:brain-persist worker" | "/brain-persist worker"
valid_harness      <harness>                # rc 0 for omp|claude
```

- [ ] **Step 1: Write failing tests**: for each harness and each fixture, assert the truth table — `ready.txt`: ready=0 busy=1 question=1 idle=0; `busy.txt`: busy=0 idle=1; `question.txt`: question=0 idle=1; `claude/trust.txt`: trust=0 idle=1; `omp` never trust; `launch-typed.txt` contains `launch_marker` and `pane_ready` is **rc 1** on it (the false-ready guard from dispatch step 7); `persist_worker_text` exact strings; `valid_harness foo` rc 1.
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement**, copying the omp patterns verbatim from `pane_idle` in `teardown-worker.sh` and the claude patterns from T1's README. `launch_cmd`: omp → `omp --auto-approve "Read your worker brief at <brief_path> and follow its priming, then greet me."`; claude → `claude "Read your worker brief at <brief_path> and follow its priming, then greet me."`.
- [ ] **Step 4: Run** → PASS.

---

### Task 4: brain-dispatch scripts

Spec §5.7. Depends on T2, T3. The current prose in `skills/brain-dispatch/SKILL.md` steps 4, 6, 7 (launcher-subagent block) is the reference behaviour — port it faithfully, then generalise.

**Files:**
- Create: `skills/brain-dispatch/scripts/preflight.sh`
- Create: `skills/brain-dispatch/scripts/wait-for-brief.sh`
- Create: `skills/brain-dispatch/scripts/launch-worker.sh`
- Create: `skills/brain-dispatch/scripts/dispatch-scripts.test.sh`

**Interfaces:**
- Consumes: everything in T2/T3 tables; scripts start with `. "$(dirname "$0")/../../_shared/lib/host.sh"; . "$(dirname "$0")/../../_shared/lib/harness-chrome.sh"`.
- Produces (stdout, single line, `key=value` space-separated):
  - `preflight.sh --host H --harness X --project-dir D` → `dir_exists=yes|no vcs=jj|git|none free_gb=<int> harness_bin=present|missing guardrail=active|inactive|n/a`; rc 1 if `dir_exists=no` or `harness_bin=missing`; rc 2 on bad args or `host_allows` failure.
  - `wait-for-brief.sh --host H --slug S [--timeout N=90]` → `synced=yes|no`; rc 1 on `no`.
  - `launch-worker.sh --host H --harness X --slug S --project-dir D` → `verified=yes|no session=brain-worker-S attach=<attach_cmd>`; rc 1 on `no` (session left running for inspection, say so on stderr).

- [ ] **Step 1: Write tests** with `BRAIN_SSH`/`BRAIN_TMUX` stubs: (a) preflight rc 2 for `--host mac --harness omp`; (b) preflight on `--host local --project-dir <tmp with .jj and .git>` → `vcs=jj`; (c) preflight `free_gb` is an integer; (d) preflight with `--harness claude` and `PATH` lacking `claude` → `harness_bin=missing` rc 1; (e) wait-for-brief local with the note present under `BRAIN_VAULT=<tmp>` → `synced=yes`; absent with `--timeout 4` → `synced=no` rc 1; (f) launch-worker with a fake tmux (`capture-pane` returns fixture text by a counter file: shell-prompt → launch-typed → ready) → `verified=yes` and the attach string.
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement `preflight.sh`**: `df` by remote `uname -s` (Darwin → `df -g D | awk 'NR==2{print $4}'`; Linux → `df -BG --output=avail D | tail -1 | tr -dc 0-9`); `harness_bin` via `run_on_host H "command -v X"`; `guardrail` only when `X=omp` and host is Linux: `systemctl --user is-active llama-classifier`, on inactive try `systemctl --user start llama-classifier` once and re-check.
- [ ] **Step 4: Implement `wait-for-brief.sh`**: loop `run_on_host H "test -f ~/Obsidian/vault/workers/S.md"` every 3 s (local checks `${BRAIN_VAULT:-$HOME/Obsidian/vault}` directly).
- [ ] **Step 5: Implement `launch-worker.sh`** porting dispatch steps 6–7 exactly: `tmx H new-session -d -s brain-worker-S -c D`; 15× readiness loop with `RDY-S` marker and dotenv-prompt `n` answer; `send-keys C-u`; type `launch_cmd X ~/Obsidian/vault/workers/S.md` **without Enter**; verify `launch_marker`; separate `send-keys Enter`; then a 20× (2 s) poll: if `pane_trust_prompt` → `send-keys Enter`, `sleep 2`, continue; if `pane_ready` → verified. `tmx` for **every** tmux call.
- [ ] **Step 6: Run tests** → PASS. `bash -n` all three.
- [ ] **Step 7: Live smoke on `local` only**: `launch-worker.sh --host local --harness omp --slug smoke-omp --project-dir ~/projects/brain` and the same with `--harness claude --slug smoke-claude`; both must print `verified=yes`; then `command tmux kill-session` both. **Do not** write a worker note into the vault for this; the script must not require one to exist. Report the two output lines verbatim.

---

### Task 5: `teardown-worker.sh` gains `--host`/`--harness`

Spec §5.8. Depends on T2, T3.

**Files:**
- Modify: `skills/brain-collect/scripts/teardown-worker.sh`
- Rewrite: `skills/brain-collect/scripts/teardown-worker.test.sh`

**Interfaces:**
- Consumes: `run_on_host`, `tmx`, `pane_idle`, `persist_worker_text`, `valid_harness`.
- Produces: same CLI plus `--host <name> --harness omp|claude` (both **required**; rc 2 if missing/invalid). Output lines `REAPED …`/`STALLED …` unchanged.

- [ ] **Step 1: Rewrite the test** so fixtures load from `skills/_shared/lib/fixtures/<harness>/*.txt`; keep every existing case (gate A/B/C, stale jj workspace, mid-write veto) and add: (a) rc 2 without `--host`; (b) the same idle/busy/question truth table for `--harness claude`; (c) with `BRAIN_SSH=fake-ssh`, `--host mac` routes `has-session`, `capture-pane`, `send-keys`, `kill-session` and the `jj`/`git` gate-C commands through the stub (assert the stub's log contains `workmac zsh -lc`), while gate A (`collect_state`, `find sessions -newer`) reads the **local** temp vault.
- [ ] **Step 2: Run** → FAIL (unknown args).
- [ ] **Step 3: Implement**: source both libs; delete the local `pane_idle`; replace every `command tmux …` with `tmx "$host" …`; wrap `jj -R`, `git -C`, `rm -rf "$jj_workspace"`, `jj workspace forget`, `git worktree remove` in `run_on_host "$host"`; `trigger_persist` sends `persist_worker_text "$harness"`. Keep `set_collect_state`, `artefacts_ready`, `no_unpushed` logic intact (only their command execution is routed).
- [ ] **Step 4: Run** → PASS. Update the header comment's Usage line.

---

### Task 6: Harness prose reference files

Spec §4.1, §5 pointer, §5.5, §5.6, §5.7 (rationale relocation).

**Files:**
- Create: `skills/_shared/harness/omp.md`
- Create: `skills/_shared/harness/claude-code.md`
- Read: `skills/brain-dream/SKILL.md` (Step 2 fan-out paragraph, Notes), `skills/brain-dispatch/SKILL.md` (the `--auto-approve`/pi-automode paragraphs after step 7), `skills/brain-sync-meetings/SKILL.md` (Authentication check, last Notes bullet), `README.md` §3.

Both files use the **same section headings** in the same order so an agent can find the same fact in either:
`## Invoking a skill` · `## Subagents` · `## Fan-out subagents` · `## Asking the user` · `## MCP servers` · `## Session id` · `## Shell quirks` · `## Skills discovery and refresh` · `## Scheduling` · `## Workers launched by brain-dispatch`.

- [ ] **Step 1: Write `omp.md`** (≤ 80 lines): `/skill:<name> [args]`; the `task` tool, batch all tasks in one `tasks[]` call and let reports auto-deliver (moved from brain-dream); `ask` tool; `/mcp list|enable|reauth|reconnect <server>`, definitions in `~/projects/brain/omp/mcp.json` (symlinked to `~/.omp/agent/mcp.json`), hosted-OAuth credential persists across sessions; the session id line `This session's id is <id> (harness: omp)`; `CI=true` in the bash tool → `env -u CI qmd vsearch`; `skills.customDirectories`, picked up on next start; no in-session cron; workers run `omp --auto-approve` contained by pi-automode + `llama-classifier` (moved from dispatch).
- [ ] **Step 2: Write `claude-code.md`** (≤ 80 lines): `/<name> [args]` or the Skill tool; the Agent tool, **do not name** reader agents (the 2026-07-30 relay hazard, moved from brain-dream) — dispatch them in one message; `AskUserQuestion`; `/mcp` for status/reauth, servers configured in Claude Code's own settings (see `claude/` in the repo README); session id line `This session's id is <id> (harness: claude-code)` from the SessionStart hook; no `CI` quirk (keeping `env -u CI` is harmless); skills are symlinks `~/.claude/skills/<name>` → repo, refreshed by `claude/install.sh`; in-session scheduling exists (CronCreate) but brain-sync-meetings stays manual; workers are launched as plain `claude "…"` and run under the user's auto-mode default — nothing to preflight.
- [ ] **Step 3: Check** neither file mentions the other harness except in the one-line preamble "You are in <harness>; the other harness's file is `<path>` — do not read it."

---

### Task 7: Neutral rewording — plan-day, plan-week, post-standup, orient, status

Spec §5.1–5.3.

**Files:**
- Modify: `skills/brain-plan-day/SKILL.md`, `skills/brain-plan-week/SKILL.md`, `skills/brain-post-standup/SKILL.md`, `skills/brain-orient/SKILL.md`, `skills/brain-status/SKILL.md`

- [ ] **Step 1:** In all five, replace every `/skill:brain-<x>` with prose ("the brain-<x> skill"); check with `grep -n '/skill:' <file>` → empty. Keep the frontmatter `argument-hint` lines untouched.
- [ ] **Step 2 (orient):** reword the `env -u CI` justification to "some harnesses set `CI=true` in their shell tool, under which `qmd vsearch` aborts"; "The `brain-vault` omp extension injects" → "The session-start wiring injects"; replace `/mcp reauth shortcut` with "re-authenticate the `shortcut` MCP server (command in the harness reference)". Add the two-line **Harness** pointer (spec §5 wording) directly under the H1.
- [ ] **Step 3 (status):** add `host`, `harness`, `attach` to the worker-note facts bullet; in Step 3 replace both composed `tmux attach -t brain-worker-<slug>` renderings with "the note's `attach` command verbatim"; MCP wording as in orient; add the Harness pointer.
- [ ] **Step 4:** `grep -n -i 'omp\b\|claude' <five files>` → only the pointer lines. Report the grep output.

---

### Task 8: Neutral rewording — persist, sync-meetings, dream

Spec §4.5, §5.4–5.6.

**Files:**
- Modify: `skills/brain-persist/SKILL.md`, `skills/brain-sync-meetings/SKILL.md`, `skills/brain-dream/SKILL.md`

- [ ] **Step 1 (persist):** remove `/skill:` prefixes; both mentions of `This session's omp id is <id>` → `This session's id is <id>` "from the injected vault context"; Step 2 heading stays "dispatch one subagent" with the Harness pointer under the H1 for the tool name; the `env -u CI` justification reworded as in T7; "Notes written before the 2026-09-11 omp port carry the tag `claude-code-workflow`" may stay (historical fact, not a harness instruction).
- [ ] **Step 2 (sync-meetings):** remove `/skill:` prefixes; Authentication check → "the Krisp MCP server is defined per harness (see the harness reference); confirm its tools are available, otherwise stop and tell the user to enable/re-authenticate it via the harness's `/mcp` command"; delete the last Notes bullet about cron (now in the reference files) and replace with "This is the manual trigger; whether the harness offers scheduling is in the harness reference." Add the pointer.
- [ ] **Step 3 (dream):** replace the whole "Dispatch them as one `task` batch" paragraph with "**Fan out per the harness reference's *Fan-out subagents* section** — it carries the relay rule that keeps reports arriving without nudging."; delete the Notes bullet on skills discovery (goes to README in T12); shorten the Provenance bullet to end at "…would have relayed directly." Add the pointer.
- [ ] **Step 4:** `grep -n -i '/skill:\|omp\b\|claude' <three files>` → only pointer lines and the historical tag sentence. Report the output.

---

### Task 9: Thin `brain-dispatch/SKILL.md`

Spec §5.7. Depends on T4, T6. This is prose surgery on a 232-line file; keep every rule that is **not** mechanics.

**Files:**
- Modify: `skills/brain-dispatch/SKILL.md`

- [ ] **Step 1: Frontmatter.** `argument-hint: <today action> [base directory] [--host <name>] [--harness omp|claude]`. Description: replace "running omp primed from its brief" with "running the chosen harness primed from its brief, on the chosen host".
- [ ] **Step 2: Add the Harness pointer** under the H1 and a **Hosts** bullet under *Vault & path facts*: "Worker hosts are listed in `~/projects/brain/skills/_shared/hosts.conf` (`local` is this machine). Omitted `--host` → `local`; omitted `--harness` → the host's default; a pair the file does not allow is refused before anything is written."
- [ ] **Step 3: Step 1 (main session):** parse `--host`/`--harness` out of the argument; pass them to the launcher subagent.
- [ ] **Step 4: Launcher-subagent block:** replace step 4's disk + guardrail preflight prose with: run `bash ~/projects/brain/skills/brain-dispatch/scripts/preflight.sh --host <host> --harness <harness> --project-dir <project_dir>`; interpret `free_gb` (<20 warn, <5 refuse for code), `guardrail=inactive` → warning, non-zero rc → failure. Keep the VCS detection sentence but take `vcs` from preflight output.
- [ ] **Step 5: Step 5 (worker note):** add `host:`, `harness:`, `attach:` fields (attach value comes from `launch-worker.sh` — write the note first with `attach:` filled from `hosts.conf` knowledge: `tmux attach -t brain-worker-<slug>` locally, `ssh -t <ssh_alias> tmux attach -t brain-worker-<slug>` remotely). In the brief: `/skill:manage-mr` → "the manage-mr skill"; `/skill:brain-persist worker` → "the brain-persist skill in worker mode"; "`ask`-tool timeout" → "a timeout on your question tool"; "**AskUserQuestion**" likewise.
- [ ] **Step 6: Steps 6–7:** replace both shell blocks and the surrounding explanation with: run `wait-for-brief.sh --host <host> --slug <slug>` (on `synced=no`: fail, leave `primed`), then `launch-worker.sh --host <host> --harness <harness> --slug <slug> --project-dir <project_dir>`; `verified=yes` → set `working`; `verified=no` → leave `primed`, report. Keep **one** sentence each on *why* the typed-line verification and the ready-chrome poll exist, pointing at the scripts. Delete the `--auto-approve`/pi-automode paragraphs (now in `omp.md`).
- [ ] **Step 7: Return summary** adds `host`, `harness`, `attach`. **Step 3 (main session):** report line becomes "Dispatched `<slug>` on `<host>` (`<harness>`) — attach with `<attach>`".
- [ ] **Step 8: Notes:** neutral wording throughout; `grep -n -i '/skill:\|omp\b\|claude\|tmux' SKILL.md` → only the pointer lines, `hosts.conf`/`attach` examples, and the script names. Target length ≤ 140 lines. Report the grep output and `wc -l`.

---

### Task 10: `brain-collect/SKILL.md` passes host/harness

Spec §5.8. Depends on T5.

**Files:**
- Modify: `skills/brain-collect/SKILL.md`

- [ ] **Step 1:** Add `host`, `harness`, `attach` to the worker-note facts bullet. Remove `/skill:` prefixes.
- [ ] **Step 2:** In *persist-then-teardown*, the invocation becomes `bash ~/projects/brain/skills/brain-collect/scripts/teardown-worker.sh --slug <slug> --project-dir <project_dir> --mode <done|park> --host <host> --harness <harness> [--jj-workspace <ws>] [--vcs <vcs>]`, "values come from the worker-note frontmatter". Replace the manual-intervention `tmux attach -t brain-worker-<slug>` and the **leave** option's attach hint with "the note's `attach` command".
- [ ] **Step 3:** Reword "it is a detached process, not the harness agent" (fine, neutral) — leave. Add the Harness pointer (for MCP re-auth wording) and change `/mcp reauth shortcut` as in T7.
- [ ] **Step 4:** `grep -n -i '/skill:\|omp\b\|claude' SKILL.md` → only pointer lines. Report.

---

### Task 11: `claude/` wiring + session-id line in `omp/brain-vault.ts`

Spec §4.5, §6.

**Files:**
- Create: `claude/hooks/brain-session-start.sh`, `claude/hooks/brain-session-end.sh`, `claude/settings.snippet.json`, `claude/install.sh`, `claude/README.md`
- Modify: `omp/brain-vault.ts` (the line emitting `This session's omp id is`)
- Create: `claude/install.test.sh`

- [ ] **Step 1: Fetch the Mac originals** for reference: `command ssh -o BatchMode=yes workmac 'cat ~/.claude/hooks/obsidian-session-start.sh; echo =====; cat ~/.claude/hooks/obsidian-session-end.sh; echo =====; python3 -c "import json;print(json.dumps(json.load(open(\"/Users/user/.claude/settings.json\"))[\"hooks\"],indent=1))"'`. Read `omp/brain-vault.ts` `buildContext` to match its output blocks exactly (`--- VAULT: TOP OF MIND ---`, `--- VAULT: LATEST SESSION ---`, qmd hits, the session-id line).
- [ ] **Step 2: Write `brain-session-start.sh`**: read hook JSON from stdin (`session_id`, `cwd`), `VAULT="${BRAIN_VAULT:-$HOME/Obsidian/vault}"`, `qmd="$(command -v qmd)"`, print the same blocks as the extension plus `This session's id is <session_id> (harness: claude-code)`. Output must be plain text on stdout (Claude Code injects it as context).
- [ ] **Step 3: Write `brain-session-end.sh`**: `command -v qmd >/dev/null && qmd update >/dev/null 2>&1; exit 0`.
- [ ] **Step 4: Write `settings.snippet.json`**: `hooks.SessionStart` (matcher `startup|resume`, command `bash ~/projects/brain/claude/hooks/brain-session-start.sh`) and `hooks.SessionEnd` (command `bash ~/projects/brain/claude/hooks/brain-session-end.sh`).
- [ ] **Step 5: Test + write `install.sh`**: test creates a temp `HOME` with a fake repo `skills/{a,_shared,b}/`, only `a` and `b` having `SKILL.md`; running `install.sh` must create `$HOME/.claude/skills/a` and `b` symlinks, **not** `_shared`, be idempotent (second run changes nothing, exit 0), and replace a stale symlink pointing elsewhere. Implement with `BRAIN_ROOT`/`HOME` overridable.
- [ ] **Step 6: Edit `omp/brain-vault.ts`**: the emitted line becomes `This session's id is ${id} (harness: omp)`. `grep -n "session's" omp/brain-vault.ts` shows exactly one line.
- [ ] **Step 7: `claude/README.md`** (≤ 40 lines): what each file is, how to install on a machine (`bash ~/projects/brain/claude/install.sh`, merge the snippet into `~/.claude/settings.json`), and that this replaces the pre-port `obsidian-session-*.sh` hooks.

---

### Task 12: README

Spec §7. Depends on T6–T11.

**Files:**
- Modify: `README.md`

- [ ] **Step 1: §1 diagram:** "session start ─► session-start wiring (omp extension | Claude Code hook) injects…"; `/skill:brain-persist` → "brain-persist".
- [ ] **Step 2: §3:** after the omp wiring subsection add "### Claude Code wiring (`~/.claude`)" with a table: `~/.claude/skills/<name>` symlinks (created by `claude/install.sh`), `claude/hooks/*`, `settings.json` hook entries, MCP servers per Claude Code settings. Add "### Worker hosts" with `skills/_shared/hosts.conf`, the Mac's prerequisites (tmux, jj, glab, claude at `~/.local/bin`, repo at `~/projects/brain`, vault synced by Syncthing, skills symlinked), and the `zsh -lc` / `command ssh` facts.
- [ ] **Step 3: §4 "Skill storage":** describe both discovery paths and `_shared/` (harness references, libs, hosts.conf; ignored by omp, skipped by install.sh). Move the skills-discovery note deleted from brain-dream here.
- [ ] **Step 4: §7 Known limitations:** add the two items from spec §7.
- [ ] **Step 5: §8:** add the three rows from spec §7; change "Change execution-layer behaviour" to name the scripts too.
- [ ] **Step 6:** `grep -n '/skill:' README.md` → only in the omp-specific wiring sentences, if any; report.

---

### Task 13: Grep gate + full offline test run

Spec §8. Depends on everything.

- [ ] **Step 1:** `grep -rn '/skill:\|/brain-[a-z-]*\b' skills/brain-*/SKILL.md` → empty (frontmatter `argument-hint` excepted).
- [ ] **Step 2:** `grep -rn -i 'omp\b\|claude' skills/brain-*/SKILL.md` → only Harness pointer lines and brain-persist's historical `claude-code-workflow` tag sentence. List every other hit as a defect and fix it.
- [ ] **Step 3:** `test ! -e skills/_shared/SKILL.md`; `bash -n` every `*.sh` under `skills/` and `claude/`.
- [ ] **Step 4:** Run all tests: `for t in skills/_shared/lib/*.test.sh skills/brain-dispatch/scripts/*.test.sh skills/brain-collect/scripts/*.test.sh claude/*.test.sh; do echo "== $t"; bash "$t" || echo "FAILED $t"; done` → no `FAILED`.
- [ ] **Step 5:** `jj status` → list the changed/added files; confirm none is under `~/Obsidian`. Report the file list and test summary verbatim.
