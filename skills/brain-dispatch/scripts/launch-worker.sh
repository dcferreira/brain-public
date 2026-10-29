#!/usr/bin/env bash
#
# launch-worker.sh — the whole tmux launch dance for brain-dispatch, host- and
# harness-neutral (spec §5.7; ported verbatim from SKILL.md steps 6–7).
#
# Creates a detached tmux session rooted in the project dir, gets the harness running in
# it pointed at the worker's brief, and does not return `verified=yes` until the
# harness's OWN composer chrome is on the pane.
#
# Every tmux call goes through `tmx` (host.sh) — never a bare `tmux`, which on the Linux
# desktop is an oh-my-zsh plugin function that exits 127 in a non-interactive shell, and
# on a remote host has to travel over ssh. Every chrome string comes from harness-chrome.sh —
# never a literal here.
#
# THE THREE FAILURE MODES THIS DANCE EXISTS FOR (do not simplify any of them away):
#   1. A shell that is not ready yet, or an interactive zsh `dotenv` plugin prompt
#      (`found '.env' file. Source it?`) in any project dir with a `.env`, silently eats
#      the first characters of the command — the signature is `command not found: mp`.
#      Hence: probe with a unique `RDY-<slug>` marker and answer the dotenv prompt `n`,
#      rather than sleeping and hoping.
#   2. A half-typed command line. Hence: type the launch line WITHOUT Enter, grep the
#      pane for `launch_marker`, and only then send Enter as a SEPARATE send-keys call.
#   3. A false "ready" read off the typed command line itself. Hence: readiness is
#      `pane_harness_up` (the harness's own chrome, free OR already running the priming
#      turn the brief started), which is deliberately false on a pane that merely
#      contains the typed launch text (fixtures/<harness>/launch-typed.txt).
#
#   Plus, for Claude Code only: Remote Control. The launch/resume line itself carries
#   `--remote-control <slug>`, so the worker connects at startup, steerable from
#   claude.ai/code and the mobile app under its own slug — nothing is typed afterwards (a
#   `/rc` into an already-connected session only opens a blocking "already connected"
#   dialog). Once the composer is verified up, the pane is polled for the connection. If
#   that dialog is ever on the pane (verify loop or RC poll), it is answered `Escape` —
#   never Enter, which could pick `Disconnect` — and reported as `rc_dialog=`.
#
#   Plus, for Claude Code only: the folder-trust dialog, whose default selection is
#   `No, exit`. It is answered `Down` then `Enter` as two separate send-keys calls — a
#   bare Enter quits the harness and leaves dispatch staring at a dead pane.
#
# Usage:
#   launch-worker.sh --host <host from hosts.conf> --harness <omp|claude> --slug <slug> \
#                    --project-dir <dir> [--model <model-id>] [--resume <session-id>]
#                    [--note-dir workers|private/workers] [--scope shared|private|all]
#                    [--project <slug>]
#
# --note-dir says where the worker note lives in the vault (default `workers`; a private
# worker's is `private/workers`) — it only changes the brief path in the launch sentence.
# --scope / --project are handed to the worker as tmux env on session creation
# (`new-session -e BRAIN_SCOPE=... -e BRAIN_PROJECT=...`). BRAIN_SCOPE is ALWAYS passed
# (default `shared` when --scope is omitted) so a worker never inherits the tmux server's scope.
#
# A FRESH launch rooted in the brain repo (~/projects/brain) with a scope other than `all`
# is refused (rc 2, no tmux call): the repo's .claude/settings.json forces BRAIN_SCOPE=all and
# overrides the per-worker scope. Use ~/projects/workbench instead. --resume only warns.
#
# --model pins the launched harness to a specific model via its own `--model` flag
# (both omp and claude support one). Omitted, the typed launch command is byte-identical
# to before this flag existed — the pane just gets the harness's own default model.
#
# --resume <session-id> REVIVES an existing conversation instead of priming a fresh one
# (brain-revive-workers, after a reboot killed the tmux sessions): the same dance, but
# the typed line is `resume_cmd` (`claude --resume <uuid>` / `omp --auto-approve --resume
# <id-prefix|path>`) and never the brief sentence. The id is validated first (claude: a
# UUID; omp: `[A-Za-z0-9._/~-]+`). A resumed conversation can take longer to load, so the
# composer poll defaults to 45 tries instead of 20 (DISPATCH_VERIFY_TRIES still wins).
# Once ready, pane lines of the resume banner saying a turn "didn't finish before the
# previous session ended" are echoed to stderr as `note: <line>` for the caller to relay.
#
# Conversation ids. A fresh claude launch PINS its id with `--session-id <uuid>`
# (generated here with uuidgen or /proc/sys/kernel/random/uuid; LAUNCH_SESSION_ID
# overrides it, for tests). omp cannot pin one, so after readiness the id is DISCOVERED
# on the target host: the newest ~/.omp/agent/sessions/*/*.jsonl written since this launch
# started whose FIRST user message is this slug's launch sentence (`unknown` if none turns
# up — a convenience, not a gate).
#
# Prints ONE line: `verified=yes|no session=brain-worker-<slug> rc=yes|no|n/a
# attach=<attach cmd> session_id=<id|unknown> mode=launch|resume`. The two newest fields
# are appended AFTER attach, so parsers of the older four-field line keep working as long
# as they stop `attach` at ` session_id=`. `rc` is Remote Control: `yes` connected,
# `no` attempted but unconfirmed, `n/a` never attempted — a harness without Remote
# Control (omp), or a launch that never got a live session to connect. Remote Control is
# a CONVENIENCE, NOT A LAUNCH GATE: `rc=no` never changes `verified` or the exit code.
# When the "already connected" dialog was met, ` rc_dialog=dismissed|stuck` is appended
# after `mode=` (absent otherwise).
# rc 0 on yes; 1 on no (the session is LEFT RUNNING for inspection — never killed here);
# 2 on bad arguments / unknown host / a harness the host does not run / a malformed id.
#
# The worker note is NOT required to exist: this script only types its path into the
# launch command. Use wait-for-brief.sh first when the note must be there (remote hosts).

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BRAIN_ROOT="${BRAIN_ROOT:-$(cd "$HERE/../../.." && pwd)}"
export BRAIN_ROOT
# shellcheck source=../../_shared/lib/host.sh
. "$HERE/../../_shared/lib/host.sh"
# shellcheck source=../../_shared/lib/harness-chrome.sh
. "$HERE/../../_shared/lib/harness-chrome.sh"

