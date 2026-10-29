# Design: brain-dream — the cross-session "dreaming" layer

Date: 2026-07-22
Status: design approved (sections confirmed in brainstorming); pending implementation plan.

> **Partly superseded (2026-09-11 port to Linux + oh-my-pi).** The pattern-finding design still holds.
> Two things changed with the move: the `personal-dreamer` / `~/.claude` half (Step 4) is now **optional**
> and invoked only if that skill is installed, and the reader/writer subagents are dispatched as one
> `task` batch (reports auto-deliver) rather than as named Claude Code agents. See the README for the
> current wiring.

## Problem & goal

`brain-persist` distils **one** session into one vault note. Nothing reads **across** those notes. The goal of `brain-dream` is the cross-session layer: an LLM reads the accumulated session-note distillations and surfaces what is recurring in the user's actual work — themes, friction, re-litigated decisions, open threads — and turns each into a **concrete, actionable proposal**. It delegates the `~/.claude` memory + "am I repeating myself to Claude" half to the existing `personal-dreamer` skill, and does light vault hygiene on the side.

This is deliberately **prompt-driven**: an LLM *reads* the notes and reasons about patterns. It must **not** use hard-coded regex/keyword counting — an earlier prototype wrongly tried that, and the point of dreaming is model judgement over the corpus.

The failure mode to avoid (learned from a colleague's first personal-dream prototype): **shallow, non-actionable observations**. Every pattern `brain-dream` reports must carry a concrete proposed action, or it is not reported.

## Division of labour (why this is not a duplicate)

| Tool | Substrate | Job |
|------|-----------|-----|
| `brain-persist` | 1 live session | distil → session note (the reduction step) |
| `personal-dreamer` | `~/.claude` memory + raw transcripts | memory hygiene + self-improvement (invoked by `brain-dream`) |
| **`brain-dream`** | **`vault/sessions/*.md` + the vault** | **cross-session work patterns + light vault hygiene** |

`personal-dreamer` already exists (team-engineer plugin) and explicitly *defers* vault-session-note pattern-finding to a vault-side counterpart — that counterpart is `brain-dream`. It also owns the "repeated-instruction to Claude" signal (which lives in raw transcripts, not in the work-focused session notes), so `brain-dream` does not need to reproduce it.

## Inputs

- **Primary:** `vault/sessions/*.md` (the brain-persist distillations, ~69 today) over a window. **Incremental by default** — sessions since the last dream, tracked by a watermark — with a `--full` override to dream over everything.
- **Vault hygiene (secondary, surface-only):** `[[link]]` integrity (dangling targets); top-of-mind items that session-notes show are done-but-still-open; knowledge notes that contradict each other. **Never rewrite** content that `brain-persist` / `brain-collect` own (session notes, diary, top-of-mind status) — surface for the user to action.
- **Delegated:** `personal-dreamer` (its on-demand propose-and-confirm flow) for the `~/.claude` memory + transcript half.
- **Oracle (reused):** the `team-brain` skill for org-fact cross-checks, exactly as the personal-dreamer run does.

## Output

One dated note, propose-and-confirm: `vault/inbox/YYYY-MM-DD-brain-dream.md` (distinct from personal-dreamer's `-memory-dream.md`).

- **§ Digest** — a short narrative of the window's recurring themes / friction / open threads, for context.
- **§ Proposed actions** — each pattern → one concrete action the user approves or declines: a backlog entry, a knowledge note to mint, a skill/command tweak, a top-of-mind nudge, or a `team-brain` `brain-proposal` candidate. Approved actions are then applied (writes delegated to a subagent). Declined actions are recorded in the dream note so the next run does not re-surface them.

## Architecture (follows brain-* skill conventions)

The skill lives at `~/projects/brain/skills/brain-dream/SKILL.md` (mirrored to `~/.claude/skills/`), following the existing `brain-*` pattern where the main agent distils and subagents do file writes / re-index.

1. **Resolve window** (main agent) — read the watermark (last-dream date); default to sessions since then, or all with `--full`.
2. **Fan out reader subagents** over batches of session notes (matches the user's delegate-to-subagents working style); each returns candidate patterns with the session ids that evidence them.
3. **Synthesise** candidates into deduped, evidenced patterns; drop any without a concrete proposed action.
4. **Invoke `personal-dreamer`** for the `~/.claude` half; fold its findings into the same report.
5. **Light vault hygiene** cross-check ([[link]] integrity; done-but-open top-of-mind; contradicting knowledge notes) — surface only.
6. **Write** the dated dream note (subagent) + `qmd update && qmd embed` re-index.
7. **Propose-and-confirm**, then apply approved actions to their proper targets (backlog / knowledge note / skill / brain-proposal), recording declines.

## Principles (from the brief + the org dreaming philosophy)

- **Prompt-driven, not hard-coded** — an LLM reads the notes; no regex/keyword counting.
- **Actionable or it is noise** — every reported pattern carries a proposed action.
- **Primary sources** — re-derive from session notes / filesystem; prior dream output is used *only* to avoid re-proposing dismissed items, never as a source of truth (the compounding trap).
- **Propose-and-confirm** — never writes without approval; mirrors `personal-dreamer`.
- **Provenance** — each pattern cites the session ids + dates that evidence it; each applied write carries a provenance line.
- **British English** throughout.

## Cadence

**On-demand only for v1** (like `personal-dreamer`'s interactive mode). An optional **weekly** report-only mode can be added later (mirroring `personal-dreamer`'s `nightly-run` pattern); weekly suits cross-session accumulation better than nightly. Out of scope for v1.

## YAGNI / deliberately out of scope for v1

- No scheduled automation (add later if the on-demand version proves its worth).
- No dreaming over raw transcripts (that is `personal-dreamer`'s job).
- No rewriting of session / diary / top-of-mind content `brain-dream` does not own.
- No new dependency on hard-coded pattern taxonomies — patterns emerge from the read.

## Open questions

None outstanding — the three brainstorming open items (output orientation = digest + proposals; window = incremental-since-last-dream with `--full`; cadence = on-demand v1) were confirmed on 2026-07-22.

## References

- Worker brief: `vault/workers/setup-dreaming.md`
- Source meeting: a team daily meeting note (2026-07-15)
- Prior art: a `personal-dreamer` skill from a team plugin; a colleague's write-up on dreaming; the original setup's `vault-dream`.
- Complements: `brain-persist`, `brain-collect`, `brain-dispatch` skills in this repo.
