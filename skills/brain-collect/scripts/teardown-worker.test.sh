#!/usr/bin/env bash
#
# Tests for teardown-worker.sh. Sources the script (main is guarded) and exercises
# the pure functions — set_collect_state, artefacts_ready, pane_idle, no_unpushed —
# against the shared fixtures in skills/_shared/lib/fixtures/<harness>/*.txt, covering
# the failure modes that motivated the conjunction gate: a worker mid-write must NOT be
# reaped, an unanswered question must NOT be reaped, an early flag flip without a fresh
# note must NOT be reaped, and only an all-clear state may be reaped.
#
# Two axes are now asserted on top of that:
#   harness — the idle truth table runs for BOTH omp and claude, from the same fixtures
#             harness-chrome.test.sh uses (pane_idle now lives in the chrome library).
#   host    — a full `main` run against `--host homeserver` with BRAIN_SSH stubbed by a fake
#             that logs its argv, proving every tmux/jj/git call is routed through
#             `homeserver zsh -lc` while gate A still reads the LOCAL temp vault.
#
# The host axis brings its own failure mode, asserted below: an ssh that exits 255 (host
# down, VPN drop, BatchMode refusal) must NEVER be mistaken for a clean tree or a finished
# worker — gate C says "not clean" and the main loop stalls instead of tearing down.
#
# Runs offline: no real ssh, no real tmux, no real worker session.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIX="$HERE/../../_shared/lib/fixtures"
# Pin the host axis: never depend on this machine's hostname or the default repo hosts.conf.
export BRAIN_HOSTS="$HERE/../../_shared/hosts.conf"
export BRAIN_SELF_HOST=desktop
# shellcheck source=teardown-worker.sh
source "$HERE/teardown-worker.sh"

PASS=0 FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
assert_true()  { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
assert_false() { local d="$1"; shift; if "$@"; then bad "$d"; else ok "$d"; fi; }
assert_eq()    { local d="$1" want="$2" got="$3"; if [ "$want" = "$got" ]; then ok "$d"; else bad "$d (want '$want' got '$got')"; fi; }
assert_contains()     { local d="$1" needle="$2" hay="$3"; case "$hay" in *"$needle"*) ok "$d" ;; *) bad "$d (missing '$needle')" ;; esac; }
assert_not_contains() { local d="$1" needle="$2" hay="$3"; case "$hay" in *"$needle"*) bad "$d (unexpected '$needle')" ;; *) ok "$d" ;; esac; }

fixture() { cat "$FIX/$1/$2.txt"; }

# touch_future <file> — stamp <file> far in the future, so it is unconditionally newer
# than any marker the run under test creates. `touch -d @<epoch>` is GNU-only; the
# [[CC]YY]MMDDhhmm form of `-t` is understood by both GNU and BSD touch.
touch_future() { touch -t 209901010000 "$1"; }

# with_timeout <seconds> <cmd...> — run <cmd> under a wall-clock cap and return its exit
# status, or 124 if the cap was hit (the same convention as coreutils `timeout`). Uses
# `timeout`/`gtimeout` when either is installed; otherwise falls back to a background
# child plus a watchdog that kills it, so the hang guard still holds on a stock macOS
# with no coreutils. Sets WITH_TIMEOUT_REAL=no when the fallback was used.
WITH_TIMEOUT_REAL=yes
if command -v timeout >/dev/null 2>&1; then
  with_timeout() { timeout "$@"; }
elif command -v gtimeout >/dev/null 2>&1; then
  with_timeout() { gtimeout "$@"; }
else
  WITH_TIMEOUT_REAL=no
  with_timeout() {
    local secs="$1"; shift
    "$@" &
    local pid=$!
    ( local i=0
      while [ "$i" -lt "$secs" ]; do sleep 1; i=$((i+1)); kill -0 "$pid" 2>/dev/null || exit 0; done
      kill -9 "$pid" 2>/dev/null ) &
    local watchdog=$!
    local rc=0
    wait "$pid" 2>/dev/null || rc=$?
    kill "$watchdog" 2>/dev/null
    wait "$watchdog" 2>/dev/null
    [ "$rc" -eq 137 ] && rc=124
    return "$rc"
  }
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "set_collect_state:"
NOTE_A="$TMP/a.md"; printf -- '---\nslug: x\nstatus: collected\n---\n\n# x\n' >"$NOTE_A"
set_collect_state "$NOTE_A" "collecting"
assert_eq   "inserts collect_state when absent" "collect_state: collecting" "$(grep '^collect_state:' "$NOTE_A")"
assert_true "keeps frontmatter fences intact"   grep -qxF -- '---' "$NOTE_A"
set_collect_state "$NOTE_A" "persisted"
assert_eq   "replaces existing collect_state"   "collect_state: persisted" "$(grep '^collect_state:' "$NOTE_A")"
assert_eq   "does not duplicate the field"      "1" "$(grep -c '^collect_state:' "$NOTE_A")"

