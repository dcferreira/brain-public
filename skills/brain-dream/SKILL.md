---
name: brain-dream
description: Dream over the vault — read across recent session-note distillations to surface recurring work patterns, friction, and open threads as actionable proposals, plus a light vault-hygiene pass, and fold in the `personal-dreamer` skill's memory findings when that skill is available. The cross-session layer above per-session brain-persist. Use when the user says "dream over my sessions", "run a dream", "what patterns have come up", "cross-session review", or wants a periodic look-back across recent work.
argument-hint: "[optional: --full | since:YYYY-MM-DD]"
---

# Dream — Cross-Session Patterns Across the Vault

> **Harness.** If you have a `task` tool you are in omp: read `~/projects/brain/skills/_shared/harness/omp.md`. If you have an `Agent` tool you are in Claude Code: read `~/projects/brain/skills/_shared/harness/claude-code.md`. Read one, never both.

Where the brain-persist skill distils **one** session into one note, the brain-dream skill reads **across** those notes to surface what is recurring in your work — themes, friction, re-litigated decisions, open threads — and turns each into a **concrete proposal** you approve or decline. It also folds in the `personal-dreamer` skill's memory findings (when that skill is installed) and does a light vault-hygiene pass.

**How this runs:** the *main agent* orchestrates — it fans out reader subagents over the session notes, synthesises their candidate patterns, and drives the propose-and-confirm dialogue (only it holds that thread); *subagents* do the reading and the eventual file writes + re-index, keeping verbose output out of the main thread.

**Prompt-driven, not pattern-matched.** The analysis is an LLM *reading and reasoning over* the notes. Do **NOT** grep/keyword-count to "find patterns" — that was an explicit failure of an earlier prototype. Read the notes and think.

**Actionable or it is noise.** Every pattern reported MUST carry a concrete proposed action. A shallow observation with no proposed change is dropped, not reported — this is the bar the first personal-dream prototype missed.

**Propose-and-confirm.** Nothing is written or applied without the user's approval, exactly like `personal-dreamer`.

## Vault facts