PROBE_TRIES="${DISPATCH_PROBE_TRIES:-15}"     # shell-readiness attempts
PROBE_SLEEP="${DISPATCH_PROBE_SLEEP:-1}"      # seconds between them
TYPE_TRIES="${DISPATCH_TYPE_TRIES:-3}"        # retype attempts for a mangled line
VERIFY_TRIES="${DISPATCH_VERIFY_TRIES:-}"     # composer polls (20 × 2 s = 40 s; resume 45 × 2 s)
VERIFY_SLEEP="${DISPATCH_VERIFY_SLEEP:-2}"    # seconds between them
RC_SLEEP="${DISPATCH_RC_SLEEP:-3}"            # seconds between Remote Control polls
RC_TRIES="${DISPATCH_RC_TRIES:-3}"            # Remote Control polls once the composer is up
ID_TRIES="${DISPATCH_ID_TRIES:-5}"            # omp session-file lookups after ready

die2() { printf 'launch-worker: %s\n' "$1" >&2; exit 2; }
# need_val <remaining argc> <flag> — see preflight.sh: a trailing value-taking flag would
# otherwise make `shift 2` fail under `set -u` and spin the parse loop forever.
need_val() { [ "$1" -ge 2 ] || die2 "$2 needs a value"; }
usage() { sed -n '/^# Usage:/,/^$/p' "$0"; }
snooze() { [ "${1:-0}" = 0 ] || sleep "$1"; }