# Gate B. pane_idle now comes from the chrome library and takes the harness as $1; the
# fixtures are the very captures that used to be heredocs in this file.
echo "pane_idle (omp):"
assert_false "busy pane (tool running) is not idle"          pane_idle omp "$(fixture omp busy)"
assert_false "approval dialog is not idle"                   pane_idle omp "$(fixture omp question)"
assert_false "question pane (Do you want) is not idle"       pane_idle omp "Do you want to proceed?"
assert_false "blank pane with no chrome is not idle"         pane_idle omp ""
assert_true  "idle composer is idle"                         pane_idle omp "$(fixture omp ready)"
assert_false "idle composer + running tool loses to busy veto" pane_idle omp " ⠼ 3s > ◒ DeepSeek V4.1-Flash ▶─6%─────╎┃1M─◀ ⚙ 1
 π >"
assert_false "shell prompt with the launch line typed is not idle" pane_idle omp "$(fixture omp launch-typed)"

echo "pane_idle (claude):"
assert_false "busy pane (shell tool running) is not idle"    pane_idle claude "$(fixture claude busy)"
assert_false "AskUserQuestion dialog is not idle"            pane_idle claude "$(fixture claude question)"
assert_false "folder-trust prompt is not idle"               pane_idle claude "$(fixture claude trust)"
assert_false "blank pane with no chrome is not idle"         pane_idle claude ""
assert_true  "idle composer is idle"                         pane_idle claude "$(fixture claude ready)"
assert_false "shell prompt with the launch line typed is not idle" pane_idle claude "$(fixture claude launch-typed)"

echo "pane_idle (unknown harness):"
assert_false "unknown harness is never idle"                 pane_idle nope "$(fixture omp ready)"

echo "artefacts_ready:"
SESS="$TMP/sessions"; mkdir -p "$SESS"
MARKER="$TMP/marker"; : >"$MARKER"; sleep 1
NOTE_NOFLAG="$TMP/noflag.md"; printf 'status: collected\n' >"$NOTE_NOFLAG"
NOTE_FLAG="$TMP/flag.md";     printf 'collect_state: persisted\n' >"$NOTE_FLAG"
printf '# note\n' >"$SESS/2026-08-21 something.md"          # a session note written AFTER the marker
assert_true  "flag + fresh session note → ready"           artefacts_ready "$NOTE_FLAG" "$MARKER" "$SESS"
assert_false "fresh note but no flag → not ready"          artefacts_ready "$NOTE_NOFLAG" "$MARKER" "$SESS"

# Gate C on the LOCAL host: identical semantics to before the host axis existed.
echo "no_unpushed (git + non-code, host=desktop):"
assert_true  "empty workspace arg (non-code) → clean"      no_unpushed "" "" desktop
GW="$TMP/gitws"; mkdir -p "$GW"; ( cd "$GW" && git init -q && git config user.email t@t && git config user.name t )
assert_true  "clean git worktree → clean"                  no_unpushed "git" "$GW" desktop
printf 'x\n' >"$GW/dirty.txt"
assert_false "dirty git worktree → not clean"              no_unpushed "git" "$GW" desktop

echo "no_unpushed (jj, host=desktop):"
JW="$TMP/jjws"; mkdir -p "$JW"
if command -v jj >/dev/null 2>&1 && jj git init "$JW" >/dev/null 2>&1; then
  assert_true  "empty jj working copy → clean"             no_unpushed "jj" "$JW" desktop
  printf 'x\n' >"$JW/wip.txt"                              # uncommitted, undescribed WIP
  assert_false "undescribed jj WIP → not clean"           no_unpushed "jj" "$JW" desktop
  jj -R "$JW" describe -m "wip captured" >/dev/null 2>&1
  assert_true  "described jj change → clean"               no_unpushed "jj" "$JW" desktop
else
  echo "  skip jj cases (jj unavailable or init failed)"
fi

# Gate C must FAIL CLOSED: ssh rc 255 produces the same empty output a clean tree does.
echo "no_unpushed (transport failure, ssh exits 255):"
DEADSSH="$TMP/dead-ssh"
printf '#!/usr/bin/env bash\nexit 255\n' >"$DEADSSH"; chmod +x "$DEADSSH"
cp "$HERE/../../_shared/hosts.conf" "$TMP/hosts.conf"
rc_of() { local rc=0; "$@" >/dev/null 2>&1 || rc=$?; echo "$rc"; }
dead_no_unpushed() ( BRAIN_SSH="$DEADSSH" BRAIN_HOSTS="$TMP/hosts.conf"; no_unpushed "$@" )
assert_eq "git + unreachable host → NOT clean (rc 1)" "1" "$(rc_of dead_no_unpushed git '~/ws' homeserver)"
assert_eq "jj + unreachable host → NOT clean (rc 1)"  "1" "$(rc_of dead_no_unpushed jj  '~/ws' homeserver)"
assert_eq "unknown vcs with a workspace → NOT clean"  "1" "$(rc_of no_unpushed '' '~/ws' desktop)"
assert_eq "no workspace at all is still clean"        "0" "$(rc_of no_unpushed '' '' desktop)"

