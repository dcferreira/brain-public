---
name: brain-sync-meetings
description: Pull recent meeting notes from the Krisp MCP into the knowledge vault. For each new meeting it writes a markdown note to the vault's meetings/ folder and re-indexes qmd. Use when the user wants to sync, pull, or import Krisp meetings into their vault, or asks to catch up the vault with recent meetings.
argument-hint: "[optional: number of days to look back, default 7]"
---

# Sync Meetings — Krisp → Vault

> **Harness.** If you have a `task` tool you are in omp: read `~/projects/brain/skills/_shared/harness/omp.md`. If you have an `Agent` tool you are in Claude Code: read `~/projects/brain/skills/_shared/harness/claude-code.md`. Read one, never both.

Pull recent meeting notes from the Krisp MCP and capture them as markdown notes in the knowledge vault, so they become part of the searchable second brain. This mirrors the original setup's meeting pipeline's capture step, but pulls on demand via the MCP rather than receiving webhooks.

## Facts

- Vault meetings folder: `~/Obsidian/vault/meetings/`
- Note filename: `YYYY-MM-DD <title>.md` (sanitise the title — replace `/`, `:` and other path-unsafe characters with `-`)
- Default look-back window: **7 days** (override with the argument, e.g. `14`)
- Re-index command after writing: `qmd update && qmd embed` (meetings are shared, so the private index is not touched)
- Scope: meetings default to `area: work` — write `area: work` into every new meeting note's frontmatter unless the user says otherwise.

## Principle — capture, do not synthesise

Krisp generates the summary, key points, and action items **itself**, server-side. This skill is a **pure renderer**, exactly like the original setup's poller: it writes Krisp's own content into the note verbatim. **Do NOT generate or summarise a meeting yourself** — no LLM-written summaries in the per-meeting note. Cross-meeting synthesis is a separate future "digest" step that writes a *proposal* to `inbox/`; it does not belong here.

Meeting notes are raw capture, so they are written **directly** to `meetings/` — not `inbox/`. Never edit `00-home/top-of-mind.md` or other durable docs from this skill.

## Known-mangling glossary — normalise AT SYNC

Krisp's transcription mishears the same names and terms every time. Fix them **here, at capture**, so no downstream artefact ever sees the mangled form — a mangled name reached a **published Notion page** despite three separate warning notes in the vault, because each downstream skill was left to catch it. Verbatim capture does **not** extend to transcription errors: a misheard name is not the speaker's wording.

| Krisp writes | Correct form |
| --- | --- |
| Jon / John | Jonn |
| Katherine | Kathryn |
| Mark | Marc |
| SP | SOP |
| Wiget builder | Widget Builder |

Apply these throughout the note — frontmatter `participants`/`speakers`, Key Points, Action Items **and** the transcript — and extend the table whenever a new recurring mangling shows up. **Hard rule: no name and no verbatim quote leaves a transcript unchecked.** Before writing the note, check every person-name against the meeting's `attendees`/`speakers` roster and this glossary, and check any line you are about to render as a quote reads as something that person plausibly said. If a name is not on the roster and is not in the glossary, flag it in the report rather than guessing silently.

**Apply the glossary roster-scoped and meaning-checked, never as a blind find-and-replace.** A mechanical pass over this table actively corrupts correct text, and the 10 Aug sync caught three live instances in one run:

- **Only correct a name when the real colleague is plausibly the referent** — i.e. they are on this meeting's `attendees` roster *and* the mention is about work. A `John` who is a stranger in a personal anecdote, or an arbitrary example customer name in a data-residency discussion ("I'm sure there's a customer called John"), must be left exactly as Krisp wrote it.
- **Check the term actually means what the glossary assumes.** `SP → SOP` is right in "create the SOP with the SP tool", and wrong in "SP it out of…" (that is *split*). Substituting there would have invented a sentence nobody said.
- **Never "correct" an already-correct name.** This row was inverted for weeks — the table read `Kathryn → Katherine`, which would rewrite the right spelling into the wrong one. Ground truth: Krisp's own identified-speaker metadata is `Kathryn Example`, and a meeting note carried an explicit correction note recording that Krisp mislabels her `Katherine` in transcripts. Before adding or trusting a row, confirm which side is the mangle.
- When roster-scoping **blocks** a fix you suspect is genuine (e.g. "the SOP tool that Johnny put together", where Jonn is not on that roster), leave the text alone and **flag it for a human call** — do not quietly apply it anyway.

Two further quirks worth knowing, both observed repeatedly: Krisp's `speakers` list sometimes contains a **duplicated** name (deduplicate it, and say so), and Krisp's Action Item **assignee** fields are frequently wrong — it has stamped the user's own name on nine items across two planning meetings whose text plainly reads "<a colleague with the same first name> to…". Keep Krisp's assignee verbatim, but flag the mismatch in the report so no downstream skill treats it as fact.

