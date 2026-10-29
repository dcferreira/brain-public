#!/usr/bin/env bash
#
# Tests for the three brain-dispatch scripts — preflight.sh, wait-for-brief.sh and
# launch-worker.sh (spec §5.7, task 4 brief cases (a)–(f)).
#
# Everything runs OFFLINE and touches no real harness, no real tmux, no ssh and no
# vault: `BRAIN_SSH` and `BRAIN_TMUX` are stubbed with fake scripts under a temp dir,
# `BRAIN_VAULT` points at a temp vault, and the only host exercised is the fixture's self
# host `testself` (whose run_on_host is a plain `bash -c`).
#
# The launch-worker case is the interesting one: the fake tmux answers `capture-pane`
# from a COUNTER file so the pane appears to move through the three states the launch
# dance must distinguish —
#   captures 1–2 : the shell prompt, with the `RDY-<slug>` marker echoed back
#   capture  3   : fixtures/<harness>/launch-typed.txt plus an echo of the literal line
#                  actually typed (command typed, NOT yet run — this is the false-ready
#                  trap: it contains the launch text but no composer, so pane_ready must
#                  still be false)
#   capture  4+  : fixtures/<harness>/ready.txt (the harness composer is up), optionally
#                  with a Remote Control line appended — the post-`/rc` pane, which only a
#                  claude launch ever reaches
# — and logs every invocation so the tests can assert the dance itself (C-u before
# typing, the typed line sent WITHOUT Enter, Enter as its own send-keys call, and the
# harness-gated `/rc <slug>` connect after the composer is verified up). Later sections
# cover conversation ids (claude `--session-id` pinning, omp session-file discovery under
# a fake HOME), `--resume` revival, and the remote ssh + `zsh -lc` quoting hop.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
FIX="$REPO/skills/_shared/lib/fixtures"
# shellcheck source=../../_shared/lib/harness-chrome.sh
. "$REPO/skills/_shared/lib/harness-chrome.sh"