# The stale-workspace fallback: a workspace whose change was integrated elsewhere makes
# the snapshotting read fail. Both reads come back empty, the --ignore-working-copy retry
# is attempted, and when that is empty too the gate reads "unpushed work" (never clean).
echo "no_unpushed (stale jj workspace, stubbed jj):"
STUBBIN="$TMP/stubbin"; mkdir -p "$STUBBIN"
JJLOG="$TMP/jj.log"
cat >"$STUBBIN/jj" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$JJLOG"
exit 1                       # a stale workspace: the read fails, printing nothing
EOF
chmod +x "$STUBBIN/jj"
STALEWS="$TMP/stalews"; mkdir -p "$STALEWS"     # it exists: a never-created path is clean
assert_eq "both jj reads empty → NOT clean" "1" \
  "$(rc_of env PATH="$STUBBIN:$PATH" bash -c 'source "$0"; no_unpushed jj "$1" desktop' "$HERE/teardown-worker.sh" "$STALEWS")"
JJ_CALLS="$(cat "$JJLOG" 2>/dev/null)"
assert_contains "the --ignore-working-copy fallback is attempted" "--ignore-working-copy" "$JJ_CALLS"
assert_eq "five jj reads in total (2 snapshotting + 2 fallback + merged probe)" "5" "$(grep -c . "$JJLOG")"

# ---------------------------------------------------------------------------------
# CLI contract: --host and --harness are required, and both are validated.
# ---------------------------------------------------------------------------------
echo "argument validation (rc 2):"
run_script() { bash "$HERE/teardown-worker.sh" "$@" >/dev/null 2>&1; echo $?; }
BASE=(--slug x --project-dir '~/projects/brain' --mode park)
assert_eq "missing --harness → rc 2"         "2" "$(run_script "${BASE[@]}" --host desktop)"
assert_eq "missing --harness (no --host) → rc 2" "2" "$(run_script "${BASE[@]}")"
assert_eq "invalid --harness → rc 2"         "2" "$(run_script "${BASE[@]}" --host desktop --harness borg)"
assert_eq "unknown --host → rc 2"            "2" "$(run_script "${BASE[@]}" --host nowhere --harness omp)"
assert_eq "host that does not run the harness → rc 2" "2" "$(run_script "${BASE[@]}" --host homeserver --harness omp)"
assert_eq "still rc 2 for a missing --slug"  "2" "$(run_script --project-dir '~/p' --mode park --host desktop --harness omp)"
# Legacy `--host local`: read as this machine (BRAIN_SELF_HOST), with a stderr warning.
LT="$TMP/legacy"; mkdir -p "$LT/vault/workers"
printf -- '---\nslug: lg\nhost: local\nharness: omp\n---\n' >"$LT/vault/workers/lg.md"
LFAKE="$LT/tmux"; printf '#!/usr/bin/env bash\necho no server running >&2; exit 1\n' >"$LFAKE"; chmod +x "$LFAKE"
LOUT="$(BRAIN_VAULT="$LT/vault" BRAIN_TMUX="$LFAKE" REAP_PERSIST_SETTLE=0 REAP_POLL_INTERVAL=0 \
        bash "$HERE/teardown-worker.sh" --slug lg --host local --harness omp --project-dir '~/p' --mode park 2>"$LT/err")"
assert_contains "--host local still works (session gone → REAPED)" "REAPED lg" "$LOUT"
assert_contains "--host local warns naming slug and self" "warning: lg: legacy host 'local' read as desktop" "$(cat "$LT/err")"
assert_not_contains "warning stays off stdout" "warning" "$LOUT"
assert_eq "--host local with an unresolved self → rc 2" "2" \
  "$(BRAIN_SELF_HOST=nowhere bash "$HERE/teardown-worker.sh" --slug lg --host local --harness omp --project-dir '~/p' --mode park >/dev/null 2>&1; echo $?)"
assert_contains "…and says why" "this machine's host is unresolved" \
  "$(BRAIN_SELF_HOST=nowhere bash "$HERE/teardown-worker.sh" --slug lg --host local --harness omp --project-dir '~/p' --mode park 2>&1 >/dev/null)"
# A legacy project_dir that is not on this machine: the warning says it probably belongs
# to another host (HOME pinned so `~` expansion is deterministic).
mkdir -p "$LT/home/p"
legacy_err() { HOME="$LT/home" BRAIN_VAULT="$LT/vault" BRAIN_TMUX="$LFAKE" REAP_PERSIST_SETTLE=0 REAP_POLL_INTERVAL=0 \
    bash "$HERE/teardown-worker.sh" --slug lg --harness omp --mode park "$@" 2>&1 >/dev/null; }
