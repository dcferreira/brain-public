# Vault topic scoping — area/project scopes, private subtree, scoped search (design)

Date: 2026-10-15. Agreed with the user in the `vault-topic-scoping` worker session.

## Goal

An agent scoped to one project (e.g. ClientCo) finds that project's notes cleanly, and an agent
that is not working in the user's private sphere does not see private material (learning,
own-business ideas, personal finance, health, home admin) through either
**search** or **startup context**. This is clean separation by default, not access control:
a determined agent can still read files.

## Starting state (2026-10-15)

[verified: grep/ls over ~/Obsidian/vault, qmd collection list, brain repo @ main]

- Folders are by note type (`workers/`, `sessions/`, `knowledge/`, `meetings/`, `diary/`,
  `inbox/`, `planning/`, `00-home/`) plus a top-level `learning/` (learning, all private).
- 448 worker notes, none with `tags:`. Topic lives only in the slug prefix.
- Knowledge and session tags are freeform (`clientco` vs `clientco` vs `cc2`).
- qmd has one collection, `vault`, over `**/*.md` (3,230 files). The index is per machine.
- `00-home/top-of-mind.md` mixes work and `[personal]` Today items (11 personal lines, 228
  Today lines in total). `claude/hooks/brain-session-start.sh` and its omp twin
  `omp/brain-vault.ts` inject it whole into every session, along with the latest session
  note and a qmd search on the cwd basename.
- Ten skills read or write top-of-mind: collect, dispatch, dream, orient, persist,
  plan-day, plan-week, post-standup, status, sync-meetings.
- The vault reaches the Mac and `homeserver` through Syncthing.

## Decisions (settled with the user)

1. **Three areas: `work` | `projects` | `private`.** `work` is Acme. `projects` is
   side projects (agent-pawl, budgebell, toxic-news, brain). `private` is everything that is the user's own:
   `learning`, `business`, `finance`, `health`, `home`, … Work and projects are
   visible to every session. Private is visible only to sessions working in the private
   sphere.
   Amended 2026-10-16: brain is a projects-area project; sessions in ~/projects/brain still run with scope all.
2. **Scope is an env var, and it fails closed.** `BRAIN_SCOPE` is `shared` (default when
   unset), `private` or `all`. `BRAIN_PROJECT=<slug>` is optional and only narrows focus.
   brain-dispatch sets both for workers. The user's coordinator session (plan-day, dispatch,
   collect, status) runs with `BRAIN_SCOPE=all` through a launcher alias. Brain workers get
   `all`.
3. **Private Today items live in a separate file,** `private/private.md` (its own Today
   and This-week sections). The shared top-of-mind never contains private text, so a
   worker that opens it with Read sees nothing private. (Filtering inside the hook was
   rejected because workers and brain-orient read the file directly.)
4. **Private notes live in a physical `private/` subtree with their own qmd index.** The
   `vault` collection ignores `private/**`. A separate index (`qmd --index private`)
   covers `private/`. A plain `qmd search`, the default habit of every agent, cannot return
   a private note. Frontmatter `area: private` is written as well, but the path is what
   enforces it. (A frontmatter-only filter was rejected: one missed tag leaks a note, and
   agents call qmd directly.)
5. **Project scoping is a focus filter, not a wall:** frontmatter `project:` plus
   `brain-search --project <slug>`, a wrapper in the brain repo that runs qmd and keeps
   only hits whose frontmatter matches.
6. **The vocabulary is an open, living registry, not a fixed list.** It has aliases to stop
   drift. When nothing fits, the session adds an entry and says so in one line.
7. **The migration is dry-run first.** The user reviews a report before any vault write. A
   full snapshot is taken before the write. Notes that mix work and private content are
   flagged, never auto-split.

## Data model

### Frontmatter

Every worker, session and knowledge note carries:

```yaml
area: work        # work | projects | private
project: clientco      # a registry slug
```

Meeting notes carry `area` (default `work`) and `project` when it is known. Existing
`tags:` are left untouched; they are not the scope mechanism.

### Registry

Two files, so that even the names of private projects stay out of shared context:

- `00-home/scopes.md`: `work` and `projects` entries.
- `private/scopes.md`: `private` entries.

