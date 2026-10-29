#!/usr/bin/env bash
#
# Tests for worker-monitor.sh — the coordinator's change-only worker-fleet monitor.
#
# Runs OFFLINE: the vault is a temp dir of hand-built worker notes, tmux is a stub that
# serves the captured harness fixtures (skills/_shared/lib/fixtures) as each session's
# pane and logs its argv, ssh is a stub that runs the remote command locally under a fake
# remote HOME, the clock is MONITOR_NOW (+ MONITOR_NOW_STEP per poll) and the loop is
# bounded by MONITOR_MAX_POLLS with --interval 0. No real tmux, ssh, harness or vault.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
MON="$HERE/worker-monitor.sh"
FX="$REPO/skills/_shared/lib/fixtures"

PASS=0 FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
assert_eq()           { local d="$1" want="$2" got="$3"; if [ "$want" = "$got" ]; then ok "$d"; else bad "$d (want '$want' got '$got')"; fi; }
assert_contains()     { local d="$1" needle="$2" hay="$3"; case "$hay" in *"$needle"*) ok "$d" ;; *) bad "$d (missing '$needle' in '$hay')" ;; esac; }
assert_not_contains() { local d="$1" needle="$2" hay="$3"; case "$hay" in *"$needle"*) bad "$d (unexpected '$needle' in '$hay')" ;; *) ok "$d" ;; esac; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

T0=1790000000
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }
# stamp <file> <epoch> — portable mtime set (`-t` is understood by GNU and BSD touch).
stamp() {
    local t
    t="$(date -d "@$2" +%Y%m%d%H%M.%S 2>/dev/null || date -r "$2" +%Y%m%d%H%M.%S)"
    touch -t "$t" "$1"
}

LH="$TMP/home-local"; RH="$TMP/home-remote"; mkdir -p "$LH" "$RH"
V="$TMP/vault"; mkdir -p "$V/workers"
PANES="$TMP/panes"; mkdir -p "$PANES"

# note <slug> <frontmatter line>... — writes <vault>/workers/<slug>.md
note() {
    local slug="$1"; shift
    { printf -- '---\nslug: %s\n' "$slug"; for l in "$@"; do printf '%s\n' "$l"; done
      printf -- '---\n\n# %s\n' "$slug"; } >"$V/workers/$slug.md"
}
# pane <session> <fixture> — the session exists and shows <fixture> (harness/state.txt)
# as its VISIBLE screen, with no scrollback. scroll <session> <text> — scrollback above it,
# served only to a `capture-pane -S <n>` (a plain capture-pane is the visible screen).
pane() { cp "$FX/$2.txt" "$PANES/$1"; rm -f "$PANES/$1.scroll"; }
scroll() { printf '%s\n' "$2" >"$PANES/$1.scroll"; }
nopane() { rm -f "$PANES/$1" "$PANES/$1.scroll"; }
# transcript <home> <sid> <epoch>
transcript() {
    mkdir -p "$1/.claude/projects/-x-proj"
    : >"$1/.claude/projects/-x-proj/$2.jsonl"
    stamp "$1/.claude/projects/-x-proj/$2.jsonl" "$3"
}

# stub tmux: a session exists iff $PANES/<session> exists; capture-pane prints it, with
# $PANES/<session>.scroll in front of it only when asked for history (`-S`).
# The monitor targets sessions exactly (`=S`, `=S:`), as real tmux prefix-matches `-t S`.
TLOG="$TMP/tmux.log"; : >"$TLOG"
cat >"$TMP/fake-tmux" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$TLOG"
cmd="\$1"; shift; t="" hist=""
while [ \$# -gt 0 ]; do case "\$1" in -t) t="\$2"; shift 2 ;; -S) hist=1; shift 2 ;; *) shift ;; esac; done
t="\${t#=}"; t="\${t%:}"   # exact-match targets: =<session> / =<session>:
case "\$cmd" in
  has-session)  [ -f "$PANES/\$t" ] && exit 0; echo "can't find session: \$t" >&2; exit 1 ;;
  capture-pane) [ -f "$PANES/\$t" ] || exit 1
                [ -n "\$hist" ] && [ -f "$PANES/\$t.scroll" ] && cat "$PANES/\$t.scroll"
                cat "$PANES/\$t" ;;
  *) echo "fake-tmux: refusing \$cmd" >&2; exit 99 ;;
esac
EOF
chmod +x "$TMP/fake-tmux"
export BRAIN_TMUX="$TMP/fake-tmux"

# stub ssh: logs argv; `<alias> zsh -lc <quoted>` runs the command under bash with the
# fake remote HOME.
SLOG="$TMP/ssh.log"; : >"$SLOG"
cat >"$TMP/fake-ssh" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$SLOG"
[ "\$1" = "-o" ] && shift 2
shift
if [ "\$1" = zsh ] && [ "\$2" = -lc ]; then HOME="$RH"; export HOME; eval "exec bash -c \$3"; fi
echo "fake-ssh: unexpected \$*" >&2; exit 97
EOF
chmod +x "$TMP/fake-ssh"
printf '#!/usr/bin/env bash\necho "ssh: connect to host: Connection refused" >&2\nexit 255\n' >"$TMP/dead-ssh"
chmod +x "$TMP/dead-ssh"
export BRAIN_SSH="$TMP/fake-ssh"
export BRAIN_HOSTS="$REPO/skills/_shared/hosts.conf"
export BRAIN_SELF_HOST=desktop   # never depend on this machine's hostname