PASS=0 FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
assert_eq()       { local d="$1" want="$2" got="$3"; if [ "$want" = "$got" ]; then ok "$d"; else bad "$d (want '$want' got '$got')"; fi; }
assert_contains() { local d="$1" needle="$2" hay="$3"; case "$hay" in *"$needle"*) ok "$d" ;; *) bad "$d (missing '$needle' in '$hay')" ;; esac; }
assert_not_contains() { local d="$1" needle="$2" hay="$3"; case "$hay" in *"$needle"*) bad "$d (unexpected '$needle' in '$hay')" ;; *) ok "$d" ;; esac; }
assert_matches()  { local d="$1" re="$2" s="$3"; if printf '%s' "$s" | grep -qE "$re"; then ok "$d"; else bad "$d ('$s' !~ /$re/)"; fi; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export BRAIN_ROOT="$REPO"
# A fixture hosts.conf with a self row of our own, so nothing depends on the real machine's
# hostname or on the production registry: BRAIN_SELF_HOST pins who "this machine" is.
SELF=testself
cat >"$TMP/hosts.conf" <<'EOF'
# name      ssh_alias      harnesses   default_harness  hostnames
testself    -              omp,claude  omp              testself-box
homeserver       homeserver          claude      claude           homeserver
EOF
export BRAIN_HOSTS="$TMP/hosts.conf"
export BRAIN_SELF_HOST="$SELF"

# A fake ssh that would print instead of connecting: any test that reaches it is a bug
# (only the self host is exercised), but it guarantees the suite can never touch the network.
cat >"$TMP/fake-ssh" <<'EOF'
#!/usr/bin/env bash
echo "fake-ssh: $*" >&2
exit 0
EOF
chmod +x "$TMP/fake-ssh"
export BRAIN_SSH="$TMP/fake-ssh"

# A stub `omp` on PATH. preflight.sh probes the harness binary on the host's own login
# PATH, so without this the whole preflight block depends on which harnesses happen to be
# installed on the machine running the suite (a claude-only host such as homeserver, so every
# `harness_bin=present` case would fail there). Case (d) below deliberately keeps its own
# stripped PATH, so the "binary missing" path is still exercised for real.
STUB_BIN="$TMP/stub-bin"; mkdir -p "$STUB_BIN"
printf '#!/usr/bin/env bash\nexit 0\n' >"$STUB_BIN/omp"
chmod +x "$STUB_BIN/omp"
export PATH="$STUB_BIN:$PATH"

# with_timeout <seconds> <cmd...> — run <cmd> under a wall-clock cap and return its exit
# status, or 124 if the cap was hit (the same convention as coreutils `timeout`). Uses
# `timeout`/`gtimeout` when either is installed; otherwise falls back to a background
# child plus a watchdog that kills it, so the hang guard still holds on a stock macOS
# with no coreutils.
if command -v timeout >/dev/null 2>&1; then
    with_timeout() { timeout "$@"; }
elif command -v gtimeout >/dev/null 2>&1; then
    with_timeout() { gtimeout "$@"; }
else
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

# Sleeps are collapsed so the suite runs in ~5 s instead of ~40 s.
export DISPATCH_PROBE_SLEEP=0
export DISPATCH_VERIFY_SLEEP=0
export DISPATCH_RC_SLEEP=0

# ---------------------------------------------------------------- preflight.sh ----

echo "preflight.sh:"

# (a) disallowed host/harness pair — homeserver speaks claude only — refused before any probe.
OUT="$("$HERE/preflight.sh" --host homeserver --harness omp --project-dir "$TMP" 2>"$TMP/err.a")"; RC=$?
assert_eq "(a) --host homeserver --harness omp → rc 2" "2" "$RC"
assert_eq "(a) prints nothing on stdout"        ""  "$OUT"
assert_contains "(a) explains on stderr" "harness" "$(cat "$TMP/err.a")"

# (b) a colocated checkout (both .jj and .git present) is jj.
PROJ="$TMP/proj"; mkdir -p "$PROJ/.jj" "$PROJ/.git"
OUT="$("$HERE/preflight.sh" --host "$SELF" --harness omp --project-dir "$PROJ" 2>/dev/null)"; RC=$?
assert_contains "(b) dir_exists=yes"            "dir_exists=yes" "$OUT"
assert_contains "(b) colocated .jj+.git → jj"   "vcs=jj"         "$OUT"
assert_eq       "(b) rc 0"                      "0"              "$RC"
assert_contains "(b) harness_bin reported"      "harness_bin="   "$OUT"

# a bare directory has no VCS
OUT="$("$HERE/preflight.sh" --host "$SELF" --harness omp --project-dir "$TMP" 2>/dev/null)"
assert_contains "(b) no .jj/.git → vcs=none" "vcs=none" "$OUT"

# a missing directory is a hard failure
OUT="$("$HERE/preflight.sh" --host "$SELF" --harness omp --project-dir "$TMP/nope" 2>/dev/null)"; RC=$?
assert_contains "(b) missing dir → dir_exists=no" "dir_exists=no" "$OUT"
assert_eq       "(b) missing dir → rc 1"          "1"             "$RC"

# (c) free_gb is a bare integer (GNU or BSD df, chosen by the host's uname).
OUT="$("$HERE/preflight.sh" --host "$SELF" --harness omp --project-dir "$PROJ" 2>/dev/null)"
FREE="$(printf '%s\n' "$OUT" | tr ' ' '\n' | sed -n 's/^free_gb=//p')"
assert_matches "(c) free_gb is an integer" '^[0-9]+$' "$FREE"

# (d) --harness claude with a PATH that has no `claude` → harness_bin=missing, rc 1.
OUT="$(PATH=/usr/bin:/bin "$HERE/preflight.sh" --host "$SELF" --harness claude --project-dir "$PROJ" 2>/dev/null)"; RC=$?
assert_contains "(d) claude off PATH → harness_bin=missing" "harness_bin=missing" "$OUT"
assert_eq       "(d) rc 1"                                  "1"                   "$RC"
assert_contains "(d) guardrail n/a for claude"              "guardrail=n/a"       "$OUT"

# bad args are rc 2, like a disallowed pair
"$HERE/preflight.sh" --host "$SELF" --harness omp >/dev/null 2>&1; RC=$?
assert_eq "(a) missing --project-dir → rc 2"  "2" "$RC"
"$HERE/preflight.sh" --host "$SELF" --harness nope --project-dir "$PROJ" >/dev/null 2>&1; RC=$?
assert_eq "(a) unknown harness → rc 2"        "2" "$RC"
"$HERE/preflight.sh" --host nowhere --harness omp --project-dir "$PROJ" >/dev/null 2>&1; RC=$?
assert_eq "(a) unknown host → rc 2"           "2" "$RC"

# self-name handling: `--host local` is a deprecated alias for self; an unknown host and an
# unresolved self host are refused with a clear message.
OUT="$("$HERE/preflight.sh" --host local --harness omp --project-dir "$PROJ" 2>"$TMP/err.legacy")"; RC=$?
assert_eq       "(h) --host local (deprecated alias) still works → rc 0" "0" "$RC"
assert_contains "(h) --host local → dir_exists=yes"   "dir_exists=yes" "$OUT"
"$HERE/preflight.sh" --host nowhere --harness omp --project-dir "$PROJ" >/dev/null 2>"$TMP/err.unk"
assert_contains "(h) unknown host → clear message"    "unknown host: nowhere" "$(cat "$TMP/err.unk")"
for H in local; do
    OUT="$(BRAIN_SELF_HOST='' BRAIN_HOSTNAME=no-such-machine "$HERE/preflight.sh" --host "$H" --harness omp --project-dir "$PROJ" 2>"$TMP/err.unres")"; RC=$?
    assert_eq       "(h) unresolved self (host '$H') → rc 2" "2" "$RC"
    assert_contains "(h) unresolved self → names BRAIN_SELF_HOST" "BRAIN_SELF_HOST" "$(cat "$TMP/err.unres")"
    assert_contains "(h) unresolved self → names hosts.conf"       "hosts.conf" "$(cat "$TMP/err.unres")"
done
BRAIN_SELF_HOST='' BRAIN_HOSTNAME=testself-box "$HERE/preflight.sh" --host local --harness omp --project-dir "$PROJ" >/dev/null 2>&1; RC=$?
assert_eq "(h) self resolved from hostname → --host local rc 0" "0" "$RC"

# ------------------------------------------------------------ wait-for-brief.sh ----

echo "wait-for-brief.sh:"

# (e) present in the (temp) vault → synced=yes, immediately.
VAULT="$TMP/vault"; mkdir -p "$VAULT/workers"
printf -- '---\nslug: here\n---\n' >"$VAULT/workers/here.md"
OUT="$(BRAIN_VAULT="$VAULT" "$HERE/wait-for-brief.sh" --host "$SELF" --slug here 2>/dev/null)"; RC=$?
assert_eq "(e) note present → synced=yes" "synced=yes" "$OUT"
assert_eq "(e) rc 0"                      "0"          "$RC"

# (e) absent, with a short timeout → synced=no, rc 1, and it really waits.
T0=$SECONDS
OUT="$(BRAIN_VAULT="$VAULT" "$HERE/wait-for-brief.sh" --host "$SELF" --slug gone --timeout 4 2>/dev/null)"; RC=$?
ELAPSED=$((SECONDS - T0))
assert_eq "(e) note absent → synced=no" "synced=no" "$OUT"
assert_eq "(e) rc 1"                    "1"         "$RC"
if [ "$ELAPSED" -ge 3 ] && [ "$ELAPSED" -le 12 ]; then ok "(e) honoured --timeout 4 (${ELAPSED}s)"; else bad "(e) --timeout 4 took ${ELAPSED}s"; fi

"$HERE/wait-for-brief.sh" --host "$SELF" >/dev/null 2>&1; RC=$?
assert_eq "(e) missing --slug → rc 2" "2" "$RC"

# (h) wait-for-brief: `--host local` is the deprecated alias for self; unknown / unresolved refused.
OUT="$(BRAIN_VAULT="$VAULT" "$HERE/wait-for-brief.sh" --host local --slug here 2>/dev/null)"; RC=$?
assert_eq "(h) wait-for-brief --host local (deprecated alias) → synced=yes" "synced=yes" "$OUT"
"$HERE/wait-for-brief.sh" --host nowhere --slug here >/dev/null 2>"$TMP/err.wunk"; RC=$?
assert_eq "(h) wait-for-brief unknown host → rc 2" "2" "$RC"
assert_contains "(h) wait-for-brief unknown host → clear message" "unknown host: nowhere" "$(cat "$TMP/err.wunk")"
BRAIN_SELF_HOST='' BRAIN_HOSTNAME=no-such-machine "$HERE/wait-for-brief.sh" --host local --slug here >/dev/null 2>"$TMP/err.wres"; RC=$?
assert_eq "(h) wait-for-brief unresolved self → rc 2" "2" "$RC"
assert_contains "(h) wait-for-brief unresolved self → names BRAIN_SELF_HOST" "BRAIN_SELF_HOST" "$(cat "$TMP/err.wres")"

# ------------------------------------------------------------- launch-worker.sh ----

echo "launch-worker.sh:"

# (h) launch-worker host handling, before anything is launched: unknown host and unresolved
# self are rc 2 with a clear message and no tmux call (BRAIN_TMUX points at a stub that fails).
"$HERE/launch-worker.sh" --host nowhere --harness omp --slug x --project-dir "$TMP" >/dev/null 2>"$TMP/err.lunk"; RC=$?
assert_eq "(h) launch-worker unknown host → rc 2" "2" "$RC"
assert_contains "(h) launch-worker unknown host → clear message" "unknown host: nowhere" "$(cat "$TMP/err.lunk")"
BRAIN_SELF_HOST='' BRAIN_HOSTNAME=no-such-machine "$HERE/launch-worker.sh" --host local --harness omp --slug x --project-dir "$TMP" >/dev/null 2>"$TMP/err.lres"; RC=$?
assert_eq "(h) launch-worker unresolved self → rc 2" "2" "$RC"
assert_contains "(h) launch-worker unresolved self → names BRAIN_SELF_HOST" "BRAIN_SELF_HOST" "$(cat "$TMP/err.lres")"
# `--host local` is canonicalised: the could-not-create message names the real host, never `local`.
FAILT="$TMP/fake-tmux.fail"; printf '#!/usr/bin/env bash\nexit 1\n' >"$FAILT"; chmod +x "$FAILT"
BRAIN_TMUX="$FAILT" "$HERE/launch-worker.sh" --host local --harness omp --slug canon --project-dir "$TMP" >/dev/null 2>"$TMP/err.lcanon"; RC=$?
assert_eq "(h) launch-worker --host local (deprecated alias) reaches tmux → rc 1" "1" "$RC"
assert_contains "(h) launch-worker messages name the canonical host" "on $SELF" "$(cat "$TMP/err.lcanon")"
assert_not_contains "(h) launch-worker messages never say 'on local'" "on local" "$(cat "$TMP/err.lcanon")"

# An empty fake HOME for launch-worker runs: an omp launch looks for its new session file
# under ~/.omp/agent/sessions, and the suite must never read the real one.
FAKE_HOME="$TMP/home"; mkdir -p "$FAKE_HOME"
# A fixed conversation id for claude launches (LAUNCH_SESSION_ID is launch-worker's test
# override for uuid generation). Unset per-case where generation itself is under test.
export LAUNCH_SESSION_ID=0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d

make_fake_tmux() {
    # $1 = harness, $2 = slug, $3 = path to write the fake to, $4 = counter, $5 = log,
    # $6 = Remote Control tail: `connected` appends a Remote Control line to the post-ready
    #      captures, anything else leaves them as the bare ready fixture.
    # $7 = model, optional and now redundant: capture 3 echoes back whatever literal was
    #      last typed (see TYPED below), so a `--model` launch line shows up by itself.
    # $8 = the fixture served once the harness is up (default `ready`): `busy-thinking`
    #      etc. model a priming turn that is already streaming when dispatch looks.
    #
    # The ladder: captures 1–2 the shell prompt, 3 launch-typed, 4 the ready fixture (which
    # ends the verify poll), and 5+ the POST-`/rc` pane — only claude gets that far, since
    # only claude has a Remote Control command to send. No fixture holds a connected pane
    # (see fixtures/README.md), so the connected state is faked with an inline line.
    #
    # TYPED: real tmux always echoes back what was actually typed, so every literal
    # send-keys (4 args: `send-keys -t <session> <text>`, not a bare key name) is saved and
    # printed under the launch-typed fixture on capture 3, as a shell-prompt line with no
    # composer chrome — the false-ready guard still holds. This is what makes a claude
    # launch line carrying `--session-id <uuid>` (and so a different marker) verifiable.
    local rc_tail=''
    [ "${6:-}" = connected ] && rc_tail='printf "%s\n" "  Remote Control session: '"$2"'"'
    cat >"$3" <<EOF
#!/usr/bin/env bash
# Fake tmux: logs every call, and answers capture-pane from a counter file so the pane
# walks shell-prompt → launch-typed → ready → (post-/rc).
printf '%s\n' "\$*" >>"$5"
if [ "\${1:-}" = send-keys ] && [ \$# -eq 4 ]; then
    case "\$4" in C-u|Enter|Down) ;; *) printf '%s' "\$4" >"$4.typed" ;; esac
fi
[ "\${1:-}" = "capture-pane" ] || exit 0
n=\$(( \$(cat "$4" 2>/dev/null || echo 0) + 1 ))
printf '%s' "\$n" >"$4"
if [ "\$n" -le 2 ]; then
    printf '%s\n' "~/projects/brain \$ echo RDY-$2" "RDY-$2" "~/projects/brain \$ "
elif [ "\$n" -eq 3 ]; then
    cat "$FIX/$1/launch-typed.txt"
    printf '~/projects/brain \$ %s\n' "\$(cat "$4.typed" 2>/dev/null)"
else
    # FAKE_ON_READY (env, optional): run once the harness is "up" — how a test has omp
    # write its session file only AFTER launch, as the real one does.
    [ -z "\${FAKE_ON_READY:-}" ] || eval "\$FAKE_ON_READY"
    cat "$FIX/$1/${8:-ready}.txt"
    $rc_tail
fi
EOF
    chmod +x "$3"
}

