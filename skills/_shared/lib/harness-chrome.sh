#!/usr/bin/env bash
#
# harness-chrome.sh — the harness axis (omp | claude): what a pane looks like and what
# command launches it. Spec §4.4. This is the ONLY place harness chrome strings and
# launch commands live; brain-dispatch's launch-worker.sh (ready poll, trust prompt,
# typed-line verification) and brain-collect's teardown-worker.sh (idle gate) both
# source it, so no SKILL.md prose and no script ever hard-codes a harness string.
#
# Pure functions, no side effects: nothing here launches, types into, or reads a pane —
# callers pass the already-captured pane text as an argument. Only bash builtins plus
# grep, sed and awk are used, and every function returns non-zero rather than exiting, so
# the file is safe to `source` under a caller's `set -e`/`set -u`.
#
# Functions (every one takes the harness as $1):
#   launch_cmd          <harness> <brief_path> [model] [session_id] [rc_name]
#                                                prints the full command line to type
#   launch_marker       <harness> [model] [session_id] [rc_name]
#                                                prints the substring proving the typed line arrived
#   resume_cmd          <harness> <id> [model] [rc_name]
#                                                prints the command line resuming conversation <id>
#   resume_marker       <harness> [model] [rc_name]
#                                                prints the prefix proving the resume line arrived
#   valid_session_id    <harness> <id>           rc 0 when <id> is safe to type as that harness's id
#   pane_ready          <harness> <pane-text>    rc 0 when the composer is up and free
#   pane_capture_flags  <harness>                extra `tmux capture-pane` flags this harness needs
#   pane_busy           <harness> <pane-text>    rc 0 when a tool/turn is running
#   pane_question       <harness> <pane-text>    rc 0 when a prompt/dialog awaits an answer
#   pane_trust_prompt   <harness> <pane-text>    rc 0 only for claude's folder-trust prompt
#   pane_idle           <harness> <pane-text>    ready && !busy && !question
#   pane_harness_up     <harness> <pane-text>    rc 0 when the harness owns the pane, ready OR busy
#   pane_rc_connected   <harness> <pane-text>    rc 0 when a Remote Control session is up
#   pane_rc_dialog      <harness> <pane-text>    rc 0 while claude's RC "already connected" dialog shows
#   pane_question_text  <harness> <pane-text>    prints the pending question as one line:
#                                                `<header>: <question> [1 <opt> / 2 <opt>]`
#   pane_last_message   <harness> <pane-text>    prints the first line of the last assistant message
#   persist_worker_text <harness>                the scoped-persist line a worker is sent
#   rc_connect_text     <harness> <slug>         the Remote Control line to type (claude: none —
#                                                named at launch); rc 1 = no Remote Control
#   valid_harness       <harness>                rc 0 for omp|claude
#
# Chrome provenance: skills/_shared/lib/fixtures/README.md, with one captured
# `tmux capture-pane -p` fixture per state. The omp patterns are the observed chrome of
# omp 18.1.16, copied verbatim from the old `pane_idle` in teardown-worker.sh; the claude
# patterns are Claude Code 2.1.272. If a harness rewords its chrome, recapture the
# fixture, update the README, and fix the pattern here — nowhere else.

set -u

# Claude Code's composer prompt line: `❯` + U+00A0 (no-break space) and nothing else.
# Written as explicit bytes so no editor can silently normalise the NBSP to a space.
CLAUDE_COMPOSER_LINE=$'\xe2\x9d\xaf\xc2\xa0'

# strip_dim_ghost — reads a pane capture on stdin, writes it back with two things removed:
# (1) any ESC[2m...ESC[0m span, content included — Claude Code's rendering for an unsent
#     autosuggestion "ghost" sitting in the composer (the terminal analogue of a zsh/fish
#     autosuggestion: grey text, Tab to accept, never actually typed); (2) any other bare
#     SGR code (`ESC[...m`), which carries no content and is safe to drop everywhere.
# A REAL unsent draft renders in normal weight (no ESC[2m), so it survives this untouched
# and still fails the composer's exact-line match below — only a genuine autosuggestion
# reduces to the bare line. On a plain (non-`-e`) capture there are no escape codes to
# strip at all, so this is a no-op and safe to apply unconditionally to any pane text.
# Grounded in a live capture (`tmux capture-pane -p -e`) of an idle Claude Code pane:
# `\x1b[39m` + `❯` + NBSP + `\x1b[2m<suggested text>\x1b[0m` — see fixtures/README.md.
strip_dim_ghost() {
    sed -E 's/\x1b\[2m[^\x1b]*\x1b\[0m//g; s/\x1b\[[0-9;]*m//g'
}

