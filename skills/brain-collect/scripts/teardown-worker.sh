#!/usr/bin/env bash
#
# teardown-worker.sh — one-command, fire-and-forget persist-then-teardown for the brain-collect skill.
#
# WHAT IT DOES
# -----------
# Run by the main session as a SINGLE background task after collect's authoritative
# writes (verify + [x]/annotate + the diary line). It performs the whole mechanical
# persist-then-teardown so the skill no longer spells out the tmux/send-keys/jj dance
# on every collect:
#
#   1. trigger the worker's own scoped persist (if the session is alive and this
#      collection's persist has not already landed — see already_persisted): flip
#      collect_state -> collecting, stamp collect_started, then send the harness's own
#      scoped-persist line (from the chrome library) into the pane;
#   2. reap on a CONJUNCTION gate (never the collect_state flag alone, which previously
#      missed flips — leaving finished workers un-reaped — and once flipped early and
#      killed a worker MID-WRITE):
#        A  persisted         : collect_state:persisted (the worker's ack of OUR reset),
#                               or a session note carrying its session id written since;
#        B  pane idle          : idle chrome, no running tool, no unanswered question,
#                               on TWO consecutive polls — this is what makes a spurious
#                               early flag flip harmless (B won't pass mid-write);
#        C  no unpushed work   : no uncommitted/undescribed changes teardown would orphan
#                               (a never-created workspace, or an @ already in trunk, is clear);
#   3. on the gate: kill the tmux session and, for --mode done, `jj workspace forget`
#      + remove the workspace dir (--mode park keeps the workspace for a later resume).
#      On the cap it re-checks the gates once; still unmet, it does NOT kill: it leaves
#      the session running and exits STALLED with the idle reason and, when A and C hold,
#      a `--force` command that skips only gate B. Its final REAPED/STALLED line reaches
#      The user via the harness background-task completion notification.
#
# The authoritative, judgement-bearing writes stay with the agent; only this mechanical
# sequence is the tool.
#
# HOST / HARNESS (spec 5.8)
# ------------------------
# The worker may live on another machine and run another harness, so the script takes
# both axes and delegates them to the shared libraries: `host.sh` decides WHERE a command
# runs (`tmx`/`run_on_host`), `harness-chrome.sh` decides WHAT a pane looks like
# (`pane_idle`) and what the persist line says (`persist_worker_text`). Gate B, gate C and
# the teardown all run ON THE WORKER'S HOST; workspace/project paths arrive with a leading
# `~` and are passed UNQUOTED into the command string so the REMOTE shell expands them.
# Gate A deliberately stays LOCAL: it reads the local vault copy, which Syncthing
# populates with original mtimes, so `find -newer marker` remains valid here.
#
# Usage:
#   teardown-worker.sh --slug <slug> [--host <name>] --harness <omp|claude> \
#                      --project-dir <dir> --mode <done|park> \
#                      [--jj-workspace <dir>] [--vcs jj|git] [--force]
#
# --force: no persist trigger, no wait — reap now if A and C hold, skipping gate B (a
# lingering background shell/subagent, or unsent composer text the human has checked).
# Refused (rc 3) unless the note carries a live `collect_started:` from a normal run first.
#
# An omitted/empty --host (a note with no host:) or `--host local` is legacy: read as
# this machine, with a stderr warning naming the slug — plus, when --project-dir (~
# expanded) does not exist here, that it probably belongs to another host. A host this
# machine has no ssh route to (hosts.conf alias `-`, not self) is refused up front, rc 2.

set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../_shared/lib" && pwd)"
# shellcheck source=../../_shared/lib/host.sh
source "$LIB_DIR/host.sh"
# shellcheck source=../../_shared/lib/harness-chrome.sh
source "$LIB_DIR/harness-chrome.sh"

