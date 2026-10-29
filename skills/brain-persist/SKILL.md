---
name: brain-persist
description: Persist session insights to the knowledge vault — write a session summary, update top-of-mind, and create or update knowledge notes. Use when wrapping up work, at a meaningful mid-task checkpoint, or when you've learned something worth preserving. Safe to run repeatedly in a session — it updates the same session note rather than creating duplicates.
argument-hint: [worker | topic or summary]
---

# Persist — Save Session Context to Vault

> **Harness.** If you have a `task` tool you are in omp: read `~/projects/brain/skills/_shared/harness/omp.md`. If you have an `Agent` tool you are in Claude Code: read `~/projects/brain/skills/_shared/harness/claude-code.md`. Read one, never both.

Capture this session's insights, decisions, and learnings in the knowledge vault so future sessions can build on them.

**How this runs:** the *main agent* distils what is worth persisting (only it has the session context); a *subagent* then does the file writes and re-index, so verbose tool output and the qmd log stay out of the main thread.

**Two modes.** The DEFAULT (no argument) is the full persist for the *main driving session* — session note + top-of-mind reconciliation + knowledge notes + re-index. Invoked with the `worker` argument (the brain-persist skill, worker mode), it runs a **scoped** persist for a dispatched worker session (see [Worker mode](#worker-mode-brain-persist-worker) below): session note + knowledge notes + re-index, **but never** top-of-mind, **never** private.md and **never** the diary. Everything else in this skill describes the default mode unless a step is explicitly marked worker-mode.

**Concurrency (both modes).** Shared-file writes — top-of-mind and knowledge notes — may collide with other agents (workers, collect) writing concurrently. If a write is rejected as out-of-date, re-read the file and retry until it succeeds.

**Editing tracked vault files (both modes).** Mutate top-of-mind, session notes and knowledge notes through the harness `read` → `edit`/`write` flow only — **never** with shell text-rewrites (`awk`/`sed -i`/`cp`/`mv`/`>` redirection). An out-of-band write changes the file behind the harness and makes the next edit fail with a stale-read error (this stalled the planning skills on 21 Aug 2026). If an out-of-band write is ever genuinely unavoidable, `read` the file again immediately, before any further `edit`.

## Vault facts

- Vault: `~/Obsidian/vault`
- Session notes: `sessions/YYYY-MM-DD <brief-description>.md` — or `private/sessions/…` for `area: private` (see **Scope routing** below).
- Top of mind: `00-home/top-of-mind.md` — sections **Today** (personal checkbox actions: `[ ]` to do · `[/]` in progress · `[x]` done · `[-]` dropped), **This week** (team + personal goals, plain bullets, grouped Team / Personal), **Previously this week**.
- Private Today file: `private/private.md` — private actions, marked `[private]`; same Today/This week layout. Written only in the default mode and only when `brain-scope includes "$(brain-scope norm)" private`.
- Long-term goals: `00-home/backlog.md` — **not** auto-injected; persist does NOT write long-term goals to top-of-mind.
- Knowledge notes: `knowledge/graph/` — or `private/knowledge/graph/` for `area: private`.
- Session id: the session-start wiring injects this session's id into the vault context, on the line `This session's id is <id>` (followed by a parenthesised harness tag — ignore it). The **main agent** must read it there and pass the value to the subagent (a subagent gets no vault context, so it cannot read the id itself).

**Scope routing (both modes).** Every session and knowledge note carries `area:` (`work` | `projects` | `private`) and `project:` (a slug from `00-home/scopes.md` or `private/scopes.md`) in its frontmatter. Take them from `$BRAIN_PROJECT` / `$BRAIN_SCOPE`, looking the project's area up in the registries; in worker mode take them from the worker note's `area:`/`project:` frontmatter instead. If neither says, ask the user rather than guess. An `area: private` note goes under `private/sessions/` or `private/knowledge/graph/` (resolve the directory with `brain-scope note-dir <area> sessions|knowledge`; for knowledge it returns `knowledge` or `private/knowledge`, so append `/graph` for claim notes); anything else stays in `sessions/` / `knowledge/graph/`. Pass the resolved `area`, `project` and directories to the subagent. If the registry file you need to append a new project row to is absent, first copy it from `~/projects/brain/bin/seed/scopes.shared.md` / `scopes.private.md` (to `00-home/scopes.md` / `private/scopes.md`), then append.

**Private material never goes into a shared note (both modes).** When the session's scope includes private (`brain-scope includes "$(brain-scope norm)" private`: `all` or `private`), a shared `sessions/` or `knowledge/` note is injected as LATEST SESSION into every shared worker, so it must carry no private content. Private-sourced material — `[private]` items, anything read from `private/`, personal topics — goes **only** into a `private/sessions/` or `private/knowledge/graph/` note. If the session covered both kinds, write **two** notes: a shared one (shared material only, `area:` work/projects) and a private one (`area: private`). The shared notes exclude the private material entirely — not even a summary line or a pointer to a private path. This applies to the session note, to every knowledge note, and to worker-mode persist. Give the subagent each note's material separately, with its own `area`, `project` and directory, and tell it this rule verbatim.

## Step 1 — main agent: distil (do not write files yet)

From this session, prepare the actual material to persist (write the real prose, not just topics — the subagent will place it verbatim):

- **Split by sensitivity first.** If the session touched private material (see *Private material never goes into a shared note* above), partition everything below into a shared set and a private set before writing any prose; the shared set must be free of private content.
- **Session note body** — what happened, decisions made and their reasoning, what's working, what's not working, next steps.
- **Harness workflow friction** (a distinct session-note section) — capture friction with the *agent harness itself*: skills, subagents, hooks/extensions, `AGENTS.md`/instructions, wrong assumptions the model made, and recurring patterns that suggest a new skill or instruction is worth creating. This exists so setup problems can be analysed and fixed over time — so keep it **separate** from ordinary domain gotchas or bugs in external tools (e.g. "this CLI is buggy"), which stay in *what's not working*. Omit the section entirely when nothing setup-related came up.
- **A short topic description** for the filename (e.g. `second-brain setup`).
- **The current session id** — take it from the `This session's id is <id>` line of the injected vault context, and pass the value to the subagent, so the session note records which session produced it.
- **Top-of-mind updates** — reconcile the page with what actually happened this session (for `[private]` actions, reconcile `private/private.md` the same way — only when `brain-scope includes "$(brain-scope norm)" private`; otherwise leave them alone): which **Today** actions changed status (started → `[/]`, finished → `[x]`, dropped → `[-]`, or new actions worked on but not yet listed). **Leave completed `[x]` actions in Today** — do **not** sweep them into **Previously this week**; only `brain-sweep` (run by the brain-plan-day and brain-plan-week skills) sweeps. Also note whether any **This week** goal genuinely changed. Do **not** put long-term goals on top-of-mind — those live in `00-home/backlog.md`.
- **Knowledge claims** — only when the session produced reusable patterns, decisions, or insights. Each as a *claim-titled* note (`qmd hybrid search beats keyword search.md`, not `search.md`) with its body and `[[wikilinks]]` to related claims.
  - **Search before you mint.** For **every** claim, first run `brain-search "<the claim>"` (scope-aware; add `--project <slug>`) and `env -u CI qmd vsearch "<the claim>"`. **The `env -u CI` is load-bearing:** some harnesses set `CI=true` in their shell tool, under which `qmd vsearch` **aborts** (`LLM operations are disabled in CI`) instead of returning no hits — so without it the check silently looks like "no near-match" and you mint the sibling this rule exists to prevent. On a **near-match** — an existing note making the same or a materially overlapping claim — **update that note** rather than creating a sibling next to it (one cluster in the graph is already five near-identical notes). Mint a new note only when the claim genuinely has no home.
  - **Supersede explicitly.** If a new or updated note **contradicts or replaces** an older one, never leave the older one standing — half the graph's contradictions are exactly a newer note beside an un-retired older one. Add a banner as the **first line** of the superseded note, and link back from the new one:
    ```markdown
    > [!warning] Superseded by [[<new note basename>]] (<YYYY-MM-DD>) — <one line on what changed>
    ```
  - Wikilink hygiene (this prevents broken links that spawn empty duplicate pages in Obsidian):
    - **Never put `/` in a note name or wikilink** — Obsidian treats it as a folder separator and the link breaks (name it `persist is the only writer of top-of-mind`, not a name that begins with a slash). Refer to a slash-command in prose, but keep the name/link slash-free.
    - Every `[[wikilink]]` must **exactly match the basename** of a note that already exists or that you are creating in this same persist. **Never leave a dangling link** — a broken wikilink, when clicked, silently creates an empty note (often at the vault root), which then shadows the real one.
- **State words, never a bare "shipped".** Every claim that something shipped carries the state you actually verified — **merged**, **tagged**, **deployed** or **enabled** — and says where it stops (e.g. "merged `!787`, not yet deployed"). "Shipped" conflates "an MR exists" with "users have it". This holds in the session note, in top-of-mind, and in knowledge notes. **If a human process change depends on the code** — a runbook, an SOP, a message telling someone to use it — the state to verify is **deployed**, not merged: hit the live endpoint or check the deploy before writing it down.
- **Link references.** Whenever you mention an issue or PR (e.g. `brain #12`), write it as a markdown link to its full URL — e.g. `[brain #12](https://github.com/example-user/brain/pull/12)`. Resolve the URL from the repo's GitHub remote (or `gh`); never leave a bare `#12`. This applies in the session note **and** in top-of-mind.

*Provenance: the state-word rule and the search-before-mint / supersede-banner rules above came from `brain-dream 2026-07-30` — three of six contradictions in the graph were a newer note leaving an older one standing, and one cluster had grown to five near-identical notes.*

## Step 2 — dispatch one subagent to write it

Dispatch a single general-purpose subagent. Give it the material from Step 1 plus these instructions verbatim:

> Determine today's date with `date +%Y-%m-%d` — do not assume it. Then, using native file tools and British English:
>
> **Private material never goes into a shared note.** Material supplied as private (`area: private`) is written only under `private/sessions/` or `private/knowledge/graph/`. When both a shared and a private set are supplied, write two notes (one per set, each in its own directory with its own `area`) and never copy private content, summaries or `private/` paths into the shared one.
>
> 1. **Session note (update, don't duplicate).** Look in the supplied sessions directory (`sessions/` or `private/sessions/`, per the supplied `area`) for a note named `<today> <topic>.md`, or one otherwise clearly covering the same topic dated today. If one exists, **update it** — keep its filename, revise/extend its sections, don't append redundant text; and **add the supplied session id to its `session_ids` frontmatter list if not already present** (a note touched across sessions accumulates them). Otherwise create `<sessions dir>/<today> <brief-description>.md` with YAML frontmatter:
> ```
> ---
> date: <today>
> area: <supplied area>
> project: <supplied project>
> session_ids: [<session id>]
> tags: [<relevant tags>]
> ---
> ```
> Then cover: what happened, decisions + reasoning, what's working, what's not, next steps. When the supplied material includes harness workflow friction, add a distinct `## Harness workflow friction` section holding those items, and add `harness-workflow` to the note's `tags` frontmatter list so the issues are findable across sessions (via `qmd search`). (Notes written before the 2026-09-11 omp port carry the tag `claude-code-workflow` for the same thing — search both.) Omit both the section and the tag when nothing setup-related came up.
> 2. **Top-of-mind.** Edit `00-home/top-of-mind.md` (and `private/private.md` for `[private]` actions, when supplied) to reflect reality: update **Today** action statuses (`[ ]`/`[/]`/`[x]`/`[-]`), and add any action worked on but not yet listed (as `[/]`). **Leave completed `[x]` actions in Today — do NOT sweep them into Previously this week** (`brain-sweep` does that). Update **This week** goals only if they genuinely changed. Do NOT write long-term goals here — they live in `00-home/backlog.md`. Update in place; don't duplicate items that are already present. Keep it short.
> 3. **Knowledge notes.** Create or update the supplied claim notes in the supplied knowledge directory (`knowledge/graph/` or `private/knowledge/graph/`), with `area:` and `project:` in their frontmatter, claim-named, wiki-linked. **Before creating any note, `brain-search` and `env -u CI qmd vsearch` its claim: on a near-match, UPDATE the existing note instead of creating a sibling** — only mint when the claim has no home. Where a note supersedes an older one, add the supplied supersede banner as the first line of the **old** note and link back from the new one. **No `/` in any note name or `[[wikilink]]`**, and every `[[wikilink]]` must exactly match the basename of a note that exists or is being created here — no dangling links. After writing, verify with `grep -rn '\[\[/' .` from the vault root (it should print nothing); fix any hits before continuing.
> 4. **Re-index.** Run `qmd update && qmd embed`, and when any private note was written also `qmd --index private update && qmd --index private embed` (update = keyword/BM25, embed = vectors; embed only processes changed content, so it's cheap).
> 5. **Report back one line:** session note (created or updated, with filename), top-of-mind changes, and knowledge notes created/updated.

## Step 3 — main agent: tell the user

Relay the subagent's one-line summary so the user knows what was persisted.

## Worker mode (`brain-persist worker`)

Run this **only** when invoked with the `worker` argument — i.e. inside a dispatched worker session (the ones the brain-dispatch skill launches). A worker session holds the full journey — the decisions, the reasoning, and any harness friction — that its task-scoped `## Result` note deliberately does **not** capture. Worker mode preserves that journey **without** duplicating what the brain-collect skill and the driving session already own.

**Does** (the scoped subset of the default flow):

- **Session note** — `sessions/<date> <topic>.md` (or `private/sessions/…` for `area: private`, with `area:`/`project:` from the worker note), capturing the worker's journey (what happened, decisions + reasoning, what's working / not), including a `## Harness workflow friction` section (with the `harness-workflow` tag) when setup friction came up. Date it to the work: today by `date +%Y-%m-%d`, unless updating an existing note for the same work — the normal update-don't-duplicate rule from Step 1/Step 2 applies.
- **Knowledge notes** — create/update claim-titled notes in `knowledge/graph/` (or `private/knowledge/graph/` for `area: private`) for genuinely reusable insights, wiki-linked, with the same wikilink hygiene, search-before-mint and supersede-banner rules as the default mode.
- **Re-index** — `qmd update && qmd embed`; plus `qmd --index private update && qmd --index private embed` when a private note was written.

**Skips (deliberately):**

- **Top-of-mind and private.md reconciliation — entirely.** A worker must **not** touch `00-home/top-of-mind.md` or `private/private.md`. The brain-collect skill owns the `[x]`/annotation for the dispatched action, and the *driving* session owns top-of-mind reconciliation — a worker touching it duplicates a completed action (observed in testing).
- **The diary — entirely.** The brain-collect skill owns the `## Shipped` / `## Blocked` diary line.

**Completion handshake (worker mode's FINAL step).** After the writes and re-index, the worker checks its OWN worker note (`brain-scope find-worker <its-slug>` prints its path; `workers/` or `private/workers/`) (it knows its slug from the brief it was launched with):

- If that note's `collect_state` is `collecting` → set `collect_state: persisted`. This is the signal the brain-collect skill polls for before tearing the session down.
- If `collect_state` is **absent** → this is a mid-session voluntary checkpoint, not collect-triggered: leave all status fields untouched (do not add `collect_state`, do not change `status`).

**Private material (worker mode too).** The scope rule above applies unchanged: a worker whose scope includes private writes private-sourced material only to `private/sessions/` / `private/knowledge/graph/` notes, and splits into a shared and a private note when the journey covered both. A shared-scope worker never has private material to write.

Worker mode still delegates the file writes to a subagent per the default pattern; just give that subagent the scoped instruction set above (session note + knowledge + re-index + the `collect_state` handshake) and tell it **not** to touch top-of-mind, private.md or the diary.