assert_contains "legacy + project_dir missing here → other-host hint" \
  "warning: lg: legacy host 'local' read as desktop — project_dir ~/q is not on this machine; it probably belongs to another host (fix its host:)" \
  "$(legacy_err --host local --project-dir '~/q')"
assert_not_contains "legacy + project_dir present here → no hint" "is not on this machine" \
  "$(legacy_err --host local --project-dir '~/p')"
# Omitted or empty --host = this machine, treated as legacy (same warning as --host local).
LOUT="$(HOME="$LT/home" BRAIN_VAULT="$LT/vault" BRAIN_TMUX="$LFAKE" REAP_PERSIST_SETTLE=0 REAP_POLL_INTERVAL=0 \
        bash "$HERE/teardown-worker.sh" --slug lg --harness omp --project-dir '~/p' --mode park 2>"$LT/err")"
assert_contains "omitted --host → self (session gone → REAPED)" "REAPED lg" "$LOUT"
assert_contains "omitted --host warns as legacy 'unset'" "warning: lg: legacy host 'unset' read as desktop" "$(cat "$LT/err")"
assert_contains "empty --host warns as legacy 'unset'" "warning: lg: legacy host 'unset' read as desktop" \
  "$(legacy_err --host '' --project-dir '~/p')"
assert_contains "omitted --host + project_dir missing here → other-host hint" "project_dir ~/q is not on this machine" \
  "$(legacy_err --project-dir '~/q')"
# A host this machine has no ssh route to (alias -, not self): refuse up front, rc 2 —
# never poll "unreachable — retrying" until the 30-minute cap.
NRH="$(mktemp)"; sed 's/^desktop[[:space:]]\{1,\}[^[:space:]]\{1,\}/desktop   -/' "$BRAIN_HOSTS" >"$NRH"
NR_OUT="$(BRAIN_HOSTS="$NRH" BRAIN_SELF_HOST=homeserver with_timeout 10 bash "$HERE/teardown-worker.sh" --slug lg --host desktop --harness omp \
          --project-dir '~/p' --mode park 2>&1)"; NR_RC=$?
assert_eq "self=homeserver, --host desktop (alias -) → rc 2" "2" "$NR_RC"
assert_contains "…says there is no ssh route" "no ssh route from homeserver to desktop" "$NR_OUT"
assert_not_contains "…and never polls" "retrying" "$NR_OUT"
rm -f "$NRH"
assert_eq "trailing --slug with no value → rc 2, not an unbound-variable hang" "2" \
  "$(with_timeout 5 bash "$HERE/teardown-worker.sh" --slug >/dev/null 2>&1; echo $?)"

# ---------------------------------------------------------------------------------
# Host routing: a full `main` run with --host homeserver. BRAIN_SSH is a fake that logs its
# argv and answers has-session / capture-pane / git status, so nothing real is touched.
# Gate A must stay LOCAL (the temp vault below), gates B/C and teardown must go over
# the stub as `homeserver zsh -lc …`.
# ---------------------------------------------------------------------------------
echo "host routing (--host homeserver, BRAIN_SSH stubbed):"
RT="$TMP/routing"; mkdir -p "$RT/vault/workers" "$RT/vault/sessions"
cp "$HERE/../../_shared/hosts.conf" "$RT/hosts.conf"
RNOTE="$RT/vault/workers/remote-slug.md"
printf -- '---\nslug: remote-slug\nhost: homeserver\nharness: claude\n---\n' >"$RNOTE"
# A session note that is unconditionally newer than the run's marker: gate A's freshness
# check must be satisfied from this LOCAL vault, never over ssh.
printf '# session\n' >"$RT/vault/sessions/2026-09-15 remote.md"
touch_future "$RT/vault/sessions/2026-09-15 remote.md"

SSH_LOG="$RT/ssh.log"
FAKE_SSH="$RT/fake-ssh"
cat >"$FAKE_SSH" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$SSH_LOG"
case "\$*" in
  *has-session*)   exit 0 ;;
  # the worker answers its scoped persist by flipping the flag in the local vault
  *send-keys*)     printf 'collect_state: persisted\n' >"$RNOTE"; exit 0 ;;
  *capture-pane*)  cat "$FIX/claude/ready.txt"; exit 0 ;;
  *porcelain*)     exit 0 ;;          # clean git worktree
esac
exit 0
EOF
chmod +x "$FAKE_SSH"

ROUT="$(BRAIN_VAULT="$RT/vault" BRAIN_HOSTS="$RT/hosts.conf" BRAIN_SSH="$FAKE_SSH" \
        REAP_POLL_INTERVAL=1 REAP_MAX_WAIT=4 REAP_IDLE_STREAK=1 REAP_PERSIST_SETTLE=0 \
        bash "$HERE/teardown-worker.sh" --slug remote-slug --host homeserver --harness claude \
             --project-dir '~/projects/brain' --mode done --vcs git \
             --jj-workspace '~/projects/brain-worker-remote-slug' 2>&1)"
RLOG="$(cat "$SSH_LOG" 2>/dev/null)"