VAULT="${BRAIN_VAULT:-$HOME/Obsidian/vault}"
POLL_INTERVAL="${REAP_POLL_INTERVAL:-15}"     # seconds between polls
MAX_WAIT="${REAP_MAX_WAIT:-1800}"             # cap (30 min); wall-clock does not matter
NEED_STREAK="${REAP_IDLE_STREAK:-2}"          # consecutive passing polls before teardown
PERSIST_SETTLE="${REAP_PERSIST_SETTLE:-3}"    # pause after triggering persist, before polling
DIALOG_SETTLE="${REAP_DIALOG_SETTLE:-1}"      # pause after Escape-ing a dialog, before re-checking
STARTED_MARGIN="${REAP_STARTED_MARGIN:-3600}" # collect_started older than MAX_WAIT + this is stale

# --- worker-note edit (this is a detached tool, NOT the harness agent, so it may edit
#     collect_state out of band; the agent never re-Edits the note after launching us) ---

set_collect_state() {
  local note="$1" val="$2" tmp
  [ -f "$note" ] || return 1
  tmp="$(mktemp)"
  if grep -qE '^collect_state:' "$note"; then
    awk -v v="$val" '/^collect_state:/{print "collect_state: " v; next} {print}' "$note" >"$tmp"
  else
    # insert the field just before the closing frontmatter fence
    awk -v v="$val" '
      NR==1 && /^---[[:space:]]*$/ {print; infm=1; next}
      infm && /^---[[:space:]]*$/ && !added {print "collect_state: " v; print; added=1; infm=0; next}
      {print}
    ' "$note" >"$tmp"
  fi
  mv "$tmp" "$note"
}

# field_value <note> <key> — the frontmatter value of <key>, or nothing.
field_value() {
  awk -v k="$2" 'NR==1 && /^---/ {infm=1; next} infm && /^---/ {exit}
    infm && index($0, k ":") == 1 {sub("^" k ":[[:space:]]*", ""); sub("[[:space:]]+$", ""); print; exit}' "$1" 2>/dev/null
}

# clear_field <note> <key> — drop <key> from the note (no-op when absent).
clear_field() {
  local note="$1" key="$2" tmp
  grep -qE "^$key:" "$note" 2>/dev/null || return 0
  tmp="$(mktemp)"
  grep -vE "^$key:" "$note" >"$tmp"
  mv "$tmp" "$note"
}

# fm_session_ids <session-note> — the note's frontmatter `session_ids:`/`session_id:`
# value(s): the inline value plus any `  - id` block-list lines under the key.
fm_session_ids() {
  awk 'NR==1 && /^---/ {infm=1; next} infm && /^---/ {exit} !infm {exit}
    /^session_ids?:/ {inkey=1; v=$0; sub(/^session_ids?:[[:space:]]*/, "", v); print v; next}
    inkey && /^[[:space:]]+-/ {print; next} {inkey=0}' "$1" 2>/dev/null
}

# stamp_marker <marker> <YYYY-MM-DDTHH:MM:SS> — set <marker>'s mtime to that local time
# (`touch -t [[CC]YY]MMDDhhmm.SS` is understood by GNU and BSD touch alike).
stamp_marker() {
  local s="${2//[-:T]/}"
  [[ "$s" =~ ^[0-9]{14}$ ]] || return 1
  touch -t "${s:0:12}.${s:12:2}" "$1"
}

# --- gate predicates (pure; exercised directly by teardown-worker.test.sh) --------

# A: the worker's scoped persist finished. The reaper resets the flag to `collecting`
# before it sends the prompt, so `persisted` afterwards is the worker's acknowledgement —
# enough on its own: a worker whose persist found nothing new correctly writes NO new
# session note (gate A used to wait the full cap for one). Gate B, not this flag, is what
# stops a kill after an early flip. Fallback for a worker that declined the flip (a resumed
# worker deciding it was "already persisted"): a session note written since <marker> whose
# FRONTMATTER `session_ids:`/`session_id:` carries this worker's session_id. Free text does
# not count — the coordinator's own session note routinely names the worker's slug — and a
# worker note with no session_id gets no fallback (the flag is its only signal).
artefacts_ready() {
  local note="$1" marker="$2" sessions_dir="$3" id f
  grep -qE '^collect_state:[[:space:]]*persisted[[:space:]]*$' "$note" 2>/dev/null && return 0
  id="$(field_value "$note" session_id)"
  [ -n "$id" ] || return 1
  while IFS= read -r -d '' f; do
    fm_session_ids "$f" | grep -qF -- "$id" && return 0
  done < <(find "$sessions_dir" -maxdepth 1 -name '*.md' -newer "$marker" -print0 2>/dev/null)
  return 1
}