for H in omp claude; do
    SLUG="fake-$H"
    CNT="$TMP/cnt.$H"; LOG="$TMP/log.$H"; FT="$TMP/fake-tmux.$H"
    : >"$LOG"; rm -f "$CNT"
    make_fake_tmux "$H" "$SLUG" "$FT" "$CNT" "$LOG" connected

    OUT="$(HOME="$FAKE_HOME" BRAIN_TMUX="$FT" "$HERE/launch-worker.sh" --host "$SELF" --harness "$H" \
            --slug "$SLUG" --project-dir "$PROJ" 2>"$TMP/err.$H")"; RC=$?
    LOGTXT="$(cat "$LOG")"

    assert_eq       "(f) $H verified=yes"  "verified=yes" "$(printf '%s\n' "$OUT" | tr ' ' '\n' | sed -n '/^verified=/p')"
    assert_eq       "(f) $H rc 0"          "0" "$RC"
    assert_contains "(f) $H session name"  "session=brain-worker-$SLUG" "$OUT"
    assert_contains "(f) $H attach string" "attach=tmux attach -t brain-worker-$SLUG" "$OUT"
    # Remote Control: claude is named at launch by `--remote-control <slug>` and the
    # follow-up capture shows a Remote Control session; nothing is typed after the launch
    # (a `/rc` on a connected session only opens the "already connected" dialog). omp has
    # no Remote Control at all.
    if [ "$H" = claude ]; then WANT_RC=yes; else WANT_RC=n/a; fi
    WANT_ENTERS=1
    assert_eq       "(f) $H rc=$WANT_RC" "rc=$WANT_RC" \
        "$(printf '%s\n' "$OUT" | tr ' ' '\n' | sed -n '/^rc=/p')"
    assert_contains "(f) $H one line"      "verified=yes session=brain-worker-$SLUG rc=$WANT_RC attach=tmux attach -t brain-worker-$SLUG" "$OUT"
    assert_eq       "(f) $H stdout is exactly one line" "1" "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')"
    if [ "$H" = claude ]; then
        assert_contains "(f) claude names Remote Control at launch, before --session-id" \
            "send-keys -t brain-worker-$SLUG claude --remote-control $SLUG --session-id $LAUNCH_SESSION_ID \"Read your worker brief" "$LOGTXT"
    else
        assert_not_contains "(f) omp gets no --remote-control" "--remote-control" "$LOGTXT"
    fi
    if printf '%s\n' "$LOGTXT" | grep -q '/rc'; then
        bad "(f) $H must never be sent /rc"
    else
        ok  "(f) $H is never sent /rc"
    fi

    # the dance itself
    assert_contains "(f) $H new-session detached in the project dir" \
        "new-session -d -s brain-worker-$SLUG -c $PROJ" "$LOGTXT"
    assert_contains "(f) $H probes with the RDY marker" "echo RDY-$SLUG" "$LOGTXT"
    assert_contains "(f) $H clears the line with C-u"   "send-keys -t brain-worker-$SLUG C-u" "$LOGTXT"
    assert_contains "(f) $H types the launch command"   "Read your worker brief" "$LOGTXT"
    assert_contains "(f) $H brief path is the slug's worker note" \
        "Obsidian/vault/workers/$SLUG.md" "$LOGTXT"
    # Enter is its own send-keys call — never appended to the typed command line, and only
    # the launch line is ever Entered.
    assert_eq "(f) $H Enter sent as a separate call ($WANT_ENTERS bare Enter(s))" "$WANT_ENTERS" \
        "$(printf '%s\n' "$LOGTXT" | grep -cx "send-keys -t brain-worker-$SLUG Enter")"
    if printf '%s\n' "$LOGTXT" | grep -qE 'Read your worker brief.*Enter$'; then
        bad "(f) $H typed the command and Enter in one call"
    else
        ok  "(f) $H typed the command WITHOUT Enter"
    fi
done

# Scope plumbing: --scope/--project become tmux env on session creation, --note-dir moves
# the brief path; with none of them the new-session argv is byte-identical (the (f) loop
# above asserts the default `workers` path and `new-session ... -c $PROJ`).
H=claude; SLUG="fake-scope"
CNT="$TMP/cnt.scope"; LOG="$TMP/log.scope"; FT="$TMP/fake-tmux.scope"; : >"$LOG"; rm -f "$CNT"
make_fake_tmux "$H" "$SLUG" "$FT" "$CNT" "$LOG" connected
OUT="$(BRAIN_TMUX="$FT" "$HERE/launch-worker.sh" --host "$SELF" --harness "$H" --slug "$SLUG" \
        --project-dir "$PROJ" --scope private --project clientco --note-dir private/workers 2>"$TMP/err.scope")"; RC=$?
LOGTXT="$(cat "$LOG")"
assert_eq "(scope) private launch rc 0" "0" "$RC"
assert_contains "(scope) new-session carries -e BRAIN_SCOPE/-e BRAIN_PROJECT" \
    "new-session -d -s brain-worker-$SLUG -c $PROJ -e BRAIN_SCOPE=private -e BRAIN_PROJECT=clientco" "$LOGTXT"
assert_contains "(scope) brief sentence points at private/workers" \
    "Obsidian/vault/private/workers/$SLUG.md" "$LOGTXT"
: >"$LOG"; rm -f "$CNT"
BRAIN_TMUX="$FT" "$HERE/launch-worker.sh" --host "$SELF" --harness "$H" --slug "$SLUG" \
    --project-dir "$PROJ" --scope all >/dev/null 2>&1
LOGTXT="$(cat "$LOG")"
assert_contains "(scope) --scope alone → BRAIN_SCOPE=all and an empty BRAIN_PROJECT" \
    "new-session -d -s brain-worker-$SLUG -c $PROJ -e BRAIN_SCOPE=all -e BRAIN_PROJECT=" "$LOGTXT"
assert_not_contains "(scope) --scope alone sets no project value" "BRAIN_PROJECT=g" "$LOGTXT"
: >"$LOG"; rm -f "$CNT"
BRAIN_TMUX="$FT" "$HERE/launch-worker.sh" --host "$SELF" --harness "$H" --slug "$SLUG" \
    --project-dir "$PROJ" >/dev/null 2>&1
assert_eq "(scope) no scope flag → new-session still pins BRAIN_SCOPE=shared" \
    "new-session -d -s brain-worker-$SLUG -c $PROJ -e BRAIN_SCOPE=shared -e BRAIN_PROJECT=" "$(grep '^new-session' "$LOG")"
for BAD in "--scope bogus" "--project Bad_Slug" "--project -x" "--note-dir elsewhere"; do
    : >"$LOG"
    # shellcheck disable=SC2086
    BRAIN_TMUX="$FT" "$HERE/launch-worker.sh" --host "$SELF" --harness "$H" --slug "$SLUG" \
        --project-dir "$PROJ" $BAD >/dev/null 2>&1; RC=$?
    assert_eq "(scope) '$BAD' → rc 2" "2" "$RC"
    assert_eq "(scope) '$BAD' → tmux never touched" "" "$(cat "$LOG")"
done

# wait-for-brief --note-dir: a note only under private/workers.
mkdir -p "$VAULT/private/workers"
printf -- '---\nslug: priv\n---\n' >"$VAULT/private/workers/priv.md"
OUT="$(BRAIN_VAULT="$VAULT" "$HERE/wait-for-brief.sh" --host "$SELF" --slug priv --note-dir private/workers 2>/dev/null)"; RC=$?
assert_eq "(scope) wait-for-brief --note-dir private/workers finds it" "synced=yes" "$OUT"
OUT="$(BRAIN_VAULT="$VAULT" "$HERE/wait-for-brief.sh" --host "$SELF" --slug priv --timeout 0 2>/dev/null)"; RC=$?
assert_eq "(scope) default note dir does not see a private note" "synced=no" "$OUT"
BRAIN_VAULT="$VAULT" "$HERE/wait-for-brief.sh" --host "$SELF" --slug priv --note-dir nope >/dev/null 2>&1; RC=$?
assert_eq "(scope) wait-for-brief bad --note-dir → rc 2" "2" "$RC"

# Brain-repo guard: ~/projects/brain/.claude/settings.json forces BRAIN_SCOPE=all and overrides
# the per-worker scope, so a FRESH non-all launch rooted there is refused (rc 2, tmux never
# touched); a --resume warns on stderr and proceeds (old workers cannot be moved).
H=claude; SLUG="fake-brainguard"
CNT="$TMP/cnt.bg"; LOG="$TMP/log.bg"; FT="$TMP/fake-tmux.bg"; : >"$LOG"; rm -f "$CNT"
make_fake_tmux "$H" "$SLUG" "$FT" "$CNT" "$LOG" connected
for BD in '~/projects/brain' '~/projects/brain/' "$HOME/projects/brain" "$HOME/projects/brain/" \
    '~/projects/brain//' '~/projects//brain' '~/projects/./brain' '~/projects/brain/.' '/Users/someone/projects/brain'; do
    for SC in "--scope shared" ""; do
        : >"$LOG"; rm -f "$CNT"
        # shellcheck disable=SC2086
        BRAIN_TMUX="$FT" "$HERE/launch-worker.sh" --host "$SELF" --harness "$H" --slug "$SLUG" \
            --project-dir "$BD" $SC >/dev/null 2>"$TMP/err.bg"; RC=$?
        assert_eq "(brain-guard) fresh in $BD [$SC] → rc 2" "2" "$RC"
        assert_eq "(brain-guard) fresh in $BD [$SC] → tmux never touched" "" "$(cat "$LOG")"
        assert_contains "(brain-guard) refusal points at workbench" "~/projects/workbench" "$(cat "$TMP/err.bg")"
    done
done
: >"$LOG"; rm -f "$CNT"
OUT="$(BRAIN_TMUX="$FT" "$HERE/launch-worker.sh" --host "$SELF" --harness "$H" --slug "$SLUG" \
        --project-dir '~/projects/brain' --scope all 2>"$TMP/err.bg")"; RC=$?
assert_eq "(brain-guard) fresh + brain + all → rc 0" "0" "$RC"
assert_contains "(brain-guard) fresh + brain + all → launched" "new-session -d -s brain-worker-$SLUG" "$(cat "$LOG")"
: >"$LOG"; rm -f "$CNT"
BRAIN_TMUX="$FT" "$HERE/launch-worker.sh" --host "$SELF" --harness "$H" --slug "$SLUG" \
    --project-dir '~/projects/workbench' --scope shared >/dev/null 2>"$TMP/err.bg"; RC=$?