host="" harness="" slug="" project_dir="" model="" resume_id="" note_dir=workers scope="" bproject=""
while [ $# -gt 0 ]; do
    case "$1" in
        --host)        need_val $# "$1"; host="$2"; shift 2 ;;
        --harness)     need_val $# "$1"; harness="$2"; shift 2 ;;
        --slug)        need_val $# "$1"; slug="$2"; shift 2 ;;
        --project-dir) need_val $# "$1"; project_dir="$2"; shift 2 ;;
        --model)       need_val $# "$1"; model="$2"; shift 2 ;;
        --resume)      need_val $# "$1"; resume_id="$2"; shift 2 ;;
        --note-dir)    need_val $# "$1"; note_dir="$2"; shift 2 ;;
        --scope)       need_val $# "$1"; scope="$2"; shift 2 ;;
        --project)     need_val $# "$1"; bproject="$2"; shift 2 ;;
        -h|--help)     usage; exit 0 ;;
        *) die2 "unknown argument: $1" ;;
    esac
done

[ -n "$host" ] && [ -n "$harness" ] && [ -n "$slug" ] && [ -n "$project_dir" ] \
    || die2 "--host, --harness, --slug and --project-dir are all required"
# Canonicalise: `local` (deprecated alias) becomes this machine's real hosts.conf name, so
# everything below (and every message) uses the real name. An unknown host, or a self that
# cannot be resolved, is refused here — before any probe, note or launch.
if ! canon="$(host_canon "$host")"; then
    if host_is_legacy "$host"; then
        die2 "cannot resolve which host this machine is: its hostname is not in skills/_shared/hosts.conf — add it to that row's hostnames column or set BRAIN_SELF_HOST"
    fi
    die2 "unknown host: $host (see skills/_shared/hosts.conf)"
fi
host="$canon"
valid_harness "$harness" || die2 "unknown harness: $harness (expected omp|claude)"
host_allows "$host" "$harness" \
    || die2 "host '$host' does not run harness '$harness' (see skills/_shared/hosts.conf)"

case "$note_dir" in workers|private/workers) ;; *) die2 "--note-dir must be workers or private/workers" ;; esac
case "$scope" in ''|shared|private|all) ;; *) die2 "--scope must be shared, private or all" ;; esac
case "$bproject" in '') ;; [a-z0-9]*) case "$bproject" in *[!a-z0-9-]*) die2 "--project must match ^[a-z0-9][a-z0-9-]*\$" ;; esac ;; *) die2 "--project must match ^[a-z0-9][a-z0-9-]*\$" ;; esac
# Values are validated above, so the `-e` flags need no quoting through tmx's `$*` join.
env_flags=""
# Always explicit: tmux inherits its server's global env, so an omitted scope could leak `all`.
env_flags="-e BRAIN_SCOPE=${scope:-shared}"
# BRAIN_PROJECT is always set too (empty when omitted) so a stale tmux-server value cannot leak in.
env_flags="$env_flags -e BRAIN_PROJECT=$bproject"

# Brain-repo guard. ~/projects/brain/.claude/settings.json sets env BRAIN_SCOPE=all, and a
# project's settings env OVERRIDES the process env — so ANY session rooted there runs as
# `all`, whatever `-e BRAIN_SCOPE=` says below. A fresh worker that is not itself an
# `all`-scope (project: brain) worker must therefore not be rooted there: refuse, before any
# tmux call. A --resume only warns — an old worker rooted there cannot be moved.
# Exact dir only: verified that Claude Code doesn't apply .claude/settings.json from a subdirectory cwd.
# Known gap: a symlink to the brain repo (or a differently named checkout) is not detected.
# The path is normalised first (collapse `//` and `/./`, strip trailing slashes) and matched as
# `~/projects/brain` or any `*/projects/brain` (so $HOME and remote-home absolute paths count);
# over-blocking a path that really ends in projects/brain is the safe side.
norm_dir="$project_dir"
while :; do
    prev="$norm_dir"
    norm_dir="${norm_dir//\/\//\/}"; norm_dir="${norm_dir//\/.\//\/}"
    [ "$norm_dir" != "$prev" ] || break