# collect_started_live <note> — rc 0 when the note's `collect_started:` is set and younger
# than MAX_WAIT + STARTED_MARGIN. Teardown clears it on REAPED, but a STALLED leaves it;
# expiring it means a later collection re-triggers the persist (and --force refuses)
# instead of reading an old run's `persisted` as this one's.
collect_started_live() {
  local started f t
  started="$(field_value "$1" collect_started)"; [ -n "$started" ] || return 1
  f="$(mktemp)"
  stamp_marker "$f" "$started" || { rm -f "$f"; return 1; }
  t="$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null)"; rm -f "$f"
  [ -n "$t" ] && [ $(( $(date +%s) - t )) -le $(( MAX_WAIT + STARTED_MARGIN )) ]
}

# already_persisted <note> <sessions_dir> <marker> — rc 0 when THIS collection's persist
# already landed, so the prompt must not be sent again (a re-run after STALLED used to
# start a second persist). "This collection" = since the note's `collect_started:`, which
# the reaper stamps when it triggers and clears on REAPED; a `persisted`/`collecting` with
# no stamp, or an expired one (collect_started_live), is stale (e.g. a resumed worker, an
# old STALLED) and is reset by the next trigger. On rc 0, <marker> carries the
# collect_started time for gate A.
already_persisted() {
  local note="$1" sessions_dir="$2" marker="$3"
  collect_started_live "$note" || return 1
  : >"$marker"; stamp_marker "$marker" "$(field_value "$note" collect_started)" || return 1
  artefacts_ready "$note" "$marker" "$sessions_dir"
}

# B: the worker's pane is idle — not running a tool, not awaiting an answer.
# `pane_idle <harness> <pane>` now lives in skills/_shared/lib/harness-chrome.sh, the one
# place harness chrome strings exist (the omp patterns there are this script's former
# predicate, verbatim). Keeping "busy" and "question" as hard vetoes inside it is what
# prevents the mid-write / mid-question kill; the fixtures behind those patterns are in
# skills/_shared/lib/fixtures/<harness>/.
#
# idle_reason <harness> <pane> — prints why gate B fails (nothing when idle), so a STALLED
# says `idle=no reason=…` instead of leaving the caller to attach and look. A lingering
# background shell (a persist's `qmd embed`) or subagent keeps the pane busy, possibly for
# the whole cap; that is reported, never silently treated as idle — `--force` is the way
# past it. The shell/agent patterns mirror pane_busy's in harness-chrome.sh.
idle_reason() {
  local harness="$1" pane="$2" p
  pane_idle "$harness" "$pane" && return 0
  if pane_question "$harness" "$pane"; then echo question; return 0; fi
  if [ "$harness" = claude ]; then
    p="$(printf '%s\n' "$pane" | strip_sgr)"
    if pane_busy claude "$pane"; then
      if grep -qE "^ +[^ ].* · [0-9]+ shells?( · .*)? *\$" <<<"$p"; then echo background-shell
      elif grep -qE "^ +[^ ].* [0-9]+s · ${CLAUDE_TOKENS} *\$" <<<"$p"; then echo background-agents
      else echo busy; fi
      return 0
    fi
    if grep -qE "^${CLAUDE_COMPOSER_LINE}.*[[:alnum:][:punct:]]" <<<"$(printf '%s' "$pane" | strip_dim_ghost)"; then
      echo unsent-composer-text; return 0
    fi
  elif pane_busy "$harness" "$pane"; then echo busy; return 0
  fi
  echo no-composer
}