assert_contains "reaps the remote worker"            "REAPED remote-slug" "$ROUT"
assert_contains "every call goes through zsh -lc"    "homeserver zsh -lc" "$RLOG"
assert_contains "has-session routed to the host"     "has-session" "$RLOG"
assert_contains "capture-pane routed to the host"    "capture-pane" "$RLOG"
# The remote command is printf-%q-quoted before it crosses ssh, so spaces show up
# backslash-escaped in the log (see run_on_host) — match on that literal form.
assert_contains "capture-pane carries -e for claude" 'capture-pane\ -p\ -e' "$RLOG"
assert_contains "send-keys routed to the host"       "send-keys" "$RLOG"
assert_contains "the persist text is the harness's"  "brain-persist" "$RLOG"
assert_contains "kill-session routed to the host"    "kill-session" "$RLOG"
assert_contains "tmux is still invoked as 'command tmux'" 'command\ tmux' "$RLOG"
assert_contains "gate C git check routed to the host"     "porcelain" "$RLOG"
assert_contains "workspace removal routed to the host"    "worktree" "$RLOG"
assert_contains "workspace path left for the REMOTE shell to expand" "~/projects/brain-worker-remote-slug" "$RLOG"
assert_not_contains "gate A never leaves the local vault"  "collect_state" "$RLOG"
assert_not_contains "gate A's find never leaves the local vault" "sessions" "$RLOG"

# A worker whose note lives ONLY in private/workers/: gate A must read and flip that note.
echo "private worker note (only under private/workers):"
PT="$TMP/privnote"; mkdir -p "$PT/vault/private/workers" "$PT/vault/sessions"
cp "$HERE/../../_shared/hosts.conf" "$PT/hosts.conf"
PNOTE="$PT/vault/private/workers/priv-slug.md"
printf -- '---\nslug: priv-slug\nhost: homeserver\nharness: claude\n---\n' >"$PNOTE"
printf '# session\n' >"$PT/vault/sessions/2026-09-15 priv.md"
touch_future "$PT/vault/sessions/2026-09-15 priv.md"
PSSH="$PT/fake-ssh"
cat >"$PSSH" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *has-session*)   exit 0 ;;
  *send-keys*)     printf 'collect_state: persisted\n' >"$PNOTE"; exit 0 ;;
  *capture-pane*)  cat "$FIX/claude/ready.txt"; exit 0 ;;
esac
exit 0
EOF
chmod +x "$PSSH"
POUT="$(BRAIN_VAULT="$PT/vault" BRAIN_HOSTS="$PT/hosts.conf" BRAIN_SSH="$PSSH" \
        REAP_POLL_INTERVAL=1 REAP_MAX_WAIT=4 REAP_IDLE_STREAK=1 REAP_PERSIST_SETTLE=0 \
        bash "$HERE/teardown-worker.sh" --slug priv-slug --host homeserver --harness claude \
             --project-dir '~/projects/brain' --mode done --vcs git \
             --jj-workspace '~/projects/brain-worker-priv-slug' 2>&1)"
assert_contains "reaps a worker whose note is only in private/workers" "REAPED priv-slug" "$POUT"
assert_eq "persist flag was written to the private note" "collect_state: persisted" "$(grep '^collect_state:' "$PNOTE")"
assert_true "no stray note created under workers/" test ! -e "$PT/vault/workers/priv-slug.md"

# ---------------------------------------------------------------------------------
# An unreachable host must never be read as a finished worker: no REAPED, no teardown,
# stall to the cap instead. This is the outage that would otherwise delete live work.
# ---------------------------------------------------------------------------------
echo "unreachable host (ssh exits 255):"
UT="$TMP/unreach"; mkdir -p "$UT/vault/workers" "$UT/vault/sessions"
printf -- '---\nslug: gone-slug\n---\ncollect_state: persisted\n' >"$UT/vault/workers/gone-slug.md"
printf '# session\n' >"$UT/vault/sessions/2026-09-15 gone.md"
touch_future "$UT/vault/sessions/2026-09-15 gone.md"
UOUT="$(BRAIN_VAULT="$UT/vault" BRAIN_HOSTS="$TMP/hosts.conf" BRAIN_SSH="$DEADSSH" \
        REAP_POLL_INTERVAL=1 REAP_MAX_WAIT=2 REAP_IDLE_STREAK=1 REAP_PERSIST_SETTLE=0 \
        bash "$HERE/teardown-worker.sh" --slug gone-slug --host homeserver --harness claude \
             --project-dir '~/projects/brain' --mode done --vcs git \
             --jj-workspace '~/projects/brain-worker-gone-slug' 2>&1)"; URC=$?
assert_not_contains "never reaps an unreachable worker" "REAPED" "$UOUT"
assert_contains     "says the host is unreachable"      "unreachable" "$UOUT"
assert_contains     "stalls instead"                    "STALLED gone-slug" "$UOUT"
assert_eq           "exits 3 (stalled)"                 "3" "$URC"