# strip_sgr — reads a pane capture on stdin, writes it back with every SGR code
# (`ESC[...m`) removed and ALL content kept. Unlike strip_dim_ghost it never drops a dim
# span's text: the readers below (pane_question_text, pane_last_message) must not lose a
# dim-styled line just because it is faint. A no-op on a plain (non-`-e`) capture. The ESC
# byte is spliced in by bash rather than written `\x1b`, which BSD sed does not understand.
# Also drops OSC sequences (`ESC ] … ESC \` or `… BEL`) — a `-e` capture keeps Claude
# Code's OSC 8 hyperlinks, `ESC]8;id=<id>;<url>ESC\<text>ESC]8;;ESC\`, around every
# link in a reply (seen live) — keeping the link TEXT.
strip_sgr() {
    local esc=$'\033' bel=$'\a'
    sed "s/${esc}\\[[0-9;]*m//g; s/${esc}[]][^${esc}${bel}]*${esc}\\\\//g; s/${esc}[]][^${esc}${bel}]*${bel}//g"
}

# valid_harness <harness> — rc 0 for the two supported harnesses, rc 1 for anything else.
valid_harness() {
    case "${1:-}" in
        omp|claude) return 0 ;;
        *) return 1 ;;
    esac
}

# launch_cmd <harness> <brief_path> [model] [session_id] — the full command line dispatch
# types into a fresh pane. omp needs `--auto-approve` (its approval dialog would otherwise
# block an unattended worker); claude takes no permission flags, because auto-accept mode
# is the user's own default. An optional [model] inserts `--model <model>` — both harnesses
# support one — right after the harness name and before its other flags; an empty or
# omitted [model] leaves the command byte-identical to before this parameter existed.
# An optional [session_id] (claude only) adds `--session-id <uuid>` after any `--model`,
# pinning the conversation id at launch so the worker can later be resumed by id
# (`resume_cmd`). omp has no flag to pin an id, so it IGNORES [session_id] and its line is
# unchanged; empty/omitted leaves claude's line unchanged too. rc 1 on an unknown harness.
#
# An optional [rc_name] (claude only) adds `--remote-control <rc_name>` after any `--model`
# and before `--session-id`: the session connects to Remote Control at startup under that
# name (verified on 2.1.303, and it wins over a host's `remoteControlAtStartup: true`).
# The flag's value is OPTIONAL in Claude Code, so a bare flag would swallow the next word
# as the name: it is only ever emitted with its value, and a name that is empty-but-given,
# starts with `-` or holds anything but [A-Za-z0-9._-] is refused (rc 1). omp ignores it.
launch_cmd() {
    local harness="${1:-}" brief="${2:-}" model="${3:-}" sid="${4:-}" rcn="${5:-}"
    local sentence="Read your worker brief at ${brief} and follow its priming, then greet me."
    local model_flag="" sid_flag="" rc_flag=""
    [ -n "$model" ] && model_flag="--model $(model_word "$model") "
    [ -n "$sid" ] && sid_flag="--session-id ${sid} "
    case "$harness" in
        omp)    printf '%s\n' "omp ${model_flag}--auto-approve \"${sentence}\"" ;;
        claude)
            rc_flag="$(rc_name_flag "$rcn")" || return 1
            printf '%s\n' "claude ${model_flag}${rc_flag}${sid_flag}\"${sentence}\"" ;;
        *) return 1 ;;
    esac
}

# model_word <model> — the model id as one safe shell word for the typed line: a plain id
# (letters, digits, . _ : / @ -) is unchanged; anything else (e.g. `claude-opus-5-5[1m]`,
# which zsh would glob and abort on) is single-quoted, embedded quotes escaped.
model_word() {
    local m="${1:-}"
    if [[ "$m" =~ ^[A-Za-z0-9._:/@-]+$ ]]; then printf '%s' "$m"
    else printf "'%s'" "${m//\'/\'\\\'\'}"; fi
}

# rc_name_flag <name> —`--remote-control <name> ` (trailing space) for a safe name, nothing
# for an empty one, rc 1 for an unsafe one (see launch_cmd).
rc_name_flag() {
    local n="${1:-}"
    [ -n "$n" ] || return 0
    [[ "$n" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 1
    printf '%s' "--remote-control ${n} "
}

# launch_marker <harness> [model] [session_id] — the substring dispatch greps for in the
# captured pane to prove the launch line arrived intact before pressing Enter. Deliberately
# short enough to survive the pane's hard wrap (both fixtures wrap mid-sentence at 100
# columns). It identifies the launch, never the state: it also scrolls above claude's trust
# dialog. [model] must match whatever was passed to launch_cmd, since `--model <id>` sits
# between the harness name and the rest of the marker text; empty/omitted reproduces the
# original marker unchanged.
#
# With a claude [session_id] the marker stops at `--session-id` — still a PREFIX of the
# typed line, so it still catches the known failure (a not-ready shell eating the leading
# characters) — and deliberately leaves the 36-char uuid out: prefix + uuid would wrap in
# a detached pane's default 80 columns. launch-worker.sh proves the uuid itself arrived with
# a separate, wrap-tolerant check. omp ignores [session_id], as launch_cmd does.
# With a claude [rc_name] it stops at `--remote-control` for the same reason (the slug and
# uuid after it are checked wrap-tolerantly by launch-worker.sh).
launch_marker() {
    local harness="${1:-}" model="${2:-}" sid="${3:-}" rcn="${4:-}"
    local model_flag=""
    [ -n "$model" ] && model_flag="--model $(model_word "$model") "
    case "$harness" in
        omp)    printf '%s\n' "omp ${model_flag}--auto-approve \"Read your worker brief" ;;
        claude)
            if [ -n "$rcn" ]; then
                printf '%s\n' "claude ${model_flag}--remote-control"
            elif [ -n "$sid" ]; then
                printf '%s\n' "claude ${model_flag}--session-id"
            else
                printf '%s\n' "claude ${model_flag}\"Read your worker brief"
            fi
            ;;
        *) return 1 ;;
    esac
}