# C: no uncommitted/undescribed work that teardown would orphan.
#
# FAILS CLOSED. Every probe here now runs over `run_on_host`, so a transport failure
# (ssh rc 255: host down, VPN drop, BatchMode auth refusal) produces the SAME empty
# output a clean tree does. Reading that as "clean" would let teardown delete a workspace
# nothing ever inspected, so the command's exit status is captured separately from its
# output and any non-zero rc means NOT clean. The jj branch already fails closed: an
# unanswered probe leaves both flags empty and the final test is false.
no_unpushed() {
  local vcs="$1" ws="$2" host="$3"
  [ -z "$ws" ] && return 0                    # non-code: nothing to guard
  case "$vcs" in jj|git) ;; *) return 1 ;; esac
  # A declared workspace that was never created (the worker worked in project_dir
  # instead) holds nothing to orphan. Only an explicit "absent" counts: a transport
  # failure prints nothing and falls through to the fail-closed probes below.
  [ "$(run_on_host "$host" "if [ -e $ws ]; then echo present; else echo absent; fi" 2>/dev/null)" = absent ] && return 0
  case "$vcs" in
    jj)
      local empty desc merged
      # Read @ WITH the default snapshot, so un-snapshotted WIP in the workspace counts
      # as work to preserve. Without this, a fresh workspace holding real edits reads as
      # empty @ and teardown destroys it.
      empty="$(run_on_host "$host" "jj -R $ws log -r '@' --no-graph -T 'if(empty,\"1\",\"0\")'" 2>/dev/null)"
      desc="$(run_on_host "$host" "jj -R $ws log -r '@' --no-graph -T 'if(description,\"1\",\"0\")'" 2>/dev/null)"
      if [ -z "$empty" ] && [ -z "$desc" ]; then
        # A STALE workspace (the change was integrated onto trunk elsewhere) makes the
        # snapshot read above fail. Fall back to the RECORDED @ via
        # `--ignore-working-copy`, which skips the snapshot/update that fails — otherwise
        # both flags come back empty, the gate wrongly reads "unpushed work" forever, and
        # teardown hangs to its cap.
        empty="$(run_on_host "$host" "jj -R $ws log -r '@' --ignore-working-copy --no-graph -T 'if(empty,\"1\",\"0\")'" 2>/dev/null)"
        desc="$(run_on_host "$host" "jj -R $ws log -r '@' --ignore-working-copy --no-graph -T 'if(description,\"1\",\"0\")'" 2>/dev/null)"
      fi
      # safe if the working copy is empty, or its changes are captured in a described commit
      { [ "$empty" = "1" ] || [ "$desc" = "1" ]; } && return 0
      # …or @ is already reachable from trunk (merged): nothing teardown could lose.
      merged="$(run_on_host "$host" "jj -R $ws log -r '@ & ::trunk()' --ignore-working-copy --no-graph -T '\"1\"'" 2>/dev/null)"
      [ "$merged" = "1" ]
      ;;
    git)
      local out rc
      out="$(run_on_host "$host" "git -C $ws status --porcelain" 2>/dev/null)"; rc=$?
      [ "$rc" -eq 0 ] || return 1              # unreachable/errored: cannot prove clean
      [ -z "$out" ]
      ;;
  esac
}

# extra_workspaces <vcs> <project_dir> <slug> <host> — prints the OTHER jj workspaces
# whose name contains <slug> (a worker that spawned `<slug>-2`/`<slug>-review`), one per
# line. Report-only: teardown forgets just `<slug>`; the caller decides about the rest.
extra_workspaces() {
  [ "$1" = jj ] || return 0
  run_on_host "$4" "jj -R $2 workspace list --ignore-working-copy" 2>/dev/null \
    | awk -F: -v s="$3" '{n=$1; gsub(/[[:space:]]/, "", n)} n != s && index(n, s) {print n}'
}

# --- persist trigger + teardown --------------------------------------------------

