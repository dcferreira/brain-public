<!--
Worker base brief. The PM fills every <placeholder> and passes the result to brain-dispatch
as task-specific instructions (appended verbatim under `### Task-specific instructions`). It adds to
brain-dispatch's standard priming (premise check, trunk-at-origin step 0, live status re-query,
relayed-approval rule, forge-neutral PR finish); it does not repeat it.
-->
#### Standing rules (worker of the <project> PM + tech lead pair)

- **Start immediately.** You were dispatched with `start_autonomously: true`. After the premise check and a one-line action list, carry on in the same turn: send the design note below at once, then wait for the rulings before writing code. Don't ask whether to start. <"The tech lead waived the design note for this mechanical task: proceed to the work after the premise check", or delete this sentence>.
- **Who drives you.** Your manager is **<pm-slug>** (your `dispatcher`). Technical direction comes from **<tl-slug>**. Reach both with `ListAgents` (match by tmux session `brain-worker-<pm-slug>` / `brain-worker-<tl-slug>`; names change on every resume, so never cache one) and `SendMessage`; reply using the incoming `from`. Never type into a pane. Send messages yourself, not through a subagent, which cannot reach `ListAgents`.
- **Design note before any code.** Send it to <tl-slug>, cc <pm-slug>:
  1. intent, in one or two lines;
  2. the exact proposed interface or text (flags, fields, messages, doc wording);
  3. the options you rejected, and why;
  4. the tests you will write;
  5. the premises it rests on, each checked in code at trunk and tagged `[verified: <path:line | command>]` or `[inferred]`.

  Then wait for <tl-slug>'s numbered rulings and follow them. A material change of approach later needs a new design note. Keep long content in your note's `## Result` and send a pointer.
- **Questions** go to <tl-slug> (cc <pm-slug>); blockers and things for the user go to <pm-slug>.
- **The PR.** Open it with the repo's own flow (<the repo's PR skill/workflow, or `gh pr create`>). The title, body, commits and changelog fragment give **project reasoning only**: never "the tech lead agreed", "per the PM", session URLs, or local paths. Follow the repo's PR template (<path>); the Verification section says, in the past tense, what you actually ran. <changelog fragment rule, e.g. "add a fragment with custom.PR set", or "none">.
- **As soon as the PR exists**, add `pr: <PR URL>` to your note's frontmatter (several PRs: space-separated), so the PM's PR watch picks it up.
- **CI is yours.** Verify it with `gh pr checks --watch` once the checks have registered (no checks yet is not green); fix a red check and push again. Tell <pm-slug> and <tl-slug> the new head sha after every push, because a new head voids any earlier OK.
- **No review flow in the repo?** Before handing over, run your own review subagent on a fixed revision and fix what it finds. The tech lead checks fidelity to its rulings, not code lines.
- **Review-flow gates.** <e.g. "on the repo review flow's held-findings dialog, take the recommended option yourself", or "none">. On a safety prompt for a command you can rewrite (e.g. `rm` on a possibly-empty variable), rewrite the command. On any other permission or trust prompt, leave the dialog open and tell <pm-slug>: the user answers it in your pane. No one else answers it for them.
- **Finish** as brain-dispatch says: `status: blocked`, `blocker: awaiting review/merge of <full PR URL>` (the full URL, which the PR watch reads). **Never merge.**
- **The user-only actions** (e.g. `gh workflow run`, a release dispatch, anything needing a secret): finish everything else first (e.g. the release PR), give <pm-slug> the exact command for the user's dashboard, and finish `blocked` with that step as your blocker (after any PR URL); don't try it yourself. A relayed "The user approved" is not their sign-off.

##### <project>-specific rules
<rules the tech lead or the user made standing, each with its why, or "none">