# resume_cmd <harness> <id> [model] — the command line brain-revive-workers (via
# launch-worker.sh --resume) types to reopen an EXISTING conversation by id, instead of
# priming a fresh one from the brief. It carries no brief sentence at all, by design:
# revival must never start a new conversation. omp keeps `--auto-approve` for the same
# unattended-worker reason as launch_cmd; [model] sits where launch_cmd puts it. Callers
# validate <id> with valid_session_id first. rc 1 on an unknown harness or an empty <id>.
# [rc_name] (claude only) adds `--remote-control <rc_name>` before `--resume`, as launch_cmd
# does. Verified on 2.1.303: a resume that REATTACHES to the conversation's persisted Remote
# Control session keeps that session's original title — the name only applies when a new
# Remote Control session is minted.
resume_cmd() {
    local harness="${1:-}" id="${2:-}" model="${3:-}" rcn="${4:-}"
    local model_flag="" rc_flag=""
    [ -n "$id" ] || return 1
    [ -n "$model" ] && model_flag="--model $(model_word "$model") "
    case "$harness" in
        omp)    printf '%s\n' "omp ${model_flag}--auto-approve --resume ${id}" ;;
        claude)
            rc_flag="$(rc_name_flag "$rcn")" || return 1
            printf '%s\n' "claude ${model_flag}${rc_flag}--resume ${id}" ;;
        *) return 1 ;;
    esac
}

# resume_marker <harness> [model] [rc_name] — the resume line's counterpart to launch_marker:
# a short PREFIX of resume_cmd, stopping before the id (and, with a claude [rc_name], before
# the name) for the same wrap reason (an omp id may be a long session-file path).
# launch-worker.sh checks the id separately.
resume_marker() {
    local harness="${1:-}" model="${2:-}" rcn="${3:-}"
    local model_flag=""
    [ -n "$model" ] && model_flag="--model $(model_word "$model") "
    case "$harness" in
        omp)    printf '%s\n' "omp ${model_flag}--auto-approve --resume" ;;
        claude)
            if [ -n "$rcn" ]; then printf '%s\n' "claude ${model_flag}--remote-control"
            else printf '%s\n' "claude ${model_flag}--resume"; fi ;;
        *) return 1 ;;
    esac
}

# valid_session_id <harness> <id> — rc 0 when <id> is a well-formed conversation id for
# that harness, and therefore safe to type into a pane as a bare shell word. claude: a
# UUID (what `--session-id`/`--resume` take). omp: `--resume` accepts an id prefix or a
# session-file path, so `[A-Za-z0-9._/~-]+` — no spaces, quotes or shell metacharacters.
# A bash `=~` on the whole string, not a line-wise grep, so an embedded newline can never
# smuggle a second line past the check.
valid_session_id() {
    local harness="${1:-}" id="${2:-}"
    case "$harness" in
        claude) [[ "$id" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] ;;
        omp)    [[ "$id" =~ ^[A-Za-z0-9._/~-]+$ ]] ;;
        *) return 1 ;;
    esac
}

# persist_worker_text <harness> — the scoped-persist line collect sends a worker.
# omp addresses skills with the `/skill:` prefix; Claude Code with a bare slash command.
persist_worker_text() {
    case "${1:-}" in
        omp)    printf '%s\n' '/skill:brain-persist worker' ;;
        claude) printf '%s\n' '/brain-persist worker' ;;
        *) return 1 ;;
    esac
}

# rc_connect_text <harness> <slug> — the line dispatch types into a verified-ready pane to
# connect the worker to Remote Control. rc 1 (printing nothing) for a harness that has no
# Remote Control at all — that rc gates the whole feature in launch-worker.sh, so no caller
# needs to name a harness to decide.
#
# claude: rc 0 and prints NOTHING. The worker is named at launch by `--remote-control <slug>`
# (launch_cmd/resume_cmd), and a typed `/rc <slug>` on an already-connected session ignores
# the name and opens the blocking "already connected" dialog (pane_rc_dialog) — which every
# `--resume` (auto-reconnect) and every launch on a `remoteControlAtStartup: true` host hit.
rc_connect_text() {
    local harness="${1:-}"
    case "$harness" in
        omp)    return 1 ;;
        claude) return 0 ;;
        *) return 1 ;;
    esac
}