**Fused-recording check — two back-to-back calls captured as one.** Krisp sometimes merges a meeting with the call the user joined immediately after into a **single** recording, silently, so every downstream artefact then mis-attributes the second call's content to the first meeting. The reliable tell is a **speaker who is not on the meeting's own `attendees` roster** (once a team daily was fused with the weekly demos call that followed, and a colleague not on the daily's roster appearing as a speaker was the giveaway; the rule of thumb the user gave was "once <that colleague> speaks it's already the other meeting"). Before rendering, if the `speakers` list contains anyone absent from `attendees`, or the transcript plainly shifts roster/topic partway through, **flag it in the report as a possible fused recording**, note roughly where the second call appears to start, and do **not** silently attribute the whole transcript to the first meeting. If the user confirms it is fused, capture only the relevant meeting's portion (or note the boundary explicitly in the note).

## Authentication check (do this first)

The Krisp MCP server is defined per harness (see the harness reference); confirm its tools are available (e.g. `mcp__krisp_search_meetings`), otherwise stop and tell the user to enable/re-authenticate it via the harness's `/mcp` command. If the tools are not available:

> Stop. Tell the user: "The Krisp MCP isn't connected. Enable/re-authenticate it via the harness's `/mcp` command, then re-run the brain-sync-meetings skill."

Do NOT fall back to a partial or empty result when Krisp is unavailable — a misleading "0 meetings" is worse than an honest stop.

## Steps

1. **Determine the window.** Call `mcp__krisp_date_time` for today's date, then compute the look-back start (default 7 days back).

2. **List meetings in the window.** Call `mcp__krisp_search_meetings` with `after: <start-date>` and `fields: ["name", "date", "url"]`, `limit: 50`. This returns the candidate meetings with their `meeting_id`s.

3. **Dedupe with upgrade.** Read the YAML frontmatter of existing notes in `meetings/` and collect their `meeting_id`s. For each candidate:
   - **New id** → capture it (steps 4–5).
   - **Existing id, and the note has `notes_pending: true`** → Krisp had not finished generating notes when it was last captured. Re-fetch and overwrite to **upgrade** it (steps 4–5).
   - **Existing id, no `notes_pending` flag** → already fully captured. Skip.

4. **Check speakers are identified — pause and ask if not.** After fetching a meeting's document (`mcp__krisp_get_multiple_documents`), inspect the transcript. If Krisp has **not** identified one or more speakers, they appear as generic labels — `Speaker_1`, `Speaker_2`, `Speaker 3`, etc. — and the `speakers` metadata field is short or missing names. When that happens for a meeting the user cares about:

   > **Stop and ask the user to assign the speakers in Krisp**, then re-pull. Tell them: "Krisp hasn't identified some speakers in *<meeting title>* (showing `Speaker_2`, `Speaker_3`, …). Open the meeting in the Krisp web app and assign the speaker names, then tell me and I'll pull it again." Once the user confirms, re-call `get_multiple_documents` **and** re-fetch metadata to pick up the corrected `speakers`, and only then render.

   - This gate is **per-meeting**, not per-run: named meetings proceed straight to rendering; only the unnamed ones pause. If the user says to **proceed anyway** (e.g. speakers can't be identified, or it's a low-value meeting), capture with the generic labels and add a one-line note under `## Transcript` that speakers were not identified.
   - **Krisp often re-labels the transcript but not the Action Items / Key Points** — those can still say `Speaker_3` after a re-pull. Map those to the now-named speaker from transcript context when rendering (e.g. `Speaker_3` → `Jane Doe`).

5. **Fetch and render each meeting to capture.**
   - You already have Krisp's **rendered** markdown (Key Points, Action Items, Transcript) from the `get_multiple_documents` call in step 4 — this is the primary content source.
   - Call `mcp__krisp_search_meetings` with `id: <meeting_id>` and `fields: ["name","date","url","attendees","speakers","is_recurring"]` for clean metadata.
   - Write `meetings/YYYY-MM-DD <title>.md`:

     ```markdown
     ---
     title: "<meeting title>"
     date: <YYYY-MM-DD>
     meeting_id: <Krisp meeting id>
     source: krisp
     area: work
     participants: [<Krisp `attendees` — the roster>]
     speakers: [<Krisp `speakers` — those who actually spoke>]
     url: <Krisp meeting url>
     synced: <YYYY-MM-DD>
     ---

     # <meeting title>

     ## Key Points
     <Krisp's key points, verbatim — omit this heading if Krisp produced none>

     ## Action Items
     - [ ] <Krisp action item> — <assignee, due date if Krisp gave them>

     ## Transcript
     <transcript, verbatim>
     ```

   - **Participants vs speakers:** `participants` = Krisp's `attendees` field (the invited/joined roster); `speakers` = Krisp's `speakers` field (those actually detected speaking). Populate each from its respective Krisp field; use an empty list `[]` if a field is absent. Do not merge them.
   - **Render Krisp's content verbatim.** Keep Krisp's own wording (including its US spelling) — it is captured data, not your prose. Tidy only obvious artefacts (empty duplicate headings, an empty "Transcript 1" block) and apply the **known-mangling glossary** above (a misheard name is a transcription error, not the speaker's wording).
   - **Omit any section Krisp did not produce.** Do not invent a Summary/Key Points/Action Items section. Do **not** rely on the Outline — Krisp's "Generate Outline" often stays manual and may never be present.
   - **If Krisp has only a transcript** (notes not generated yet): write the note with the transcript and set **`notes_pending: true`** in the frontmatter. The next sync will upgrade it once Krisp's notes exist (step 3). Tip: the user can make Krisp generate notes automatically by setting a default template in Krisp → Settings → AI Note Taker → Templates (Pro plan; Free caps at 2 notes/day).

6. **Re-index.** If at least one note was written or upgraded, run `qmd update && qmd embed`. Otherwise skip.

7. **Report.** Concisely: meetings found in the window; new notes written (filenames); notes upgraded from `notes_pending`; meetings that paused awaiting speaker assignment in Krisp; meetings skipped as already-captured; any glossary normalisations applied and any unrecognised name flagged; and confirm the re-index ran.

## Notes

- `meeting_id` is the dedupe key — always populate it from the stable Krisp id, never the title or date.
- **Provenance:** the known-mangling glossary and the normalise-at-sync rule came from `brain-dream 2026-07-30` — normalising here, once, is what stops a mangled name reaching a published artefact; leaving it to each downstream skill demonstrably does not.
- This is the manual trigger; whether the harness offers scheduling is in the harness reference.
