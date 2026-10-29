# Pane fixtures

Verbatim `command tmux capture-pane -p` output, one file per harness state. These are the
ground truth for the chrome patterns in `skills/_shared/lib/harness-chrome.sh` (spec §4.4)
and are consumed by `harness-chrome.test.sh` / `teardown-worker.test.sh`.

**Never edit a fixture.** If a harness changes its chrome, recapture and update this README.
No comment line ever goes inside a fixture — provenance lives here only.

## Files

| File | Captured | Harness | Version | State |
|---|---|---|---|---|
| `claude/launch-typed.txt` | 2026-09-15 | Claude Code | 2.1.272 | shell prompt with the launch command typed, not yet run |
| `claude/trust.txt`        | 2026-09-15 | Claude Code | 2.1.272 | folder-trust prompt (first run in an unknown cwd) |
| `claude/ready.txt`        | 2026-09-15 | Claude Code | 2.1.272 | idle composer after a finished turn |
| `claude/busy.txt`         | 2026-09-15 | Claude Code | 2.1.272 | shell tool running (`sleep 20 && echo done`) |
| `claude/question.txt`     | 2026-09-15 | Claude Code | 2.1.272 | `AskUserQuestion` dialog awaiting an answer |
| `claude/ready-ghost.txt`  | 2026-09-17 | Claude Code | (macOS, live) | idle composer showing an unsent autosuggestion "ghost" (dim/faint text, Tab to accept) — synthetic: `claude/ready.txt` with its bare composer line replaced by a byte-for-byte reproduction of a real dim-wrapped composer line captured live off a genuinely-idle macOS worker pane (`tmux capture-pane -p -e`); everything else is unstyled `ready.txt` content, since only the composer line's styling matters to the check |
| `claude/busy-draft.txt`   | 2026-09-17 | Claude Code | (macOS, live) | idle-looking composer holding a REAL unsent draft (normal weight, no dim wrapper) — synthetic, same construction as `ready-ghost.txt` but without the `ESC[2m` wrapper, to prove a genuine draft is never mistaken for a ghost |
| `claude/busy-bg-agents.txt` / `-styled.txt` | 2026-10-02 | Claude Code | (linux, live) | turn ENDED (bare composer, no spinner) while a background subagent still runs — busy. Live worker `brain-worker-budgebell-linux-quiet-probes`, `capture-pane -p` / `-p -e`, `-S -40`, 125 columns. Shows Claude Code's agent panel under the footer: `  ● main` and `  ◯ general-purpose  <activity>  2m 25s · ↓ 70.5k tokens`. The `[Opus 5.5] …`, `Context/Usage` and `◐/✓ agent […]` rows are the user's claude-hud statusline plugin, not Claude Code |
| `claude/busy-agent-notification.txt` / `-styled.txt` | 2026-10-02 | Claude Code | (linux, live) | the same pane one 15 s poll after its last agent finished (the previous poll's panel row read `3m 30s · ↓ 76.9k tokens`; the agent's `● Agent "…" finished · 3m 43s` notification rendered only on the NEXT poll, so it is not in this capture): agent panel gone, footer now also says `/tasks to see subagents`, claude-hud still shows a stale `◐` — and claude is already HANDLING the agent notification: `✢ Beaming… (2s · thinking)` above the composer, a spinner with no token count yet — busy. First committed as `ready-after-bg-agents*.txt` and asserted idle; renamed (bytes unchanged) after review spotted the spinner. No capture of the truly-idle moment after it exists; the tests cut the two spinner lines out of this capture to stand for it |
| `claude/busy-bg-shell.txt` / `-styled.txt` | 2026-10-02 | Claude Code | (linux, live) | turn ENDED (bare composer, no spinner, `✻ Worked for 1m 51s · done 13:10 · 1 shell still running`) while a `run_in_background` shell (a CI watch) still runs — busy: claude re-invokes itself when the shell exits. Live worker `brain-worker-budgebell-log-utc`, `capture-pane -p` / `-p -e`, 125 columns, saved read-only by the coordinator. The footer reads `⏵⏵ auto mode on · 1 shell · ← for agents` (the `1 shell` segment replaces `(shift+tab to cycle)`). Contains `Ran 2 shell commands` summaries, which are not a signal |
| `claude/ready-after-bg-shell.txt` / `-styled.txt` | 2026-10-02 | Claude Code | (linux, live) | the same pane as `busy-bg-shell*.txt` after its shell exited and the wake-up turn ended — idle. Captured read-only (`capture-pane -p` / `-p -e`, visible screen) at 13:15:54 on a 20 s poll of `brain-worker-budgebell-log-utc`. Sequence seen: 13:13:34 footer `· 1 shell ·`; 13:13:54 footer back to `(shift+tab to cycle) · ← for agents`, the done line REWRITTEN in place to `✻ Worked for 1m 51s · done 13:10` (suffix dropped), `● Background command "…" completed (exit code 0)` and a `· Metamorphosing… (9s · ↓ 341 tokens · thinking)` spinner (busy); this capture: `✻ Churned for 29s · done 13:14`, bare composer, unchanged on the next poll |
| `claude/busy-thinking.txt` / `-styled.txt` | 2026-10-02 | Claude Code | (linux, live) | main turn running: `✽ Pouncing… (1m 0s · ↓ 4.2k tokens · thought for 1s)` — the minutes, `k` count and trailing segment the 2.1.272 regex missed; the `-e` copy splits the suffix with SGR codes. Live worker `brain-worker-budgebell-log-utc`; also shows the stale `✻ Waiting for 1 background agent to finish` line after its agent finished |
| `claude/rc-already-connected.txt` | 2026-10-19 | Claude Code | 2.1.303 | Remote Control "already connected" dialog — `/rc other-name` typed into a throwaway session launched as `claude --remote-control rc-flag-test` (so already connected). `capture-pane -p`, 120×40. The dialog replaces the composer; the `/remote-control is active · …` banner above it is the live connected state. Footer `Enter to select · Esc to continue`; `Escape` dismissed it back to the composer, connection and name untouched |
| `claude/busy-rc-dialog-text.txt` | 2026-10-19 | Claude Code | (synthetic) | busy pane whose transcript PRINTS the "already connected" dialog mid-scroll (a tool `cat`ing `rc-already-connected.txt`) with the normal spinner + composer below — NOT the dialog. Synthetic: `busy.txt` lines 1–16 and 18–30 around a `● Bash(cat …)` tool block holding `rc-already-connected.txt` lines 31–40 indented as tool output |
| `omp/launch-typed.txt`    | 2026-09-15 | omp | 18.1.19 | shell prompt with the launch command typed, not yet run |
| `omp/ready.txt`           | 2026-08-21 | omp | 18.1.16 | idle composer (lifted from `teardown-worker.test.sh`) |
| `omp/busy.txt`            | 2026-08-21 | omp | 18.1.16 | tool running (lifted from `teardown-worker.test.sh`) |
| `omp/question.txt`        | 2026-08-21 | omp | 18.1.16 | `Allow tool:` approval dialog (lifted from `teardown-worker.test.sh`) |