assert_eq "(brain-guard) workbench + shared → rc 0" "0" "$RC"
assert_contains "(brain-guard) workbench + shared → launched" "new-session -d -s brain-worker-$SLUG" "$(cat "$LOG")"
: >"$LOG"; rm -f "$CNT"
OUT="$(env -u LAUNCH_SESSION_ID BRAIN_TMUX="$FT" "$HERE/launch-worker.sh" --host "$SELF" --harness "$H" --slug "$SLUG" \
        --project-dir '~/projects/brain' --scope shared --resume 0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d 2>"$TMP/err.bg")"; RC=$?
assert_eq "(brain-guard) resume + brain + shared → rc 0 (proceeds)" "0" "$RC"
assert_contains "(brain-guard) resume + brain + shared → warns on stderr" "warning" "$(cat "$TMP/err.bg")"
assert_contains "(brain-guard) resume + brain + shared → launched" "new-session -d -s brain-worker-$SLUG" "$(cat "$LOG")"

# --model: threads a model id into the typed launch command for both harnesses. Omission
# (the loop above, no --model passed) must leave the typed command byte-identical to
# before this flag existed — asserted there already by "(f) $H types the launch command".
for H in omp claude; do
    SLUG="fake-model-$H"
    CNT="$TMP/cnt.model.$H"; LOG="$TMP/log.model.$H"; FT="$TMP/fake-tmux.model.$H"
    : >"$LOG"; rm -f "$CNT"
    make_fake_tmux "$H" "$SLUG" "$FT" "$CNT" "$LOG" '' claude-opus-5

    OUT="$(BRAIN_TMUX="$FT" "$HERE/launch-worker.sh" --host "$SELF" --harness "$H" \
            --slug "$SLUG" --project-dir "$PROJ" --model claude-opus-5 \
            2>"$TMP/err.model.$H")"; RC=$?
    LOGTXT="$(cat "$LOG")"

    assert_eq "(f) $H --model verified=yes" "verified=yes" \
        "$(printf '%s\n' "$OUT" | tr ' ' '\n' | sed -n '/^verified=/p')"
    assert_eq "(f) $H --model rc 0" "0" "$RC"
    if [ "$H" = omp ]; then
        assert_contains "(f) omp --model sits before --auto-approve" \
            "omp --model claude-opus-5 --auto-approve" "$LOGTXT"
    else
        assert_contains "(f) claude --model sits before the sentence" \
            "claude --model claude-opus-5 --remote-control $SLUG --session-id $LAUNCH_SESSION_ID \"Read your worker brief" "$LOGTXT"
    fi
done
assert_eq "(f) launch-worker.sh --model with no value → rc 2" "2" \
    "$("$HERE/launch-worker.sh" --host "$SELF" --harness claude --slug x \
        --project-dir "$PROJ" --model >/dev/null 2>&1; echo $?)"

# The priming turn is ALREADY STREAMING when dispatch first looks (the brief is passed as
# the positional prompt): the pane is busy, not ready — but the harness is up, so the
# launch is verified (reviewer finding: pane_ready vetoes busy, and the verify loop timed
# out "composer never appeared" on a healthy worker).
for HB in "claude busy-thinking" "claude busy-thinking-styled" "claude busy" "omp busy"; do
    H="${HB%% *}" BF="${HB#* }"
    SLUG="fake-busy-$H-$BF"
    CNT="$TMP/cnt.$SLUG"; LOG="$TMP/log.$SLUG"; FT="$TMP/fake-tmux.$SLUG"
    : >"$LOG"; rm -f "$CNT"
    make_fake_tmux "$H" "$SLUG" "$FT" "$CNT" "$LOG" connected '' "$BF"
    OUT="$(HOME="$FAKE_HOME" DISPATCH_VERIFY_TRIES=3 BRAIN_TMUX="$FT" "$HERE/launch-worker.sh" --host "$SELF" \
            --harness "$H" --slug "$SLUG" --project-dir "$PROJ" 2>"$TMP/err.$SLUG")"; RC=$?
    assert_contains "(f) $H pane already busy ($BF) → verified=yes" "verified=yes" "$OUT"
    assert_eq       "(f) $H pane already busy ($BF) → rc 0" "0" "$RC"
done

# Remote Control that does NOT connect: same ladder, but the post-launch captures are the bare
# ready fixture with no Remote Control line. RC is a convenience, not a launch gate, so the
# worker is still verified=yes at rc 0 — only the `rc=` key changes, and stderr says so.
SLUG=norc
CNT="$TMP/cnt.norc"; LOG="$TMP/log.norc"; FT="$TMP/fake-tmux.norc"
: >"$LOG"; rm -f "$CNT"
make_fake_tmux claude "$SLUG" "$FT" "$CNT" "$LOG"
OUT="$(BRAIN_TMUX="$FT" "$HERE/launch-worker.sh" --host "$SELF" --harness claude \
        --slug "$SLUG" --project-dir "$PROJ" 2>"$TMP/err.norc")"; RC=$?
LOGTXT="$(cat "$LOG")"
assert_contains "(f) /rc unconfirmed → rc=no"          "rc=no"        "$OUT"
assert_contains "(f) /rc unconfirmed → still verified=yes" "verified=yes" "$OUT"
assert_eq       "(f) /rc unconfirmed → still rc 0"     "0"            "$RC"
assert_contains "(f) rc unconfirmed → it was requested at launch" "--remote-control $SLUG" "$LOGTXT"
assert_not_contains "(f) rc unconfirmed → still no /rc typed" "/rc" "$LOGTXT"
assert_contains "(f) /rc unconfirmed → says so on stderr, not a launch gate" \
    "Remote Control" "$(cat "$TMP/err.norc")"

# a pane that never reaches ready → verified=no, rc 1, session left running.
STUCK="$TMP/fake-tmux.stuck"; LOG="$TMP/log.stuck"; : >"$LOG"
cat >"$STUCK" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$LOG"
[ "\${1:-}" = "capture-pane" ] || exit 0
printf '%s\n' "~/projects/brain \$ echo RDY-stuck" "RDY-stuck" "~/projects/brain \$ "
EOF
chmod +x "$STUCK"
OUT="$(DISPATCH_VERIFY_TRIES=2 BRAIN_TMUX="$STUCK" "$HERE/launch-worker.sh" --host "$SELF" \
        --harness omp --slug stuck --project-dir "$PROJ" 2>"$TMP/err.stuck")"; RC=$?
assert_contains "(f) never-ready pane → verified=no" "verified=no" "$OUT"
assert_eq       "(f) never-ready pane → rc 1"        "1"           "$RC"
assert_contains "(f) says the session is left running" "left running" "$(cat "$TMP/err.stuck")"
if printf '%s\n' "$(cat "$LOG")" | grep -q '^kill-session'; then
    bad "(f) must NOT kill the session on failure"
else
    ok  "(f) leaves the session for inspection"
fi