# Trigger the worker's own scoped persist in its live pane, on the worker's own host.
# `tmx` runs `$BRAIN_TMUX` (default `command tmux`, which bypasses the oh-my-zsh tmux
# plugin wrapper) there; the persist line itself is the harness's, from the chrome
# library. Text and Enter are sent as TWO calls so a running TUI's bracketed-paste cannot
# swallow a combined `… Enter`. The text is `printf %q`-quoted so it survives as ONE
# send-keys argument through the local or remote shell.
#
# Before sending it resets collect_state to `collecting` (clearing any stale value) and
# stamps `collect_started:` with <marker>'s time, which already_persisted reads on a re-run.
# rc 0 = sent, 1 = session dead, 2 = held: a question is open (see send_persist).
trigger_persist() {
  local slug="$1" sess="$2" note="$3" host="$4" harness="$5" marker="$6"
  tmx "$host" has-session -t "$sess" >/dev/null 2>&1 || return 1   # dead: nothing to trigger
  persist_worker_text "$harness" >/dev/null || return 1
  local now
  now="$(date +%Y-%m-%dT%H:%M:%S)"; stamp_marker "$marker" "$now"
  set_collect_state "$note" "collecting"
  clear_field "$note" collect_started
  [ -f "$note" ] && awk -v v="$now" '{print} /^collect_state:/ {print "collect_started: " v}' "$note" >"$note.tmp" \
    && mv "$note.tmp" "$note"
  send_persist "$sess" "$host" "$harness"
}

# send_persist <sess> <host> <harness> — type the persist line, but NEVER over an open
# dialog: Enter on any question picks an option, and on Remote Control's "already
# connected" dialog could pick `Disconnect this session`. That dialog is dismissed with
# Escape (pane_rc_dialog: the safe answer) and the pane re-checked; any question still up
# → nothing is typed, rc 2. rc 0 = sent.
send_persist() {
  local sess="$1" host="$2" harness="$3" text qtext pane
  text="$(persist_worker_text "$harness")" || return 1
  printf -v qtext '%q' "$text"
  pane="$(capture_pane "$host" "$harness" "$sess")"
  if pane_rc_dialog "$harness" "$pane"; then
    tmx "$host" send-keys -t "$sess" Escape
    sleep "$DIALOG_SETTLE"
    pane="$(capture_pane "$host" "$harness" "$sess")"
  fi
  pane_question "$harness" "$pane" && return 2
  tmx "$host" send-keys -t "$sess" "$qtext"
  tmx "$host" send-keys -t "$sess" Enter
  return 0
}

# capture_pane <host> <harness> <sess> — the pane as the chrome predicates expect it.
capture_pane() {
  # shellcheck disable=SC2046  # pane_capture_flags prints 0 or 1 flag words, meant to split
  tmx "$1" capture-pane -p $(pane_capture_flags "$2") -t "$3" 2>/dev/null
}

# Kill the session and (for --mode done) drop the workspace — all on the worker's host.
# `$project_dir`/`$jj_workspace` stay UNQUOTED inside the command string so the remote
# shell expands their leading `~`.
teardown() {
  local slug="$1" sess="$2" mode="$3" vcs="$4" project_dir="$5" jj_workspace="$6" host="$7" note="${8:-}"
  local extra
  extra="$(extra_workspaces "$vcs" "$project_dir" "$slug" "$host" | paste -sd ' ' -)"
  [ -z "$extra" ] || echo "note: other jj workspaces under $slug left in place: $extra"
  tmx "$host" kill-session -t "$sess" >/dev/null 2>&1
  # this collection is over: a later resume + collect must trigger a fresh persist
  [ -z "$note" ] || clear_field "$note" collect_started
  # done → drop the workspace; park → keep it (a later re-dispatch resumes the work).
  if [ "$mode" = "done" ] && [ -n "$jj_workspace" ]; then
    case "$vcs" in
      jj)  run_on_host "$host" "jj -R $project_dir workspace forget $slug" >/dev/null 2>&1
           run_on_host "$host" "rm -rf $jj_workspace" >/dev/null 2>&1 ;;
      git) run_on_host "$host" "git -C $project_dir worktree remove --force $jj_workspace" >/dev/null 2>&1 ;;
    esac
  fi
}