The three 18.1.16 omp fixtures are the heredocs that used to live in
`skills/brain-collect/scripts/teardown-worker.test.sh`; they are byte-identical to those
heredocs. `omp/launch-typed.txt` was captured fresh on 2026-09-15 (omp 18.1.19).
There is no `omp/trust.txt`: omp has no folder-trust prompt.

## Distinguishing strings

### Claude Code 2.1.272

| State | Distinguishing string (grep-able) | Notes |
|---|---|---|
| composer present | the line `❯ ` where the separator is **U+00A0** (no-break space), i.e. `grep -qxF $'❯ '` | present in `ready` and `busy` only — the omp analogue of `π >` |
| busy | `(<n>s · ↓ <n> tokens)` on the spinner line, regex `\([0-9]+s · ↓ [0-9]+ tokens\)`; secondary: `(ctrl+b ctrl+b (twice) to run in background)` while a shell tool runs | a **finished** turn instead reads `· done HH:MM`, so match `tokens)`, never the bare `·` |
| question | `Enter to select · ↑/↓ to navigate · Esc to cancel` | the dialog replaces the composer, so the composer line is absent |
| trust | `Is this a project you created` and `Yes, I trust this folder` | its footer is `Enter to confirm · Esc to cancel` — deliberately different from the question footer, so the two do not collide. Default selection is **`No, exit`**: answer `Down` then `Enter`, not `Enter` alone |
| rc already connected (2.1.303) | the dialog's shape at the screen bottom: last non-blank line `Enter to select · Esc to continue`, `[❯ ]Continue` and `[❯ ]Disconnect this session` option lines within the last 12 non-blank lines, no composer `❯`/`───` rule after them — never the strings anywhere (`claude/busy-rc-dialog-text.txt`) | `/rc` typed into a session already connected to Remote Control; counts as a question, never as a fresh connect. Answer `Escape`, never `Enter`. See `claude/rc-already-connected.txt` |
| launch-typed | `claude "Read your worker brief` | also present in `trust.txt` (the typed line scrolls above the dialog), so it identifies the launch, never the state |
| busy (spinner, live forms) | `(<elapsed> · ↓ <n>[.n][k\|M] tokens[ · <segment>])`, elapsed `30s` or `1m 0s`, segment e.g. `thinking`, `thought for 1s` | SGR-stripped first — a `-e` capture splits `↓` from the count with colour codes. See `claude/busy-thinking*.txt` |
| busy (spinner, before any tokens) | the whole line `<glyph> <Verb>… (<elapsed>[ · <segment>])`, regex `^[^ ]+ [^ ]+… \(([0-9]+[hm] )*[0-9]+s( · [^)]*)?\) *$`, e.g. `✢ Beaming… (2s · thinking)` | the first seconds of a turn. Anchored so `✻ Crunched for 13m 4s · done 12:42` (finished) and prose quoting a spinner never match. See `claude/busy-agent-notification*.txt` |
| busy (background agents) | an agent-panel row ending `<elapsed> · ↓ <n>[k] tokens` with NO parentheses, regex `^ +[^ ].* [0-9]+s · ↓ [0-9]+(\.[0-9]+)?[kM]? tokens *$` | the row exists only while the agent runs; it vanished within one 15 s poll of the agent's `finished` notification. NOT signals: the `●`/`◯` row glyphs (panel selection), the footer hints `← for agents` and `/tasks to see subagents` (shown with no agent running), `✻ Waiting for N background agent to finish` (stays in scrollback after the agent finishes), and claude-hud's `◐ agent` rows (user plugin, stale) |
| busy (background shell) | an indented footer segment `· <n> shell[s]` followed by ` · ` or end of line, regex `^ +[^ ].* · [0-9]+ shells?( · .*)? *$`, e.g. `  ⏵⏵ auto mode on · 1 shell · ← for agents` | a turn that ended with a background shell still running. Plural `shells` is inferred, never observed. the segment vanished within one 20 s poll of the shell exiting (`claude/ready-after-bg-shell*.txt`). NOT signals: the column-0 done line `✻ Worked for … · done HH:MM · 1 shell still running` (claude rewrote it to drop the suffix when the shell exited, but it is transcript and scrolls off the capture; the footer is pinned) and `Ran N shell commands` summaries. See `claude/busy-bg-shell*.txt` |
| ready | composer present AND NOT busy AND NOT question | same composition as omp's `pane_idle` |
| ready (ghost) | same composer check, but only after `strip_dim_ghost` removes an `ESC[2m...ESC[0m` span — Claude Code renders an unsent autosuggestion in that dim/faint SGR, distinct from a genuine unsent draft (never dim). A `-e` (styled) capture is required for `pane_ready` to make this distinction at all — a plain `-p` capture has already discarded the signal, so `pane_capture_flags claude` returns `-e` | see `claude/ready-ghost.txt` vs `claude/busy-draft.txt` |