# pane_rc_dialog <harness> <pane> — rc 0 while Claude Code's Remote Control "already
# connected" dialog is up (fixtures/claude/rc-already-connected.txt, 2.1.303): `/rc` typed
# into a session that is already connected. It replaces the composer and blocks the worker.
# Anchored on the dialog's SHAPE at the bottom of the screen, never on its strings anywhere
# (a worker printing them — `cat`ing the fixture — is not blocked): the last non-blank line
# is the footer `Enter to select · Esc to continue`, and the option lines
# `[❯ ]Disconnect this session` and `[❯ ]Continue` sit within the last 12 non-blank lines
# with no composer (`❯` alone) or `───` rule between them and the footer.
# ANSWERING IT (this only detects): `Escape` — it and the
# default `Continue` both just dismiss, connection untouched; never Enter, which would pick
# `Disconnect this session` if the highlight ever moved. omp: rc 1 always.
pane_rc_dialog() {
    local harness="${1:-}" pane="${2:-}" p
    case "$harness" in
        claude)
            p="$(printf '%s\n' "$pane" | strip_sgr | sed $'s/\xc2\xa0/ /g; s/[[:space:]]*$//' \
                | grep -v '^[[:space:]]*$' | tail -n 12)"
            [ "$(tail -n 1 <<<"$p" | sed 's/^[[:space:]]*//')" = 'Enter to select · Esc to continue' ] || return 1
            grep -qE '^[[:space:]]*(❯[[:space:]]*)?Continue$' <<<"$p" || return 1
            p="$(sed -n '/^[[:space:]]*\(❯[[:space:]]*\)\{0,1\}Disconnect this session$/,$p' <<<"$p")"
            [ -n "$p" ] || return 1
            ! grep -qE '^[[:space:]]*❯$|(─){8,}' <<<"$p"
            ;;
        *) return 1 ;;
    esac
}

# pane_rc_connected <harness> <pane> — rc 0 when the pane shows a live Remote Control
# session: claude 2.1.303 prints `/remote-control is active · Continue here, on your phone,
# or at` + the claude.ai/code URL above the composer. The grep is the original
# `remote control|claude.ai/code` plus that banner's `remote-control is active` (never a bare
# `remote-control`, which the typed `--remote-control` launch line also holds),
# case-insensitive. Vetoed while the "already connected"
# dialog is up (pane_rc_dialog): that dialog names Remote Control and the URL too, but it
# is a blocked pane, not a fresh named connect. omp: rc 1 always.
pane_rc_connected() {
    local harness="${1:-}" pane="${2:-}"
    case "$harness" in
        omp) return 1 ;;
        claude)
            pane_rc_dialog "$harness" "$pane" && return 1
            printf '%s' "$pane" | grep -qiE 'remote control|remote-control is active|claude\.ai/code' && return 0
            return 1
            ;;
        *) return 1 ;;
    esac
}