# claude's folder-trust dialog: Down THEN Enter, as two separate send-keys calls —
# a bare Enter would select "No, exit" and kill the harness.
TRUST="$TMP/fake-tmux.trust"; LOG="$TMP/log.trust"; CNT="$TMP/cnt.trust"; : >"$LOG"; rm -f "$CNT"
cat >"$TRUST" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$LOG"
[ "\${1:-}" = send-keys ] && [ \$# -eq 4 ] && case "\$4" in C-u|Enter|Down) ;; *) printf '%s' "\$4" >"$CNT.typed" ;; esac
[ "\${1:-}" = "capture-pane" ] || exit 0
n=\$(( \$(cat "$CNT" 2>/dev/null || echo 0) + 1 ))
printf '%s' "\$n" >"$CNT"
if [ "\$n" -le 2 ]; then printf '%s\n' "~/p \$ echo RDY-trusty" "RDY-trusty" "~/p \$ "
elif [ "\$n" -eq 3 ]; then cat "$FIX/claude/launch-typed.txt"; printf '~/p \$ %s\n' "\$(cat "$CNT.typed")"
elif [ "\$n" -eq 4 ]; then cat "$FIX/claude/trust.txt"
else cat "$FIX/claude/ready.txt"; fi
EOF
chmod +x "$TRUST"
OUT="$(BRAIN_TMUX="$TRUST" "$HERE/launch-worker.sh" --host "$SELF" --harness claude \
        --slug trusty --project-dir "$PROJ" 2>/dev/null)"; RC=$?
LOGTXT="$(cat "$LOG")"
assert_contains "(f) trust prompt then ready → verified=yes" "verified=yes" "$OUT"
assert_eq       "(f) trust prompt → rc 0" "0" "$RC"
assert_eq "(f) answers the trust prompt with Down" "1" \
    "$(printf '%s\n' "$LOGTXT" | grep -cx 'send-keys -t brain-worker-trusty Down')"
if printf '%s\n' "$LOGTXT" | grep -qx 'send-keys -t brain-worker-trusty Down Enter'; then
    bad "(f) Down and Enter must be separate send-keys calls"
else
    ok  "(f) Down and Enter are separate send-keys calls"
fi

# Remote Control "already connected" dialog (fixtures/claude/rc-already-connected.txt): it
# replaces the composer and blocks the worker. Fallback: detect it, send `Escape` (never
# Enter — Enter would pick `Disconnect` if the highlight moved), re-check, report it.
# DLG_AT = the capture that shows the dialog: 4 = the first post-Enter poll (the verify
# loop), 5 = the first Remote Control poll after a clean verify. Every capture after an
# Escape is the ready pane with the live connected banner.
make_dialog_tmux() {  # make_dialog_tmux <slug> <fake> <counter> <log> <dlg_at> [sticky]
    cat >"$2" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$4"
[ "\${1:-}" = send-keys ] && [ \$# -eq 4 ] && case "\$4" in C-u|Enter|Down|Escape) ;; *) printf '%s' "\$4" >"$3.typed" ;; esac
[ "\${1:-}" = send-keys ] && [ "\${4:-}" = Escape ] && [ -z "${6:-}" ] && touch "$3.esc"
[ "\${1:-}" = "capture-pane" ] || exit 0
n=\$(( \$(cat "$3" 2>/dev/null || echo 0) + 1 ))
printf '%s' "\$n" >"$3"
if [ "\$n" -le 2 ]; then printf '%s\n' "~/p \\\$ echo RDY-$1" "RDY-$1" "~/p \\\$ "
elif [ "\$n" -eq 3 ]; then printf '~/p \\\$ %s\n' "\$(cat "$3.typed")"
elif [ -f "$3.esc" ]; then printf '%s\n' "  /remote-control is active · Continue here, on your phone, or at"; cat "$FIX/claude/ready.txt"
elif [ "\$n" -ge $5 ]; then cat "$FIX/claude/rc-already-connected.txt"
else cat "$FIX/claude/ready.txt"; fi
EOF
    chmod +x "$2"
}
for CASE in "resume 4" "resume 5" "launch 4"; do
    MODE="${CASE% *}" AT="${CASE#* }"
    SLUG="dlg-$MODE-$AT"
    CNT="$TMP/cnt.$SLUG"; LOG="$TMP/log.$SLUG"; FT="$TMP/fake-tmux.$SLUG"; : >"$LOG"; rm -f "$CNT" "$CNT.esc"
    make_dialog_tmux "$SLUG" "$FT" "$CNT" "$LOG" "$AT"
    if [ "$MODE" = resume ]; then XARGS="--resume $LAUNCH_SESSION_ID"; else XARGS=""; fi
    # shellcheck disable=SC2086
    OUT="$(HOME="$FAKE_HOME" BRAIN_TMUX="$FT" "$HERE/launch-worker.sh" --host "$SELF" --harness claude \
            --slug "$SLUG" --project-dir "$PROJ" $XARGS 2>"$TMP/err.$SLUG")"; RC=$?
    LOGTXT="$(cat "$LOG")"
    assert_eq       "(dialog $MODE @$AT) rc 0" "0" "$RC"
    assert_contains "(dialog $MODE @$AT) verified, connected, dialog reported" \
        "verified=yes session=brain-worker-$SLUG rc=yes attach=" "$OUT"
    assert_contains "(dialog $MODE @$AT) rc_dialog=dismissed appended after mode" "mode=$MODE rc_dialog=dismissed" "$OUT"
    assert_eq       "(dialog $MODE @$AT) exactly one Escape sent" "1" \
        "$(grep -cx "send-keys -t brain-worker-$SLUG Escape" "$LOG")"
    assert_eq       "(dialog $MODE @$AT) only the launch line is Entered (never Enter on the dialog)" "1" \
        "$(grep -cx "send-keys -t brain-worker-$SLUG Enter" "$LOG")"
    assert_not_contains "(dialog $MODE @$AT) never types /rc" "/rc" "$LOGTXT"
done
# a dialog that will not go away: rc=no, rc_dialog=stuck, still verified (RC is no gate)
SLUG=dlg-stuck
CNT="$TMP/cnt.$SLUG"; LOG="$TMP/log.$SLUG"; FT="$TMP/fake-tmux.$SLUG"; : >"$LOG"; rm -f "$CNT" "$CNT.esc"
make_dialog_tmux "$SLUG" "$FT" "$CNT" "$LOG" 5 sticky
OUT="$(HOME="$FAKE_HOME" BRAIN_TMUX="$FT" "$HERE/launch-worker.sh" --host "$SELF" --harness claude \
        --slug "$SLUG" --project-dir "$PROJ" --resume "$LAUNCH_SESSION_ID" 2>"$TMP/err.$SLUG")"; RC=$?
assert_eq       "(dialog stuck) rc 0 (Remote Control is not a launch gate)" "0" "$RC"
assert_contains "(dialog stuck) rc=no" "rc=no attach=" "$OUT"
assert_contains "(dialog stuck) rc_dialog=stuck" "mode=resume rc_dialog=stuck" "$OUT"
assert_contains "(dialog stuck) says so on stderr" "already connected" "$(cat "$TMP/err.$SLUG")"
assert_eq       "(dialog stuck) exactly ONE Escape in total (repeated Esc opens claude's rewind menu)" "1" \
    "$(grep -cx "send-keys -t brain-worker-$SLUG Escape" "$LOG")"
assert_eq       "(dialog stuck) never Enter on the dialog" "1" \
    "$(grep -cx "send-keys -t brain-worker-$SLUG Enter" "$LOG")"

# --------------------------------------------------- argument-parser robustness ----
#
# A value-taking flag with nothing after it: `shift 2` on one remaining argument FAILS
# under `set -u` without consuming anything, so an unguarded `while [ $# -gt 0 ]` loop
# spins forever. Each of these must be a prompt rc 2, and `timeout 5` proves it does not
# hang (a hang would surface as rc 124).

echo "trailing flag with no value:"
with_timeout 5 "$HERE/preflight.sh" --host "$SELF" --harness omp --project-dir >/dev/null 2>&1; RC=$?
assert_eq "preflight.sh --project-dir with no value → rc 2" "2" "$RC"
with_timeout 5 "$HERE/wait-for-brief.sh" --host "$SELF" --slug x --timeout >/dev/null 2>&1; RC=$?
assert_eq "wait-for-brief.sh --timeout with no value → rc 2" "2" "$RC"
with_timeout 5 "$HERE/launch-worker.sh" --host "$SELF" --harness omp --slug x --project-dir >/dev/null 2>&1; RC=$?
assert_eq "launch-worker.sh --project-dir with no value → rc 2" "2" "$RC"
with_timeout 5 "$HERE/preflight.sh" --host >/dev/null 2>&1; RC=$?
assert_eq "preflight.sh --host with no value → rc 2" "2" "$RC"

# ------------------------------------------------- launch-worker: session exists ----
#
# A session of this name already running is almost certainly a LIVE worker. Reusing it
# would type `echo RDY-<slug>` + Enter into its composer up to 15 times — stray user
# messages into somebody's running session. It must fail without touching the pane.

echo "launch-worker.sh, session already exists:"
EXIST="$TMP/fake-tmux.exists"; LOG="$TMP/log.exists"; : >"$LOG"
cat >"$EXIST" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$LOG"
case "\${1:-}" in
  new-session) exit 1 ;;   # already exists
  has-session) exit 0 ;;   # ...and it is alive
  *) exit 0 ;;
esac
EOF
chmod +x "$EXIST"
OUT="$(BRAIN_TMUX="$EXIST" "$HERE/launch-worker.sh" --host "$SELF" --harness omp \
        --slug taken --project-dir "$PROJ" 2>"$TMP/err.exists")"; RC=$?
assert_eq       "existing session → rc 1" "1" "$RC"
assert_contains "existing session → verified=no" "verified=no session=brain-worker-taken" "$OUT"
assert_contains "existing session → says attach or kill it first" "attach or kill it first" "$(cat "$TMP/err.exists")"
if grep -q 'send-keys' "$LOG"; then
    bad "existing session: must send NOTHING to the pane"
else
    ok  "existing session: nothing sent to the pane"
fi

# ------------------------------------------- launch-worker: mangled line, retyped ----
#
# Failure mode 2: the pane swallowed part of the command. The script must clear the line
# and retype rather than pressing Enter on a broken command.

echo "launch-worker.sh, mangled launch line:"
MANGLE="$TMP/fake-tmux.mangle"; LOG="$TMP/log.mangle"; CNT="$TMP/cnt.mangle"; : >"$LOG"; rm -f "$CNT"
cat >"$MANGLE" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$LOG"
[ "\${1:-}" = "capture-pane" ] || exit 0
n=\$(( \$(cat "$CNT" 2>/dev/null || echo 0) + 1 ))
printf '%s' "\$n" >"$CNT"
if [ "\$n" -le 2 ]; then printf '%s\n' "~/p \$ echo RDY-mangled" "RDY-mangled" "~/p \$ "
elif [ "\$n" -eq 3 ]; then printf '%s\n' "~/p \$ mp --auto-approve \"Read your worker bri"
elif [ "\$n" -eq 4 ]; then cat "$FIX/omp/launch-typed.txt"
else cat "$FIX/omp/ready.txt"; fi
EOF
chmod +x "$MANGLE"
OUT="$(BRAIN_TMUX="$MANGLE" "$HERE/launch-worker.sh" --host "$SELF" --harness omp \
        --slug mangled --project-dir "$PROJ" 2>/dev/null)"; RC=$?
LOGTXT="$(cat "$LOG")"
assert_contains "mangled then intact → verified=yes" "verified=yes" "$OUT"
assert_eq       "mangled then intact → rc 0" "0" "$RC"
assert_eq "retypes the launch line (twice typed)" "2" \
    "$(printf '%s\n' "$LOGTXT" | grep -c 'Read your worker brief')"
assert_eq "still exactly one bare Enter" "1" \
    "$(printf '%s\n' "$LOGTXT" | grep -cx 'send-keys -t brain-worker-mangled Enter')"
# after the mangled attempt the log reads: <typed line>, capture-pane, C-u (the clear).
if printf '%s\n' "$LOGTXT" | grep -A2 'Read your worker brief' | grep -qx 'send-keys -t brain-worker-mangled C-u'; then
    ok  "clears the mangled line with C-u before retyping"
else
    bad "did not C-u after the mangled attempt"
fi

# ------------------------------------- launch-worker: conversation ids (fresh launch) ----
#
# Every launch now reports the harness conversation id on its final line (`session_id=`,
# plus `mode=launch`), so brain-revive-workers can later resume exactly that conversation.
# claude: the id is PINNED at launch with `--session-id <uuid>` (generated locally, or
# LAUNCH_SESSION_ID in tests). omp cannot pin one, so it is DISCOVERED after readiness from
# the newest session file whose FIRST user message is this slug's launch sentence.