done
while [ "${norm_dir%/}" != "$norm_dir" ] && [ "$norm_dir" != / ]; do norm_dir="${norm_dir%/}"; done
case "${norm_dir%/.}" in
    "~/projects/brain"|*/projects/brain)
        if [ "${scope:-shared}" != all ]; then
            if [ -z "$resume_id" ]; then
                die2 "--project-dir is the brain repo, whose .claude/settings.json forces BRAIN_SCOPE=all and overrides --scope ${scope:-shared}; use ~/projects/workbench for a project-less non-code worker (or pass --scope all for a project:brain worker)"
            fi
            printf 'launch-worker: warning: resuming a worker rooted in the brain repo; its .claude/settings.json forces BRAIN_SCOPE=all, overriding the worker scope %s\n' "${scope:-shared}" >&2
        fi ;;
esac

session="brain-worker-$slug"
# Written with `~` and never expanded locally: the `~` sits inside the double-quoted
# launch sentence sent to the pane, so the pane's shell never sees it as a bare word to
# expand — it reaches the harness literally, and the harness resolves it when it reads
# the path.
brief="~/Obsidian/vault/$note_dir/$slug.md"

# new_uuid — a fresh lowercase UUID, generated HERE (not on the target host: a uuid is a
# uuid wherever it was minted). LAUNCH_SESSION_ID overrides it so tests are deterministic.
new_uuid() {
    if [ -n "${LAUNCH_SESSION_ID:-}" ]; then printf '%s\n' "$LAUNCH_SESSION_ID"; return 0; fi
    { uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null; } | tr 'A-F' 'a-f'
}

# mode / sid — what the final line reports as `mode=` and `session_id=`. A resume knows
# its id up front; a fresh claude launch pins one; a fresh omp launch learns it after
# readiness (step 6), and until then it is `unknown`.
if [ -n "$resume_id" ]; then
    mode=resume
    valid_session_id "$harness" "$resume_id" \
        || die2 "--resume: '$resume_id' is not a valid $harness session id"
    sid="$resume_id"
    cmd="$(resume_cmd "$harness" "$resume_id" "$model" "$slug")" \
        || die2 "no resume command for harness $harness (a claude --slug must match [A-Za-z0-9][A-Za-z0-9._-]*)"
    marker="$(resume_marker "$harness" "$model" "$slug")" || die2 "no resume marker for harness $harness"
    [ -n "$VERIFY_TRIES" ] || VERIFY_TRIES=45
else
    mode=launch
    sid="" pin=""
    if [ "$harness" = claude ]; then
        [ -z "${LAUNCH_SESSION_ID:-}" ] || valid_session_id claude "$LAUNCH_SESSION_ID" \
            || die2 "LAUNCH_SESSION_ID '$LAUNCH_SESSION_ID' is not a UUID"
        pin="$(new_uuid)"
        # No uuid source at all: launch unpinned rather than not at all — the worker is
        # what matters; only its later revival by id is lost.
        if valid_session_id claude "$pin"; then sid="$pin"; else
            pin=""
            printf 'launch-worker: could not generate a session uuid — launching without --session-id\n' >&2
        fi
    fi
    cmd="$(launch_cmd "$harness" "$brief" "$model" "$pin" "$slug")" \
        || die2 "no launch command for harness $harness (a claude --slug must match [A-Za-z0-9][A-Za-z0-9._-]*)"
    marker="$(launch_marker "$harness" "$model" "$pin" "$slug")" || die2 "no launch marker for harness $harness"
    [ -n "$VERIFY_TRIES" ] || VERIFY_TRIES=20
fi

capture() { tmx "$host" capture-pane -p -t "$session" 2>/dev/null; }
# send_literal <text> — send-keys of literal text, `printf %q`-escaped so the shell that
# runs tmux on the target host passes it through as ONE argument, unexpanded (a `~` in
# the launch line must reach the pane as a tilde, not as this machine's $HOME).
send_literal() { local q; printf -v q '%q' "$1"; tmx "$host" send-keys -t "$session" "$q"; }
send_key()     { tmx "$host" send-keys -t "$session" "$1"; }
# send_line <text> — literal text AND Enter in ONE send-keys call. Used ONLY for the
# throwaway probe/dotenv answers; the launch line itself is never sent this way (mode 2).
send_line()    { local q; printf -v q '%q' "$1"; tmx "$host" send-keys -t "$session" "$q" Enter; }