Each entry is one row of a markdown table, machine-parsed:

```markdown
| project | area | aliases | slug prefixes |
|---|---|---|---|
| clientco | work | clientco, cc2 | clientco- |
| flow-designer | work | flow-design, scenarios, sop-tool | flow-designer-, flow-design-, scenario-, sop- |
| budgebell | projects | habits | budgebell-, habits- |
```

Initial work/projects entries: `clientco`, `carco`, `client-b`, `client-c`, `client-d`,
`client-e`, `flow-designer`, `pulse`, `access`, `agent-platform`, `acme` (the catch-all:
engineer tooling, demos, status updates, admin, other internal work),
`agent-pawl`, `budgebell`, `toxic-news`, `brain`. Initial private entries: `learning`,
`business`, `finance`, `health`, `home`. The migration dry run refines these lists.

**Resolution order** for a candidate value: exact slug, then alias, then slug prefix. If
nothing matches, the session (dispatch or persist) adds a new row and tells the user in one
line ("added project `foo` (work) to scopes.md"). Aliases are where synonyms get resolved
for good.

### Paths

| area | worker note | session note | knowledge | diary Shipped | Today line |
|---|---|---|---|---|---|
| work / projects | `workers/` | `sessions/` | `knowledge/` | `diary/<date>.md` | `00-home/top-of-mind.md` |
| private | `private/workers/` | `private/sessions/` | `private/knowledge/` | `private/diary/<date>.md` | `private/private.md` |

`learning/` moves to `private/learning/`. `meetings/`, `inbox/` and `planning/` stay shared.
A private item in them is moved by hand when the migration report flags it.

**A missing `private/` is treated as empty everywhere.** The skills ship before the
migration runs, so every reader must tolerate its absence.

## Components

All shell, in the style of `skills/_shared/lib` (sourced libs plus `*.test.sh` against
fixtures).

1. **`skills/_shared/lib/scope.sh`**: read `area`/`project` from a note's frontmatter;
   load and resolve the two registries (slug, then alias, then prefix); map area + note
   type to a path; normalise `BRAIN_SCOPE` (unset or unknown → `shared`); answer "does
   scope S include area A".
2. **`bin/brain-search [--scope shared|private|all] [--project <slug>] [-n N] "<query>"`**:
   scope defaults to `$BRAIN_SCOPE`, project to `$BRAIN_PROJECT` (`--project ''` turns the
   filter off). It queries the `vault` index, and also `--index private` when the scope
   includes private. It runs qmd `search --format json`, drops hits whose `project:`
   doesn't match (when a project is set), merges results, and prints markdown like
   `qmd search --md`. It warns, but succeeds, when the private index does not exist yet.
3. **`bin/brain-migrate-scope classify|apply`**: the one-time backfill (see Migration).
   Idempotent.
4. **`claude/hooks/brain-session-start.sh`** and **`omp/brain-vault.ts`**:
   - always: shared top-of-mind; the latest session note from `sessions/`; related notes
     through `brain-search` (filtered by `BRAIN_PROJECT` when it is set, otherwise the
     current cwd-basename query, with scope applied);
   - when the scope includes private: also `private/private.md`, and the latest session is
     the newer of `sessions/` and `private/sessions/`;
   - a line stating the active scope, the project, and how to search
     (`brain-search "<q>"`);
   - the "keep Today current" instruction names the right file for the scope.
5. **Skill edits**
   - **brain-dispatch**: classify the action into area + project (registry; ask the user
     when it is unclear; add a registry entry when it is new); write both into the worker
     note's frontmatter; choose the path by area; launch the worker with `BRAIN_SCOPE` and
     `BRAIN_PROJECT` in its env (`all` for `project: brain`, `private` for other private
     work, `shared` otherwise); the brief tells the worker to search with `brain-search`.
   - **brain-persist**: write `area`/`project` on session and knowledge notes, taken from
     env or the worker note; route private notes into `private/`; re-index both indexes.
   - **brain-collect**: find the worker note in either folder; mark the Today line done in
     the file it lives in; write the Shipped entry to the matching diary.
   - **brain-plan-day, brain-status, brain-post-standup, brain-plan-week**: read and write
     both Today/This-week files when the scope includes private. Without it, they say that
     private items are hidden and point to the alias.
   - **brain-orient, brain-dream**: search through `brain-search`; read `private/private.md`
     only when the scope allows it.
   - **brain-revive-workers, brain-monitor, brain-dashboard**: find worker notes in both
     folders (glob both).