echo "launch-worker.sh, session ids on a fresh launch:"
SID="$LAUNCH_SESSION_ID"
field() { printf '%s\n' "$2" | tr ' ' '\n' | sed -n "s/^$1=//p"; }

SLUG=sid-claude
CNT="$TMP/cnt.sidc"; LOG="$TMP/log.sidc"; FT="$TMP/fake-tmux.sidc"; : >"$LOG"; rm -f "$CNT"
make_fake_tmux claude "$SLUG" "$FT" "$CNT" "$LOG" connected
OUT="$(HOME="$FAKE_HOME" BRAIN_TMUX="$FT" "$HERE/launch-worker.sh" --host "$SELF" --harness claude \
        --slug "$SLUG" --project-dir "$PROJ" 2>/dev/null)"; RC=$?
LOGTXT="$(cat "$LOG")"
assert_eq "claude fresh → rc 0" "0" "$RC"
assert_eq "claude fresh → exact typed line pins the session id" \
    "send-keys -t brain-worker-$SLUG claude --remote-control $SLUG --session-id $SID \"Read your worker brief at ~/Obsidian/vault/workers/$SLUG.md and follow its priming, then greet me.\"" \
    "$(printf '%s\n' "$LOGTXT" | grep -- '--session-id' | head -1)"
assert_eq "claude fresh → final line appends session_id + mode after attach" \
    "verified=yes session=brain-worker-$SLUG rc=yes attach=tmux attach -t brain-worker-$SLUG session_id=$SID mode=launch" \
    "$OUT"

# no override → a fresh lowercase uuid is generated, typed, and reported
SLUG=sid-gen
CNT="$TMP/cnt.sidg"; LOG="$TMP/log.sidg"; FT="$TMP/fake-tmux.sidg"; : >"$LOG"; rm -f "$CNT"
make_fake_tmux claude "$SLUG" "$FT" "$CNT" "$LOG" connected
OUT="$(env -u LAUNCH_SESSION_ID HOME="$FAKE_HOME" BRAIN_TMUX="$FT" "$HERE/launch-worker.sh" \
        --host "$SELF" --harness claude --slug "$SLUG" --project-dir "$PROJ" 2>/dev/null)"
GEN="$(field session_id "$OUT")"
assert_matches "generated session_id is a lowercase uuid" \
    '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' "$GEN"
assert_contains "generated session_id is the one typed" "claude --remote-control $SLUG --session-id $GEN \"Read" "$(cat "$LOG")"
OUT2="$(rm -f "$CNT"; env -u LAUNCH_SESSION_ID HOME="$FAKE_HOME" BRAIN_TMUX="$FT" "$HERE/launch-worker.sh" \
        --host "$SELF" --harness claude --slug "$SLUG" --project-dir "$PROJ" 2>/dev/null)"
if [ "$(field session_id "$OUT2")" != "$GEN" ]; then ok "each launch generates a new uuid"; else bad "uuid reused across launches"; fi

# a malformed override is a usage error, before any tmux call
LOG="$TMP/log.sidbad"; : >"$LOG"; FT="$TMP/fake-tmux.sidbad"
make_fake_tmux claude sidbad "$FT" "$TMP/cnt.sidbad" "$LOG"
LAUNCH_SESSION_ID=not-a-uuid BRAIN_TMUX="$FT" "$HERE/launch-worker.sh" --host "$SELF" --harness claude \
    --slug sidbad --project-dir "$PROJ" >/dev/null 2>&1; RC=$?
assert_eq "LAUNCH_SESSION_ID not a uuid → rc 2" "2" "$RC"
assert_eq "LAUNCH_SESSION_ID not a uuid → no tmux call" "" "$(cat "$LOG")"

# the uuid itself must be verified on the pane, not just the marker prefix: a pane that
# shows `claude --session-id` but a truncated id is never Entered.
TRUNC="$TMP/fake-tmux.trunc"; LOG="$TMP/log.trunc"; CNT="$TMP/cnt.trunc"; : >"$LOG"; rm -f "$CNT"
cat >"$TRUNC" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$LOG"
[ "\${1:-}" = "capture-pane" ] || exit 0
n=\$(( \$(cat "$CNT" 2>/dev/null || echo 0) + 1 ))
printf '%s' "\$n" >"$CNT"
if [ "\$n" -le 2 ]; then printf '%s\n' "~/p \$ echo RDY-trunc" "RDY-trunc" "~/p \$ "
else printf '%s\n' "~/p \$ claude --remote-control trunc --session-id 0a1b2c3d-4e5f \"Read your worker brief"; fi
EOF
chmod +x "$TRUNC"
OUT="$(BRAIN_TMUX="$TRUNC" "$HERE/launch-worker.sh" --host "$SELF" --harness claude \
        --slug trunc --project-dir "$PROJ" 2>/dev/null)"; RC=$?
assert_eq "truncated uuid on the pane → rc 1" "1" "$RC"
assert_eq "truncated uuid → Enter never sent" "0" \
    "$(grep -cx 'send-keys -t brain-worker-trunc Enter' "$LOG")"
assert_contains "truncated uuid → failure line carries mode=launch" "mode=launch" "$OUT"

# a uuid that wraps across the pane's width still verifies (newlines are joined)
WRAP="$TMP/fake-tmux.wrap"; LOG="$TMP/log.wrap"; CNT="$TMP/cnt.wrap"; : >"$LOG"; rm -f "$CNT"
cat >"$WRAP" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$LOG"
[ "\${1:-}" = "capture-pane" ] || exit 0
n=\$(( \$(cat "$CNT" 2>/dev/null || echo 0) + 1 ))
printf '%s' "\$n" >"$CNT"
if [ "\$n" -le 2 ]; then printf '%s\n' "~/p \$ echo RDY-wrap" "RDY-wrap" "~/p \$ "
elif [ "\$n" -eq 3 ]; then printf '%s\n' "~/p \$ claude --remote-control wrap --session-id 0a1b2c3d-4e5f-4a6b" "-8c7d-9e0f1a2b3c4d \"Read your worker brief at"
else cat "$FIX/claude/ready.txt"; fi
EOF
chmod +x "$WRAP"
OUT="$(BRAIN_TMUX="$WRAP" "$HERE/launch-worker.sh" --host "$SELF" --harness claude \
        --slug wrap --project-dir "$PROJ" 2>/dev/null)"; RC=$?
assert_eq "uuid wrapped across two pane rows → rc 0" "0" "$RC"

# omp: discovered from the fake HOME's session files. The worker's file is written by
# "omp" only once the harness is up (FAKE_ON_READY) and is OLDER than a coordinator
# transcript that merely QUOTES the same sentence in a later message — the coordinator's
# first user message is something else, so it must not be picked. An OLD session file of
# a previous dispatch of the same slug (written before this launch started) must never be
# picked either, even when omp has not written the new one yet.
OHOME="$TMP/omp-home"; OSESS="$OHOME/.omp/agent/sessions/-projects-brain"; mkdir -p "$OSESS"
OSLUG=sid-omp
OSENT="Read your worker brief at ~/Obsidian/vault/workers/$OSLUG.md and follow its priming, then greet me."
WORKER_ID=01a0a4dc-5a6c-70da-bde2-a62afe728802
OLD_ID=01a0a4dc-0000-70da-bde2-00000000beef
COORD_ID=01a0ffff-0000-7000-8000-000000000000
omp_worker_file() {  # omp_worker_file <id> <out-file>
  {
    printf '{"type":"title","v":1,"title":"Read worker brief and greet"}\n'
    printf '{"type":"session","version":3,"id":"%s","timestamp":"2026-09-15T11:38:19.628Z","cwd":"/x"}\n' "$1"
    printf '{"type":"model_change","id":"3242e563","parentId":null}\n'
    printf '{"type":"message","id":"ad63d14e","parentId":"3242e563","message":{"role":"user","content":[{"type":"text","text":"%s"}]}}\n' "$OSENT"
  } >"$2"
}
omp_worker_file "$WORKER_ID" "$TMP/omp-worker-template.jsonl"
omp_worker_file "$OLD_ID" "$OSESS/2026-09-10T09-00-00-000Z_$OLD_ID.jsonl"
touch -t 202609100900 "$OSESS/2026-09-10T09-00-00-000Z_$OLD_ID.jsonl"
NEWF="$OSESS/2026-09-15T11-38-19-628Z_$WORKER_ID.jsonl"
{
  printf '{"type":"session","version":3,"id":"%s","timestamp":"2026-09-15T11:00:00.000Z","cwd":"/x"}\n' "$COORD_ID"
  printf '{"type":"message","id":"aa","parentId":null,"message":{"role":"user","content":[{"type":"text","text":"dispatch a worker"}]}}\n'
  printf '{"type":"message","id":"bb","parentId":"aa","message":{"role":"user","content":[{"type":"text","text":"it typed %s"}]}}\n' "$OSENT"
} >"$OSESS/2026-09-15T11-00-00-000Z_$COORD_ID.jsonl"
# "omp" writes the worker's file once up; the coordinator transcript is touched right
# after it, so the coordinator is the NEWEST file and must still lose on content.
ON_READY="[ -f '$NEWF' ] || { cp '$TMP/omp-worker-template.jsonl' '$NEWF'; sleep 1; touch '$OSESS/2026-09-15T11-00-00-000Z_$COORD_ID.jsonl'; }"
LTMP="$TMP/launch-tmpdir"; mkdir -p "$LTMP"