# ---------------------------------------------------------------------------------
# The stall family (brain-dream 2026-10-19, proposal 4): a reaper that re-sends the
# persist prompt to an already-persisted worker, waits forever for a session note an
# unchanged-but-persisted worker never writes, reads a never-created workspace as dirty,
# and ends on a bare STALLED with no way forward.
# ---------------------------------------------------------------------------------
echo "artefacts_ready (unchanged-but-persisted, declined flip):"
SF="$TMP/stall"; mkdir -p "$SF/sessions"
SMARK="$SF/marker"; : >"$SMARK"; sleep 1
printf -- '---\nslug: s\nsession_id: abc-123\ncollect_state: persisted\n---\n' >"$SF/flag.md"
assert_true  "flag alone → ready (an unchanged worker writes no new session note)" artefacts_ready "$SF/flag.md" "$SMARK" "$SF/sessions"
printf -- '---\nslug: s\nsession_id: abc-123\ncollect_state: collecting\n---\n' >"$SF/coll.md"
printf '# other\n' >"$SF/sessions/2026-10-19 other.md"
assert_false "collecting + a fresh note for ANOTHER session → not ready" artefacts_ready "$SF/coll.md" "$SMARK" "$SF/sessions"
# The fallback keys on the session note's FRONTMATTER session id only: the coordinator's
# own session note routinely names the worker's slug (or even its id) in prose.
printf -- '---\nsession_ids: [zzz-999]\n---\nCollected worker s (session abc-123).\n' >"$SF/sessions/2026-10-19 coordinator.md"
assert_false "collecting + a fresh note naming slug/id only in its BODY → not ready" artefacts_ready "$SF/coll.md" "$SMARK" "$SF/sessions"
printf -- '---\nslug: s\ncollect_state: collecting\n---\n' >"$SF/noid.md"
assert_false "worker note with no session_id: no fallback (slug in a note is not enough)" artefacts_ready "$SF/noid.md" "$SMARK" "$SF/sessions"
printf -- '---\nsession_ids: [abc-123]\n---\n' >"$SF/sessions/2026-10-19 mine.md"
assert_true  "collecting + a fresh note carrying this session id → ready (worker declined the flip)" artefacts_ready "$SF/coll.md" "$SMARK" "$SF/sessions"
SF2="$TMP/stall2"; mkdir -p "$SF2/sessions"; : >"$SF2/marker"; sleep 1
printf -- '---\ndate: 2026-10-19\nsession_ids:\n  - zzz-999\n  - abc-123\n---\n' >"$SF2/sessions/2026-10-19 list.md"
assert_true  "block-list session_ids carrying this id → ready" artefacts_ready "$SF/coll.md" "$SF2/marker" "$SF2/sessions"

echo "already_persisted (idempotent trigger):"
# collect_started expires (MAX_WAIT + margin), so fixtures stamp it relative to now.
NOW="$(date +%Y-%m-%dT%H:%M:%S)"
AP="$TMP/ap"; mkdir -p "$AP/sessions"
printf -- '---\nslug: s\nsession_id: abc-123\ncollect_state: persisted\n---\n' >"$AP/nostart.md"
assert_false "persisted with no collect_started (stale, e.g. a resumed worker) → re-trigger" already_persisted "$AP/nostart.md" "$AP/sessions" "$AP/m1"
printf -- '---\nslug: s\nsession_id: abc-123\ncollect_state: persisted\ncollect_started: %s\n---\n' "$NOW" >"$AP/done.md"
assert_true  "persisted since collect_started → do not re-send" already_persisted "$AP/done.md" "$AP/sessions" "$AP/m2"
printf -- '---\nslug: s\nsession_id: abc-123\ncollect_state: persisted\ncollect_started: 2020-01-01T10:00:00\n---\n' >"$AP/old.md"
assert_false "persisted under an EXPIRED collect_started (an old STALLED) → re-trigger" already_persisted "$AP/old.md" "$AP/sessions" "$AP/m4"
assert_true  "collect_started_live: fresh stamp → live"    collect_started_live "$AP/done.md"
assert_false "collect_started_live: expired stamp → stale" collect_started_live "$AP/old.md"
assert_false "collect_started_live: absent → stale"        collect_started_live "$AP/nostart.md"
printf -- '---\nslug: s\nsession_id: abc-123\ncollect_state: collecting\ncollect_started: %s\n---\n' "$NOW" >"$AP/coll.md"
assert_false "stale collecting, nothing written since → re-trigger" already_persisted "$AP/coll.md" "$AP/sessions" "$AP/m3"

echo "no_unpushed (never-created workspace / merged @):"
assert_true  "declared jj workspace that was never created → clean" no_unpushed jj "$TMP/never-created-ws" desktop
assert_true  "declared git worktree that was never created → clean" no_unpushed git "$TMP/never-created-wt" desktop
MW="$TMP/mergedws"; mkdir -p "$MW"
MSTUB="$TMP/mergedstub"; mkdir -p "$MSTUB"
cat >"$MSTUB/jj" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *trunk*) echo 1 ;;        # @ is already an ancestor of trunk: merged
  *) echo 0 ;;              # non-empty, undescribed