6. **`claude/install.sh`**: link `bin/*` into `~/.local/bin`; idempotently ensure the qmd
   config has `ignore: ["private/**"]` on `vault` and a `private` index whose collection
   covers `$VAULT/private`. `install.test.sh` covers this.
7. **Docs**: README (the scope model, the registry, the coordinator alias, migration
   steps) and this spec.

## Migration

`brain-migrate-scope classify` is read-only. For every note in `workers/`, `sessions/`,
`knowledge/`, `meetings/`, `diary/`, `inbox/` and `learning/`, it proposes `area` +
`project` using the first rule that hits:

1. existing `area:`/`project:` frontmatter (so re-runs are idempotent);
2. folder: `learning/` → `private`/`learning`;
3. registry slug prefix on the filename;
4. registry aliases matched against `tags:`, `week_goal:` and `customer:`;
5. for worker notes, the matching Today line: `[personal]` → private; "Personal project
   — X" → projects/X when X is in the registry;
6. otherwise **unclassified**.

Each proposal records which rule fired. Unclassified notes are then given to a cheap
subagent (haiku) that reads each note and proposes a value, marked `[inferred]`. A note is
never auto-classified as private on an LLM guess alone without appearing in the report.
Anything still unresolved defaults to `work` (the visible bucket) and is listed.

**Report**: `migration-report.csv` (path, proposed area, project, rule, confidence) plus a
markdown summary: counts per area/project, every private move, every `[inferred]` or
unclassified note, and **mixed** notes (diary days and sessions whose body matches both a
private and a non-private registry term). Mixed notes stay where they are as `work`, and
the user decides per note.

`brain-migrate-scope apply --report <csv>` runs only after the user signs off. It:
1. snapshots the vault (`tar` into `~/Obsidian/backups/vault-<timestamp>.tar.gz`);
2. writes the frontmatter in place;
3. `mv`s private notes into `private/…` (Obsidian wikilinks resolve by name, so they
   survive);
4. moves the `[personal]` Today/This-week lines from top-of-mind into `private/private.md`
   (side-project items relabelled `projects` stay put);
5. writes the initial `scopes.md` files, then runs `qmd update` on both indexes.

## Testing

Red-green, offline, fixture vaults under the test dirs:

- `scope.test.sh`: frontmatter parsing, registry resolution (slug/alias/prefix/miss),
  scope normalisation (unset/garbage → shared), path mapping.
- `brain-search.test.sh`: run against a stub `qmd` on PATH that returns canned JSON per
  index; asserts scope fan-out, project filtering, and a missing private index.
- `brain-session-start.test.sh`: fixture vault containing private sentinels; with
  `BRAIN_SCOPE` unset, **no private sentinel string appears anywhere in the output**; with
  `private`/`all` it does; works when `private/` is missing.
- `brain-migrate-scope.test.sh`: each classification rule, mixed-note detection,
  idempotency (classify after apply proposes no changes), apply on a fixture copy (moves,
  frontmatter, top-of-mind split).
- `install.test.sh`: qmd config edits are idempotent.
- omp: `brain-vault.ts` gets the same sentinel assertion in its existing test style, or a
  smoke run if it has none.

## Rollout (each step needs the user's approval)

1. Review the jj change → push to `mac` and `homeserver` → on all three hosts, `jj new main`
   and `claude/install.sh`.
2. `brain-migrate-scope classify` → the user reviews the report → adjust rules and registry
   → re-run until clean.
3. Snapshot, then `apply`. Syncthing carries the moves. Run `qmd update` on each host.
4. The user adds the `BRAIN_SCOPE=all` coordinator alias.

**Window hazard**: between steps 1 and 3, a worker on old skills could write a private
note to its old path. Re-running classify/apply picks it up.

## Out of scope

- Access control: a determined agent can still `cat` `private/`.
- Splitting mixed diary or session notes automatically.
- Retagging the freeform `tags:` vocabulary.
- Per-project qmd collections.