# only the OLD file of a previous dispatch exists → unknown, never the stale id
CNT="$TMP/cnt.sido0"; LOG="$TMP/log.sido0"; FT="$TMP/fake-tmux.sido0"; : >"$LOG"; rm -f "$CNT"
make_fake_tmux omp "$OSLUG" "$FT" "$CNT" "$LOG"
OUT="$(TMPDIR="$LTMP" HOME="$OHOME" BRAIN_TMUX="$FT" DISPATCH_ID_TRIES=2 DISPATCH_VERIFY_SLEEP=0 \
        "$HERE/launch-worker.sh" --host "$SELF" --harness omp \
        --slug "$OSLUG" --project-dir "$PROJ" 2>/dev/null)"; RC=$?
assert_eq "omp fresh, only an older same-slug session file → rc 0" "0" "$RC"
assert_eq "omp fresh, only an older same-slug session file → session_id=unknown" \
    "unknown" "$(field session_id "$OUT")"
assert_eq "omp fresh → start marker cleaned up" "" "$(ls -A "$LTMP")"

CNT="$TMP/cnt.sido"; LOG="$TMP/log.sido"; FT="$TMP/fake-tmux.sido"; : >"$LOG"; rm -f "$CNT"
make_fake_tmux omp "$OSLUG" "$FT" "$CNT" "$LOG"
OUT="$(TMPDIR="$LTMP" FAKE_ON_READY="$ON_READY" HOME="$OHOME" BRAIN_TMUX="$FT" "$HERE/launch-worker.sh" --host "$SELF" --harness omp \
        --slug "$OSLUG" --project-dir "$PROJ" 2>/dev/null)"; RC=$?
assert_eq "omp fresh → rc 0" "0" "$RC"
assert_eq "omp fresh, old + new same-slug files → session_id of the NEW one" \
    "$WORKER_ID" "$(field session_id "$OUT")"
assert_eq "omp fresh (found) → start marker cleaned up" "" "$(ls -A "$LTMP")"
assert_contains "omp fresh → mode=launch" "rc=n/a attach=tmux attach -t brain-worker-$OSLUG session_id=$WORKER_ID mode=launch" "$OUT"
assert_eq "omp fresh → typed line byte-identical (no id flag)" \
    "send-keys -t brain-worker-$OSLUG omp --auto-approve \"$OSENT\"" \
    "$(grep -F 'Read your worker brief' "$LOG" | head -1)"

# omp with no matching session file → session_id=unknown, still verified (a convenience)
CNT="$TMP/cnt.sidu"; LOG="$TMP/log.sidu"; FT="$TMP/fake-tmux.sidu"; : >"$LOG"; rm -f "$CNT"
make_fake_tmux omp sid-unknown "$FT" "$CNT" "$LOG"
OUT="$(HOME="$OHOME" BRAIN_TMUX="$FT" "$HERE/launch-worker.sh" --host "$SELF" --harness omp \
        --slug sid-unknown --project-dir "$PROJ" 2>/dev/null)"; RC=$?
assert_eq "omp no session file → rc 0" "0" "$RC"
assert_contains "omp no session file → session_id=unknown" "session_id=unknown mode=launch" "$OUT"

# ---------------------------------------------------- launch-worker: --resume ----
#
# Revival: the SAME dance, but the typed line is `resume_cmd` — never the brief sentence,
# which would prime a FRESH conversation (the known past failure this mode exists for).

echo "launch-worker.sh --resume:"
for H in claude omp; do
    SLUG="res-$H"
    if [ "$H" = claude ]; then RID="$SID"; else RID=01a0a4dc; fi
    CNT="$TMP/cnt.res.$H"; LOG="$TMP/log.res.$H"; FT="$TMP/fake-tmux.res.$H"; : >"$LOG"; rm -f "$CNT"
    make_fake_tmux "$H" "$SLUG" "$FT" "$CNT" "$LOG" connected
    OUT="$(env -u LAUNCH_SESSION_ID HOME="$FAKE_HOME" BRAIN_TMUX="$FT" "$HERE/launch-worker.sh" \
            --host "$SELF" --harness "$H" --slug "$SLUG" --project-dir "$PROJ" --resume "$RID" \
            2>"$TMP/err.res.$H")"; RC=$?
    LOGTXT="$(cat "$LOG")"
    assert_eq "$H --resume → rc 0" "0" "$RC"
    assert_eq "$H --resume → typed exactly the resume command" \
        "send-keys -t brain-worker-$SLUG $(resume_cmd "$H" "$RID" '' "$SLUG")" \
        "$(printf '%s\n' "$LOGTXT" | grep -F -- '--resume' | head -1)"
    if printf '%s\n' "$LOGTXT" | grep -q 'Read your worker brief'; then
        bad "$H --resume must NEVER type the brief sentence (fresh conversation)"
    else
        ok  "$H --resume never types the brief sentence"
    fi
    if printf '%s\n' "$LOGTXT" | grep -q -- '--session-id'; then
        bad "$H --resume must not pin a new session id"
    else
        ok  "$H --resume pins no new session id"
    fi
    if printf '%s\n' "$LOGTXT" | grep -qE -- '--resume.*Enter$'; then
        bad "$H --resume typed the command and Enter in one call"
    else
        ok  "$H --resume typed WITHOUT Enter"
    fi
    assert_contains "$H --resume → new-session in the project dir" \
        "new-session -d -s brain-worker-$SLUG -c $PROJ" "$LOGTXT"
    assert_contains "$H --resume → RDY probe still runs" "echo RDY-$SLUG" "$LOGTXT"
    if [ "$H" = claude ]; then
        assert_contains "claude --resume → --remote-control <slug> before --resume" \
            "claude --remote-control $SLUG --resume $RID" "$LOGTXT"
        assert_not_contains "claude --resume → never types /rc (it would open the dialog)" "/rc" "$LOGTXT"
        WANT_RC=yes
    else
        WANT_RC=n/a
    fi
    assert_eq "$H --resume → final line" \
        "verified=yes session=brain-worker-$SLUG rc=$WANT_RC attach=tmux attach -t brain-worker-$SLUG session_id=$RID mode=resume" \
        "$OUT"
done

# --resume with --model threads the model into the resume line
CNT="$TMP/cnt.resm"; LOG="$TMP/log.resm"; FT="$TMP/fake-tmux.resm"; : >"$LOG"; rm -f "$CNT"
make_fake_tmux claude res-model "$FT" "$CNT" "$LOG"
HOME="$FAKE_HOME" BRAIN_TMUX="$FT" "$HERE/launch-worker.sh" --host "$SELF" --harness claude \
    --slug res-model --project-dir "$PROJ" --resume "$SID" --model claude-opus-5 >/dev/null 2>&1
assert_contains "--resume --model → model before --resume" \
    "send-keys -t brain-worker-res-model claude --model claude-opus-5 --remote-control res-model --resume $SID" "$(cat "$LOG")"