esac
EOF
chmod +x "$MSTUB/jj"
assert_eq "undescribed @ already reachable from trunk → clean" "0" \
  "$(rc_of env PATH="$MSTUB:$PATH" bash -c 'source "$0"; no_unpushed jj "$1" desktop' "$HERE/teardown-worker.sh" "$MW")"

echo "idle_reason (why gate B fails):"
assert_eq "idle claude pane → empty reason"          ""                      "$(idle_reason claude "$(fixture claude ready)")"
assert_eq "unsent composer text"                     "unsent-composer-text"  "$(idle_reason claude "$(fixture claude busy-draft)")"
assert_eq "lingering background shell (qmd embed)"   "background-shell"      "$(idle_reason claude "$(fixture claude busy-bg-shell)")"
assert_eq "lingering background subagent"            "background-agents"     "$(idle_reason claude "$(fixture claude busy-bg-agents)")"
assert_eq "open question"                            "question"              "$(idle_reason claude "$(fixture claude question)")"
assert_eq "running turn"                             "busy"                  "$(idle_reason claude "$(fixture claude busy)")"

# Full runs: a fake ssh that answers tmux/git, so `main` is exercised end to end.
stall_run() {  # stall_run <dir> <capture-fixture> [extra args...]
  local d="$1" cap="$2"; shift 2
  cat >"$d/fake-ssh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$d/ssh.log"
case "\$*" in
  *has-session*)   exit 0 ;;
  *send-keys*)     [ -n "\${FLIP:-}" ] && sed -i.bak 's/^collect_state:.*/collect_state: persisted/' "$d/vault/workers/w.md"; exit 0 ;;
  *capture-pane*)  cat "$FIX/claude/$cap.txt"; exit 0 ;;
  *porcelain*)     exit 0 ;;
esac
exit 0
EOF
  chmod +x "$d/fake-ssh"
  BRAIN_VAULT="$d/vault" BRAIN_HOSTS="$TMP/hosts.conf" BRAIN_SSH="$d/fake-ssh" \
    REAP_POLL_INTERVAL=1 REAP_MAX_WAIT=3 REAP_IDLE_STREAK=1 REAP_PERSIST_SETTLE=0 REAP_DIALOG_SETTLE=0 \
    bash "$HERE/teardown-worker.sh" --slug w --host homeserver --harness claude \
         --project-dir '~/projects/brain' --mode done --vcs git --jj-workspace '~/projects/brain-worker-w' "$@" 2>&1
}
new_stall_dir() { local d="$TMP/$1"; mkdir -p "$d/vault/workers" "$d/vault/sessions"; : >"$d/ssh.log"; printf -- "$2" >"$d/vault/workers/w.md"; echo "$d"; }

echo "main: already persisted → no second persist prompt:"
D="$(new_stall_dir run-idem "---\\nslug: w\\nsession_id: abc-123\\ncollect_state: persisted\\ncollect_started: $NOW\\n---\\n")"
OUT="$(stall_run "$D" ready)"
assert_contains     "reaps"                       "REAPED w" "$OUT"
assert_not_contains "never re-sends the prompt"   "send-keys" "$(cat "$D/ssh.log")"
assert_eq "collect_started cleared on REAPED"     "" "$(grep '^collect_started:' "$D/vault/workers/w.md")"

echo "main: unchanged-but-persisted (no new session note):"
D="$(new_stall_dir run-unch '---\nslug: w\nsession_id: abc-123\ncollect_state: persisted\n---\n')"
OUT="$(FLIP=1 stall_run "$D" ready)"
assert_contains "stale persisted is re-triggered"  "send-keys" "$(cat "$D/ssh.log")"
assert_contains "reaps without a fresh sessions/*.md" "REAPED w" "$OUT"