There is **no** `esc to interrupt` string in 2.1.272 — do not pattern on it. The spinner
verb rotates (`Galloping…`, `Tinkering…`, `Brewed`, `Sautéed`), so never match the verb.
`⏵⏵ auto mode on (shift+tab to cycle)` appears in `ready` and `busy` but depends on the
user's permission mode, and the `Context …/Usage …` line comes from the user's custom
statusline — neither is safe to pattern on.

### omp 18.1.16

| State | Distinguishing string |
|---|---|
| ready | `π >` present and no spinner / `⚙ [1-9]` |
| busy | `⚙ [1-9]`, braille spinner (`⠼`), elapsed `28s >` |
| question | `Allow tool:`, `up/down navigate`, `enter select`, `esc cancel` |
| launch-typed | `omp --auto-approve "Read your worker brief` |
| trust | n/a — omp has no folder-trust prompt |

## How the Claude Code set was captured

```
mkdir /tmp/fx-capture-XXXX                       # a never-opened dir triggers the trust prompt
command tmux new-session -d -s fx-claude -x 100 -y 30 -c /tmp/fx-capture-XXXX
# type the launch command WITHOUT Enter        -> launch-typed.txt
# Enter, sleep 5                               -> trust.txt
# Down, Enter, wait for the turn to finish     -> ready.txt
# `run: sleep 20 && echo done`, Enter, sleep 8 -> busy.txt
# `ask me a yes/no question using your question tool`, Enter, sleep 12 -> question.txt
command tmux kill-session -t fx-claude
```

Pane geometry was 100x30; captures therefore wrap at 100 columns and carry trailing blank
rows. Patterns must not assume a width.