- Vault: `~/Obsidian/vault`
- Session notes (the substrate): `sessions/YYYY-MM-DD <topic>.md` — brain-persist's distillations, with `date` / `session_ids` / `tags` / `area` / `project` frontmatter. `private/sessions/` is part of the substrate **only** when `brain-scope includes "$(brain-scope norm)" private` succeeds; from a shared-scope session it does not exist for this skill.
- Dream notes (this skill's output): `inbox/YYYY-MM-DD-brain-dream.md`.
- **Watermark:** the date of the most recent `inbox/*-brain-dream.md`. The default window is session notes dated on/after it; `--full` dreams over all; `since:YYYY-MM-DD` overrides explicitly.
- Backlog (a common action target): `00-home/backlog.md`. Knowledge notes: `knowledge/graph/`. Top of mind: `00-home/top-of-mind.md` (and `private/private.md`, when private is in scope) — **surface-only** here; never rewritten by this skill.
- **Private routing rule.** Any pattern, proposal or digest line evidenced (even partly) by a private note (`private/sessions/`, `private/knowledge/`, `private/private.md`) goes **only** to private destinations: the dream note lines to `private/inbox/YYYY-MM-DD-brain-dream.md`, knowledge notes to `private/knowledge/graph/`, backlog-like actions to `private/private.md`. The shared dream note (`inbox/…`) and shared targets (`00-home/backlog.md`, `knowledge/graph/`) carry only items evidenced purely by shared notes. Tell the reader subagents and writers this rule verbatim.
- Searching the vault: `brain-search` (scope-aware), not raw `qmd search`.
- Re-index command after writing: `qmd update && qmd embed`, then `qmd --index private update` when a private file was written.

## Step 1 — main agent: resolve the window

Determine today's date with `date +%Y-%m-%d` (never assume it). Find the watermark: `ls inbox/*-brain-dream.md` and take the latest date. The window is session notes dated on/after the watermark, unless `--full` (all notes) or `since:<date>` was given. List the in-window `sessions/*.md` files (plus `private/sessions/*.md` when private is in scope). If the window is empty, tell the user the last dream already covered everything and stop.

## Step 2 — fan out reader subagents

Split the in-window session notes into batches (~15–20 notes each) and dispatch one general-purpose reader subagent per batch, with these instructions verbatim.

**Fan out per the harness reference's *Fan-out subagents* section** — it carries the relay rule that keeps reports arriving without nudging.

> Read each session note in full (native file tools, British English). You are hunting **cross-cutting patterns**, not summarising individual sessions. Reason over what you read — do NOT grep or keyword-count. Return a list of candidate patterns; for each: a one-line description, the **evidence** (the session-note filenames + dates that show it), and a **concrete proposed action** (a backlog entry, a knowledge note to mint, a skill/command change, a top-of-mind nudge, or a `team-brain` brain-proposal candidate). Kinds worth surfacing: the same friction hit more than once; a decision re-litigated across sessions; an open thread that keeps recurring with no resolution; a manual task done repeatedly that a skill could own; a theme spanning many sessions that has no consolidating home. **The most valuable move — always check for it:** if a recurring friction *already has a knowledge note* but keeps happening anyway, the fix is NOT another note — it is to fold the lesson into the skill / config / hook / brief-priming that would actually *prevent* it. Search for an existing note (`brain-search`, or `knowledge/graph/` — and `private/knowledge/graph/` when private is in scope) before proposing a mint, and prefer a preventive change over a fresh note. **If a candidate has no concrete action, drop it** — do not return observations for their own sake. Return nothing if the batch genuinely holds no cross-cutting pattern.

## Step 3 — main agent: synthesise

Merge the subagents' candidates into a deduped, evidenced set — batches routinely surface the **same** pattern independently, which is itself a strong-signal; merge those into one item and combine their evidence. Discard anything still lacking a concrete action. **Rank by recurrence × actionability** and present the strongest (≈5–8) in full, folding weaker or single-session candidates into a brief tail — a wall of 15 findings is as useless as none. **Dedup against prior dreams:** read the `## Declined` section of recent `inbox/*-brain-dream.md` notes and drop patterns the user already dismissed — use prior dream output *only* for this dedup, never as a source of truth about the work itself (re-derive truth from the session notes).

## Step 4 — fold in personal-dreamer (only if that skill is installed)

If the `personal-dreamer` skill is available, invoke it to produce its findings (memory hygiene + improvement pass over the harness config and transcripts) **without applying them** — collect its proposed actions and present them within this dream's consolidated report rather than as a separate run. If it was already run today, note that and skip re-running it. If it is not installed, say so in one line and continue with the rest of the dream — it is an optional add-on, not a prerequisite.

## Step 5 — light vault hygiene (surface-only)

A quick cross-check, reported for the user to action — **never** rewritten here (session notes, diary and top-of-mind status are owned by brain-persist / brain-collect / the driving session):

- Dangling `[[wikilinks]]` whose target basename does not exist (`grep -rn '\[\[' knowledge/ 00-home/` and verify targets).
- Top-of-mind **Today** items the in-window session notes show are finished but are still `[ ]`/`[/]`.
- Knowledge notes that flatly contradict each other.

## Step 6 — present the consolidated report (propose-and-confirm)

Show the user, grouped, in the conversation:

- **§ Digest** — a short narrative of the window's recurring themes / friction / open threads.
- **§ Proposed actions** — each pattern → its evidence + one concrete proposed action, numbered, from all of: cross-session patterns (Steps 2–3), personal-dreamer findings (Step 4), vault hygiene (Step 5). The user approves or declines each. Do not write anything yet.

## Step 7 — apply approved actions + write the dream note

After the user picks, dispatch one writer subagent per independent target. **Fan them out per the harness reference's *Fan-out subagents* section** — it carries the relay rule that keeps reports arriving without nudging. The writer, using British English:

1. Apply each **approved** action to its proper target (private-evidenced actions to private targets only, per the private routing rule) — `00-home/backlog.md`, a `knowledge/graph/` claim note (wikilink hygiene: no `/` in names/links, no dangling links), a brain-* skill file, or a drafted `team-brain` brain-proposal (never opened automatically). Personal-dreamer's approved memory edits are applied per that skill's own flow. **Shared files (backlog, top-of-mind, knowledge) may collide with concurrent writers — on an out-of-date rejection, re-read and retry.** Every applied write carries a provenance line (the dream date + the evidencing session ids).
2. Write `inbox/YYYY-MM-DD-brain-dream.md` recording the run (shared-evidenced items only; private-evidenced lines go to `private/inbox/YYYY-MM-DD-brain-dream.md` per the private routing rule): the `## Digest`, an `## Applied` list (what was written and where), and a `## Declined` list (so future dreams skip these). Always write this note even if everything was declined — it advances the watermark.
3. Re-index: `qmd update && qmd embed` (and `qmd --index private update` if any private file was written).
4. Report back one line: patterns surfaced, actions applied, actions declined.

## Step 8 — main agent: tell the user

Relay the subagent's one-line summary.

## Notes

- Link references (issues / PRs) are written as markdown links to their full URL, resolved from the repo remote or `gh` — never a bare `#123`.
- **Provenance:** the subagent-relay rule in Steps 2 and 7 came from `brain-dream 2026-07-30` — a Claude Code run that named its readers and spent 8 nudges and 11 idle notifications chasing reports that unnamed agents would have relayed directly.
- v1 is on-demand only. A weekly report-only mode (mirroring `personal-dreamer`'s nightly-run) is a deliberate later addition, not part of this skill yet.
- **External skills this one can use, if installed:** `personal-dreamer` (Step 4) and `team-brain` (an org-facts oracle referenced for brain-proposals in Steps 2 and 7). Neither ships with this repo; both are optional and the skill degrades gracefully without them.