echo "main: STALLED says why and offers --force:"
D="$(new_stall_dir run-draft '---\nslug: w\nsession_id: abc-123\n---\n')"
OUT="$(FLIP=1 stall_run "$D" busy-draft)"; RC=$?
assert_eq       "exits 3"                          "3" "$RC"
assert_contains "names the idle reason"            "idle=no reason=unsent-composer-text" "$OUT"
assert_contains "prints a force-reap command"      "--force" "$OUT"
: >"$D/ssh.log"
OUT="$(stall_run "$D" busy-draft --force)"
assert_contains     "--force reaps when A and C hold" "REAPED w" "$OUT"
assert_contains     "--force says it skipped the idle gate" "forced" "$OUT"
assert_not_contains "--force never re-sends the prompt" "send-keys" "$(cat "$D/ssh.log")"
D="$(new_stall_dir run-force-no '---\nslug: w\nsession_id: abc-123\ncollect_state: collecting\n---\n')"
OUT="$(stall_run "$D" busy-draft --force)"; RC=$?
assert_eq           "--force without A → rc 3"     "3" "$RC"
assert_not_contains "--force without A never reaps" "REAPED" "$OUT"
# A stale `persisted` from an earlier park, with no collect_started: --force must not take
# it as this collection's persist (that reaped with no persist and no idle gate).
D="$(new_stall_dir run-force-stale '---\nslug: w\nsession_id: abc-123\ncollect_state: persisted\n---\n')"
OUT="$(stall_run "$D" busy-draft --force)"; RC=$?
assert_eq           "--force with no collect_started → rc 3"      "3" "$RC"
assert_not_contains "--force with no collect_started never reaps" "REAPED" "$OUT"
assert_contains     "…and says why"                               "--force refused" "$OUT"
assert_contains     "…naming collect_started"                     "collect_started" "$OUT"
assert_not_contains "…and touches nothing on the host"            "kill-session" "$(cat "$D/ssh.log")"
D="$(new_stall_dir run-force-old '---\nslug: w\nsession_id: abc-123\ncollect_state: persisted\ncollect_started: 2020-01-01T10:00:00\n---\n')"
OUT="$(stall_run "$D" busy-draft --force)"; RC=$?
assert_eq           "--force with an expired collect_started → rc 3" "3" "$RC"
assert_not_contains "…never reaps"                                   "REAPED" "$OUT"

echo "main: expired collect_started re-triggers the persist:"
D="$(new_stall_dir run-expired '---\nslug: w\nsession_id: abc-123\ncollect_state: persisted\ncollect_started: 2020-01-01T10:00:00\n---\n')"
OUT="$(FLIP=1 stall_run "$D" ready)"
assert_contains "an old STALLED's stamp does not suppress a new persist" "brain-persist" "$(cat "$D/ssh.log")"
assert_contains "reaps once the new persist lands"                       "REAPED w" "$OUT"

# The persist prompt is never typed over an open dialog: Enter on Remote Control's
# "already connected" dialog could pick Disconnect, and on any question picks an option.
echo "main: persist trigger vs an open dialog:"
D="$(new_stall_dir run-question '---\nslug: w\nsession_id: abc-123\n---\n')"
OUT="$(FLIP=1 stall_run "$D" question)"; RC=$?
assert_not_contains "question open → persist text not typed" "brain-persist" "$(cat "$D/ssh.log")"
assert_not_contains "question open → no Enter sent"          "Enter" "$(cat "$D/ssh.log")"
assert_contains     "question open → reports reason=question" "reason=question" "$OUT"
assert_eq           "question open → STALLED rc 3"            "3" "$RC"
D="$(new_stall_dir run-rc-stuck '---\nslug: w\nsession_id: abc-123\n---\n')"
OUT="$(FLIP=1 stall_run "$D" rc-already-connected)"
assert_contains     "RC dialog → dismissed with Escape"        "Escape" "$(cat "$D/ssh.log")"
assert_not_contains "RC dialog that stays up → no Enter"       "Enter" "$(cat "$D/ssh.log")"
assert_not_contains "RC dialog that stays up → text not typed" "brain-persist" "$(cat "$D/ssh.log")"
# Escape clears it: the next capture is a ready composer, so the persist goes in.
D="$(new_stall_dir run-rc-clear '---\nslug: w\nsession_id: abc-123\n---\n')"
cat >"$D/fake-ssh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$D/ssh.log"
case "\$*" in
  *has-session*)      exit 0 ;;
  *send-keys*Escape*) : >"$D/escaped"; exit 0 ;;
  *send-keys*)        sed -i.bak 's/^collect_state:.*/collect_state: persisted/' "$D/vault/workers/w.md"; exit 0 ;;
  *capture-pane*)     if [ -e "$D/escaped" ]; then cat "$FIX/claude/ready.txt"; else cat "$FIX/claude/rc-already-connected.txt"; fi; exit 0 ;;
esac
exit 0
EOF
chmod +x "$D/fake-ssh"
OUT="$(BRAIN_VAULT="$D/vault" BRAIN_HOSTS="$TMP/hosts.conf" BRAIN_SSH="$D/fake-ssh" \
    REAP_POLL_INTERVAL=1 REAP_MAX_WAIT=3 REAP_IDLE_STREAK=1 REAP_PERSIST_SETTLE=0 REAP_DIALOG_SETTLE=0 \
    bash "$HERE/teardown-worker.sh" --slug w --host homeserver --harness claude \
         --project-dir '~/projects/brain' --mode done --vcs git --jj-workspace '~/projects/brain-worker-w' 2>&1)"
RCLOG="$(cat "$D/ssh.log")"
assert_contains "RC dialog dismissed, then the persist is typed" "brain-persist" "$RCLOG"
assert_eq       "Escape goes before the persist text" "Escape" "$(grep -oE 'Escape|brain-persist' <<<"$RCLOG" | head -1)"
assert_contains "…and the worker is reaped" "REAPED w" "$OUT"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