# start_mark — fresh omp only: a marker file created ON THE TARGET HOST just before the
# launch Enter (step 3); step 6 accepts only session files newer than it, so an older
# session file of a previous dispatch of the same slug is never mistaken for this one.
start_mark=""
drop_mark() {
    [ -n "$start_mark" ] || return 0
    local q; printf -v q '%q' "$start_mark"
    run_on_host "$host" "rm -f $q" >/dev/null 2>&1
    start_mark=""
}

# rc_name_typed — the `--remote-control <slug>` part of the typed line, if it has one; it
# sits after the marker, so it is checked wrap-tolerantly like the id below.
case "$cmd" in *"--remote-control $slug "*) rc_name_typed="--remote-control $slug" ;; *) rc_name_typed="" ;; esac
rc_dialog=""   # dismissed | stuck — set when the "already connected" dialog was met

fail() {
    drop_mark
    printf 'verified=no session=%s rc=n/a attach=%s session_id=%s mode=%s\n' \
        "$session" "$(attach_cmd "$host" "$session")" "${sid:-unknown}" "$mode"
    printf 'launch-worker: %s — session %s left running on %s for inspection (%s)\n' \
        "$1" "$session" "$host" "$(attach_cmd "$host" "$session")" >&2
    exit 1
}

# --- 1. detached session, cwd = project dir (unquoted so a remote `~` expands there) ---
# An EXISTING session is a hard failure, never a reuse: a session of this name is most
# likely a live worker, and the readiness probe below would type `echo RDY-<slug>` + Enter
# into its composer up to 15 times — 15 stray user messages into somebody's running
# session. Nothing is sent to the pane on this path.
if ! tmx "$host" new-session -d -s "$session" -c "$project_dir" ${env_flags:+$env_flags} >/dev/null 2>&1; then
    printf 'verified=no session=%s rc=n/a attach=%s session_id=%s mode=%s\n' \
        "$session" "$(attach_cmd "$host" "$session")" "${sid:-unknown}" "$mode"
    if tmx "$host" has-session -t "$session" >/dev/null 2>&1; then
        printf 'launch-worker: session %s already exists on %s — attach or kill it first (%s); nothing was sent to the pane\n' \
            "$session" "$host" "$(attach_cmd "$host" "$session")" >&2
    else
        printf 'launch-worker: could not create tmux session %s on %s\n' "$session" "$host" >&2
    fi
    exit 1
fi

# --- 2. shell readiness: a unique marker echoed back is the only reliable signal ------
shell_ready=""
i=0
while [ "$i" -lt "$PROBE_TRIES" ]; do
    i=$((i + 1))
    pane="$(capture)"
    if printf '%s' "$pane" | grep -qiE "found '?\.env'? file|Source it\?"; then
        send_line 'n'             # do NOT source it
        snooze "$PROBE_SLEEP"
        continue
    fi
    send_key C-u                  # clear any partial line
    send_line "echo RDY-$slug"
    snooze "$PROBE_SLEEP"
    if capture | grep -q "^RDY-$slug$"; then shell_ready=yes; break; fi
    snooze "$PROBE_SLEEP"
done
[ -n "$shell_ready" ] || fail "shell never became ready (no RDY-$slug echo after $PROBE_TRIES probes)"

