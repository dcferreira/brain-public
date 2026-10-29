# Vault Topic Scoping Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give every vault note an `area`/`project` scope. Keep `private` notes and Today
items out of shared startup context and shared search. Add `brain-search --project` for
focused search.

**Architecture:** A Python stdlib module, `bin/brain_scope.py`, owns the rules:
frontmatter, registry, area→path, and scope normalisation. Three thin CLIs on PATH sit on
top of it: `brain-scope` (small queries for shell callers), `brain-search` (qmd wrapper)
and `brain-migrate-scope` (one-time backfill). The SessionStart hook (bash) and the omp
extension (TS) become scope-aware. The dispatch, collect, monitor and revive shell
scripts learn the `private/workers/` path and pass scope into the worker's tmux env.
Skill prose is updated last.

**Tech Stack:** bash (repo's `*.test.sh` style with `ok/bad/assert_*` helpers); Python 3
stdlib only, compatible with **3.9** (the Mac's system python): no `match`, no `X | Y`
type unions at runtime, `from __future__ import annotations` is fine; `unittest` with a
`.test.sh` wrapper, as in `skills/brain-dashboard/scripts/`; TypeScript for omp; qmd 2.8.3.

**Spec:** `specs/2026-10-15-vault-topic-scoping-design.md`. Read it first; this plan
argues from it.

## Global Constraints

- Areas are exactly `work`, `projects`, `private`. Scopes are exactly `shared`, `private`,
  `all`. Unset or unknown `BRAIN_SCOPE` → `shared` (fail closed).
- `shared` includes `work` and `projects`. `private` includes all three areas (a private
  worker may still need work context). `all` includes all three.
- Vault root: `$BRAIN_VAULT`, else `~/Obsidian/vault`. The private subtree is
  `<vault>/private/` and mirrors `workers/`, `sessions/`, `knowledge/`, `diary/`, plus
  `private/private.md` and `private/scopes.md`. Shared registry: `00-home/scopes.md`.
- A missing `private/` (or missing registry or index) is treated as empty. It is never an
  error, never a crash, and never a non-zero exit from the hook.
- The qmd shared collection is `vault` in the default index; the private collection is
  `private` in index `private` (`qmd --index private …`, config
  `~/.config/qmd/private.yml`).
- Nothing in this change writes to the real vault or the real qmd config during tests.
  All tests use temp dirs and a stub `qmd`.
- Python: stdlib only, py3.9-compatible. Bash: `set -uo pipefail`, and `command`-prefix
  any `tmux`/`ssh` (oh-my-zsh shadows them; see `skills/_shared/lib/host.sh`).
- The working copy is jj workspace `~/projects/jj-workspaces/vault-topic-scoping`. Do not
  run `git commit`. After each task: `jj describe` is NOT needed. The coordinator owns the
  change description; just leave edits in the working copy.

## Review Focus

1. **A private sentinel leaking into shared hook output** through any block (top-of-mind,
   latest session, related notes). The newest session note being private must not make it
   the injected "latest session" under `shared`. Pinned in Task 3.
2. **Notes with no frontmatter, CRLF line endings, or a `---` horizontal rule in the
   body.** Frontmatter read/write must not corrupt the body or insert a second
   frontmatter block. Pinned in Task 1.
3. **`brain-search` when qmd returns non-JSON, empty output, a missing private index, or
   a hit file that no longer exists.** It degrades to fewer results and never tracebacks.
   Pinned in Task 2.
4. **Migration re-run after apply** must propose zero changes and must not double-move a
   file or overwrite an existing `private/…` file with the same name (it refuses that
   file and reports it). Pinned in Task 6.
5. **Old and new worker-note paths:** revive and monitor must find a worker whether its
   note lives in `workers/` or `private/workers/`, and the brief sentence for a private
   worker must point at `private/workers/`. Pinned in Task 5.

---

## File Structure

| File | Responsibility |
|---|---|
| `bin/brain_scope.py` (new) | Library: frontmatter read/write, registry load and resolve, scope normalisation and inclusion, area→path mapping, worker-note lookup |
| `bin/brain-scope` (new, exec) | CLI for shell callers: `norm`, `includes`, `note-dir`, `find-worker`, `field` |
| `bin/brain-search` (new, exec) | qmd wrapper: scope fan-out, project filter, markdown output |
| `bin/brain-migrate-scope` (new, exec) | `classify` (report) and `apply` (snapshot, frontmatter, moves, top-of-mind split, registries, qmd update) |
| `bin/tests/*_test.py`, `bin/tests/bin.test.sh` (new) | unittest suites plus a bash wrapper |
| `claude/hooks/brain-session-start.sh` | Scope-aware injection |
| `claude/hooks/brain-session-start.test.sh` (new) | Hook sentinel tests |
| `omp/brain-vault.ts` | Same logic for omp |
| `skills/brain-dispatch/scripts/launch-worker.sh` | `--scope/--project/--note-dir` → tmux `-e` env + brief path |
| `skills/brain-dispatch/scripts/wait-for-brief.sh` | `--note-dir` support |
| `skills/brain-collect/scripts/teardown-worker.sh` | Find the note in either dir |
| `skills/brain-monitor/scripts/worker-monitor.sh` | Find the note in either dir |
| `skills/brain-revive-workers/scripts/{find-live-sessions,revive-workers}.sh` | Both dirs; pass scope through on resume |
| `claude/install.sh` + `install.test.sh` | Link `bin/brain-*` into `~/.local/bin`; ensure the qmd configs |
| `skills/*/SKILL.md` | Prose routing (Task 8) |
| `README.md`, `claude/README.md` | Docs (Task 9) |

---

### Task 1: `brain_scope.py` core library + `brain-scope` CLI

**Files:**
- Create: `bin/brain_scope.py`, `bin/brain-scope`, `bin/tests/brain_scope_test.py`, `bin/tests/bin.test.sh`

**Interfaces (Produces):**
```python
AREAS = ("work", "projects", "private")
SCOPES = ("shared", "private", "all")

def vault_root() -> str            # $BRAIN_VAULT or ~/Obsidian/vault, expanded
def norm_scope(raw: str | None) -> str          # unknown/None/"" -> "shared"; case-insensitive
def scope_includes(scope: str, area: str) -> bool  # per Global Constraints; unknown area -> treated as "work"
def read_frontmatter(text: str) -> dict[str, str]  # top-level `key: value` scalars only; strips quotes; {} if none
def set_frontmatter(text: str, updates: dict[str, str]) -> str
    # replaces existing keys in place, appends new keys before closing '---';
    # creates a block at top if none; preserves body byte-for-byte and the file's newline style (\n or \r\n)
def note_dir(area: str, kind: str) -> str
    # kind in {"workers","sessions","knowledge","diary"}; returns relative dir:
    # private -> "private/<kind>", else "<kind>"
def today_file(area: str) -> str   # private -> "private/private.md", else "00-home/top-of-mind.md"
def find_worker_note(slug: str, vault: str | None = None) -> str | None
    # absolute path of workers/<slug>.md, else private/workers/<slug>.md, else None
@dataclass
class Entry: project: str; area: str; aliases: list[str]; prefixes: list[str]
def load_registry(vault: str | None = None) -> list[Entry]
    # parses 00-home/scopes.md and private/scopes.md (either may be missing);
    # markdown table rows `| project | area | aliases | slug prefixes |`, comma-separated cells,
    # skips header/separator rows and rows with an area not in AREAS
def resolve(value: str, registry: list[Entry]) -> Entry | None
    # case-insensitive: exact project, then alias
def resolve_slug(slug: str, registry: list[Entry]) -> Entry | None
    # longest matching prefix wins (so "flow-designer-" beats "va-")
```

`bin/brain-scope` CLI (prints to stdout, exit 0 unless noted):
- `brain-scope norm [<raw>]` prints the normalised scope (arg, else `$BRAIN_SCOPE`)
- `brain-scope includes <scope> <area>` exits 0 if included, else 1
- `brain-scope note-dir <area> <kind>` prints e.g. `private/workers`
- `brain-scope find-worker <slug>` prints the absolute path; exits 1 if not found
- `brain-scope today-file <area>` prints `00-home/top-of-mind.md` or `private/private.md`
- `brain-scope field <file> <key>` prints the frontmatter value; empty if absent

`bin/brain-scope` is a 4-line python script:
```python
#!/usr/bin/env python3
import os, sys
sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
from brain_scope import cli_main; sys.exit(cli_main(sys.argv[1:]))
```
(`realpath` matters: install symlinks it into `~/.local/bin`.)

- [ ] **Step 1: Write failing tests** in `bin/tests/brain_scope_test.py` (unittest; insert `bin/` into `sys.path`). Required cases:
  - `norm_scope`: `None`, `""`, `"bogus"` → `shared`; `"ALL"` → `all`; `"private"` → `private`.
  - `scope_includes`: shared+private → False; shared+work, shared+projects → True; private+work → True; all+private → True; shared+`"weird"` → True (treated as work).
  - `read_frontmatter`: a normal block; no block → `{}`; quoted values `'a'`/`"a"` stripped; CRLF file; body containing a `---` rule after the block is ignored; a list-valued key (`tags:` followed by `- x` lines) is not returned as a scalar and does not break later keys.
  - `set_frontmatter`: replaces `area:` in place (line order kept); adds `project:` before the closing `---`; text with no frontmatter gets `---\narea: work\n---\n` prepended; body after the block is byte-identical (assert on a body containing `---` and a trailing no-newline); CRLF preserved.
  - `note_dir`/`today_file` for each area.
  - `find_worker_note` against a temp vault: in `workers/`; in `private/workers/`; in neither → None; `private/` missing entirely → no exception.
  - `load_registry`: both files present; the private file missing; a malformed row skipped; `resolve("clientco")` → clientco via alias; `resolve_slug("flow-designer-foo")` picks `flow-designer` over a `va-` prefix entry.
  - CLI: `subprocess.run([bin/brain-scope, "includes", "shared", "private"])` → rc 1; `note-dir private workers` → `private/workers`.
  Create `bin/tests/bin.test.sh`: `cd "$(dirname "$0")" && python3 -m unittest -v brain_scope_test` (later tasks append modules), exit with its rc.
- [ ] **Step 2: Run** `bash bin/tests/bin.test.sh` → FAIL (`ModuleNotFoundError: brain_scope`).
- [ ] **Step 3: Implement** `bin/brain_scope.py` and `bin/brain-scope` (chmod +x). Frontmatter: a block exists only if line 1 is exactly `---` (after stripping `\r`). It ends at the next line that is exactly `---`. Parse `^([A-Za-z0-9_-]+):\s*(.*)$` lines at column 0. A key whose value is empty is a block or list key; skip it.
- [ ] **Step 4: Run** `bash bin/tests/bin.test.sh` → all pass.

---

### Task 2: `brain-search`

**Files:**
- Create: `bin/brain-search`, `bin/tests/brain_search_test.py`; append the module to `bin/tests/bin.test.sh`

**Interfaces:**
- Consumes: `vault_root`, `norm_scope`, `scope_includes`, `read_frontmatter`, `resolve`, `load_registry` from Task 1.
- Produces: CLI `brain-search [--scope S] [--project P] [-n N] [--json] <query...>`
  - scope default `$BRAIN_SCOPE` (normalised); project default `$BRAIN_PROJECT`; `--project ''` disables the filter. The project value is resolved through the registry (an alias maps to the slug); an unresolvable value is used literally.
  - qmd binary: `$BRAIN_QMD`, else `qmd` on PATH. Runs `qmd search <query> --format json -n <fetch>` (fetch = `N*5` when filtering by project, else `N`; N default 5) on the default index, plus `qmd --index private search …` when `scope_includes(scope,"private")`.
  - Hit `file` `qmd://vault/<rel>` → `<vault>/<rel>`; `qmd://private/<rel>` → `<vault>/private/<rel>`.
  - Project filter: keep a hit only if the file exists and its frontmatter `project` equals the resolved slug (case-insensitive).
  - Defence in depth: under a scope that excludes private, drop any hit whose path is under `<vault>/private/` or whose frontmatter `area` is `private`.
  - Merge by score descending, take N. Output markdown, one block per hit: `## <title>\n<vault-relative path> · score <s>\n\n<snippet>\n` (or a JSON list with `--json`). No hits → empty stdout, rc 0.
  - Any qmd failure (missing binary, non-zero rc, non-JSON output) → skip that index and warn on stderr; never a traceback.

- [ ] **Step 1: Write failing tests** using a stub qmd: a temp executable python script that logs its argv to a file and prints canned JSON chosen by an env var per index (`STUB_DEFAULT_JSON`, `STUB_PRIVATE_JSON` paths). Set `BRAIN_QMD` to it and `BRAIN_VAULT` to a temp vault with notes carrying frontmatter. Cases:
  - shared scope: only the default index is called (assert argv log); a private hit in the canned output is dropped.
  - all scope: both indexes are called; results are merged by score.
  - `--project clientco` keeps only `project: clientco` notes; `--project clientco` (alias) behaves the same; the fetch count is `-n 25` for N=5.
  - `--project ''` with `BRAIN_PROJECT=clientco` set → no filter.
  - private index stub exits 1 → still prints the default-index results, rc 0.
  - stub prints `garbage` → rc 0, empty stdout.
  - a hit whose file was deleted is dropped under a project filter and kept without one.
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement** `bin/brain-search` (python, same `realpath` import trick).
- [ ] **Step 4: Run** `bash bin/tests/bin.test.sh` → pass.

---

### Task 3: Scope-aware SessionStart hook

**Files:**
- Modify: `claude/hooks/brain-session-start.sh`
- Create: `claude/hooks/brain-session-start.test.sh`

**Interfaces:**
- Consumes: `brain-search` and `brain-scope` from Tasks 1–2. The hook locates them as `${BRAIN_BIN:-<repo>/bin}` where `<repo>` = `$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)`. If they're missing, it falls back to the old behaviour minus anything private.

New behaviour (keep the existing qmd-resolution block; export it as `BRAIN_QMD` for brain-search):
1. `scope=$(brain-scope norm)` (fallback: `shared` if the call fails); `project="${BRAIN_PROJECT:-}"`.
2. TOP OF MIND block: unchanged.
3. If `brain-scope includes $scope private` → `--- VAULT: PRIVATE TOP OF MIND ---` + `private/private.md` (if present).
4. LATEST SESSION: the newest dated note from `sessions/`, plus `private/sessions/` only when private is included. Choose by basename sort (ISO dates), as today.
5. RELATED NOTES: query = `$project` if set, else the cwd basename (same skip rules). Run `brain-search --scope "$scope" -n 3 "$query"`; if a project is set, add `--project "$project"`. Header: `--- VAULT: RELATED NOTES (project: <q>) ---`.
6. Footer: keep the existing lines, but replace the qmd sentence with "search it with `brain-search \"<query>\"` (scope-aware; add `--project <slug>` to focus)". Add `Vault scope for this session: <scope>` + (`, project: <p>` if set) + `. Private notes live under private/ and are only visible in private/all scope.` When private is included, the Today instruction says: "work and projects actions live in 00-home/top-of-mind.md, private ones in private/private.md".

- [ ] **Step 1: Write failing test** `brain-session-start.test.sh` (repo assert style). Fixture vault: `00-home/top-of-mind.md` (contains `SHARED_TOM`), `private/private.md` (`PRIVATE_TOM_SENTINEL`), `sessions/2026-10-01 a.md` (`SHARED_SESSION`), `private/sessions/2026-10-02 b.md` (`PRIVATE_SESSION_SENTINEL`, newer). Stub qmd as in Task 2, but in bash: the default index returns one hit to a shared note; the private index returns a hit to a private note containing `PRIVATE_HIT_SENTINEL`. Run the hook with `printf '{"session_id":"s1","cwd":"/x/clientco"}' | BRAIN_VAULT=… BRAIN_QMD=… BRAIN_BIN=<repo>/bin bash hook`. Assert:
  - `BRAIN_SCOPE` unset: output contains `SHARED_TOM`, `SHARED_SESSION` and `Vault scope for this session: shared`. It contains **none** of the strings matching `PRIVATE_.*SENTINEL` (grep the whole output).
  - `BRAIN_SCOPE=garbage` → same as unset.
  - `BRAIN_SCOPE=all` → contains `PRIVATE_TOM_SENTINEL` and `PRIVATE_SESSION_SENTINEL` (the newer session wins).
  - `BRAIN_SCOPE=private` → contains `PRIVATE_TOM_SENTINEL`.
  - `private/` deleted, `BRAIN_SCOPE=all` → exit 0, `SHARED_SESSION` present.
  - `BRAIN_PROJECT=clientco` → the stub log shows `--project clientco` was not passed to qmd itself (brain-search handles it), and the header says `project: clientco`.
  - exit code is 0 in every case.
- [ ] **Step 2: Run** `bash claude/hooks/brain-session-start.test.sh` → FAIL.
- [ ] **Step 3: Implement** in the hook.
- [ ] **Step 4: Run** → pass. Also run the existing `bash claude/install.test.sh` (unchanged) to confirm nothing else broke.

---

### Task 4: omp extension parity

**Files:**
- Modify: `omp/brain-vault.ts`

Mirror Task 3 exactly in `buildContext()`: same blocks, headers and footer strings, the same scope normalisation (reimplement `normScope` and `includesPrivate` in TS; fail closed), the newest session across both dirs when private is included, and related notes via `brain-search` (spawn `${BRAIN_BIN}/brain-search` or `brain-search` on PATH, with the same args) instead of raw qmd. `session_shutdown` reindex: also run `qmd --index private update` (detached, errors ignored).

- [ ] **Step 1:** Check whether the repo has any TS test harness for omp (`grep -rn "brain-vault" omp README.md`). If there is none, add no new framework. Instead add `omp/brain-vault.smoke.sh`, which transpiles/runs `buildContext` via `bun` if available (`bun -e 'import(...)'`) against the Task 3 fixture vault with `BRAIN_SCOPE` unset, and asserts no `PRIVATE_.*SENTINEL`. If bun is not installed, skip with a printed note (exit 0).
- [ ] **Step 2:** Implement; run the smoke test (or `bun build omp/brain-vault.ts --target bun --outdir /tmp/x` at minimum to type-check/compile).
- [ ] **Step 3:** Diff the footer strings against the hook's; they must match apart from skill invocation syntax (`/skill:` vs `/`).

---

### Task 5: Worker-path plumbing in dispatch / collect / monitor / revive scripts

**Files:**
- Modify: `skills/brain-dispatch/scripts/launch-worker.sh`, `skills/brain-dispatch/scripts/wait-for-brief.sh`, `skills/brain-collect/scripts/teardown-worker.sh`, `skills/brain-monitor/scripts/worker-monitor.sh`, `skills/brain-revive-workers/scripts/find-live-sessions.sh`, `skills/brain-revive-workers/scripts/revive-workers.sh`
- Test: extend `dispatch-scripts.test.sh`, `teardown-worker.test.sh`, `worker-monitor.test.sh`, `revive-scripts.test.sh`

**Interfaces:**
- `launch-worker.sh` gains `[--note-dir workers|private/workers]` (default `workers`; anything else → die2), `[--scope shared|private|all]` and `[--project <slug>]`.
  - The brief path becomes `~/Obsidian/vault/<note-dir>/<slug>.md`.
  - The scope is passed as tmux env on session creation: `tmx "$host" new-session -d -s "$session" -c "$project_dir" -e BRAIN_SCOPE=<scope> [-e BRAIN_PROJECT=<p>]`. Only add `-e` flags when the options are given, so the default argv is byte-identical to today (existing tests must stay green). Validate the scope against the three values and the project against `^[a-z0-9][a-z0-9-]*$`.
- `wait-for-brief.sh` gains `--note-dir` with the same semantics for its local and remote `test -f`.
- `teardown-worker.sh`, `worker-monitor.sh`: resolve the note as `$VAULT/workers/$slug.md` if present, else `$VAULT/private/workers/$slug.md` (pure bash, no python dependency on remote hosts).
- `find-live-sessions.sh`: the `SENT_PREFIX` match and sed extraction accept `~/Obsidian/vault/workers/` **and** `~/Obsidian/vault/private/workers/`.
- `revive-workers.sh`: iterate `"$vault"/workers/*.md "$vault"/private/workers/*.md` (nullglob-safe); when calling launch-worker for a resume, pass `--scope`/`--project` read from the note's frontmatter (`area: private` + `project: brain` → `all`; `area: private` → `private`; otherwise omit). Pass `--note-dir private/workers` for notes found there.

- [ ] **Step 1: Failing tests** (extend each existing test file in its own style):
  - dispatch: a `launch-worker.sh --scope private --project clientco --note-dir private/workers` dry run against the stubbed tmx records `-e BRAIN_SCOPE=private -e BRAIN_PROJECT=clientco` and a brief sentence containing `vault/private/workers/<slug>.md`; `--scope bogus` → exit 2; no new flags → the recorded new-session argv is identical to the pre-change expectation.
  - wait-for-brief: a note under `private/workers` is found with `--note-dir private/workers`.
  - teardown and monitor: a fixture note only in `private/workers/` is read.
  - revive: a note in `private/workers/` with `area: private`/`project: brain` is a candidate, and its resume call carries `--scope all --note-dir private/workers`; find-live-sessions extracts the slug from a pane line with the private path.
- [ ] **Step 2: Run** each test file → new cases FAIL, old ones pass.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** all four test files plus `skills/_shared/lib/*.test.sh` → pass.

---

### Task 6: `brain-migrate-scope classify`

**Files:**
- Create: `bin/brain-migrate-scope`, `bin/brain_migrate.py` (logic), `bin/tests/brain_migrate_test.py`; append to `bin.test.sh`
- Create: `bin/seed/scopes.shared.md`, `bin/seed/scopes.private.md` (initial registries, copied into the vault by `apply` only if absent)

**Seed registries** (columns `| project | area | aliases | slug prefixes |`):
- shared: clientco (work; aliases clientco, cc2, clientco; prefixes clientco-), carco (work; carco-), client-b (work; client-b-), client-c (work; client-c-), client-d (work; aliases clientd; prefixes client-d-, clientd-), client-e (work; deploy-client-e), flow-designer (work; aliases flow-design, flow design, scenarios, sop tool; prefixes flow-designer-, flow-design-, scenario-, sop-, fix-flow-design-, deploy-flow-designer-), pulse (work; pulse-, fix-pulse-), access (work; access-, deploy-access-, customer-facing-access-), agent-platform (work; aliases af; prefixes deploy-agent-platform-, verify-af-), acme (work; aliases acme, billing; prefixes acme-, update-, customer-, fix-, deployer-), agent-pawl (projects; aliases pawl; prefixes agent-pawl-, pawl-, agentic-workflow-), budgebell (projects; aliases habits; prefixes budgebell-, habits-), toxic-news (projects; toxic-news-)
- private: brain (aliases second brain, vault; prefixes brain-, vault-), learning (aliases learning, courses, reading; prefixes learning-, course-), business (aliases own business; prefixes business-), finance (prefixes finance-), health (aliases exercise, fitness; prefixes health-), home (aliases garden, board games; prefixes garden-, games-)

**Interfaces:**
- `brain-migrate-scope classify [--vault V] [--registry-from-seed] --out DIR` writes `DIR/migration-report.csv` and `DIR/migration-report.md`; read-only on the vault.
  - The registry comes from the vault files if present, else from the seed (`--registry-from-seed` forces the seed).
  - Scanned folders: `workers sessions knowledge meetings diary inbox learning` plus `private/**` (so re-runs are idempotent).
- CSV columns: `path,kind,proposed_area,proposed_project,rule,confidence,dest_path,mixed,notes`
  - `kind` = top folder (`learning` → kind `learning`).
  - `rule` ∈ `frontmatter|folder|slug-prefix|alias|today-label|unclassified`.
  - `confidence` ∈ `high|medium|low`.
  - `dest_path` = the vault-relative path after apply (`private/<kind>/<name>` for private workers/sessions/knowledge/diary; `private/learning/<rest>` for learning; unchanged otherwise, including meetings/inbox, which are flagged in `notes` when private).
- Rules, first hit wins:
  1. frontmatter `area` valid → (its area, its project), high.
  2. path under `learning/` → private/learning, high; path already under `private/` → private, project via the later rules, high.
  3. `resolve_slug(filename stem)` → high.
  4. aliases: each value of `tags:` (scalar or `- x` list lines, so add a small list reader here), `week_goal`, `customer`, `project` resolved via `resolve` → medium.
  5. workers only: find the line in `00-home/top-of-mind.md` (and `private/private.md` if present) that mentions `workers/<slug>` or `brain-worker-<slug>` or the note's `today_action` first bold span. `[personal]` → private, project via `resolve` over the line's `— <word> —` labels, else `home`, medium. `Personal project — X` with X resolvable → that entry, medium.
  6. else unclassified → area `work`, project empty, low.
- `mixed`: for diary/sessions/meetings/inbox, `yes` when the body contains a whole-word, case-insensitive match for any private entry's project or alias **and** any shared entry's. Mixed notes never move (`dest_path` = path) and keep the proposed area `work` unless rule 1/2 says otherwise.
- `migration-report.md`: counts by area×project; a list of every row with a `dest_path` change; every low/medium row; every mixed row; every private row in meetings/inbox. Also a line saying "N unclassified — run the LLM pass (see SKILL/README) before apply".
- Collision check: if a `dest_path` already exists and differs from `path`, `notes` = `collision` and that row will be skipped by apply.

- [ ] **Step 1: Failing tests** on a temp fixture vault (built in `setUp`). Cover each rule once, longest-prefix precedence, an alias hit through a `tags:` list, a `[personal]` Today line → private/home, `Personal project — agent-pawl` → projects/agent-pawl, mixed diary detection, learning → private/learning/<rest>, a collision, read-only (snapshot an mtime+hash of every file before and after; equal), and idempotency: after manually applying the dest moves plus frontmatter, classify reports zero rows with `dest_path != path` and every row rule `frontmatter` or `folder`.
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → pass.

---

### Task 7: `brain-migrate-scope apply`

**Files:**
- Modify: `bin/brain_migrate.py`, `bin/tests/brain_migrate_test.py`

**Interfaces:**
- `brain-migrate-scope apply --report DIR/migration-report.csv [--vault V] [--backup-dir D] [--no-qmd] [--yes]`
  - Without `--yes`: print a summary of what would happen and exit 3 (a second guard; the human approval happens out of band).
  - With `--yes`:
    1. `tar czf <D>/vault-<YYYYmmdd-HHMMSS>.tar.gz -C <vault parent> <vault name>`, where D defaults to `~/Obsidian/backups`. Abort if tar fails.
    2. For each CSV row (skipping `collision`): set frontmatter `area`/`project` (no project key if empty); never touch meetings/diary bodies beyond frontmatter. Diary files have none today, so they get a new block with just `area`.
    3. Move to `dest_path` (`os.makedirs` parents; `os.rename`; refuse if the dest exists).
    4. Split top-of-mind: every line under `## Today` / `## This week` / `## Previously this week` that starts with `- [` and contains `[personal]` moves to `private/private.md` under the same heading. `private/private.md` is created with a `# Private — top of mind` title plus those headings. The `[personal]` marker is rewritten to `[private]`. Lines keep their order. Everything else in top-of-mind is byte-identical.
    5. Copy the seed registries to `00-home/scopes.md` / `private/scopes.md` if absent.
    6. Unless `--no-qmd`: `qmd update` and `qmd --index private update` (failures are reported, not fatal).
    7. Print counts moved, tagged, skipped.
  - Re-runnable: a second apply with a fresh classify report is a no-op apart from the snapshot.

- [ ] **Step 1: Failing tests** (fixture vault, `--no-qmd`, temp backup dir): without `--yes` → exit 3, vault unchanged; with `--yes` → backup tarball exists; a private worker is moved with frontmatter set; a learning file is moved under `private/learning/`; a collision row is left alone; the top-of-mind split moves exactly the `[personal]` lines (assert the remaining file equals the original minus those lines); `private/private.md` contains them rewritten with `[private]`; registries are seeded; a second classify+apply moves nothing.
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement.** **Step 4: Run** → pass.

---

### Task 8: Install script — bin links + qmd configs

**Files:**
- Modify: `claude/install.sh`, `claude/install.test.sh`

**Behaviour** (append to install.sh, keep the existing skill-linking untouched):
1. `BIN_DIR="${BRAIN_BIN_DIR:-$HOME/.local/bin}"`; `mkdir -p`; for each executable `"$BRAIN_ROOT"/bin/brain-*` (not `*.py`), symlink it into `BIN_DIR`, with the same up-to-date/replace-stale/skip-non-symlink logic and messages as the skills loop.
2. qmd configs. `QMD_CONF="${XDG_CONFIG_HOME:-$HOME/.config}/qmd"`, `VAULT="${BRAIN_VAULT:-$HOME/Obsidian/vault}"`. Done by a small python helper, `bin/brain-scope qmd-config <conf_dir> <vault>`; add this subcommand to Task 1's CLI, with a unit test added there or here:
   - `index.yml`: if collection `vault` exists and has no `ignore` containing `private/**`, add `ignore:\n      - "private/**"` under it (line-based edit that preserves everything else; no YAML lib). If it already has it → no change.
   - `private.yml`: if absent, create it with the same `models:` block copied from `index.yml` (if present) plus `collections:\n  private:\n    path: <vault>/private\n    pattern: "**/*.md"\n`.
   - Print `qmd config: up to date` or what changed. Never runs `qmd update` (the migration does).
   - If `index.yml` is missing, print a warning and skip (qmd is not set up on this host).

- [ ] **Step 1: Failing tests** in install.test.sh: a fake `BRAIN_ROOT/bin/brain-x` (exec) and `brain_scope.py`; temp HOME. Assert `~/.local/bin/brain-x` is linked and `brain_scope.py` is not; a fixture `index.yml` (copy the real shape: models + `collections: vault:` with path/pattern) gets the ignore line; a second run changes nothing (compare a hash); `private.yml` is created with the models block and the private path. Real brain-scope is used via `BRAIN_ROOT` pointing at a fake root that symlinks `bin/brain_scope.py` and `bin/brain-scope` from the real repo.
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement.** **Step 4: Run** → pass.

---

### Task 9: Skill prose updates

**Files:** `skills/{brain-dispatch,brain-persist,brain-collect,brain-plan-day,brain-status,brain-post-standup,brain-plan-week,brain-orient,brain-dream,brain-revive-workers,brain-monitor,brain-dashboard,brain-sync-meetings}/SKILL.md`

Edit only the parts that touch paths, top-of-mind or search. Keep each skill's voice and structure. Required content per skill:
- **brain-dispatch:** a new step after context gathering, *classify scope*: pick `area` + `project` with `brain-scope` and the registries (`00-home/scopes.md`, `private/scopes.md`); `[private]`-marked Today items are private. If it's unclear, ask the user. If it's new, append a row to the right registry and say so in one line. Write `area:`/`project:` into the worker note frontmatter. The note path is `$(brain-scope note-dir <area> workers)/<slug>.md`. Pass `--note-dir`, `--scope` (`all` when project is `brain`, `private` for other private work, else `shared`) and `--project` to `wait-for-brief.sh`/`launch-worker.sh`. The worker brief template tells the worker to search with `brain-search` (and `--project <slug>`). When flipping the Today line to `[/]`, edit it in `$(brain-scope today-file <area>)`.
- **brain-persist:** write `area`/`project` on session and knowledge notes, taken from `$BRAIN_SCOPE`/`$BRAIN_PROJECT` or the worker note's frontmatter. Route private ones under `private/sessions` and `private/knowledge`. Re-index both indexes (`qmd update; qmd --index private update`). Worker mode never writes top-of-mind *or* private.md.
- **brain-collect:** find the note with `brain-scope find-worker`; mark the Today line in the file matching the note's area; the Shipped entry goes to `diary/` or `private/diary/` by area.
- **brain-plan-day, brain-status, brain-post-standup, brain-plan-week:** read and write both `00-home/top-of-mind.md` and `private/private.md` when `brain-scope includes "$(brain-scope norm)" private`. Otherwise operate on shared only and print one line: "private items hidden — run from an all-scoped session (BRAIN_SCOPE=all)". New private actions go to private.md with a `[private]` marker. Rollover and archiving treat both files symmetrically. The weekly snapshot of private goals goes to `private/planning/YYYY-Www.md`.
- **brain-orient, brain-dream:** search via `brain-search`; read `private/private.md` and `private/sessions` only when the scope includes private.
- **brain-revive-workers, brain-monitor, brain-dashboard, brain-sync-meetings:** mention that worker notes may live in `private/workers/` (scripts handle it), and that meetings default to `area: work` (sync-meetings writes `area: work` into new meeting notes unless the user says otherwise).

- [ ] **Step 1:** `grep -n "top-of-mind\|workers/\|qmd search\|qmd update\|diary/\|sessions/\|knowledge/" skills/*/SKILL.md` to get the full inventory. Every hit must be either updated or consciously left (shared-only is correct).
- [ ] **Step 2:** Make the edits.
- [ ] **Step 3:** Re-run the grep. For each remaining hit, confirm it is correct for shared-only, or that it is generic.

---

### Task 10: Docs

**Files:** `README.md`, `claude/README.md`

- `README.md`: a new section, "Scopes: work / projects / private", covering the three areas, `BRAIN_SCOPE`/`BRAIN_PROJECT` (default shared, fail closed), the `private/` subtree, the two registries, `brain-search`, the second qmd index, the coordinator alias (`alias claude-all='BRAIN_SCOPE=all claude'`, plus the omp equivalent), and the migration runbook (classify → LLM pass on unclassified → review → `apply --yes` → `qmd update` on each host). Update the file/path inventory table and §8 "common changes" (adding a project = a registry row). Add `bin/tests/bin.test.sh` and `claude/hooks/brain-session-start.test.sh` to the offline test list.
- `claude/README.md`: install now also links `bin/brain-*` and edits the qmd configs.

- [ ] Write, then re-read for stale statements (e.g. "qmd has one collection").

---

## Final verification (coordinator)

- [ ] Run every test suite: `bash bin/tests/bin.test.sh`, `bash claude/hooks/brain-session-start.test.sh`, `bash claude/install.test.sh`, `for t in skills/*/scripts/*.test.sh skills/_shared/lib/*.test.sh; do bash "$t" || echo "FAILED $t"; done`.
- [ ] Live smoke, read-only against the real vault: `BRAIN_SCOPE= bash claude/hooks/brain-session-start.sh <<<'{"session_id":"x","cwd":"'$PWD'"}' | grep -c '\[personal\]'`. This is *expected to be non-zero before migration* (top-of-mind still holds them), which is why the migration matters. Note this in the Result.
- [ ] `bin/brain-migrate-scope classify --out <scratch>` against the real vault (read-only), for the user's review.