# pane_busy <harness> <pane> — rc 0 while a tool or turn is running.
#
# omp: the spinner bar (`⚙ <n>` for running tools, a braille frame, or `esc to
# interrupt`) replaces the composer. Copied verbatim from teardown-worker.sh.
#
# claude 2.1.272: key ONLY on the spinner's token suffix `(<n>s · ↓ <n> tokens)` and on
# the shell-tool hint. A FINISHED turn reads `· done HH:MM` on the same kind of line, so
# matching a bare `·` or the elapsed seconds would read every idle pane as busy. There is
# no `esc to interrupt` string in 2.1.272; the spinner verb rotates (Galloping…,
# Tinkering…, Brewed, Sautéed) so it is never matched; `⏵⏵ auto mode on` and the
# `Context …/Usage …` statusline appear in both ready and busy and are not safe either.
# The count is `<n>`, `<n.n>k` or `<n.n>M`, and the suffix may carry a trailing segment:
# live panes show `(39s · ↓ 3.6k tokens)` and `(30s · ↓ 1.6k tokens · thinking)`
# (fixtures/claude/busy-thinking.txt) — the original `[0-9]+ tokens\)` missed both.
#
# Background subagents (fixtures/claude/busy-bg-agents*.txt): a worker that ENDED its
# turn while agents it launched in the background still run shows an empty composer and
# no spinner, yet it is working — the agent's completion notification wakes it. Claude
# Code then shows its agent panel under the footer, one row per agent plus `main`:
#     ● main
#     ◯ general-purpose  <current activity>          3m 6s · ↓ 75.5k tokens
# Key on that row's UNparenthesised, end-of-line `<elapsed> · ↓ <n> tokens`: the live
# download arrow `↓` only exists while the agent streams, and the panel drops the row the
# moment the agent finishes (observed on 15 s polls: the row read `3m 30s · ↓ 76.9k
# tokens`, the next poll had no panel at all, and the agent's notification then reported
# `● Agent "…" finished · 3m 43s`). Deliberately NOT matched:
# the row glyphs `●`/`◯` (they mark the panel selection, not run state); the footer hints
# `← for agents` / `/tasks to see subagents` (shown with no agent running too); the
# `✻ Waiting for N background agent to finish` line (it stays in scrollback after the
# agent finishes); the claude-hud `◐ agent […]` statusline rows (a user plugin, and stale
# — still `◐` after the agent finished). fixtures/claude/busy-agent-notification.txt is
# the same pane one poll after its agent finished: panel gone, hud still `◐`, but claude
# is already handling the agent's notification — `✢ Beaming… (2s · thinking)`, a spinner
# with NO token count yet, matched by the verb-ellipsis pattern below → busy.
#
# Background shells (fixtures/claude/busy-bg-shell*.txt): same class — a worker that ENDED
# its turn with a `run_in_background` shell still running (e.g. a CI watch) shows an empty
# composer and no spinner, yet claude re-invokes itself when the shell exits. Claude Code
# then puts a `<n> shell` segment in the footer, in place of `(shift+tab to cycle)`:
#     ⏵⏵ auto mode on · 1 shell · ← for agents
# Key on that indented footer segment `· <n> shell[s]` followed by ` · ` or end of line.
# The plural `shells` is inferred, not observed. Observed on 20 s polls: the segment
# vanished on the first poll after the shell exited, the footer went back to `(shift+tab
# to cycle)`, and claude was already handling the `Background command … completed`
# notification under a normal spinner (fixtures/claude/ready-after-bg-shell*.txt is the
# idle pane once that turn ended). Deliberately NOT matched: the done line
# `✻ Worked for 1m 51s · done 13:10 · 1 shell still running` — claude rewrote it in place
# to drop the suffix when the shell exited, but it is transcript, not pinned chrome, so
# it scrolls off the visible capture while the footer never does — and the
# `Ran 2 shell commands` tool summaries (no `· ` before the count).
CLAUDE_TOKENS='↓ [0-9]+(\.[0-9]+)?[kM]? tokens'
pane_busy() {
    local harness="${1:-}" pane="${2:-}"
    case "$harness" in
        omp)
            printf '%s' "$pane" | grep -qE '⚙ [1-9]|esc to interrupt' && return 0
            # Alternation, NOT a bracket expression: under a non-UTF-8 locale (a bare
            # `ssh`/`zsh -lc` on a remote host can have LANG unset) BSD grep reads a bracket
            # expression BYTE by byte, so `[⠋⠙...]` matches any single byte of those
            # sequences — including the 0xE2 lead byte every box-drawing and arrow
            # character in an idle pane shares, making every pane read as busy.
            printf '%s' "$pane" | grep -qE '⠋|⠙|⠹|⠸|⠼|⠴|⠦|⠧|⠇|⠏' && return 0
            return 1
            ;;
        claude)
            # SGR stripped first: a `-e` capture (what pane_capture_flags asks for) splits
            # the spinner suffix with colour codes — `(30s · ↓ESC[39m ESC[38;5;246m1.6k
            # tokens …` — so an unstripped grep never sees a styled pane as busy. The greps
            # read a here-string, not a pipe: every caller runs under `pipefail`, where
            # `printf | grep -q` on a multi-KB pane can fail with SIGPIPE when grep exits
            # on its first match while printf is still writing — a missed busy pane.
            local p
            p="$(printf '%s\n' "$pane" | strip_sgr)"
            grep -qE "\\(([0-9]+[hm] )*[0-9]+s · ${CLAUDE_TOKENS}( · [^)]*)?\\)" <<<"$p" && return 0
            # the verb-ellipsis spinner before any token count has arrived — the first
            # seconds of a turn: `✢ Beaming… (2s · thinking)` (busy-agent-notification.txt).
            # Anchored to the whole line (glyph, ONE verb word, `…`, the parenthesised
            # elapsed time) so the finished `✻ Crunched for 13m 4s · done 12:42` line and
            # prose that quotes a spinner never match.
            grep -qE "^[^ ]+ [^ ]+… \\(([0-9]+[hm] )*[0-9]+s( · [^)]*)?\\) *\$" <<<"$p" && return 0
            grep -qF '(ctrl+b ctrl+b (twice) to run in background)' <<<"$p" && return 0
            grep -qE "^ +[^ ].* [0-9]+s · ${CLAUDE_TOKENS} *\$" <<<"$p" && return 0
            grep -qE "^ +[^ ].* · [0-9]+ shells?( · .*)? *\$" <<<"$p" && return 0
            return 1
            ;;
        *) return 1 ;;
    esac
}