# --- 3. type the launch line WITHOUT Enter, verify it arrived, then Enter separately ---
# The marker is a short PREFIX of the line (proves no leading characters were eaten). A
# pinned/resumed id is checked on its own, on the capture with its row breaks removed:
# `prefix + 36-char uuid` would wrap in a detached pane's 80 columns, but an id has no
# spaces, so deleting the newlines rejoins it exactly wherever the wrap fell. The capture
# goes into a variable first: under pipefail, `capture | grep -q` can read as a miss when
# grep exits on the first match while tmux is still writing.
typed=""
i=0
while [ "$i" -lt "$TYPE_TRIES" ]; do
    i=$((i + 1))
    send_key C-u
    send_literal "$cmd"
    snooze "$PROBE_SLEEP"
    pane="$(capture)"
    if printf '%s\n' "$pane" | grep -qF "$marker" \
       && { [ -z "$sid" ] || printf '%s' "$pane" | tr -d '\n' | grep -qF "$sid"; } \
       && { [ -z "$rc_name_typed" ] || printf '%s' "$pane" | tr -d '\n' | grep -qF -- "$rc_name_typed"; }; then
        typed=yes; break
    fi
    send_key C-u                  # mangled — clear and retype, never fire a broken command
    snooze "$PROBE_SLEEP"
done
[ -n "$typed" ] || fail "launch line never arrived intact after $TYPE_TRIES attempts"

# Not created: step 6 is skipped and the id reported `unknown` — never guessed from an
# unbounded search. Only a plain absolute path is trusted (it is re-quoted for rm/find).
if [ "$mode" = launch ] && [ "$harness" = omp ]; then
    start_mark="$(run_on_host "$host" 'mktemp "${TMPDIR:-/tmp}/brain-launch.XXXXXX"' 2>/dev/null | head -n 1)"
    case "$start_mark" in /*) case "$start_mark" in *[!A-Za-z0-9._/-]*) start_mark="" ;; esac ;; *) start_mark="" ;; esac
fi

send_key Enter

# --- 4. verify the HARNESS started (composer chrome), not just that a line was typed ---
verified=""
rc_esc=""
i=0
while [ "$i" -lt "$VERIFY_TRIES" ]; do
    i=$((i + 1))
    pane="$(capture)"
    # Claude Code's folder-trust dialog defaults to `No, exit`: Down, THEN Enter.
    if pane_trust_prompt "$harness" "$pane"; then
        send_key Down
        send_key Enter
        snooze "$VERIFY_SLEEP"
        continue
    fi
    # Remote Control "already connected" dialog: Escape dismisses it, connection untouched.
    # ONE Escape per sighting (repeated Esc opens claude's rewind menu): while the same
    # dialog stays up later polls only re-check; rc_esc resets once it is gone.
    if pane_rc_dialog "$harness" "$pane"; then
        if [ -z "$rc_esc" ]; then send_key Escape; rc_esc=yes; rc_dialog=dismissed
        else rc_dialog=stuck; fi
        snooze "$VERIFY_SLEEP"
        continue
    fi
    [ -z "$rc_esc" ] || rc_dialog=dismissed
    rc_esc=""
    # ready OR busy: the brief is the positional prompt, so the priming turn may already
    # be streaming — a busy harness is a launched one (pane_ready would veto it).
    if pane_harness_up "$harness" "$pane"; then verified=yes; break; fi
    snooze "$VERIFY_SLEEP"
done
[ -n "$verified" ] || fail "$harness composer never appeared after $VERIFY_TRIES polls"

# --- 4b. resume only: surface an interrupted turn from the old session ---------------
# The revived conversation may show that its last turn was cut off by the shutdown. That
# is for the human to decide about, so it is relayed (stderr, `note: <line>`), never acted on.
# Only the resume banner counts: the pane also replays OLD history, where an ordinary
# `[Request interrupted by user]` or `Interrupted` line is noise, not a shutdown casualty.
if [ "$mode" = resume ]; then
    printf '%s\n' "$pane" \
        | grep -iF "didn't finish before the previous session ended" \
        | sed -E 's/^[[:space:]]+//; s/^/note: /' >&2
fi

# --- 5. confirm Remote Control, if this harness has any (claude only) -----------------
# Harness-gated entirely by rc_connect_text's rc: omp returns 1, so not a keystroke is sent
# and `rc=n/a` is reported. claude was named at launch (`--remote-control <slug>`), so its
# connect text is empty and nothing is typed; a non-empty text would be sent as text and
# `Enter` in two calls, like the launch line. Then poll for the connection, answering the
# "already connected" dialog with Escape if it shows. Reached ONLY on verified=yes.
rc_state="n/a"
if rc_text="$(rc_connect_text "$harness" "$slug")"; then
    rc_state="no"
    if [ -n "$rc_text" ]; then
        send_literal "$rc_text"
        snooze "$PROBE_SLEEP"
        send_key Enter
    fi
    i=0
    while [ "$i" -lt "$RC_TRIES" ]; do
        i=$((i + 1))
        snooze "$RC_SLEEP"
        pane="$(capture)"
        if pane_rc_dialog "$harness" "$pane"; then
            # one Escape per sighting; a dialog that stays up is only re-checked
            if [ -n "$rc_esc" ]; then rc_dialog=stuck; continue; fi
            send_key Escape; rc_esc=yes
            snooze "$PROBE_SLEEP"
            pane="$(capture)"
            if pane_rc_dialog "$harness" "$pane"; then rc_dialog=stuck; continue; fi
            rc_dialog=dismissed
        fi
        if [ -n "$rc_esc" ]; then rc_dialog=dismissed; fi
        rc_esc=""
        if pane_rc_connected "$harness" "$pane"; then rc_state="yes"; break; fi
    done
    if [ "$rc_dialog" = stuck ]; then
        printf 'launch-worker: %s is up but Remote Control'"'"'s "already connected" dialog would not dismiss with Escape — attach with %s and pick Continue (never Disconnect)\n' \
            "$session" "$(attach_cmd "$host" "$session")" >&2
    elif [ "$rc_state" != yes ]; then
        printf 'launch-worker: %s is up but Remote Control did not connect (--remote-control %s unconfirmed) — the worker is running and attachable with %s; Remote Control is a convenience, not a launch gate\n' \
            "$session" "$slug" "$(attach_cmd "$host" "$session")" >&2
    fi
fi

# --- 6. fresh omp only: discover the conversation id omp chose ------------------------
# omp has no flag to pin an id at launch, so read it back from its session file ON THE
# TARGET HOST: the newest ~/.omp/agent/sessions/*/*.jsonl NEWER THAN THE START MARKER whose
# FIRST user message is this slug's launch sentence (a coordinator transcript that merely
# quotes the sentence later on never matches; a previous dispatch's file predates the
# marker), then the `"id"` of its `{"type":"session",...}` header line. Run as one
# `bash -c` script so the find/while/case behave the same under the remote host's `zsh -lc`;
# printf %q makes it a single word for that outer shell. Polled briefly — the file can
# lag the composer. Empty on any failure: the final line then says `session_id=unknown`.
if [ "$mode" = launch ] && [ "$harness" = omp ] && [ -n "$start_mark" ]; then
    needle="Read your worker brief at $brief and follow its priming"
    printf -v q_needle '%q' "$needle"
    printf -v q_mark '%q' "$start_mark"
    probe='needle='"$q_needle"' mark='"$q_mark"'