# gh is a stub (BRAIN_GH): `pr view <n> -R <o/r> --json …` prints $GFX/<n>.<k>.json, where
# k counts that PR's earlier calls (so one run of several polls can change a PR between
# polls), else $GFX/<n>.json; with $GFX/<n>.<k>.fail or $GFX/<n>.fail present it prints
# that on stderr, rc 1. An executable $GFX/hook.<n>.<k> runs first (output discarded):
# a way to act BETWEEN a running monitor's polls, e.g. run a second monitor.
GFX="$TMP/ghfx"; mkdir -p "$GFX"
GLOG="$TMP/gh.log"; : >"$GLOG"
cat >"$TMP/fake-gh" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$GLOG"
[ "\$1 \$2" = "pr view" ] || { echo "fake-gh: refusing \$*" >&2; exit 98; }
n="\$3"; c="$GFX/.calls.\$n"
k="\$(cat "\$c" 2>/dev/null || echo 0)"; echo \$((k + 1)) >"\$c"
[ -x "$GFX/hook.\$n.\$k" ] && "$GFX/hook.\$n.\$k" >/dev/null 2>&1 </dev/null
[ -f "$GFX/\$n.\$k.fail" ] && { cat "$GFX/\$n.\$k.fail" >&2; exit 1; }
[ -f "$GFX/\$n.fail" ] && { cat "$GFX/\$n.fail" >&2; exit 1; }
f="$GFX/\$n.\$k.json"; [ -f "\$f" ] || f="$GFX/\$n.json"
[ -f "\$f" ] || { echo "fake-gh: no fixture for PR \$n" >&2; exit 1; }
cat "\$f"
EOF
chmod +x "$TMP/fake-gh"
export BRAIN_GH="$TMP/fake-gh"
OA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
OB=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
# ghpr <n> <state> <isDraft> <oid> <mergeable> <pass|fail|pending|none> [<k>] — PR <n>'s
# canned `gh pr view` document (for its k-th call only, when <k> is given).
ghpr() {
    local roll
    case "$6" in
        pass)    roll='[{"__typename":"CheckRun","name":"t","status":"COMPLETED","conclusion":"SUCCESS"}]' ;;
        fail)    roll='[{"__typename":"CheckRun","name":"t","status":"COMPLETED","conclusion":"FAILURE"}]' ;;
        pending) roll='[{"__typename":"CheckRun","name":"t","status":"IN_PROGRESS","conclusion":""}]' ;;
        none)    roll='[]' ;;
    esac
    printf '{"state":"%s","isDraft":%s,"headRefOid":"%s","mergeable":"%s","statusCheckRollup":%s}\n' \
        "$2" "$3" "$4" "$5" "$roll" >"$GFX/$1${7:+.$7}.json"
}
ghreset() { rm -f "$GFX"/*.json "$GFX"/*.fail "$GFX"/.calls.* "$GFX"/hook.*; : >"$GLOG"; }
ghcalls() { grep -c "^pr view $1 " "$GLOG"; }

# mon <state-dir> [args...] — one bounded run (MONITOR_MAX_POLLS defaults to 1 here)
mon() {
    local sd="$1"; shift
    HOME="$LH" MONITOR_NOW="${NOW:-$T0}" MONITOR_NOW_STEP="${STEP:-60}" \
        MONITOR_MAX_POLLS="${POLLS:-1}" bash "$MON" --vault "$V" --state-dir "$sd" --interval 0 "$@" 2>"$TMP/err"
}
# seg <line> <name> — the ` · `-separated segment for worker <name>
seg() { printf '%s\n' "$1" | awk -v n="$2" 'BEGIN { FS = " · " } { for (i = 2; i <= NF; i++) if (index($i, n " ") == 1) { print $i; exit } }'; }
nlines() { if [ -z "$1" ]; then echo 0; else printf '%s\n' "$1" | wc -l | tr -d ' '; fi; }
waiting() { printf '%s\n' "$1" | awk '{ print $3 }'; }

SID_STUCK=11111111-1111-4111-8111-111111111111
SID_BUSY=22222222-2222-4222-8222-222222222222
SID_REM=33333333-3333-4333-8333-333333333333
transcript "$LH" "$SID_STUCK" $((T0 - 40 * 60))
transcript "$LH" "$SID_BUSY" $((T0 - 60))

# ============================================================ classification table ====
echo "classification (one row each):"
note p-coll    "status: collected" "tmux_session: brain-worker-p-coll"
note p-done    "status: done" "harness: claude"
note p-cmt     "status: done   # allowed values, ONLY these: primed | working | blocked | done | parked | collected."
note p-gone    "status: working   # allowed values, ONLY these: primed | working" "harness: claude"
note p-pgone   "status: parked" "harness: claude"
note p-q       "status: working" "harness: claude"
note p-rev     "status: blocked" "harness: claude" "blocker: awaiting review/merge of PR #9 — https://github.com/example/budgebell/pull/9"
note p-revnu   "status: blocked" "harness: claude" 'blocker: "awaiting review of the \"utc\" branch"'
note p-blk     "status: blocked" "harness: claude" "blocker: need the API key from the user"
note p-park    "status: parked" "harness: claude"
note p-busy    "status: working" "harness: claude" "session_id: $SID_BUSY"
note p-stuck   "status: working" "harness: claude" "session_id: $SID_STUCK"
note p-omp     "status: working" "harness: omp"
note p-oq      "status: working" "harness: omp"
pane brain-worker-p-q     claude/question
pane brain-worker-p-rev   claude/ready
pane brain-worker-p-revnu claude/ready
pane brain-worker-p-blk   claude/ready
pane brain-worker-p-park  claude/ready
pane brain-worker-p-busy  claude/busy
pane brain-worker-p-stuck claude/busy
pane brain-worker-p-omp   omp/busy
pane brain-worker-p-oq    omp/question
pane brain-worker-p-coll  claude/ready
ghpr 9 OPEN false "$OA" MERGEABLE pass   # p-rev's blocker names budgebell PR #9 → a PR row
ALL="p-nonote p-coll p-done p-cmt p-gone p-pgone p-q p-rev p-revnu p-blk p-park p-busy p-stuck p-omp p-oq"
SD1="$TMP/sd1"
# shellcheck disable=SC2086
OUT="$(mon "$SD1" --once $ALL)"
assert_eq "--once prints exactly one line" "1" "$(nlines "$OUT")"
assert_contains "line starts <iso-ts> <label> W/N waiting (N counts the PR row)" "$(iso $T0) p 10/16 waiting · " "$OUT"
assert_eq "row 1 note missing → CHECK"        "nonote CHECK 0m no note"   "$(seg "$OUT" nonote)"
assert_eq "row 2 collected → not waiting"     "coll collected 0m"         "$(seg "$OUT" coll)"
assert_eq "row 3 done → COLLECT"              "done COLLECT 0m"           "$(seg "$OUT" done)"
assert_eq "comment-stripped status (done # …)" "cmt COLLECT 0m"           "$(seg "$OUT" cmt)"
assert_eq "row 4 session absent → REVIVE (comment stripped)" "gone REVIVE 0m note=working" "$(seg "$OUT" gone)"
assert_eq "row 4/8 parked + no session → parked" "pgone parked 0m"        "$(seg "$OUT" pgone)"
assert_eq "row 5 question → ANSWER + fixture text" \
    'q ANSWER 0m "Find brief: Should I look for the worker brief under a different name in the workers folder, such as the most recently edited one? [1 Yes / 2 No]"' \
    "$(seg "$OUT" q)"
assert_eq "row 5 omp question box"            'oq ANSWER 0m "Allow tool: bash: Command: sleep 25 && echo SLEPT [1 Approve / 2 Deny]"' "$(seg "$OUT" oq)"
assert_eq "row 6 review → PR#9 from URL"      "rev REVIEW 0m PR#9"        "$(seg "$OUT" rev)"
assert_eq "row 6 review without URL → blocker, quotes removed" 'revnu REVIEW 0m "awaiting review of the utc branch"' "$(seg "$OUT" revnu)"
assert_eq "row 7 blocked → UNBLOCK verbatim"  'blk UNBLOCK 0m "need the API key from the user"' "$(seg "$OUT" blk)"
assert_eq "row 8 parked → not waiting"        "park parked 0m"            "$(seg "$OUT" park)"
assert_eq "row 10 stuck via transcript mtime" "stuck INSPECT 0m busy 0m, transcript silent 40m" "$(seg "$OUT" stuck)"
assert_eq "row 11 busy (fresh transcript)"    "busy busy 0m"              "$(seg "$OUT" busy)"
assert_eq "row 11 omp busy (no transcript check)" "omp busy 0m"           "$(seg "$OUT" omp)"
# order: waiting (argument order) first, then the rest
ORDER="$(printf '%s\n' "$OUT" | awk 'BEGIN { FS = " · " } { for (i = 2; i <= NF; i++) { split($i, a, " "); printf "%s ", a[1] } }')"
assert_eq "waiting first in arg order, then the rest" \
    "nonote done cmt gone q rev revnu blk stuck oq coll pgone park busy omp #9 " "$ORDER"
assert_eq "--once leaves no state file" "no" "$([ -e "$SD1/p.state" ] && echo yes || echo no)"
assert_contains "sessions targeted exactly (has-session)" "has-session -t =brain-worker-p-q" "$(cat "$TLOG")"
assert_contains "state read off the VISIBLE screen (claude capture -e, no -S)" "capture-pane -p -e -t =brain-worker-p-q:"$'\n' "$(cat "$TLOG")"$'\n'
assert_contains "question text read with history (-S -60)" "capture-pane -p -e -t =brain-worker-p-q: -S -60" "$(cat "$TLOG")"
VSUM="$(cat "$V"/workers/*.md | cksum)"
# shellcheck disable=SC2086
POLLS=2 mon "$TMP/sd1b" $ALL >/dev/null
assert_eq "notes untouched by a polling run" "$VSUM" "$(cat "$V"/workers/*.md | cksum)"
assert_eq "monitor never sends keys / writes panes" "" "$(grep -vE '^(has-session|capture-pane) ' "$TLOG")"

# A worker whose note exists ONLY under <vault>/private/workers/ is read from there.
echo "private worker note (only under private/workers):"
mkdir -p "$V/private/workers"
printf -- '---\nslug: p-priv\nstatus: done\nharness: claude\n---\n\n# p-priv\n' >"$V/private/workers/p-priv.md"
OUT="$(mon "$TMP/sdpriv" --once p-priv)"
assert_eq "private-only note → COLLECT (not 'no note')" "p-priv COLLECT 0m" "$(seg "$OUT" p-priv)"
printf -- '---\nslug: p-priv\nstatus: collected\n---\n' >"$V/workers/p-priv.md"
OUT="$(mon "$TMP/sdpriv2" --once p-priv)"
assert_eq "workers/ copy wins when both exist" "p-priv collected 0m" "$(seg "$OUT" p-priv)"
rm -f "$V/workers/p-priv.md"
PV="$TMP/privonly-vault"; mkdir -p "$PV/private/workers"
printf -- '---\nslug: p-priv\nstatus: done\n---\n' >"$PV/private/workers/p-priv.md"
OUT="$(HOME="$LH" MONITOR_NOW=$T0 MONITOR_MAX_POLLS=1 bash "$MON" --vault "$PV" --state-dir "$TMP/sdpriv3" --interval 0 --once p-priv 2>/dev/null)"
assert_eq "vault with only private/workers is not 'missing'" "p-priv COLLECT 0m" "$(seg "$OUT" p-priv)"
rm -rf "$V/private"

# ================================================================== idle debounce ====
echo "idle debounce:"
note i-idle "status: working" "harness: claude"
note i-ompidle "status: primed" "harness: omp"
pane brain-worker-i-idle claude/ready
pane brain-worker-i-ompidle omp/ready
SD2="$TMP/sd2"
OUT="$(mon "$SD2" i-idle i-ompidle)"
assert_eq "1 idle poll, first run → no line" "" "$OUT"
OUT="$(NOW=$((T0 + 60)) mon "$SD2" i-idle i-ompidle)"
assert_eq "2nd idle poll (persisted across restart) → one line" "1" "$(nlines "$OUT")"
assert_eq "idle → NUDGE with last message" "idle NUDGE 1m note=working said:\"I couldn't find the brief, so I can't follow its priming yet.\"" "$(seg "$OUT" idle)"
assert_eq "omp idle → NUDGE, no said: part" "ompidle NUDGE 1m note=primed" "$(seg "$OUT" ompidle)"
SD3="$TMP/sd3"
OUT="$(POLLS=2 mon "$SD3" i-idle)"
assert_eq "2 polls in one run → exactly the NUDGE line" "1" "$(nlines "$OUT")"
assert_contains "the line is the NUDGE" "idle NUDGE" "$OUT"
assert_eq "label is the slug itself for a single worker" "i-idle" "$(printf '%s\n' "$OUT" | awk '{ print $2 }')"
OUT="$(NOW=$((T0 + 60)) mon "$SD3" --once i-idle)"
assert_contains "--once after reporting → lowercase idle" "i-idle idle 1m note=working" "$OUT"

# ================================================ background agents still running ====
echo "background agents running (empty composer) → busy, never NUDGE:"
# A worker that ended its turn while its background subagents run shows a bare composer;
# it is working and will be woken by the agent's completion notification. Real captures
# (fixtures/README.md): the styled one is what the monitor really reads (`capture -e`).
note b-bg  "status: working" "harness: claude"
note b-bgp "status: working" "harness: claude"
pane brain-worker-b-bg  claude/busy-bg-agents-styled
pane brain-worker-b-bgp claude/busy-bg-agents
SD2B="$TMP/sd2b"
OUT="$(POLLS=3 mon "$SD2B" b-bg b-bgp)"
assert_eq "3 polls with agents running → no line at all" "" "$OUT"
assert_not_contains "never a NUDGE" "NUDGE" "$OUT"
OUT="$(NOW=$((T0 + 120)) mon "$SD2B" --once b-bg b-bgp)"
assert_eq "styled capture → busy" "bg busy 2m" "$(seg "$OUT" bg)"
assert_eq "plain capture → busy"  "bgp busy 2m" "$(seg "$OUT" bgp)"
# One poll after the agent finished the panel is gone, but claude is handling the agent's
# notification (`✢ Beaming… (2s · thinking)`, no token count yet) → still busy.
pane brain-worker-b-bg claude/busy-agent-notification-styled
OUT="$(NOW=$((T0 + 150)) POLLS=2 mon "$SD2B" b-bg)"
assert_eq "agent notification being handled → busy, no line" "" "$OUT"
# Once that turn ends (the same real capture minus its spinner) it is idle → NUDGE.
sed '/Beaming/,/Tip: Connect Claude/d' "$FX/claude/busy-agent-notification-styled.txt" >"$PANES/brain-worker-b-bg"
OUT="$(NOW=$((T0 + 180)) POLLS=2 mon "$SD2B" b-bg)"
assert_contains "agent finished, panel gone, 2 idle polls → NUDGE" "b-bg NUDGE" "$OUT"
assert_contains "said: is the last column-0 ● message, not the '  ● main' row" \
    "said:\"The review turned up two real issues" "$OUT"

# ================================================ background shell still running ====
echo "background shell running (empty composer, footer '· 1 shell ·') → busy, never NUDGE:"
# A worker that ended its turn with a run_in_background shell still running (a CI watch)
# is working: claude re-invokes itself when the shell exits. Real captures
# (fixtures/README.md); the styled one is what the monitor really reads.
note s-sh  "status: working" "harness: claude"
note s-shp "status: working" "harness: claude"
pane brain-worker-s-sh  claude/busy-bg-shell-styled
pane brain-worker-s-shp claude/busy-bg-shell
SD2S="$TMP/sd2s"
OUT="$(POLLS=3 mon "$SD2S" s-sh s-shp)"
assert_eq "3 polls with a shell running → no line at all" "" "$OUT"
assert_not_contains "never a NUDGE" "NUDGE" "$OUT"
OUT="$(NOW=$((T0 + 120)) mon "$SD2S" --once s-sh s-shp)"
assert_eq "styled capture → busy" "sh busy 2m" "$(seg "$OUT" sh)"
assert_eq "plain capture → busy"  "shp busy 2m" "$(seg "$OUT" shp)"
# The real capture after the shell exited and claude finished handling it → idle → NUDGE.
pane brain-worker-s-sh claude/ready-after-bg-shell-styled
OUT="$(NOW=$((T0 + 180)) POLLS=2 mon "$SD2S" s-sh)"
assert_contains "shell finished, turn ended, 2 idle polls → NUDGE" "s-sh NUDGE" "$OUT"
assert_contains "said: is the final message" "said:\"PR #11 is ready for you to merge" "$OUT"

# ================================================== change-only emission + restart ====
echo "change-only emission, capitals, clear, restart:"
note c-a "status: blocked" "harness: claude" "blocker: need the API key"
note c-b "status: working" "harness: claude"
pane brain-worker-c-a claude/ready
pane brain-worker-c-b claude/busy
SD4="$TMP/sd4"
OUT="$(POLLS=3 mon "$SD4" c-a c-b)"
assert_eq "same state 3 polls → 1 line" "1" "$(nlines "$OUT")"
assert_eq "label = common prefix" "c" "$(printf '%s\n' "$OUT" | awk '{ print $2 }')"
assert_contains "new wait in capitals" '1/2 waiting · a UNBLOCK 0m "need the API key" · b busy 0m' "$OUT"
# <label>-<cksum of the sorted slug list>.state: two monitors sharing a label never clobber
H_CAB="$(printf '%s\n' c-a c-b | LC_ALL=C sort | cksum | awk '{ print $1 }')"
assert_eq "state file at <state-dir>/<label>-<slug-set hash>.state" "yes" "$([ -f "$SD4/c-$H_CAB.state" ] && echo yes || echo no)"
OUT="$(NOW=$((T0 + 600)) POLLS=2 mon "$SD4" c-a c-b)"
assert_eq "restart with same state → nothing re-emitted" "" "$OUT"
BEFORE="$(cat "$SD4/c-$H_CAB.state")"
OUT="$(NOW=$((T0 + 600)) mon "$SD4" --once c-a c-b)"
assert_contains "--once always prints; reported wait in lowercase with duration" 'a blocked 10m "need the API key"' "$OUT"
assert_eq "--once leaves state untouched" "$BEFORE" "$(cat "$SD4/c-$H_CAB.state")"
pane brain-worker-c-b claude/question
OUT="$(NOW=$((T0 + 900)) mon "$SD4" c-a c-b)"
assert_contains "new wait capitals, old one lowercase" \
    '2/2 waiting · a blocked 15m "need the API key" · b ANSWER 0m "Find brief:' "$OUT"
note c-a "status: blocked" "harness: claude" "blocker: need the API key AND a test account"
OUT="$(NOW=$((T0 + 960)) mon "$SD4" c-a c-b)"
assert_contains "changed wait detail → capitals again, duration reset" 'a UNBLOCK 0m "need the API key AND a test account"' "$OUT"
assert_contains "unchanged wait stays lowercase" "b question 1m" "$OUT"
note c-a "status: working" "harness: claude"
pane brain-worker-c-a claude/busy
pane brain-worker-c-b claude/busy
OUT="$(NOW=$((T0 + 1200)) mon "$SD4" c-a c-b)"
assert_eq "cleared → 0/N waiting line" "$(iso $((T0 + 1200))) c 0/2 waiting · a busy 0m · b busy 0m" "$OUT"
OUT="$(NOW=$((T0 + 1260)) POLLS=2 mon "$SD4" c-a c-b)"
assert_eq "still clear → silent" "" "$OUT"
OUT="$(NOW=$((T0 + 7200 + 1200)) mon "$SD4" --once c-a c-b)"
assert_contains "--once prints 0/N snapshot; hours duration" "0/2 waiting · a busy 2h" "$OUT"

echo "same label, different worker sets → separate state files:"
SD4B="$TMP/sd4b"
note l-a "status: blocked" "harness: claude" "blocker: x"
note l-b "status: blocked" "harness: claude" "blocker: y"
pane brain-worker-l-a claude/ready
pane brain-worker-l-b claude/ready
OUT1="$(mon "$SD4B" --label shared l-a)"
OUT2="$(mon "$SD4B" --label shared l-b)"
assert_contains "monitor A reports its wait" "l-a UNBLOCK" "$OUT1"
assert_contains "monitor B reports its wait" "l-b UNBLOCK" "$OUT2"
OUT1="$(NOW=$((T0 + 60)) mon "$SD4B" --label shared l-a)"
assert_eq "monitor A's state survived monitor B → nothing re-emitted" "" "$OUT1"
assert_eq "two state files" "2" "$(command ls "$SD4B" | grep -c '^shared-[0-9]*\.state$')"
OUT1="$(NOW=$((T0 + 120)) mon "$SD4B" --label shared l-b l-a)"
OUT2="$(NOW=$((T0 + 120)) mon "$SD4B" --label shared l-a l-b)"
assert_eq "argument order does not change the state file" "3" "$(command ls "$SD4B" | grep -c '^shared-[0-9]*\.state$')"

SD5="$TMP/sd5"
OUT="$(mon "$SD5" c-b)"
assert_eq "first run, nothing waiting → no line" "" "$OUT"

# ===================================================== visible screen vs scrollback ====
echo "state from the visible screen; scrollback only for the detail text:"
# Assistant prose / an old dialog that scrolled off must not read as an open question
# (sticky false ANSWER): the predicates see only the visible screen.
note v-prose "status: working" "harness: claude"
note v-olddlg "status: working" "harness: claude"
note v-said "status: working" "harness: claude"
pane brain-worker-v-prose claude/busy
scroll brain-worker-v-prose $'● Do you want to proceed? I can also make this edit now.\n❯ 1. Yes\n  2. No'
pane brain-worker-v-olddlg claude/busy
scroll brain-worker-v-olddlg "$(cat "$FX/claude/question.txt")"
sed '/^● /d' "$FX/claude/ready.txt" >"$PANES/brain-worker-v-said"
scroll brain-worker-v-said '● From the scrollback: the brief is missing.'
OUT="$(mon "$TMP/sdv" --once v-prose v-olddlg)"
assert_eq "prose 'Do you want to proceed?' in scrollback + busy screen → busy" "prose busy 0m" "$(seg "$OUT" prose)"
assert_eq "an old question dialog in scrollback + busy screen → busy" "olddlg busy 0m" "$(seg "$OUT" olddlg)"
OUT="$(POLLS=2 mon "$TMP/sdv2" v-said)"
assert_contains "idle said: may come from scrollback (deep capture)" 'said:"From the scrollback: the brief is missing."' "$OUT"

# ============================================================ said: from transcript ====
echo "idle said: = last line of the last assistant text message in the transcript:"
# The pane has no scrollback (hist=0): on a long final message the `● ` line scrolls off,
# so for a claude worker with a session_id the transcript is the source; the pane is the
# fallback. All panes here show claude/ready (pane said: "I couldn't find the brief, …").
PANE_SAID="I couldn't find the brief, so I can't follow its priming yet."
# txw <home> <sid> <jsonl-line>... — writes the main transcript with those lines
txw() {
    local h="$1" sid="$2"; shift 2
    mkdir -p "$h/.claude/projects/-x-proj"
    printf '%s\n' "$@" >"$h/.claude/projects/-x-proj/$sid.jsonl"
}
U='{"type":"user","isSidechain":false,"message":{"role":"user","content":"go"}}'
atext() { printf '{"type":"assistant","isSidechain":%s,"message":{"role":"assistant","content":[{"type":"text","text":"%s"}]}}' "${2:-false}" "$1"; }
ATOOL='{"type":"assistant","isSidechain":false,"message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}]}}'
ATHINK='{"type":"assistant","isSidechain":false,"message":{"role":"assistant","content":[{"type":"thinking","thinking":"hmm"},{"type":"text","text":"   "}]}}'
said_of() { printf '%s\n' "$1" | sed -n 's/.*said:"\([^"]*\)".*/\1/p'; }
SID_TA=55555555-5555-4555-8555-555555555551
SID_TB=55555555-5555-4555-8555-555555555552
SID_TC=55555555-5555-4555-8555-555555555553
SID_TD=55555555-5555-4555-8555-555555555554
SID_TE=55555555-5555-4555-8555-555555555555
SID_TF=55555555-5555-4555-8555-555555555556
txw "$LH" "$SID_TA" "$U" "$(atext 'old message')" "$U" \
    "$(atext 'Done with the change.\n\nPR #12 is ready for review.\n\n  \n')"
txw "$LH" "$SID_TB" "$U" "$(atext 'Summary first line\nEarlier text is the answer.')" "$ATOOL" "$ATHINK" \
    "$(atext 'a sidechain reply' true)"
txw "$LH" "$SID_TC" "$U" "$(atext 'Good line survives.')" '{"type":"assistant", this is not json' 'garbage'
txw "$LH" "$SID_TD" "$U" "$(atext 'Intro\n- Merged PR #3 into main')"
txw "$LH" "$SID_TF" "$U" "$ATOOL"
for x in ta tb tc td te tf; do pane brain-worker-x-$x claude/ready; done
note x-ta "status: working" "harness: claude" "session_id: $SID_TA"
note x-tb "status: working" "harness: claude" "session_id: $SID_TB"
note x-tc "status: working" "harness: claude" "session_id: $SID_TC"
note x-td "status: working" "harness: claude" "session_id: $SID_TD"
note x-te "status: working" "harness: claude" "session_id: $SID_TE"   # no transcript
note x-tf "status: working" "harness: claude" "session_id: $SID_TF"   # no text entry at all
OUT="$(POLLS=2 mon "$TMP/sdtx" x-ta x-tb x-tc x-td x-te x-tf)"
assert_eq "last line of the last assistant text, trailing blank lines skipped" \
    "PR #12 is ready for review." "$(said_of "$(seg "$OUT" ta)")"
assert_eq "last assistant entry tool_use/blank-only, sidechain ignored → earlier text" \
    "Earlier text is the answer." "$(said_of "$(seg "$OUT" tb)")"
assert_eq "unparseable lines ignored" "Good line survives." "$(said_of "$(seg "$OUT" tc)")"
assert_eq "leading markdown list marker stripped" "Merged PR #3 into main" "$(said_of "$(seg "$OUT" td)")"
assert_eq "transcript missing → pane fallback" "$PANE_SAID" "$(said_of "$(seg "$OUT" te)")"
assert_eq "transcript has no assistant text → pane fallback" "$PANE_SAID" "$(said_of "$(seg "$OUT" tf)")"
assert_not_contains "no monitor-error" "monitor-error" "$OUT"
# jq unavailable on the host → silent pane fallback (no stderr reaching stdout, no error)
mkdir -p "$TMP/nojq"
printf '#!/bin/sh\necho "zsh: command not found: jq" >&2\nexit 127\n' >"$TMP/nojq/jq"; chmod +x "$TMP/nojq/jq"
OUT="$(PATH="$TMP/nojq:$PATH" POLLS=2 mon "$TMP/sdtx2" x-ta)"
assert_eq "jq missing → pane fallback" "$PANE_SAID" "$(said_of "$OUT")"
assert_not_contains "jq missing → nothing about jq on stdout" "jq" "$OUT"
assert_not_contains "jq missing → no monitor-error" "monitor-error" "$OUT"
# long transcript line → the usual 160-char truncation
txw "$LH" "$SID_TE" "$U" "$(atext "$(printf 'y%.0s' $(seq 1 200))")"
OUT="$(POLLS=2 mon "$TMP/sdtx3" x-te)"
assert_eq "transcript said: truncated to 160 chars" "$(printf 'y%.0s' $(seq 1 159))…" "$(said_of "$OUT")"
# remote host: read over ssh from the remote HOME
SID_TR=55555555-5555-4555-8555-55555555555a
txw "$RH" "$SID_TR" "$U" "$(atext 'Remote says hi.')"
note x-tr "status: working" "host: homeserver" "harness: claude" "session_id: $SID_TR"
pane brain-worker-x-tr claude/ready
OUT="$(POLLS=2 mon "$TMP/sdtx4" x-tr)"
assert_eq "remote host transcript → said:" "Remote says hi." "$(said_of "$OUT")"
# only the tail is read: an assistant text buried far above the last 200 lines is not used
{ printf '%s\n' "$U" "$(atext 'Buried deep.')"; for _ in $(seq 1 250); do printf '%s\n' "$U"; done; } \
    >"$LH/.claude/projects/-x-proj/$SID_TA.jsonl"
OUT="$(POLLS=2 mon "$TMP/sdtx5" x-ta)"
assert_eq "text only beyond the tail → pane fallback" "$PANE_SAID" "$(said_of "$OUT")"

# ============================================================== stuck over time ====
echo "stuck after --stuck-after:"
note s-w "status: working" "harness: claude" "session_id: $SID_BUSY"
pane brain-worker-s-w claude/busy
SD6="$TMP/sd6"
OUT="$(mon "$SD6" s-w)"
assert_eq "fresh transcript → busy, silent" "" "$OUT"
OUT="$(NOW=$((T0 + 31 * 60)) mon "$SD6" s-w)"
assert_eq "transcript silent 32m → INSPECT, busy since first poll" "s-w INSPECT 0m busy 31m, transcript silent 32m" "$(seg "$OUT" s-w)"
OUT="$(NOW=$((T0 + 35 * 60)) mon "$SD6" s-w)"
assert_eq "still stuck (key ignores durations) → silent" "" "$OUT"
OUT="$(NOW=$((T0 + 31 * 60)) mon "$SD6" --once --stuck-after 60 s-w)"
assert_contains "--stuck-after 60 → busy" "0/1 waiting · s-w busy" "$OUT"

echo "stuck: subagent transcripts count as activity:"
# ~/.claude/projects/<proj>/<sid>/subagents/agent-*.jsonl — a worker whose own transcript
# is quiet while its background agent streams is working, not stuck.
SID_SUB=44444444-4444-4444-8444-444444444444
transcript "$LH" "$SID_SUB" $((T0 - 50 * 60))
mkdir -p "$LH/.claude/projects/-x-proj/$SID_SUB/subagents"
: >"$LH/.claude/projects/-x-proj/$SID_SUB/subagents/agent-a1.jsonl"
stamp "$LH/.claude/projects/-x-proj/$SID_SUB/subagents/agent-a1.jsonl" $((T0 - 2 * 60))
: >"$LH/.claude/projects/-x-proj/$SID_SUB/subagents/agent-a0.jsonl"
stamp "$LH/.claude/projects/-x-proj/$SID_SUB/subagents/agent-a0.jsonl" $((T0 - 90 * 60))
note s-sub "status: working" "harness: claude" "session_id: $SID_SUB"
pane brain-worker-s-sub claude/busy
OUT="$(mon "$TMP/sdsub" --once s-sub)"
assert_eq "main transcript silent 50m, subagent wrote 2m ago → busy" "s-sub busy 0m" "$(seg "$OUT" s-sub)"
OUT="$(NOW=$((T0 + 40 * 60)) mon "$TMP/sdsub" --once s-sub)"
assert_eq "silence is measured from the NEWEST of them" "s-sub INSPECT 0m busy 0m, transcript silent 42m" "$(seg "$OUT" s-sub)"

# ================================================================ truncation ====
echo "detail truncation:"
LONG="$(printf 'x%.0s' $(seq 1 200))"
note t-long "status: blocked" "blocker: $LONG"
pane brain-worker-t-long claude/ready
OUT="$(mon "$TMP/sd7" --once t-long)"
DET="$(printf '%s\n' "$OUT" | sed 's/.*UNBLOCK 0m "//; s/"$//')"
assert_eq "detail truncated to 160 chars with …" "$(printf 'x%.0s' $(seq 1 159))…" "$DET"
# Multibyte text under a C locale (a bare ssh/zsh -lc on a remote host can have LANG unset): bash
# counts BYTES there, so a naive ${s:0:159} splits a UTF-8 sequence.
LONGU="$(printf 'é%.0s' $(seq 1 200))"
note t-utf "status: blocked" "blocker: $LONGU"
pane brain-worker-t-utf claude/ready
utf8_ok() { printf '%s' "$1" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1; }
OUT="$(LC_ALL=C mon "$TMP/sd7u" --once t-utf)"
DET="$(printf '%s\n' "$OUT" | sed 's/.*UNBLOCK 0m "//; s/"$//')"
if utf8_ok "$OUT"; then ok "LC_ALL=C: line is valid UTF-8"; else bad "LC_ALL=C: line is valid UTF-8 (got split sequence)"; fi
assert_eq "LC_ALL=C: truncated by CHARACTERS (159 é + …)" "$(printf 'é%.0s' $(seq 1 159))…" "$DET"
# No UTF-8 locale on the host at all: byte truncation, minus any split trailing sequence.
OUT="$(LC_ALL=C MONITOR_UTF8_LOCALES=none mon "$TMP/sd7v" --once t-utf)"
DET="$(printf '%s\n' "$OUT" | sed 's/.*UNBLOCK 0m "//; s/"$//')"
if utf8_ok "$OUT"; then ok "no UTF-8 locale: line is still valid UTF-8"; else bad "no UTF-8 locale: line is still valid UTF-8"; fi
assert_eq "no UTF-8 locale: whole characters only, ends in …" "$(printf 'é%.0s' $(seq 1 79))…" "$DET"

# ================================================================== remote host ====
echo "remote host:"
note r-media "status: working" "host: homeserver" "harness: claude" "session_id: $SID_REM"
pane brain-worker-r-media claude/busy
transcript "$RH" "$SID_REM" $((T0 - 45 * 60))
: >"$SLOG"
OUT="$(mon "$TMP/sd8" --once r-media)"
assert_contains "remote stuck (transcript on remote HOME)" "r-media INSPECT 0m busy 0m, transcript silent 45m" "$OUT"
assert_contains "routed through BRAIN_SSH to the homeserver alias" "homeserver zsh -lc" "$(cat "$SLOG")"
assert_contains "remote capture-pane went over ssh" "capture-pane" "$(cat "$SLOG")"

echo "monitor-error:"
SD9="$TMP/sd9"
OUT="$(BRAIN_SSH="$TMP/dead-ssh" POLLS=3 mon "$SD9" r-media)"
assert_eq "unreachable host: one monitor-error over 3 polls" "1" "$(printf '%s\n' "$OUT" | grep -c ' monitor-error ')"
assert_contains "monitor-error line shape" "$(iso $T0) r-media monitor-error " "$OUT"
assert_contains "names the host" "homeserver" "$(printf '%s\n' "$OUT" | grep monitor-error)"
OUT="$(BRAIN_SSH="$TMP/dead-ssh" POLLS=2 mon "$SD9" r-media)"
assert_eq "same error after restart → not repeated" "0" "$(printf '%s\n' "$OUT" | grep -c ' monitor-error ')"
OUT="$(BRAIN_SSH="$TMP/dead-ssh" mon "$TMP/sd9x" --once r-media)"
assert_contains "never reached, no prior state → CHECK host unreachable" "r-media CHECK 0m host homeserver unreachable" "$OUT"

echo "host unreachable after state exists → last classification carried, marked stale:"
note r-mb "status: blocked" "host: homeserver" "harness: claude" "blocker: need the API key"
note r-mw "status: working" "host: homeserver" "harness: claude"
pane brain-worker-r-mb claude/ready
pane brain-worker-r-mw claude/busy
SD9B="$TMP/sd9b"
OUT="$(mon "$SD9B" r-mw r-mb)"
assert_contains "reachable: blocked worker reported" 'mb UNBLOCK 0m "need the API key"' "$OUT"
OUT="$(BRAIN_SSH="$TMP/dead-ssh" NOW=$((T0 + 60)) POLLS=3 mon "$SD9B" r-mw r-mb)"
assert_eq "going stale re-emits no worker line (only the one monitor-error)" "1" "$(nlines "$OUT")"
assert_contains "… and that line is the monitor-error" " monitor-error " "$OUT"
OUT="$(BRAIN_SSH="$TMP/dead-ssh" NOW=$((T0 + 600)) mon "$SD9B" --once r-mw r-mb)"
assert_eq "carried busy row is marked stale" "mw busy? 10m (stale: host homeserver unreachable)" "$(seg "$OUT" mw)"
assert_eq "carried waiting row is marked stale" 'mb blocked? 10m "need the API key" (stale: host homeserver unreachable)' "$(seg "$OUT" mb)"
assert_contains "carried rows still count as waiting" "1/2 waiting" "$OUT"
OUT="$(NOW=$((T0 + 660)) mon "$SD9B" r-mw r-mb)"
assert_eq "host back, nothing changed → silent" "" "$OUT"
OUT="$(NOW=$((T0 + 660)) mon "$SD9B" --once r-mw r-mb)"
assert_not_contains "host back → stale marker gone" "stale" "$OUT"
SD10="$TMP/sd10"
OUT="$(HOME="$LH" MONITOR_NOW=$T0 MONITOR_MAX_POLLS=3 bash "$MON" --vault "$TMP/novault" --state-dir "$SD10" --interval 0 c-a c-b 2>/dev/null)"; RC=$?
assert_eq "vault missing: keeps polling, rc 0 at max polls" "0" "$RC"
assert_eq "vault missing: one monitor-error over 3 polls" "1" "$(printf '%s\n' "$OUT" | grep -c ' monitor-error ')"
assert_contains "vault missing message" "c monitor-error vault" "$OUT"
mkdir -p "$TMP/ro"; chmod 555 "$TMP/ro"
OUT="$(POLLS=2 mon "$TMP/ro/sd" c-a 2>/dev/null)"
if [ -w "$TMP/ro" ]; then ok "state dir unwritable (skipped: running as root)"; else
    assert_eq "state dir unwritable → one monitor-error" "1" "$(printf '%s\n' "$OUT" | grep -c ' monitor-error ')"; fi
chmod 755 "$TMP/ro"

# ================================================================= defaults/usage ====
echo "defaults and usage:"
note budgebell-log-utc "status: blocked" "blocker: x"
note budgebell-nudge-cooldown "status: working"
pane brain-worker-budgebell-log-utc claude/ready
OUT="$(HOME="$LH" XDG_STATE_HOME="$TMP/xdg" MONITOR_NOW=$T0 MONITOR_MAX_POLLS=1 bash "$MON" --vault "$V" --interval 0 budgebell-log-utc budgebell-nudge-cooldown 2>/dev/null)"
assert_contains "label budgebell, names stripped" "budgebell 2/2 waiting · log-utc UNBLOCK 0m \"x\" · nudge-cooldown REVIVE 0m note=working" "$OUT"
H_BB="$(printf '%s\n' budgebell-log-utc budgebell-nudge-cooldown | LC_ALL=C sort | cksum | awk '{ print $1 }')"
assert_eq "default state dir under XDG_STATE_HOME" "yes" "$([ -f "$TMP/xdg/brain/worker-monitor/budgebell-$H_BB.state" ] && echo yes || echo no)"
OUT="$(mon "$TMP/sd11" --once c-a budgebell-log-utc)"
assert_contains "no common prefix → label workers, full names" "workers 1/2 waiting · budgebell-log-utc UNBLOCK" "$OUT"
OUT="$(mon "$TMP/sd12" --once --label fleet c-a c-b)"
assert_contains "--label overrides" " fleet 0/2 waiting · a busy" "$OUT"

HELP="$(bash "$MON" --help)"; RC=$?
assert_eq "--help rc 0" "0" "$RC"
assert_contains "--help shows the Monitor invocation" 'Monitor(command: "bash ~/projects/brain/skills/brain-monitor/scripts/worker-monitor.sh budgebell-log-utc budgebell-nudge-cooldown", description: "budgebell worker waits", timeout_ms: 1800000)' "$HELP"
assert_contains "--help says re-run on expiry" "re-run" "$HELP"
bash "$MON" >/dev/null 2>&1; RC=$?
assert_eq "no slugs → rc 2" "2" "$RC"
bash "$MON" --bogus x >/dev/null 2>&1; RC=$?
assert_eq "unknown flag → rc 2" "2" "$RC"
bash "$MON" --interval >/dev/null 2>&1; RC=$?
assert_eq "flag missing value → rc 2" "2" "$RC"
bash "$MON" --interval abc x >/dev/null 2>&1; RC=$?
assert_eq "non-numeric interval → rc 2" "2" "$RC"

echo "legacy host (local / unset) is read as this machine, with a stderr warning:"
note lg-local "status: working" "host: local" "harness: claude"
note lg-unset "status: working" "harness: claude"
note lg-far   "status: working" "host: local" "harness: claude" "project_dir: $TMP/not-on-this-machine"
note lg-real  "status: working" "host: desktop" "harness: claude"
for s in lg-local lg-unset lg-far lg-real; do pane "brain-worker-$s" claude/busy; done
SDL="$TMP/sd-legacy"
OUT="$(mon "$TMP/sd-legacy0" --once lg-local lg-unset lg-far lg-real)"
assert_eq "legacy notes still classify (busy, not unknown)" "4" "$(printf "%s\n" "$OUT" | grep -o " busy " | wc -l | tr -d " ")"
assert_not_contains "warning never reaches stdout" "warning" "$OUT"
POLLS=3 mon "$SDL" lg-local lg-unset lg-far lg-real >/dev/null; ERR="$(cat "$TMP/err")"
assert_contains "local warns, naming slug and self" "warning: lg-local: legacy host 'local' read as desktop" "$ERR"
assert_contains "unset host warns" "warning: lg-unset: legacy host 'unset' read as desktop" "$ERR"
assert_contains "missing project_dir adds the other-host hint" "project_dir $TMP/not-on-this-machine is not on this machine" "$ERR"
assert_eq "one warning per legacy slug across 3 polls" "3" "$(printf '%s\n' "$ERR" | grep -c '^warning: ')"
assert_not_contains "a real host name never warns" "lg-real" "$ERR"
OUT="$(BRAIN_SELF_HOST=nowhere mon "$TMP/sd-legacy2" --once lg-local)"
assert_contains "legacy host with unresolved self fails clearly" "lg-local CHECK 0m legacy host local but this machine is not in hosts.conf" "$OUT"
assert_contains "…and says why" "monitor-error worker lg-local: legacy host local but this machine's host is unresolved" "$OUT"

echo "legacy warning prints the raw project_dir and tests it as a directory:"
mkdir -p "$LH/proj-here"; : >"$TMP/a-file"
note lg-tilde  "status: working" "host: local" "harness: claude" "project_dir: ~/proj-not-here"
note lg-there  "status: working" "host: local" "harness: claude" "project_dir: ~/proj-here"
note lg-file   "status: working" "host: local" "harness: claude" "project_dir: $TMP/a-file"
for s in lg-tilde lg-there lg-file; do pane "brain-worker-$s" claude/busy; done
mon "$TMP/sd-legacy3" --once lg-tilde lg-there lg-file >/dev/null; ERR="$(cat "$TMP/err")"
assert_contains "raw ~ project_dir in the hint (as revive prints it)" \
    "warning: lg-tilde: legacy host 'local' read as desktop — project_dir ~/proj-not-here is not on this machine; it probably belongs to another host (fix its host:)" "$ERR"
assert_contains "~ project_dir that exists after expansion → no hint" "warning: lg-there: legacy host 'local' read as desktop" "$ERR"
assert_not_contains "…really no hint for it" "proj-here is not on this machine" "$ERR"
assert_contains "a project_dir that is a file, not a directory → hint" "project_dir $TMP/a-file is not on this machine" "$ERR"

echo "missing harness: assumed omp, warned once per slug:"
note h-noh  "status: working" "host: desktop"
note h-both "status: working" "project_dir: ~/proj-here"
for s in h-noh h-both; do pane "brain-worker-$s" omp/busy; done
POLLS=3 mon "$TMP/sd-noh" h-noh h-both >/dev/null; ERR="$(cat "$TMP/err")"
assert_contains "no harness: warns, naming the slug" "warning: h-noh: no harness: — assuming omp" "$ERR"
assert_contains "legacy + no harness: one line, revive's shape" \
    "warning: h-both: legacy host 'unset' read as desktop; no harness: — assuming omp" "$ERR"
assert_eq "one warning per slug across 3 polls" "2" "$(printf '%s\n' "$ERR" | grep -c '^warning: ')"
OUT="$(mon "$TMP/sd-noh2" --once h-noh)"
assert_contains "no-harness note still classifies as omp (busy)" "h-noh busy" "$OUT"

echo "host with no ssh route (alias -, not self): the real reason, not 'unreachable':"
sed 's/^desktop[[:space:]]\{1,\}[^[:space:]]\{1,\}/desktop   -/' "$BRAIN_HOSTS" >"$TMP/hosts-noroute.conf"
OUT="$(BRAIN_HOSTS="$TMP/hosts-noroute.conf" BRAIN_SELF_HOST=homeserver mon "$TMP/sd-noroute" --once lg-real)"
assert_contains "row names the missing route" "lg-real CHECK 0m no ssh route from homeserver to desktop (hosts.conf alias -)" "$OUT"
assert_contains "monitor-error names the missing route" "monitor-error no ssh route from homeserver to desktop (hosts.conf alias -)" "$OUT"
assert_not_contains "never 'tmux unreachable (rc 1)'" "unreachable (rc" "$OUT"

echo "host that is not in hosts.conf (e.g. a retired machine): a clear CHECK, not a crash:"
note uh-gone "status: working" "host: mac" "harness: claude" "tmux_session: brain-worker-uh-gone"
OUT="$(mon "$TMP/sd-unkhost" --once uh-gone)"; RC=$?
assert_eq "unknown host: monitor itself still exits 0" "0" "$RC"
assert_contains "row says CHECK unknown host" "uh-gone CHECK 0m unknown host mac" "$OUT"
assert_contains "monitor-error names slug and host" "monitor-error worker uh-gone: unknown host mac" "$OUT"
rm -f "$V/workers/uh-gone.md"

# ======================================================================== PR watch ====

echo "PR watch: --pr only (no slugs), change-triggered rows:"
ghreset
ghpr 4 OPEN false "$OA" MERGEABLE pending
SDP="$TMP/sdp"
P4=https://github.com/example/brain/pull/4
OUT="$(mon "$SDP" --pr "$P4")"
assert_eq "first poll → one line, label prs, new PR row in capitals" \
    "$(iso $T0) prs 0/1 waiting · #4 CI @aaaaaaa checks=pending MERGEABLE" "$OUT"
assert_contains "gh asked once, by number and repo" "pr view 4 -R example/brain --json" "$(cat "$GLOG")"
H_P="$(printf '%s\n' github:example/brain#4 | LC_ALL=C sort | cksum | awk '{ print $1 }')"
assert_eq "state file key hashes the --pr refs" "yes" "$([ -f "$SDP/prs-$H_P.state" ] && echo yes || echo no)"
OUT="$(NOW=$((T0 + 60)) POLLS=2 mon "$SDP" --pr "$P4")"
assert_eq "re-arm, nothing changed → silent" "" "$OUT"
OUT="$(NOW=$((T0 + 120)) mon "$SDP" --once --pr example/brain#4)"
assert_eq "--once (o/r#n form) → lowercase unchanged row" \
    "$(iso $((T0 + 120))) prs 0/1 waiting · #4 ci @aaaaaaa checks=pending MERGEABLE" "$OUT"
ghpr 4 OPEN false "$OA" MERGEABLE pass
OUT="$(NOW=$((T0 + 180)) mon "$SDP" --pr "$P4")"
assert_eq "ci → green prints GREEN (not waiting)" \
    "$(iso $((T0 + 180))) prs 0/1 waiting · #4 GREEN @aaaaaaa checks=pass MERGEABLE" "$OUT"
ghpr 4 OPEN false "$OA" UNKNOWN pass
OUT="$(NOW=$((T0 + 240)) mon "$SDP" --pr "$P4")"
assert_eq "mergeable flapping to UNKNOWN alone → silent" "" "$OUT"
ghpr 4 OPEN false "$OB" MERGEABLE pending
OUT="$(NOW=$((T0 + 300)) mon "$SDP" --pr "$P4")"
assert_eq "new head → HEAD" "$(iso $((T0 + 300))) prs 0/1 waiting · #4 HEAD @bbbbbbb checks=pending MERGEABLE" "$OUT"
ghpr 4 OPEN false "$OB" MERGEABLE fail
OUT="$(NOW=$((T0 + 360)) mon "$SDP" --pr "$P4")"
assert_eq "checks fail → RED, counted waiting" \
    "$(iso $((T0 + 360))) prs 1/1 waiting · #4 RED @bbbbbbb checks=fail MERGEABLE" "$OUT"
ghpr 4 OPEN false "$OB" CONFLICTING fail
OUT="$(NOW=$((T0 + 420)) mon "$SDP" --pr "$P4")"
assert_eq "red + conflicting → RED wins, detail shows both" \
    "$(iso $((T0 + 420))) prs 1/1 waiting · #4 RED @bbbbbbb checks=fail CONFLICTING" "$OUT"
ghpr 4 OPEN false "$OB" CONFLICTING pass
OUT="$(NOW=$((T0 + 480)) mon "$SDP" --pr "$P4")"
assert_eq "conflicting, checks pass → CONFLICT" \
    "$(iso $((T0 + 480))) prs 1/1 waiting · #4 CONFLICT @bbbbbbb checks=pass CONFLICTING" "$OUT"
ghpr 4 OPEN false "$OA" CONFLICTING pass
OUT="$(NOW=$((T0 + 540)) mon "$SDP" --pr "$P4")"
assert_contains "new head while conflicting → CONFLICT, not HEAD" "#4 CONFLICT @aaaaaaa" "$OUT"
ghpr 4 OPEN true "$OA" MERGEABLE pass
OUT="$(NOW=$((T0 + 600)) mon "$SDP" --pr "$P4")"
assert_contains "draft → DRAFT, not waiting" "prs 0/1 waiting · #4 DRAFT @aaaaaaa" "$OUT"
ghpr 4 MERGED false "$OA" UNKNOWN pass
OUT="$(NOW=$((T0 + 660)) mon "$SDP" --pr "$P4")"
assert_eq "merged → MERGED, counted waiting" \
    "$(iso $((T0 + 660))) prs 1/1 waiting · #4 MERGED @aaaaaaa checks=pass UNKNOWN" "$OUT"
: >"$GLOG"
OUT="$(NOW=$((T0 + 720)) POLLS=3 mon "$SDP" --pr "$P4")"
assert_eq "merged, unchanged → silent" "" "$OUT"
assert_eq "a merged PR is never re-queried" "0" "$(ghcalls 4)"
OUT="$(NOW=$((T0 + 900)) mon "$SDP" --once --pr "$P4")"
assert_contains "merged stays as a lowercase row" "prs 1/1 waiting · #4 merged @aaaaaaa" "$OUT"

echo "PR watch: closed, and transitions within one run:"
ghreset
ghpr 6 OPEN false "$OA" MERGEABLE pending
ghpr 6 OPEN false "$OA" MERGEABLE pending 1
ghpr 6 CLOSED false "$OA" UNKNOWN none 2
ghpr 6 CLOSED false "$OA" UNKNOWN none 3
OUT="$(POLLS=4 mon "$TMP/sdp2" --pr example/brain#6)"
assert_eq "pending, pending, closed, closed → two lines" "2" "$(nlines "$OUT")"
assert_contains "second line is CLOSED, waiting" "1/1 waiting · #6 CLOSED @aaaaaaa checks=none UNKNOWN" "$OUT"
assert_eq "one gh call per poll" "4" "$(ghcalls 6)"

echo "PR watch: gh failure → one monitor-error, last tuple carried stale:"
ghreset
ghpr 7 OPEN false "$OA" MERGEABLE fail
SDP3="$TMP/sdp3"
OUT="$(mon "$SDP3" --pr example/brain#7)"
assert_contains "reported RED" "#7 RED" "$OUT"
printf 'HTTP 502: Bad Gateway (https://api.github.com/graphql)\n' >"$GFX/7.fail"
OUT="$(NOW=$((T0 + 60)) POLLS=3 mon "$SDP3" --pr example/brain#7)"
assert_eq "3 failing polls → exactly one line" "1" "$(nlines "$OUT")"
assert_eq "…the monitor-error, naming the ref" \
    "$(iso $((T0 + 60))) prs monitor-error gh example/brain#7: HTTP 502: Bad Gateway (https://api.github.com/graphql)" "$OUT"
OUT="$(NOW=$((T0 + 120)) mon "$SDP3" --once --pr example/brain#7)"
assert_contains "carried row marked stale, still waiting" "1/1 waiting · #7 red? @aaaaaaa checks=fail MERGEABLE (stale: gh)" "$OUT"
rm -f "$GFX/7.fail"
OUT="$(NOW=$((T0 + 180)) mon "$SDP3" --pr example/brain#7)"
assert_eq "gh back, nothing changed → silent" "" "$OUT"
ghreset
printf 'gh: To get started with GitHub CLI, please run:  gh auth login\n' >"$GFX/8.fail"
OUT="$(POLLS=2 mon "$TMP/sdp3b" --pr example/brain#8)"
assert_eq "gh failing before any state → only the monitor-error" "1" "$(nlines "$OUT")"
assert_contains "…once" "prs monitor-error gh example/brain#8: gh: To get started" "$OUT"
OUT="$(mon "$TMP/sdp3b" --once --pr example/brain#8)"
assert_contains "never-fetched row reads unknown" "0/1 waiting · #8 unknown? (stale: gh)" "$OUT"

echo "PR watch: discovery from worker note FRONTMATTER (blocker:, pr:):"
ghreset
ghpr 9 OPEN false "$OA" MERGEABLE pass
ghpr 12 OPEN false "$OB" MERGEABLE pending
note d-rev "status: blocked" "harness: claude" "blocker: awaiting review/merge of https://github.com/example/budgebell/pull/9."
note d-two "status: working" "harness: claude" "pr: https://github.com/example/budgebell/pull/9"
note d-pr  "status: working" "harness: claude" "pr: example/budgebell#12"
pane brain-worker-d-rev claude/ready
pane brain-worker-d-two claude/busy
pane brain-worker-d-pr  claude/busy
SDD="$TMP/sdd"
OUT="$(mon "$SDD" --pr https://github.com/example/budgebell/pull/9/files d-rev d-two d-pr)"
assert_eq "worker rows unchanged, PR rows after them, deduplicated" \
    "$(iso $T0) d 1/5 waiting · rev REVIEW 0m PR#9 · two busy 0m · pr busy 0m · #9 GREEN @aaaaaaa checks=pass MERGEABLE · #12 CI @bbbbbbb checks=pending MERGEABLE" "$OUT"
assert_eq "same PR named 3 times → one gh call" "1" "$(ghcalls 9)"
OUT="$(NOW=$((T0 + 60)) mon "$SDD" --pr https://github.com/example/budgebell/pull/9/files d-rev d-two d-pr)"
assert_eq "re-arm with the identical command → silent" "" "$OUT"
ghpr 13 OPEN false "$OA" MERGEABLE pass
note d-pr  "status: working" "harness: claude" "pr: https://github.com/example/brain/pull/13"
OUT="$(NOW=$((T0 + 120)) mon "$SDD" --pr https://github.com/example/budgebell/pull/9/files d-rev d-two d-pr)"
assert_contains "two repos → <repo>#<n> names; unreferenced PR dropped" \
    "pr busy 2m · budgebell#9 green @aaaaaaa checks=pass MERGEABLE · brain#13 GREEN @aaaaaaa" "$OUT"
assert_not_contains "PR #12 no longer named → no row" "#12" "$OUT"

echo "PR watch: pr: lists PRs separated by spaces, commas, or both:"
ghreset
for n in 21 22 23 24 25 26; do ghpr $n OPEN false "$OA" MERGEABLE pass; done
note d-sep "status: working" "harness: claude" \
    "pr: example/brain#21 https://github.com/example/brain/pull/22,example/brain#23 ,  example/brain#24	example/brain#25,https://github.com/example/brain/pull/26"
pane brain-worker-d-sep claude/busy
OUT="$(mon "$TMP/sdsep" --once d-sep)"
assert_eq "space, comma, comma+spaces and tab separators → six PR rows" \
    "#21 #22 #23 #24 #25 #26" "$(printf '%s\n' "$OUT" | grep -oE '#2[0-9] GREEN' | cut -d' ' -f1 | tr '\n' ' ' | sed 's/ $//')"
assert_eq "no unsupported-reference warning" "" "$(grep 'unsupported' "$TMP/err")"

echo "PR watch: body links ignored; unsupported URLs only warn on stderr:"
ghreset
{ printf -- '---\nslug: d-body\nstatus: working\nharness: claude\n---\n\n# d-body\n'
  printf 'Earlier PR: https://github.com/example/brain/pull/1\npr: example/brain#2\n'; } >"$V/workers/d-body.md"
note d-gl "status: blocked" "harness: claude" "blocker: awaiting review of https://gitlab.com/g/p/-/merge_requests/3"
pane brain-worker-d-body claude/busy
pane brain-worker-d-gl claude/ready
OUT="$(POLLS=3 mon "$TMP/sdd2" d-body d-gl)"; ERR="$(cat "$TMP/err")"
assert_eq "body-only links → no gh call" "" "$(cat "$GLOG")"
assert_eq "no PR rows (the worker row keeps its PR#n)" "$(iso $T0) d 1/2 waiting · gl REVIEW 0m PR#3 · body busy 0m" "$OUT"
assert_eq "gitlab URL → one stderr warning per run" "1" "$(printf '%s\n' "$ERR" | grep -c '^warning: d-gl: unsupported PR reference https://gitlab.com/g/p/-/merge_requests/3')"
assert_not_contains "never on stdout" "warning" "$OUT"

echo "PR watch: workers only → gh never called, state key unchanged:"
ghreset
OUT="$(mon "$TMP/sdd3" --once c-a c-b)"
assert_eq "no PR named → no gh call" "" "$(cat "$GLOG")"
bash "$MON" --pr https://gitlab.com/g/p/-/merge_requests/3 >/dev/null 2>&1; RC=$?
assert_eq "unsupported --pr → rc 2" "2" "$RC"
bash "$MON" --pr >/dev/null 2>&1; RC=$?
assert_eq "--pr without a value → rc 2" "2" "$RC"

echo "PR watch review fixes:"
ghreset
# reordering the PR list with no state change → silent
ghpr 31 OPEN false "$OA" MERGEABLE pass; ghpr 32 OPEN false "$OA" MERGEABLE pass
note d-ord "status: working" "harness: claude" "pr: example/brain#31 example/brain#32"
pane brain-worker-d-ord claude/busy
mon "$TMP/sdord" d-ord >/dev/null
note d-ord "status: working" "harness: claude" "pr: example/brain#32 example/brain#31"
OUT="$(NOW=$((T0 + 60)) mon "$TMP/sdord" d-ord)"
assert_eq "same PRs in another order, nothing changed → silent" "" "$OUT"
# checks=none is not green (a new PR whose checks have not registered yet)
ghreset
ghpr 33 OPEN false "$OA" MERGEABLE none
OUT="$(mon "$TMP/sdnone" --pr example/brain#33)"
assert_contains "no checks + mergeable → OPEN, not GREEN" "#33 OPEN @aaaaaaa checks=none MERGEABLE" "$OUT"
ghpr 33 OPEN false "$OA" MERGEABLE pass
OUT="$(NOW=$((T0 + 60)) mon "$TMP/sdnone" --pr example/brain#33)"
assert_contains "…then checks pass → GREEN" "#33 GREEN @aaaaaaa checks=pass MERGEABLE" "$OUT"
# a rebase (new head, mergeable UNKNOWN) of a conflicting PR → HEAD, not a stale CONFLICT
ghpr 34 OPEN false "$OA" CONFLICTING pass
mon "$TMP/sdreb" --pr example/brain#34 >/dev/null
ghpr 34 OPEN false "$OB" UNKNOWN pending
OUT="$(NOW=$((T0 + 60)) mon "$TMP/sdreb" --pr example/brain#34)"
assert_contains "rebased conflicting PR → HEAD" "#34 HEAD @bbbbbbb checks=pending UNKNOWN" "$OUT"
assert_contains "…and no longer waiting" "prs 0/1 waiting" "$OUT"
# two URLs joined by a bare comma in blocker:; owner/repo deduped case-insensitively
ghreset
ghpr 41 OPEN false "$OA" MERGEABLE pass; ghpr 42 OPEN false "$OA" MERGEABLE pass
note d-cm "status: blocked" "harness: claude" "blocker: awaiting review of https://github.com/example/brain/pull/41,https://github.com/example/brain/pull/42"
pane brain-worker-d-cm claude/ready
OUT="$(mon "$TMP/sdcm" --once --pr EXAMPLE/Brain#41 d-cm)"; ERR="$(cat "$TMP/err")"
assert_contains "comma-joined URLs → both PRs" "#41 GREEN @aaaaaaa checks=pass MERGEABLE · #42 GREEN" "$OUT"
assert_eq "EXAMPLE/Brain#41 and example/brain#41 are one PR (one gh call)" "1" "$(ghcalls 41)"
assert_not_contains "no unsupported warning" "unsupported" "$ERR"
# same repo name under two owners → owner/repo#n names
ghpr 43 OPEN false "$OA" MERGEABLE pass; ghpr 44 OPEN false "$OA" MERGEABLE pass
OUT="$(mon "$TMP/sdown" --once --pr example/brain#43 --pr other/brain#44)"
assert_contains "colliding repo names → owner/repo#n" "example/brain#43 GREEN @aaaaaaa checks=pass MERGEABLE · other/brain#44 GREEN" "$OUT"
# re-arm with a CHANGED slug list (same label) re-emits no PR row
ghreset
ghpr 51 MERGED false "$OA" UNKNOWN pass
note d-a1 "status: working" "harness: claude" "pr: example/brain#51"
note d-a2 "status: working" "harness: claude"
pane brain-worker-d-a1 claude/busy; pane brain-worker-d-a2 claude/busy
SDRA="$TMP/sdra"
OUT="$(mon "$SDRA" --label pm d-a1)"
assert_contains "MERGED reported once" "#51 MERGED" "$OUT"
assert_eq "PR state kept per label" "yes" "$([ -f "$SDRA/pm.prs.state" ] && echo yes || echo no)"
OUT="$(NOW=$((T0 + 60)) mon "$SDRA" --label pm d-a1 d-a2)"
assert_eq "re-armed with another slug set → silent (no CAPS re-emit)" "" "$OUT"
OUT="$(NOW=$((T0 + 120)) mon "$SDRA" --once --label pm d-a2 d-a1)"
assert_contains "--once after the slug-set change → lowercase merged" "#51 merged @aaaaaaa" "$OUT"
# gh error text that varies between polls → one monitor-error
ghreset
ghpr 61 OPEN false "$OA" MERGEABLE pass
for k in 0 1 2; do printf 'API rate limit exceeded; resets at 2026-10-19T13:0%s:00Z (%s remaining)\n' "$k" "$((k * 7))" >"$GFX/61.$k.fail"; done
OUT="$(POLLS=3 mon "$TMP/sdrl" --pr example/brain#61)"
assert_eq "varying digits in the gh error → one monitor-error over 3 polls" "1" "$(printf '%s\n' "$OUT" | grep -c ' monitor-error ')"
assert_contains "…printed verbatim" "monitor-error gh example/brain#61: API rate limit exceeded; resets at 2026-10-19T13:00:00Z (0 remaining)" "$OUT"

echo "PR state per label is merged, never clobbered:"
# (continues SDRA: label pm already reported #51 MERGED)
PSUM="$(cksum <"$SDRA/pm.prs.state")"
OUT="$(NOW=$((T0 + 180)) POLLS=2 mon "$SDRA" --label pm d-a2)"
assert_eq "a monitor naming no PR, same label → silent" "" "$OUT"
assert_eq "…and leaves the label's PR state file intact" "$PSUM" "$(cksum <"$SDRA/pm.prs.state")"
ghreset
OUT="$(NOW=$((T0 + 240)) mon "$SDRA" --label pm --pr example/brain#51 d-a2)"
assert_eq "a collected worker's merged PR re-added via --pr → silent" "" "$OUT"
assert_eq "…and not re-queried" "0" "$(ghcalls 51)"
ghpr 71 OPEN false "$OA" MERGEABLE pass; ghpr 72 OPEN false "$OA" MERGEABLE pending
SDSH="$TMP/sdshare"
mon "$SDSH" --label shared --pr example/brain#71 >/dev/null
mon "$SDSH" --label shared --pr example/brain#72 >/dev/null
assert_eq "two monitors on one label: both PRs' records kept" "2" \
    "$(grep -o 'github:example/brain#7[12]' "$SDSH/shared.prs.state" | sort -u | wc -l | tr -d ' ')"
OUT="$(NOW=$((T0 + 60)) mon "$SDSH" --label shared --pr example/brain#71)"
assert_eq "…monitor A re-armed after B wrote → silent" "" "$OUT"
OUT="$(NOW=$((T0 + 60)) mon "$SDSH" --label shared --pr example/brain#72)"
assert_eq "…monitor B too" "" "$OUT"
assert_eq "no lock left behind" "no" "$([ -e "$SDSH/shared.prs.state.lock" ] && echo yes || echo no)"
mkdir "$SDSH/shared.prs.state.lock"; stamp "$SDSH/shared.prs.state.lock" $(( $(date +%s) - 600 ))
ghpr 72 OPEN false "$OA" MERGEABLE pass
OUT="$(NOW=$((T0 + 120)) mon "$SDSH" --label shared --pr example/brain#72)"
assert_contains "with a stale lock present" "#72 GREEN" "$OUT"
OUT="$(NOW=$((T0 + 180)) mon "$SDSH" --label shared --pr example/brain#72)"
assert_eq "…the stale lock is recovered and state saved (next run silent)" "" "$OUT"
# bounded: a PR not seen for longer than the TTL (30 days) is dropped from the file
mon "$SDSH" --label shared --pr example/brain#72 >/dev/null   # NOW=T0 + 31 days below
OUT="$(NOW=$((T0 + 31 * 86400)) mon "$SDSH" --label shared --pr example/brain#72)"
assert_eq "PR unseen for 31 days → its record dropped" "0" "$(grep -c 'github:example/brain#71' "$SDSH/shared.prs.state")"
assert_eq "…the one still watched is kept" "yes" "$(grep -q 'github:example/brain#72' "$SDSH/shared.prs.state" && echo yes || echo no)"

echo "PR state: a monitor that STOPPED naming a PR never overwrites another monitor's record of it:"
# Monitor A (2 polls) names #81 and #82, then (between its polls) its note drops #81.
# Monitor B, same label, watches #81 and reports it GREEN between A's polls. A's later
# save must not write its stale #81 back, or B's re-arm re-announces #81 in capitals.
ghreset
SDM="$TMP/sdm1"
ghpr 81 OPEN false "$OA" MERGEABLE pending 0; ghpr 81 OPEN false "$OA" MERGEABLE pass
ghpr 82 OPEN false "$OA" MERGEABLE pass
note d-m1 "status: working" "harness: claude" "pr: example/brain#81 example/brain#82"
pane brain-worker-d-m1 claude/busy
printf '#!/usr/bin/env bash\nprintf -- "---\\nslug: d-m1\\nstatus: working\\nharness: claude\\npr: example/brain#82\\n---\\n" >"%s"\n' \
    "$V/workers/d-m1.md" >"$GFX/hook.82.0"
printf '#!/usr/bin/env bash\nHOME="%s" MONITOR_NOW=%s MONITOR_MAX_POLLS=1 bash "%s" --vault "%s" --state-dir "%s" --interval 0 --label m1 --pr example/brain#81 >"%s" 2>&1\n' \
    "$LH" $((T0 + 30)) "$MON" "$V" "$SDM" "$TMP/m1-b.out" >"$GFX/hook.82.1"
chmod +x "$GFX/hook.82.0" "$GFX/hook.82.1"
POLLS=2 mon "$SDM" --label m1 d-m1 >/dev/null
assert_contains "B reported #81 GREEN between A's polls" "#81 GREEN" "$(cat "$TMP/m1-b.out")"
OUT="$(NOW=$((T0 + 120)) mon "$SDM" --label m1 --pr example/brain#81)"
assert_eq "B re-armed after A's later save → silent" "" "$OUT"

echo
printf 'worker-monitor: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