# pane_question <harness> <pane> — rc 0 while a dialog awaits a human answer. A hard veto
# on idle: this is what prevents collect killing a worker mid-question.
#
# omp: the `Allow tool:` approval box and its `up/down navigate  enter select  esc cancel`
# footer, plus the `ask` dialog wordings. Copied verbatim from teardown-worker.sh.
#
# claude: also the Remote Control "already connected" dialog (pane_rc_dialog, 2.1.303).
# claude 2.1.272: the AskUserQuestion dialog footer, which replaces the composer. Claude's
# tool-permission prompt could not be captured for the fixture set, so its documented
# wordings are listed here as a best-effort extra veto — unverified against a real pane,
# asserted only against a dialog built from question.txt's option shapes, and anchored to
# that dialog structure (wording, then a `❯ 1.` option) so assistant prose never matches. Note the trust prompt's footer is `Enter to confirm ·
# Esc to cancel`, deliberately different, so the two never collide.
pane_question() {
    local harness="${1:-}" pane="${2:-}"
    case "$harness" in
        omp)
            printf '%s' "$pane" | grep -qiE 'Allow tool:|up/down navigate|esc cancel|Do you want|Select an option' && return 0
            return 1
            ;;
        claude)
            printf '%s' "$pane" | grep -qF 'Enter to select · ↑/↓ to navigate · Esc to cancel' && return 0
            pane_rc_dialog "$harness" "$pane" && return 0
            # best-effort, uncaptured: the tool-permission prompt. Anchored to DIALOG
            # STRUCTURE — the wording only counts when the next non-blank line is a
            # selected numbered option (`❯ 1. Yes`, question.txt's option shape) — because
            # the same words in assistant prose (`● Do you want to proceed?`, possibly
            # still in scrollback) would otherwise read as a sticky open question.
            printf '%s\n' "$pane" | strip_sgr | awk '
                want && /^[[:space:]]*$/ { next }
                want { if ($0 ~ /^ *❯ [0-9]+\. /) { found = 1; exit } want = 0 }
                /^ *Do you want to (proceed|make this edit|create)/ { want = 1 }
                END { exit !found }' && return 0
            return 1
            ;;
        *) return 1 ;;
    esac
}

# pane_trust_prompt <harness> <pane> — rc 0 only for Claude Code's folder-trust prompt
# (first run in a directory it has never been opened in). omp has no such prompt and
# always returns rc 1.
#
# ANSWERING IT (this function only detects): the dialog's default selection is
# `No, exit`, so the correct keystrokes are `Down` then `Enter` — NOT `Enter` alone,
# which quits the harness and leaves dispatch staring at a dead pane.
pane_trust_prompt() {
    local harness="${1:-}" pane="${2:-}"
    case "$harness" in
        omp) return 1 ;;
        claude)
            printf '%s' "$pane" | grep -qE 'Is this a project you created|Yes, I trust this folder' && return 0
            return 1
            ;;
        *) return 1 ;;
    esac
}

# pane_ready <harness> <pane> — rc 0 when the harness's own composer is up AND free: the
# composer line is present and no busy/question/trust signature vetoes it.
#
# The composer line is what distinguishes a live harness from the SHELL PROMPT with the
# launch command merely typed into it (fixtures `launch-typed.txt`): that pane contains
# the launch text but no composer, so pane_ready is rc 1 on it. That is the false-ready
# guard dispatch relies on before it decides the worker is up.
#
# omp: `π >` on the composer/status bar. claude: the whole-line `❯`+U+00A0 prompt, which
# is present in both ready and busy panes — hence the vetoes below do the real work.
pane_ready() {
    local harness="${1:-}" pane="${2:-}"
    valid_harness "$harness" || return 1
    pane_busy "$harness" "$pane" && return 1
    pane_question "$harness" "$pane" && return 1
    pane_trust_prompt "$harness" "$pane" && return 1
    case "$harness" in
        omp)    printf '%s' "$pane" | grep -q 'π >' && return 0 ;;
        # strip into a variable, then grep a here-string: under the callers' `pipefail`,
        # `… | strip_dim_ghost | grep -q` flaked on a 68-line fixture (grep exits on the
        # composer line, sed is still writing → SIGPIPE → a ready pane read not-ready).
        claude) grep -qxF "$CLAUDE_COMPOSER_LINE" <<<"$(printf '%s' "$pane" | strip_dim_ghost)" && return 0 ;;
    esac
    return 1
}

# pane_harness_up <harness> <pane> — rc 0 when the HARNESS (not the shell) owns the pane
# and is either free (pane_ready) or running a turn (pane_busy). This is launch-worker's
# verify gate: a fresh worker is primed with its brief as the positional prompt, so its
# first turn may already be streaming when dispatch looks — busy, not ready, yet launched.
# pane_ready alone would time out "composer never appeared" on exactly that pane.
#
# Never true on the shell-with-launch-line pane (launch-typed.txt) — a busy match alone is
# not enough, the harness's own chrome must be there too: claude's composer line (`❯`+NBSP
# at column 0, bare or holding queued text; present in every busy fixture); omp's busy
# signature IS its status bar (busy.txt has no `π >`), so pane_busy suffices there. Also
# false while a question or trust dialog is up: launch-worker answers the trust prompt
# itself, and a dialog must never receive the `/rc` + Enter that follows verification.
# teardown's idle gate stays pane_idle — this is for "did it start", never "is it free".
pane_harness_up() {
    local harness="${1:-}" pane="${2:-}"
    valid_harness "$harness" || return 1
    pane_trust_prompt "$harness" "$pane" && return 1
    pane_question "$harness" "$pane" && return 1
    pane_ready "$harness" "$pane" && return 0
    pane_busy "$harness" "$pane" || return 1
    case "$harness" in
        omp) return 0 ;;
        claude) grep -q "^${CLAUDE_COMPOSER_LINE}" <<<"$(printf '%s' "$pane" | strip_dim_ghost)" && return 0 ;;
    esac
    return 1
}