# interrupted-turn notices on the resumed pane are surfaced on stderr as `note: <line>`
NOTE="$TMP/fake-tmux.note"; LOG="$TMP/log.note"; CNT="$TMP/cnt.note"; : >"$LOG"; rm -f "$CNT"
cat >"$NOTE" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$LOG"
[ "\${1:-}" = send-keys ] && [ \$# -eq 4 ] && case "\$4" in C-u|Enter|Down) ;; *) printf '%s' "\$4" >"$CNT.typed" ;; esac
[ "\${1:-}" = "capture-pane" ] || exit 0
n=\$(( \$(cat "$CNT" 2>/dev/null || echo 0) + 1 ))
printf '%s' "\$n" >"$CNT"
if [ "\$n" -le 2 ]; then printf '%s\n' "~/p \$ echo RDY-noted" "RDY-noted" "~/p \$ "
elif [ "\$n" -eq 3 ]; then printf '~/p \$ %s\n' "\$(cat "$CNT.typed")"
else
  printf '%s\n' "> [Request interrupted by user]" "  ⎿  The previous turn didn't finish before the previous session ended." "  ⎿  Tool call DIDN'T FINISH before the previous session ended" "  ⎿  Interrupted · What should Claude do instead?"
  cat "$FIX/claude/ready.txt"
fi
EOF
chmod +x "$NOTE"
OUT="$(HOME="$FAKE_HOME" BRAIN_TMUX="$NOTE" "$HERE/launch-worker.sh" --host "$SELF" --harness claude \
        --slug noted --project-dir "$PROJ" --resume "$SID" 2>"$TMP/err.note")"; RC=$?
ERRTXT="$(cat "$TMP/err.note")"
assert_eq "resume with notices → rc 0" "0" "$RC"
assert_contains "surfaces didn't-finish as a note" \
    "note: ⎿  The previous turn didn't finish before the previous session ended." "$ERRTXT"
assert_contains "surfaces the resume banner case-insensitively" \
    "note: ⎿  Tool call DIDN'T FINISH before the previous session ended" "$ERRTXT"
assert_not_contains "old history's 'interrupted' lines are not notes" "Interrupted" "$ERRTXT"
assert_not_contains "old history's '[Request interrupted by user]' is not a note" "Request interrupted" "$ERRTXT"
assert_eq "exactly the two banner lines are notes" "2" "$(grep -c '^note:' "$TMP/err.note")"
assert_eq "notes go to stderr only: stdout is one line" "1" "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')"
# a fresh launch never emits notes, even off the same pane
rm -f "$CNT"
HOME="$FAKE_HOME" BRAIN_TMUX="$NOTE" "$HERE/launch-worker.sh" --host "$SELF" --harness claude \
    --slug noted --project-dir "$PROJ" >/dev/null 2>"$TMP/err.note2"
if grep -q '^note:' "$TMP/err.note2"; then bad "fresh launch must not emit note: lines"; else ok "fresh launch emits no note: lines"; fi

# resume polls longer by default (45) — and DISPATCH_VERIFY_TRIES still overrides it
NEVER="$TMP/fake-tmux.never"; LOG="$TMP/log.never"; CNT="$TMP/cnt.never"
cat >"$NEVER" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$LOG"
[ "\${1:-}" = send-keys ] && [ \$# -eq 4 ] && case "\$4" in C-u|Enter|Down) ;; *) printf '%s' "\$4" >"$CNT.typed" ;; esac
[ "\${1:-}" = "capture-pane" ] || exit 0
n=\$(( \$(cat "$CNT" 2>/dev/null || echo 0) + 1 ))
printf '%s' "\$n" >"$CNT"
if [ "\$n" -le 2 ]; then printf '%s\n' "~/p \$ echo RDY-never" "RDY-never" "~/p \$ "
else printf '~/p \$ %s\n' "\$(cat "$CNT.typed")"; fi
EOF
chmod +x "$NEVER"
polls_after_enter() { sed -n '/^send-keys -t brain-worker-never Enter$/,$p' "$LOG" | grep -c '^capture-pane'; }
: >"$LOG"; rm -f "$CNT"
OUT="$(env -u DISPATCH_VERIFY_TRIES BRAIN_TMUX="$NEVER" "$HERE/launch-worker.sh" --host "$SELF" \
        --harness claude --slug never --project-dir "$PROJ" --resume "$SID" 2>/dev/null)"; RC=$?
assert_eq "resume never-ready → rc 1" "1" "$RC"
assert_eq "resume default VERIFY_TRIES is 45" "45" "$(polls_after_enter)"
assert_contains "resume failure line → session_id + mode=resume" "session_id=$SID mode=resume" "$OUT"
: >"$LOG"; rm -f "$CNT"
DISPATCH_VERIFY_TRIES=3 BRAIN_TMUX="$NEVER" "$HERE/launch-worker.sh" --host "$SELF" \
    --harness claude --slug never --project-dir "$PROJ" --resume "$SID" >/dev/null 2>&1
assert_eq "resume honours DISPATCH_VERIFY_TRIES=3" "3" "$(polls_after_enter)"
: >"$LOG"; rm -f "$CNT"
env -u DISPATCH_VERIFY_TRIES BRAIN_TMUX="$NEVER" "$HERE/launch-worker.sh" --host "$SELF" \
    --harness claude --slug never --project-dir "$PROJ" >/dev/null 2>&1
assert_eq "fresh launch default VERIFY_TRIES stays 20" "20" "$(polls_after_enter)"

# resume into an existing session: rc 1, nothing typed, failure line says mode=resume
LOG="$TMP/log.exists"; : >"$LOG"
OUT="$(BRAIN_TMUX="$EXIST" "$HERE/launch-worker.sh" --host "$SELF" --harness claude \
        --slug taken --project-dir "$PROJ" --resume "$SID" 2>/dev/null)"; RC=$?
assert_eq "resume, session exists → rc 1" "1" "$RC"
assert_eq "resume, session exists → failure line" \
    "verified=no session=brain-worker-taken rc=n/a attach=tmux attach -t brain-worker-taken session_id=$SID mode=resume" "$OUT"
if grep -q 'send-keys' "$LOG"; then bad "resume, session exists: nothing sent"; else ok "resume, session exists: nothing sent"; fi

# id validation — usage errors (rc 2), no tmux call at all
LOG="$TMP/log.badid"; : >"$LOG"; FT="$TMP/fake-tmux.badid"
make_fake_tmux claude badid "$FT" "$TMP/cnt.badid" "$LOG"
BRAIN_TMUX="$FT" "$HERE/launch-worker.sh" --host "$SELF" --harness claude --slug badid \
    --project-dir "$PROJ" --resume 01a0a4dc >/dev/null 2>&1; RC=$?
assert_eq "claude --resume non-uuid → rc 2" "2" "$RC"
BRAIN_TMUX="$FT" "$HERE/launch-worker.sh" --host "$SELF" --harness omp --slug badid \
    --project-dir "$PROJ" --resume '01a0;touch /tmp/pwned' >/dev/null 2>&1; RC=$?
assert_eq "omp --resume with a shell metachar → rc 2" "2" "$RC"
assert_eq "bad --resume ids → no tmux call" "" "$(cat "$LOG")"
with_timeout 5 "$HERE/launch-worker.sh" --host "$SELF" --harness omp --slug x --project-dir "$PROJ" --resume >/dev/null 2>&1; RC=$?
assert_eq "launch-worker.sh --resume with no value → rc 2" "2" "$RC"
assert_contains "--help documents --resume" "--resume" "$("$HERE/launch-worker.sh" --help)"

# ------------------------------------------- launch-worker: remote host quoting ----
#
# Remote tmux travels `ssh <alias> zsh -lc <%q cmd>`. A fake ssh that re-runs the command
# under zsh -c (bash when zsh is absent) proves the resume line and the omp session-id
# probe survive that double hop as ONE literal: the fake tmux on the far side must receive
# the resume command as a single argument.
echo "launch-worker.sh, remote host quoting:"
RSH="$TMP/fake-ssh-exec"
cat >"$RSH" <<'EOF'
#!/usr/bin/env bash
# fake ssh: drop `-o BatchMode=yes <alias>`, then do what sshd does with the rest — join
# the words with spaces and hand them to the remote login shell (zsh on a remote host) to parse.
# That parse strips one quoting layer; the inner `zsh -lc` (made `-fc`, so no login files
# are read) strips the other. bash stands in for zsh on a machine without it.
shift 3
remote="$*"
remote="${remote/#zsh -lc /zsh -fc }"
if command -v zsh >/dev/null 2>&1; then exec zsh -fc "$remote"
else remote="${remote/#zsh -fc /bash -c }"; exec bash -c "$remote"; fi
EOF
chmod +x "$RSH"
CNT="$TMP/cnt.remote"; LOG="$TMP/log.remote"; FT="$TMP/fake-tmux.remote"; : >"$LOG"; rm -f "$CNT"
make_fake_tmux claude res-remote "$FT" "$CNT" "$LOG" connected
OUT="$(BRAIN_SSH="$RSH" BRAIN_TMUX="$FT" "$HERE/launch-worker.sh" --host homeserver --harness claude \
        --slug res-remote --project-dir '~/projects/brain' --resume "$SID" 2>/dev/null)"; RC=$?
assert_eq "remote --resume → rc 0" "0" "$RC"
assert_contains "remote --resume → typed as one literal" \
    "send-keys -t brain-worker-res-remote claude --remote-control res-remote --resume $SID" "$(cat "$LOG")"
assert_contains "remote --resume → mode=resume session_id" "session_id=$SID mode=resume" "$OUT"
CNT="$TMP/cnt.remotef"; LOG="$TMP/log.remotef"; FT="$TMP/fake-tmux.remotef"; : >"$LOG"; rm -f "$CNT"
make_fake_tmux claude sid-remote "$FT" "$CNT" "$LOG" connected
OUT="$(BRAIN_SSH="$RSH" BRAIN_TMUX="$FT" "$HERE/launch-worker.sh" --host homeserver --harness claude \
        --slug sid-remote --project-dir '~/projects/workbench' 2>/dev/null)"; RC=$?
assert_eq "remote fresh claude → rc 0" "0" "$RC"
assert_contains "remote fresh claude → the full sentence arrives as one literal" \
    "send-keys -t brain-worker-sid-remote claude --remote-control sid-remote --session-id $SID \"Read your worker brief at ~/Obsidian/vault/workers/sid-remote.md and follow its priming, then greet me.\"" \
    "$(cat "$LOG")"

CNT="$TMP/cnt.media"; LOG="$TMP/log.media"; FT="$TMP/fake-tmux.media"; : >"$LOG"; rm -f "$CNT"
make_fake_tmux claude res-media "$FT" "$CNT" "$LOG" connected
OUT="$(BRAIN_SSH="$RSH" BRAIN_TMUX="$FT" "$HERE/launch-worker.sh" --host homeserver --harness claude \
        --slug res-media --project-dir '~/projects/brain' --resume "$SID" 2>/dev/null)"; RC=$?
assert_eq "homeserver --resume → rc 0" "0" "$RC"
assert_contains "homeserver --resume → attach command uses alias homeserver" "attach=ssh -t homeserver tmux attach -t brain-worker-res-media" "$OUT"
OUT="$("$HERE/preflight.sh" --host homeserver --harness omp --project-dir "$TMP" 2>"$TMP/err.media")"; RC=$?
assert_eq "preflight --host homeserver --harness omp → rc 2 (claude only)" "2" "$RC"

# omp's session-id probe over the same hop: a throwaway hosts.conf declares a remote host
# that runs omp (the real `homeserver` runs claude only), and the probe must still find the
# worker's session under the (fake) remote HOME.
RHOSTS="$TMP/hosts.remote-omp.conf"
printf 'testself  -  omp,claude  omp  testself-box\nfaromp  far-alias  omp  omp  faromp-box\n' >"$RHOSTS"
CNT="$TMP/cnt.remoteo"; LOG="$TMP/log.remoteo"; FT="$TMP/fake-tmux.remoteo"; : >"$LOG"; rm -f "$CNT"
make_fake_tmux omp "$OSLUG" "$FT" "$CNT" "$LOG"
rm -f "$NEWF"
OUT="$(FAKE_ON_READY="$ON_READY" HOME="$OHOME" BRAIN_HOSTS="$RHOSTS" BRAIN_SSH="$RSH" BRAIN_TMUX="$FT" "$HERE/launch-worker.sh" \
        --host faromp --harness omp --slug "$OSLUG" --project-dir '~/projects/workbench' 2>/dev/null)"; RC=$?
assert_eq "remote fresh omp → rc 0" "0" "$RC"
assert_eq "remote fresh omp → session id discovered through ssh + zsh -lc" \
    "$WORKER_ID" "$(field session_id "$OUT")"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