find "$HOME"/.omp/agent/sessions -mindepth 2 -maxdepth 2 -type f -name "*.jsonl" -newer "$mark" -exec ls -t {} + 2>/dev/null | head -n 50 | while IFS= read -r f; do
    case "$(grep -m1 "\"role\":\"user\"" "$f")" in
        *"$needle"*) sed -n "/\"type\":\"session\"/{s/.*\"type\":\"session\"[^{}]*\"id\":\"\([^\"]*\)\".*/\1/p;q;}" "$f"; break ;;
    esac
done'
    printf -v q_probe '%q' "$probe"
    i=0
    while [ "$i" -lt "$ID_TRIES" ]; do
        i=$((i + 1))
        found="$(run_on_host "$host" "bash -c $q_probe" 2>/dev/null | head -n 1)"
        if [ -n "$found" ] && valid_session_id omp "$found"; then sid="$found"; break; fi
        snooze "$VERIFY_SLEEP"
    done
fi
drop_mark

printf 'verified=yes session=%s rc=%s attach=%s session_id=%s mode=%s%s\n' \
    "$session" "$rc_state" "$(attach_cmd "$host" "$session")" "${sid:-unknown}" "$mode" \
    "${rc_dialog:+ rc_dialog=$rc_dialog}"
exit 0