# pane_capture_flags <harness> — extra `tmux capture-pane` flags this harness's chrome
# needs to be read correctly. claude: `-e` (preserve escape codes), so pane_ready can tell
# a dim-styled autosuggestion ghost apart from a genuine unsent draft via strip_dim_ghost
# above — both render as identical plain text once escapes are gone. omp's patterns are
# plain substring/regex matches (`π >`, spinner glyphs) with no such distinction to make,
# so it gets no extra flags — a stray per-character SGR code from `-e` risked splitting a
# match (see the C-locale bracket-expression bug above) for no benefit. rc 1, printing
# nothing, on an unknown harness.
pane_capture_flags() {
    case "${1:-}" in
        omp)    printf '\n' ;;
        claude) printf '%s\n' '-e' ;;
        *) return 1 ;;
    esac
}

# pane_idle <harness> <pane> — the teardown gate: ready && !busy && !question. Identical
# composition for both harnesses (pane_ready already applies the vetoes); kept as its own
# name because collect's Gate B reads as "is this pane idle", not "is it ready".
pane_idle() {
    local harness="${1:-}" pane="${2:-}"
    valid_harness "$harness" || return 1
    pane_busy "$harness" "$pane" && return 1
    pane_question "$harness" "$pane" && return 1
    pane_ready "$harness" "$pane"
}