# --- main ------------------------------------------------------------------------

main() {
  local slug="" project_dir="" mode="" jj_workspace="" vcs="" host="" harness="" force=no
  local usage="usage: teardown-worker.sh --slug <slug> [--host <name>] --harness <omp|claude> --project-dir <dir> --mode <done|park> [--jj-workspace <dir>] [--vcs jj|git] [--force]"
  local self; self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
  local force_cmd; printf -v force_cmd '%q ' bash "$self" "$@"; force_cmd="${force_cmd% } --force"
  # need_val <remaining argc> <flag> — a value-taking flag with nothing after it must be a
  # hard rc-2 error: under `set -u` a bare `shift 2` on one remaining argument FAILS without
  # consuming anything, and the `while [ $# -gt 0 ]` loop then spins forever.
  need_val() { [ "$1" -ge 2 ] || { echo "teardown-worker: $2 needs a value" >&2; echo "$usage" >&2; return 2; }; }
  while [ $# -gt 0 ]; do
    case "$1" in
      --slug)          need_val $# "$1" || return 2; slug="$2"; shift 2 ;;
      --project-dir)   need_val $# "$1" || return 2; project_dir="$2"; shift 2 ;;
      --mode)          need_val $# "$1" || return 2; mode="$2"; shift 2 ;;
      --jj-workspace)  need_val $# "$1" || return 2; jj_workspace="$2"; shift 2 ;;
      --vcs)           need_val $# "$1" || return 2; vcs="$2"; shift 2 ;;
      --host)          need_val $# "$1" || return 2; host="$2"; shift 2 ;;
      --harness)       need_val $# "$1" || return 2; harness="$2"; shift 2 ;;
      --force)         force=yes; shift ;;
      *) echo "teardown-worker: unknown argument '$1'" >&2; echo "$usage" >&2; return 2 ;;
    esac
  done
  if [ -z "$slug" ] || [ -z "$project_dir" ] || [ -z "$mode" ] || [ -z "$harness" ]; then
    echo "teardown-worker: --slug, --project-dir, --mode and --harness are required" >&2
    echo "$usage" >&2; return 2
  fi
  case "$mode" in done|park) ;; *) echo "teardown-worker: --mode must be done or park" >&2; return 2 ;; esac
  if ! valid_harness "$harness"; then
    echo "teardown-worker: --harness must be omp or claude (got '$harness')" >&2; return 2
  fi
  if host_is_legacy "$host"; then
    # `--host local` / no --host is the deprecated spelling of this machine: normalise,
    # warn on stderr (the same line revive-workers.sh and worker-monitor.sh print).
    local canon legacy="${host:-unset}" xdir
    if ! canon="$(host_canon "$host")"; then
      echo "teardown-worker: --host '$legacy' is legacy but this machine's host is unresolved (add its hostname to hosts.conf or set BRAIN_SELF_HOST)" >&2
      return 2
    fi
    xdir="$project_dir"; case "$xdir" in "~"|"~/"*) xdir="$HOME${xdir#\~}" ;; esac
    if [ ! -d "$xdir" ]; then
      echo "warning: $slug: legacy host '$legacy' read as $canon — project_dir $project_dir is not on this machine; it probably belongs to another host (fix its host:)" >&2
    else
      echo "warning: $slug: legacy host '$legacy' read as $canon" >&2
    fi
    host="$canon"
  fi
  if ! host_field "$host" ssh_alias >/dev/null 2>&1; then
    echo "teardown-worker: unknown --host '$host' (not in hosts.conf)" >&2
    echo "$usage" >&2; return 2
  fi
  if ! host_reachable "$host"; then
    # alias `-`: only the host itself can reach its tmux — polling would just report
    # "unreachable — retrying" until the cap.
    echo "teardown-worker: no ssh route from $(self_host 2>/dev/null || echo 'this machine') to $host (hosts.conf alias -) — run the teardown on $host itself" >&2
    return 2
  fi
  if ! host_allows "$host" "$harness"; then
    echo "teardown-worker: host '$host' does not run harness '$harness' (see hosts.conf)" >&2
    echo "$usage" >&2; return 2
  fi

  local sess="brain-worker-$slug"
  local note="$VAULT/workers/$slug.md"
  [ -e "$note" ] || { [ ! -e "$VAULT/private/workers/$slug.md" ] || note="$VAULT/private/workers/$slug.md"; }
  local sessions_dir="$VAULT/sessions"
  local marker; marker="$(mktemp)"   # its mtime = when this collection's persist was triggered

  # --force skips the trigger, so it needs a LIVE collection: without collect_started,
  # a `collect_state: persisted` may be a stale one from an earlier park, and accepting it
  # would reap with no persist and no idle gate.
  if [ "$force" = yes ] && ! collect_started_live "$note"; then
    echo "STALLED $slug: --force refused — no live collection (collect_started absent, or older than $((MAX_WAIT + STARTED_MARGIN))s), so collect_state may be stale; run without --force first so the worker persists — left running."
    rm -f "$marker"; return 3
  fi

  # 1. Trigger the worker's own persist — unless this collection's persist already landed
  #    (a re-run, or --force), or the session is already gone.
  local pending=no
  if already_persisted "$note" "$sessions_dir" "$marker"; then
    echo "teardown-worker $slug: already persisted for this collection — not re-sending the persist prompt." >&2
  elif [ "$force" = yes ]; then
    # never trigger under --force; gate A still needs the flag, or a session note
    # written since this collection's collect_started
    stamp_marker "$marker" "$(field_value "$note" collect_started)" 2>/dev/null || true
  else
    trigger_persist "$slug" "$sess" "$note" "$host" "$harness" "$marker"
    case $? in
      0) sleep "$PERSIST_SETTLE" ;;
      2) pending=yes
         echo "teardown-worker $slug: a question is open in the pane (idle=no reason=question) — persist prompt NOT sent; retrying each poll until it is answered." >&2 ;;
      *) echo "teardown-worker $slug: session not alive — skipping persist; the worker's ## Result note stands." >&2 ;;
    esac
  fi
  [ "$force" = yes ] && MAX_WAIT=0   # --force: no waiting, straight to the final check

  # 2. Reap on the conjunction gate.
  local elapsed=0 idle_streak=0
  while [ "$elapsed" -lt "$MAX_WAIT" ]; do
    # Reachability FIRST. `tmx ... has-session` fails identically for "tmux says there is
    # no such session" and "the host never answered", and the gone-session branch below
    # tears the workspace down. One unreachable poll must therefore never be read as a
    # finished worker: if the host does not answer, reap nothing, reset the streak and
    # keep polling toward the cap (which exits STALLED without killing anything).
    if ! run_on_host "$host" true >/dev/null 2>&1; then
      echo "teardown-worker $slug: host $host unreachable — not reaping; retrying." >&2
      idle_streak=0
      sleep "$POLL_INTERVAL"
      elapsed=$((elapsed + POLL_INTERVAL))
      continue
    fi

    # The host answered, so this really is tmux reporting no such session.
    if ! tmx "$host" has-session -t "$sess" >/dev/null 2>&1; then
      reap_gone "$slug" "$sess" "$mode" "$vcs" "$project_dir" "$jj_workspace" "$host" "$note"
      local rc=$?; rm -f "$marker"; return "$rc"
    fi

    # a persist held back by an open question: send it once the question is gone
    if [ "$pending" = yes ] && send_persist "$sess" "$host" "$harness"; then
      pending=no; sleep "$PERSIST_SETTLE"
    fi

    local pane; pane="$(capture_pane "$host" "$harness" "$sess")"
    if artefacts_ready "$note" "$marker" "$sessions_dir" \
       && pane_idle "$harness" "$pane" \
       && no_unpushed "$vcs" "$jj_workspace" "$host"; then
      idle_streak=$((idle_streak + 1))
      if [ "$idle_streak" -ge "$NEED_STREAK" ]; then
        teardown "$slug" "$sess" "$mode" "$vcs" "$project_dir" "$jj_workspace" "$host" "$note"
        echo "REAPED $slug (mode=$mode): persisted + idle, torn down."
        rm -f "$marker"; return 0
      fi
    else
      idle_streak=0
    fi
    sleep "$POLL_INTERVAL"
    elapsed=$((elapsed + POLL_INTERVAL))
  done

  # Cap reached (or --force) — re-check every gate once more before giving up. Without
  # --force the idle gate still holds, so this never kills mid-write; --force skips ONLY
  # gate B, and only when A and C both hold.
  if ! run_on_host "$host" true >/dev/null 2>&1; then
    echo "STALLED $slug: host $host unreachable at the final check — left running for inspection."
    rm -f "$marker"; return 3
  fi
  if ! tmx "$host" has-session -t "$sess" >/dev/null 2>&1; then
    reap_gone "$slug" "$sess" "$mode" "$vcs" "$project_dir" "$jj_workspace" "$host" "$note"
    local rc=$?; rm -f "$marker"; return "$rc"
  fi
  local a="no" b="no" c="no" why
  artefacts_ready "$note" "$marker" "$sessions_dir" && a="yes"
  # shellcheck disable=SC2046  # pane_capture_flags prints 0 or 1 flag words, meant to split
  why="$(idle_reason "$harness" "$(tmx "$host" capture-pane -p $(pane_capture_flags "$harness") -t "$sess" 2>/dev/null)")"
  if [ -z "$why" ] && [ "$a" = yes ]; then
    # idle must hold on a SECOND look too, as in the loop's streak
    sleep "$POLL_INTERVAL"
    # shellcheck disable=SC2046
    why="$(idle_reason "$harness" "$(tmx "$host" capture-pane -p $(pane_capture_flags "$harness") -t "$sess" 2>/dev/null)")"
  fi
  [ -z "$why" ] && b="yes"
  no_unpushed "$vcs" "$jj_workspace" "$host" && c="yes"
  rm -f "$marker"
  if [ "$a" = yes ] && [ "$c" = yes ] && { [ "$b" = yes ] || [ "$force" = yes ]; }; then
    teardown "$slug" "$sess" "$mode" "$vcs" "$project_dir" "$jj_workspace" "$host" "$note"
    if [ "$b" = yes ]; then echo "REAPED $slug (mode=$mode): persisted + idle at the final re-check, torn down."
    else echo "REAPED $slug (mode=$mode): forced — persisted + no unpushed work; idle gate skipped (reason=$why), torn down."; fi
    return 0
  fi
  local idle="idle=$b"; [ "$b" = yes ] || idle="idle=no reason=$why"
  if [ "$force" = yes ]; then
    echo "STALLED $slug: --force refused — it skips only the idle gate (persisted=$a $idle unpushed_clear=$c) — left running."
  else
    echo "STALLED $slug: gate not met after ${MAX_WAIT}s (persisted=$a $idle unpushed_clear=$c) — left running for inspection."
    if [ "$a" = yes ] && [ "$c" = yes ]; then
      echo "force-reap (skips only the idle gate; check the pane first if reason is not a lingering background shell/agent): $force_cmd"
    fi
  fi
  return 3
}

# A dead session cannot be mid-write, so skip gates A/B; still honour gate C.
reap_gone() {
  local slug="$1" sess="$2" mode="$3" vcs="$4" project_dir="$5" jj_workspace="$6" host="$7" note="$8"
  if no_unpushed "$vcs" "$jj_workspace" "$host"; then
    teardown "$slug" "$sess" "$mode" "$vcs" "$project_dir" "$jj_workspace" "$host" "$note"
    echo "REAPED $slug (mode=$mode): session already gone, torn down."
    return 0
  fi
  echo "STALLED $slug: session gone but workspace has uncommitted work — left for inspection."
  return 3
}

# Run main only when executed directly, so the test can source the functions.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