# pane_question_text <harness> <pane> — when pane_question holds, prints the pending
# question as ONE line: `<header>: <question text, joined> [1 <opt1> / 2 <opt2> / ...]`.
# rc 1 (printing nothing) when no question dialog is showing, when the dialog's shape is
# not recognised, or on an unknown harness. SGR codes are stripped first, so a styled
# (`-e`) capture reads the same as a plain one.
#
# claude 2.1.272 (fixtures/claude/question.txt, the AskUserQuestion dialog):
#     ☐ <header>
#   │ <question line>          <- one or more, joined with single spaces
#   ❯ 1. <option>              <- the selected option; the others are `  2. <option>`
#        <description line>    <- indented 5 spaces: dropped
#     3. Type something.       <- free-text entry: dropped
#     4. Chat about this       <- free-text entry: dropped
#   Enter to select · ↑/↓ to navigate · Esc to cancel
# Options keep the number the harness shows, since that is the key that answers them. Read
# bottom-up from the LAST numbered option, so a dialog that scrolled above the current one
# is ignored. The header is optional: a multi-question dialog shows a tab bar
# (`←  ☐ A  ☐ B  ✔ Submit  →`, reviewer-reported, uncaptured) and a permission prompt has
# none, so those print `<question> [<options>]`; with no `│ ` lines, the question is the
# contiguous plain lines directly above the options.
#
# omp 18.1.16 (fixtures/omp/question.txt, the `Allow tool:` approval box):
#   ╭─ <title> ───╮                       <- header = the box title
#   │ <body line>              │          <- 1-space indent: question text
#   │  ❯ <option>              │          <- 2+-space indent: an option (`❯` = selected)
#   │    <option>              │
#   │ up/down navigate  enter select  esc cancel   │   <- footer: dropped
#   ╰─────────────╯
# The box shows its options UNnumbered, so they are numbered here by position (1, 2, ...),
# matching the order up/down walks them. omp's other question wordings that pane_question
# accepts (`Do you want`, `Select an option`) were never captured, so their layout is
# unknown: without the `╭─` box this prints nothing and returns rc 1 rather than guess.
pane_question_text() {
    local harness="${1:-}" pane="${2:-}"
    valid_harness "$harness" || return 1
    pane_question "$harness" "$pane" || return 1
    case "$harness" in
        claude)
            # The Remote Control "already connected" dialog has no numbered options.
            if pane_rc_dialog "$harness" "$pane"; then
                printf '%s\n' 'Remote Control: already connected [Continue]'
                return 0
            fi
            # Read BOTTOM-UP from the last numbered option, so only the dialog now on
            # screen counts (an earlier one in scrollback is ignored): the options block,
            # then the question lines directly above it — the `│ ` lines, or, when the
            # dialog has none, the contiguous plain lines there — then an optional
            # `☐ <header>`. A multi-question tab bar (`←  ☐ A  ☐ B  ✔ Submit  →`) or no
            # header line at all (a permission prompt) just gives no header.
            printf '%s\n' "$pane" | strip_sgr | awk '
                { L[NR] = $0 }
                function isopt(l) { return l ~ /^ *(❯ |  )[0-9]+\. / }
                function issep(l) { return l ~ /^(─)+ *$/ }
                function blank(l) { return l ~ /^ *$/ }
                function trim(l) { sub(/^ +/, "", l); sub(/ +$/, "", l); return l }
                END {
                    last = 0
                    for (i = NR; i >= 1; i--) if (isopt(L[i])) { last = i; break }
                    if (!last) exit 1
                    # walk up over the options block: options, 5-space descriptions,
                    # separators and blank lines between options
                    first = last
                    for (i = last; i >= 1; i--) {
                        if (isopt(L[i])) { first = i; continue }
                        if (L[i] ~ /^     / || issep(L[i]) || blank(L[i])) continue
                        break
                    }
                    opts = ""
                    for (i = first; i <= last; i++) {
                        if (!isopt(L[i])) continue
                        l = L[i]; sub(/^ *(❯ |  )/, "", l)
                        n = l; sub(/\..*$/, "", n)
                        t = trim(substr(l, index(l, ".") + 1))
                        if (t == "Type something." || t == "Chat about this") continue
                        opts = (opts == "" ? n " " t : opts " / " n " " t)
                    }
                    if (opts == "") exit 1
                    # question lines directly above the options
                    q = ""; i = first - 1
                    while (i >= 1 && blank(L[i])) i--
                    if (L[i] ~ /^│ /) {
                        for (; i >= 1 && L[i] ~ /^│ /; i--) {
                            l = L[i]; sub(/^│ +/, "", l); l = trim(l)
                            if (l != "") q = (q == "" ? l : l " " q)
                        }
                    } else {
                        for (; i >= 1; i--) {
                            l = trim(L[i])
                            if (blank(L[i]) || issep(L[i]) || L[i] ~ /^ *☐ / || L[i] ~ /^ *←.*→ *$/ || L[i] ~ /^● /) break
                            q = (q == "" ? l : l " " q)
                        }
                    }
                    while (i >= 1 && blank(L[i])) i--
                    hdr = ""
                    if (i >= 1 && L[i] ~ /^ *☐ /) { hdr = L[i]; sub(/^ *☐ +/, "", hdr); hdr = trim(hdr) }
                    if (hdr != "" && q != "") printf "%s: %s [%s]\n", hdr, q, opts
                    else if (hdr != "") printf "%s [%s]\n", hdr, opts
                    else if (q != "") printf "%s [%s]\n", q, opts
                    else printf "[%s]\n", opts
                }'
            ;;
        omp)
            printf '%s\n' "$pane" | strip_sgr | awk '
                /╭─ / {
                    t = $0; sub(/^.*╭─ /, "", t); sub(/ ─.*$/, "", t)
                    hdr = t; q = ""; opts = ""; n = 0; inbox = 1; next
                }
                inbox && /╰/ { inbox = 0; next }
                inbox && /^ *│/ {
                    l = $0; sub(/^ *│/, "", l); sub(/│ *$/, "", l); sub(/ +$/, "", l)
                    if (l ~ /up\/down navigate/) next
                    if (l ~ /^  / || n > 0) {
                        sub(/^ +/, "", l); sub(/^❯ +/, "", l)
                        if (l == "") next
                        n++
                        opts = (opts == "" ? n " " l : opts " / " n " " l)
                        next
                    }
                    sub(/^ +/, "", l)
                    if (l != "") q = (q == "" ? l : q " " l)
                }
                END {
                    if (hdr == "" || opts == "") exit 1
                    if (q == "") printf "%s [%s]\n", hdr, opts
                    else printf "%s: %s [%s]\n", hdr, q, opts
                }'
            ;;
    esac
}

# pane_last_message <harness> <pane> — prints the first line of the LAST assistant message
# visible in the pane, rc 1 (printing nothing) when there is none or on an unknown harness.
# SGR codes are stripped first (strip_sgr), so a styled (`-e`) capture reads the same.
#
# claude 2.1.272: an assistant message opens with `● ` at column 0 (fixtures/claude/
# ready.txt, question.txt); its continuation lines are indented two spaces and tool calls
# collapse to an indented `Ran 1 shell command`-style summary, so the last `● ` line is the
# last message's first line. busy.txt shows none on screen (it scrolled off) → rc 1.
#
# omp: rc 1 always. None of the omp fixtures (ready/busy/question/launch-typed) shows an
# assistant message, so its chrome is unknown and is not invented here. busy.txt's
# `⎋ Running the requested sleep and echo` is the status bar's current-activity line,
# not a message. Recapture an omp pane with a finished reply to add this.
pane_last_message() {
    local harness="${1:-}" pane="${2:-}"
    case "$harness" in
        omp) return 1 ;;
        claude)
            printf '%s\n' "$pane" | strip_sgr | awk '
                /^● / { m = $0 }
                END {
                    if (m == "") exit 1
                    sub(/^● +/, "", m); sub(/ +$/, "", m)
                    print m
                }'
            ;;
        *) return 1 ;;
    esac
}
