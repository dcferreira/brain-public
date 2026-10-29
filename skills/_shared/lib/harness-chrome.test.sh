#!/usr/bin/env bash
#
# Tests for harness-chrome.sh — the harness axis (omp | claude): what a pane looks
# like and what command launches it. Every assertion runs against the captured
# fixtures in fixtures/<harness>/*.txt (see fixtures/README.md); nothing here invents
# chrome strings, and no harness is ever launched.
#
# Truth table asserted per harness (rc 0 = true):
#            ready  busy  question  trust  idle
#   ready     0      1      1        1      0
#   busy      1      0      1        1      1
#   question  1      1      0        1      1
#   trust     1      1      1        0*     1     (*claude only; omp has no trust.txt)
#   launch-typed: ready rc 1 (false-ready guard) and contains launch_marker

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIX="$HERE/fixtures"

# shellcheck source=harness-chrome.sh
source "$HERE/harness-chrome.sh"

PASS=0 FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
assert_true()  { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
assert_false() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$d"; else ok "$d"; fi; }
assert_eq()    { local d="$1" want="$2" got="$3"; if [ "$want" = "$got" ]; then ok "$d"; else bad "$d (want '$want' got '$got')"; fi; }
assert_contains() { local d="$1" needle="$2" haystack="$3"; case "$haystack" in *"$needle"*) ok "$d" ;; *) bad "$d (missing '$needle')" ;; esac; }

fixture() { cat "$FIX/$1/$2.txt"; }

# state_row <harness> <fixture> <ready> <busy> <question> <trust> <idle>
# Each expectation is the expected rc (0 = the predicate holds, 1 = it does not).
state_row() {
    local h="$1" f="$2" e_ready="$3" e_busy="$4" e_question="$5" e_trust="$6" e_idle="$7"
    local pane rc
    pane="$(fixture "$h" "$f")"
    local fn exp
    for fn in pane_ready:$e_ready pane_busy:$e_busy pane_question:$e_question \
              pane_trust_prompt:$e_trust pane_idle:$e_idle; do
        exp="${fn##*:}"
        fn="${fn%%:*}"
        rc=0
        "$fn" "$h" "$pane" >/dev/null 2>&1 || rc=$?
        [ "$rc" -ne 0 ] && rc=1
        assert_eq "$h/$f.txt: $fn → rc $exp" "$exp" "$rc"
    done
}

echo "valid_harness:"
assert_true  "valid_harness omp → rc 0"    valid_harness omp
assert_true  "valid_harness claude → rc 0" valid_harness claude
assert_false "valid_harness foo → rc 1"    valid_harness foo
assert_false "valid_harness '' → rc 1"     valid_harness ""

echo "launch_cmd / launch_marker:"
assert_eq "launch_cmd omp" \
    'omp --auto-approve "Read your worker brief at ~/w/x.md and follow its priming, then greet me."' \
    "$(launch_cmd omp '~/w/x.md')"
assert_eq "launch_cmd claude" \
    'claude "Read your worker brief at ~/w/x.md and follow its priming, then greet me."' \
    "$(launch_cmd claude '~/w/x.md')"
assert_eq "launch_marker omp"    'omp --auto-approve "Read your worker brief' "$(launch_marker omp)"
assert_eq "launch_marker claude" 'claude "Read your worker brief'              "$(launch_marker claude)"
assert_false "launch_cmd foo → rc 1"    launch_cmd foo /tmp/x.md
assert_false "launch_marker foo → rc 1" launch_marker foo
# The marker must survive the pane's wrap: it appears in the captured typed line.
assert_contains "omp/launch-typed.txt contains launch_marker omp" \
    "$(launch_marker omp)"    "$(fixture omp launch-typed)"
assert_contains "claude/launch-typed.txt contains launch_marker claude" \
    "$(launch_marker claude)" "$(fixture claude launch-typed)"
# The launch line scrolls above the trust dialog, so it identifies the launch, not the state.
assert_contains "claude/trust.txt still contains launch_marker claude" \
    "$(launch_marker claude)" "$(fixture claude trust)"

echo "launch_cmd / launch_marker with --model:"
assert_eq "launch_cmd omp with a model" \
    'omp --model claude-opus-5 --auto-approve "Read your worker brief at ~/w/x.md and follow its priming, then greet me."' \
    "$(launch_cmd omp '~/w/x.md' claude-opus-5)"
assert_eq "launch_cmd claude with a model" \
    'claude --model claude-opus-5 "Read your worker brief at ~/w/x.md and follow its priming, then greet me."' \
    "$(launch_cmd claude '~/w/x.md' claude-opus-5)"
assert_eq "launch_cmd omp with an empty model → unchanged" \
    'omp --auto-approve "Read your worker brief at ~/w/x.md and follow its priming, then greet me."' \
    "$(launch_cmd omp '~/w/x.md' '')"
assert_eq "launch_cmd claude with an empty model → unchanged" \
    'claude "Read your worker brief at ~/w/x.md and follow its priming, then greet me."' \
    "$(launch_cmd claude '~/w/x.md' '')"
assert_eq "launch_marker omp with a model" \
    'omp --model claude-opus-5 --auto-approve "Read your worker brief' \
    "$(launch_marker omp claude-opus-5)"
assert_eq "launch_marker claude with a model" \
    'claude --model claude-opus-5 "Read your worker brief' \
    "$(launch_marker claude claude-opus-5)"
assert_eq "launch_marker omp with an empty model → unchanged" \
    'omp --auto-approve "Read your worker brief' \
    "$(launch_marker omp '')"
assert_eq "launch_marker claude with an empty model → unchanged" \
    'claude "Read your worker brief' \
    "$(launch_marker claude '')"

SID0='0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d'
echo "bracketed model ids are single-quoted (zsh would glob a bare [1m]):"
assert_eq "resume_cmd claude, bracketed model" \
    "claude --model 'claude-opus-5-5[1m]' --resume $SID0" \
    "$(resume_cmd claude "$SID0" 'claude-opus-5-5[1m]')"
assert_eq "resume_marker claude, bracketed model" \
    "claude --model 'claude-opus-5-5[1m]' --resume" \
    "$(resume_marker claude 'claude-opus-5-5[1m]')"
assert_eq "launch_cmd claude, bracketed model" \
    "claude --model 'claude-opus-5-5[1m]' \"Read your worker brief at ~/w/x.md and follow its priming, then greet me.\"" \
    "$(launch_cmd claude '~/w/x.md' 'claude-opus-5-5[1m]')"
assert_eq "launch_marker claude, bracketed model" \
    "claude --model 'claude-opus-5-5[1m]' \"Read your worker brief" \
    "$(launch_marker claude 'claude-opus-5-5[1m]')"

echo "launch_cmd / launch_marker with a pinned session id:"
SID='0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d'
assert_eq "launch_cmd claude with a session id" \
    "claude --session-id $SID \"Read your worker brief at ~/w/x.md and follow its priming, then greet me.\"" \
    "$(launch_cmd claude '~/w/x.md' '' "$SID")"
assert_eq "launch_cmd claude with a model AND a session id (model first)" \
    "claude --model claude-opus-5 --session-id $SID \"Read your worker brief at ~/w/x.md and follow its priming, then greet me.\"" \
    "$(launch_cmd claude '~/w/x.md' claude-opus-5 "$SID")"
# omp cannot pin an id at launch: the arg is ignored and the line is byte-identical.
assert_eq "launch_cmd omp ignores a session id" \
    'omp --auto-approve "Read your worker brief at ~/w/x.md and follow its priming, then greet me."' \
    "$(launch_cmd omp '~/w/x.md' '' "$SID")"
assert_eq "launch_cmd claude with an empty session id → unchanged" \
    'claude "Read your worker brief at ~/w/x.md and follow its priming, then greet me."' \
    "$(launch_cmd claude '~/w/x.md' '' '')"
assert_eq "launch_marker claude with a session id" \
    'claude --session-id' "$(launch_marker claude '' "$SID")"
assert_eq "launch_marker claude with a model AND a session id" \
    'claude --model claude-opus-5 --session-id' "$(launch_marker claude claude-opus-5 "$SID")"
assert_eq "launch_marker omp ignores a session id" \
    'omp --auto-approve "Read your worker brief' "$(launch_marker omp '' "$SID")"
# The marker is a PREFIX of the typed line — it is what proves no leading chars were eaten.
case "$(launch_cmd claude '~/w/x.md' claude-opus-5 "$SID")" in
    "$(launch_marker claude claude-opus-5 "$SID")"*) ok  "claude session-id marker is a prefix of its launch_cmd" ;;
    *)                                              bad "claude session-id marker is a prefix of its launch_cmd" ;;
esac

echo "launch_cmd / launch_marker with a Remote Control name:"
SENT='"Read your worker brief at ~/w/x.md and follow its priming, then greet me."'
assert_eq "launch_cmd claude with a session id AND an rc name" \
    "claude --remote-control fake-slug --session-id $SID $SENT" \
    "$(launch_cmd claude '~/w/x.md' '' "$SID" fake-slug)"
assert_eq "launch_cmd claude with model, session id AND rc name (model, rc, id, brief)" \
    "claude --model claude-opus-5 --remote-control fake-slug --session-id $SID $SENT" \
    "$(launch_cmd claude '~/w/x.md' claude-opus-5 "$SID" fake-slug)"
assert_eq "launch_cmd omp ignores an rc name (no Remote Control)" \
    "omp --auto-approve $SENT" "$(launch_cmd omp '~/w/x.md' '' '' fake-slug)"
assert_eq "launch_cmd claude with an empty rc name → unchanged" \
    "claude --session-id $SID $SENT" "$(launch_cmd claude '~/w/x.md' '' "$SID" '')"
# `--remote-control [name]` takes an OPTIONAL value: a bare flag before the brief would
# swallow the brief as the name. An unsafe name is refused rather than typed into a shell.
assert_false "launch_cmd claude rc name starting with '-' → rc 1" launch_cmd claude '~/w/x.md' '' "$SID" -x
assert_false "launch_cmd claude rc name with a space → rc 1"      launch_cmd claude '~/w/x.md' '' "$SID" 'a b'
assert_false "launch_cmd claude rc name with ';' → rc 1"          launch_cmd claude '~/w/x.md' '' "$SID" 'a;b'
RCL="$(launch_cmd claude '~/w/x.md' claude-opus-5 "$SID" fake-slug)"
case "$RCL" in
    *"--remote-control fake-slug --session-id "*) ok  "--remote-control <slug> sits right before --session-id" ;;
    *)                                            bad "--remote-control <slug> sits right before --session-id ($RCL)" ;;
esac
case "$RCL" in
    *"--remote-control \"Read"*|*"--remote-control fake-slug \"Read"*) bad "--remote-control is directly followed by the brief ($RCL)" ;;
    *) ok "--remote-control is never directly followed by the brief" ;;
esac
assert_eq "launch_marker claude with an rc name stops at --remote-control" \
    'claude --remote-control' "$(launch_marker claude '' "$SID" fake-slug)"
assert_eq "launch_marker claude with model + rc name" \
    'claude --model claude-opus-5 --remote-control' "$(launch_marker claude claude-opus-5 "$SID" fake-slug)"
assert_eq "launch_marker omp ignores an rc name" \
    'omp --auto-approve "Read your worker brief' "$(launch_marker omp '' '' fake-slug)"
case "$RCL" in
    "$(launch_marker claude claude-opus-5 "$SID" fake-slug)"*) ok  "claude rc marker is a prefix of its launch_cmd" ;;
    *)                                                        bad "claude rc marker is a prefix of its launch_cmd" ;;
esac

echo "resume_cmd / resume_marker:"
assert_eq "resume_cmd claude" "claude --resume $SID" "$(resume_cmd claude "$SID")"
assert_eq "resume_cmd claude with a model" \
    "claude --model claude-opus-5 --resume $SID" "$(resume_cmd claude "$SID" claude-opus-5)"
assert_eq "resume_cmd omp" \
    'omp --auto-approve --resume 01a0a4dc' "$(resume_cmd omp 01a0a4dc)"
assert_eq "resume_cmd omp with a model" \
    'omp --model claude-opus-5 --auto-approve --resume 01a0a4dc' "$(resume_cmd omp 01a0a4dc claude-opus-5)"
assert_eq "resume_cmd claude with an empty model → no --model" \
    "claude --resume $SID" "$(resume_cmd claude "$SID" '')"
assert_false "resume_cmd with no id → rc 1" resume_cmd claude ''
assert_false "resume_cmd foo → rc 1"        resume_cmd foo "$SID"
assert_eq "resume_marker claude"            'claude --resume' "$(resume_marker claude)"
assert_eq "resume_marker claude with model" 'claude --model claude-opus-5 --resume' "$(resume_marker claude claude-opus-5)"
assert_eq "resume_marker omp"               'omp --auto-approve --resume' "$(resume_marker omp)"
assert_eq "resume_marker omp with model"    'omp --model claude-opus-5 --auto-approve --resume' "$(resume_marker omp claude-opus-5)"
assert_false "resume_marker foo → rc 1"     resume_marker foo
for H in omp claude; do
    case "$(resume_cmd "$H" "$SID" claude-opus-5)" in
        "$(resume_marker "$H" claude-opus-5)"*) ok  "$H resume_marker is a prefix of its resume_cmd" ;;
        *)                                      bad "$H resume_marker is a prefix of its resume_cmd" ;;
    esac
done
assert_eq "resume_cmd claude with an rc name → --remote-control before --resume" \
    "claude --remote-control fake-slug --resume $SID" "$(resume_cmd claude "$SID" '' fake-slug)"
assert_eq "resume_cmd claude with model + rc name" \
    "claude --model claude-opus-5 --remote-control fake-slug --resume $SID" "$(resume_cmd claude "$SID" claude-opus-5 fake-slug)"
assert_eq "resume_cmd omp ignores an rc name" \
    'omp --auto-approve --resume 01a0a4dc' "$(resume_cmd omp 01a0a4dc '' fake-slug)"
assert_false "resume_cmd claude unsafe rc name → rc 1" resume_cmd claude "$SID" '' '-x'
assert_eq "resume_marker claude with an rc name" 'claude --remote-control' "$(resume_marker claude '' fake-slug)"
assert_eq "resume_marker claude with model + rc name" \
    'claude --model claude-opus-5 --remote-control' "$(resume_marker claude claude-opus-5 fake-slug)"
assert_eq "resume_marker omp ignores an rc name" 'omp --auto-approve --resume' "$(resume_marker omp '' fake-slug)"
case "$(resume_cmd claude "$SID" claude-opus-5 fake-slug)" in
    "$(resume_marker claude claude-opus-5 fake-slug)"*) ok  "claude rc resume_marker is a prefix of its resume_cmd" ;;
    *)                                                 bad "claude rc resume_marker is a prefix of its resume_cmd" ;;
esac
# A resume line never carries the brief sentence: revival must never prime a fresh session.
assert_false "resume_cmd claude never contains the brief sentence" \
    grep -q 'Read your worker brief' <<<"$(resume_cmd claude "$SID")"
assert_false "resume_cmd omp never contains the brief sentence" \
    grep -q 'Read your worker brief' <<<"$(resume_cmd omp 01a0a4dc)"

echo "valid_session_id:"
assert_true  "claude: lowercase UUID"            valid_session_id claude "$SID"
assert_true  "claude: uppercase UUID"            valid_session_id claude '0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D'
assert_false "claude: omp-style prefix rejected" valid_session_id claude 01a0a4dc
assert_false "claude: UUID + trailing junk"      valid_session_id claude "$SID; rm -rf ~"
assert_false "claude: empty"                     valid_session_id claude ''
assert_true  "omp: id prefix"                    valid_session_id omp 01a0a4dc
assert_true  "omp: full id"                      valid_session_id omp 01a0a4dc-5a6c-70da-bde2-a62afe728802
assert_true  "omp: ~ path"                       valid_session_id omp '~/.omp/agent/sessions/-projects-brain/2026-09-15T11-38-19-628Z_01a0a4dc.jsonl'
assert_false "omp: space rejected"               valid_session_id omp '01a0 a4dc'
assert_false "omp: ; rejected"                   valid_session_id omp '01a0;a4dc'
assert_false "omp: \$ rejected"                  valid_session_id omp '$(id)'
assert_false "omp: empty"                        valid_session_id omp ''
assert_false "omp: embedded newline rejected"    valid_session_id omp $'01a0a4dc\nrm -rf ~'
assert_false "claude: embedded newline rejected" valid_session_id claude "$SID"$'\nrm -rf ~'
assert_false "foo harness"                       valid_session_id foo "$SID"

echo "persist_worker_text:"
assert_eq "persist_worker_text omp"    "/skill:brain-persist worker" "$(persist_worker_text omp)"
assert_eq "persist_worker_text claude" "/brain-persist worker"       "$(persist_worker_text claude)"
assert_false "persist_worker_text foo → rc 1" persist_worker_text foo

echo "rc_connect_text:"
# claude is named at launch (`--remote-control <slug>`), so there is no line to type: rc 0
# (the harness HAS Remote Control) with empty output. A typed `/rc` on an already-connected
# session only opens the "already connected" dialog.
assert_true  "rc_connect_text claude → rc 0 (has Remote Control)" rc_connect_text claude fake-slug
assert_eq    "rc_connect_text claude prints nothing (named at launch)" "" "$(rc_connect_text claude fake-slug)"
assert_false "rc_connect_text omp → rc 1 (omp has no Remote Control)" rc_connect_text omp fake-slug
assert_eq "rc_connect_text omp prints nothing" "" "$(rc_connect_text omp fake-slug 2>/dev/null || true)"
assert_false "rc_connect_text foo → rc 1" rc_connect_text foo fake-slug

echo "pane_rc_connected:"
# There is no connected-state fixture: a live Remote Control session could not be captured
# into fixtures/claude/ (see fixtures/README.md), so the POSITIVE path is asserted against
# these inline sample lines, taken from the chrome the original `/rc` sanity check grepped
# for (`remote control|claude.ai/code`, case-insensitive). The NEGATIVE path uses the real
# fixtures, none of which contains either string.
RC_SAMPLE_SESSION='  Remote Control session: fake-slug'
RC_SAMPLE_URL='  Steer this session at https://claude.ai/code'
assert_true  "claude: 'Remote Control session:' line → rc 0" pane_rc_connected claude "$RC_SAMPLE_SESSION"
assert_true  "claude: claude.ai/code line → rc 0"            pane_rc_connected claude "$RC_SAMPLE_URL"
assert_true  "claude: match is case-insensitive"             pane_rc_connected claude "  remote control: on"
assert_false "claude/ready.txt → rc 1 (not connected)"       pane_rc_connected claude "$(fixture claude ready)"
assert_false "claude/launch-typed.txt → rc 1"                pane_rc_connected claude "$(fixture claude launch-typed)"
assert_false "claude '' → rc 1"                              pane_rc_connected claude ""
assert_false "omp is never connected (sample line)"          pane_rc_connected omp "$RC_SAMPLE_SESSION"
assert_false "omp/ready.txt → rc 1"                          pane_rc_connected omp "$(fixture omp ready)"
assert_false "pane_rc_connected foo → rc 1"                  pane_rc_connected foo "$RC_SAMPLE_SESSION"
# The live connected banner (Claude Code 2.1.303, seen above the dialog in
# rc-already-connected.txt) counts once the dialog is gone.
RC_DLG="$(fixture claude rc-already-connected)"
RC_BANNER="$(sed -n '/remote-control is active/,/claude\.ai\/code/p' <<<"$RC_DLG")"$'\n'"$(fixture claude ready)"
assert_true  "claude: '/remote-control is active' banner + composer → rc 0" pane_rc_connected claude "$RC_BANNER"
assert_true  "claude: the banner line alone (URL wrapped off) → rc 0" \
    pane_rc_connected claude "  /remote-control is active · Continue here, on your phone, or at"
assert_false "claude: a typed '--remote-control <slug>' launch line is not a connection" \
    pane_rc_connected claude "$(fixture claude launch-typed)"$'\n''~/p $ claude --remote-control x --session-id y "Read'
# The "already connected" dialog alone must not read as a fresh named connect.
assert_false "claude/rc-already-connected.txt → rc 1 (dialog, not a fresh connect)" pane_rc_connected claude "$RC_DLG"

echo "pane_rc_dialog (Remote Control 'already connected' dialog):"
assert_true  "claude/rc-already-connected.txt → rc 0" pane_rc_dialog claude "$RC_DLG"
ESC=$'\033'
assert_true  "claude/rc-already-connected.txt styled → rc 0" \
    pane_rc_dialog claude "$(sed "s/^/${ESC}[39m/; s/\$/${ESC}[0m/" <<<"$RC_DLG")"
for F in "$FIX"/claude/*.txt; do
    F="$(basename "$F" .txt)"
    [ "$F" = rc-already-connected ] && continue
    assert_false "claude/$F.txt → rc 1" pane_rc_dialog claude "$(fixture claude "$F")"
done
for F in "$FIX"/omp/*.txt; do
    F="$(basename "$F" .txt)"
    assert_false "omp/$F.txt → rc 1" pane_rc_dialog omp "$(fixture omp "$F")"
done
# both strings are required: either one alone (e.g. prose quoting it) is not the dialog
assert_false "only 'Disconnect this session' → rc 1" pane_rc_dialog claude "     Disconnect this session"
assert_false "only 'Esc to continue' → rc 1"         pane_rc_dialog claude "   Enter to select · Esc to continue"
# Anchored on the dialog's shape at the BOTTOM of the screen, never on the strings
# anywhere: a worker whose own output prints the dialog (developing this feature, `cat`ing
# the fixture) must not read as blocked — an Escape there would interrupt a busy turn.
assert_false "claude/busy-rc-dialog-text.txt (dialog text mid-scroll, composer below) → rc 1" \
    pane_rc_dialog claude "$(fixture claude busy-rc-dialog-text)"
state_row  claude  busy-rc-dialog-text  1     0    1        1     1
assert_false "dialog text followed by a ready composer → rc 1" \
    pane_rc_dialog claude "$RC_DLG"$'\n'"$(fixture claude ready)"
assert_false "dialog text followed by a shell prompt (cat in a shell) → rc 1" \
    pane_rc_dialog claude "$RC_DLG"$'\n''~/p $ '
assert_true  "the dialog with trailing blank rows → rc 0" pane_rc_dialog claude "$RC_DLG"$'\n\n\n   \n'
assert_true  "the dialog with the highlight on Disconnect → rc 0" \
    pane_rc_dialog claude "$(sed 's/^     Disconnect this session$/   ❯ Disconnect this session/; s/^   ❯ Continue$/     Continue/' <<<"$RC_DLG")"
assert_false "footer at the bottom but no Continue option → rc 1" \
    pane_rc_dialog claude "$(grep -v 'Continue$' <<<"$RC_DLG")"
assert_false "footer at the bottom, options far above (>12 non-blank lines) → rc 1" \
    pane_rc_dialog claude "$(awk '{print} /Show QR code/ {for (i = 1; i <= 12; i++) print "  filler " i}' <<<"$RC_DLG")"
assert_false "omp never (dialog text) → rc 1"        pane_rc_dialog omp "$RC_DLG"
assert_false "pane_rc_dialog foo → rc 1"             pane_rc_dialog foo "$RC_DLG"
# it is an open question: not ready, not idle, not up; brain-monitor gets a one-liner
state_row  claude  rc-already-connected  1     1    0        1     1
assert_false "claude/rc-already-connected.txt → harness not up (dialog)" pane_harness_up claude "$RC_DLG"
assert_eq    "pane_question_text on the dialog" "Remote Control: already connected [Continue]" \
    "$(pane_question_text claude "$RC_DLG")"

echo "omp truth table:"
#          harness fixture       ready busy question trust idle
state_row  omp     ready         0     1    1        1     0
state_row  omp     busy          1     0    1        1     1
state_row  omp     question      1     1    0        1     1
state_row  omp     launch-typed  1     1    1        1     1

echo "claude truth table:"
state_row  claude  ready         0     1    1        1     0
state_row  claude  busy          1     0    1        1     1
state_row  claude  question      1     1    0        1     1
state_row  claude  trust         1     1    1        0     1
state_row  claude  launch-typed  1     1    1        1     1

echo "pane_harness_up (dispatch's launch verify: ready OR busy, never the shell):"
# A launch primes the worker with its brief as the positional prompt, so the first turn
# may already be streaming by the time dispatch looks: busy must count as "launched".
for F in ready busy busy-thinking busy-thinking-styled busy-bg-agents busy-agent-notification-styled busy-bg-shell busy-bg-shell-styled ready-after-bg-shell-styled ready-ghost; do
    assert_true  "claude/$F.txt → harness up" pane_harness_up claude "$(fixture claude "$F")"
done
for F in launch-typed trust question busy-draft; do
    assert_false "claude/$F.txt → not up (shell / dialog / draft)" pane_harness_up claude "$(fixture claude "$F")"
done
# a shell pane that merely ECHOES a spinner-looking line is still a shell
assert_false "claude launch-typed + spinner text, no composer → not up" \
    pane_harness_up claude "$(fixture claude launch-typed)"$'\n''✢ Beaming… (2s · thinking)'
for F in ready busy; do
    assert_true  "omp/$F.txt → harness up" pane_harness_up omp "$(fixture omp "$F")"
done
for F in launch-typed question; do
    assert_false "omp/$F.txt → not up" pane_harness_up omp "$(fixture omp "$F")"
done
assert_false "pane_harness_up claude '' → rc 1" pane_harness_up claude ""
assert_false "pane_harness_up foo → rc 1"       pane_harness_up foo "$(fixture claude ready)"

echo "pane_capture_flags:"
assert_eq   "pane_capture_flags omp is empty"    "" "$(pane_capture_flags omp)"
assert_eq   "pane_capture_flags claude is -e"    "-e" "$(pane_capture_flags claude)"
assert_false "pane_capture_flags foo → rc 1"     pane_capture_flags foo

echo "claude composer ghost-vs-draft (styled captures):"
# A styled (-e) capture with a dim/faint autosuggestion ghost in the composer must read as
# fully idle — the ghost was never actually typed. See fixtures/README.md for provenance.
state_row  claude  ready-ghost   0     1    1        1     0
# The same styling, minus the dim wrapper, is a REAL unsent draft — must NOT read as idle
# (not-ready because the composer holds real text; not "busy" — no tool/turn is running).
state_row  claude  busy-draft    1     1    1        1     1

echo "claude background agents still running (composer empty, turn ended):"
# A worker that ended its turn while background subagents run shows a bare composer, yet
# is working: the agent's completion notification will wake it. Must read busy, never idle
# (monitor NUDGE false positive; collect's idle gate must not tear it down). Real captures,
# plain and styled — see fixtures/README.md.
state_row  claude  busy-bg-agents         1     0    1        1     1
state_row  claude  busy-bg-agents-styled  1     0    1        1     1
# One 15 s poll after the agent finished: the agent panel is gone, but claude is already
# HANDLING the agent's notification — `✢ Beaming… (2s · thinking)` above the composer, a
# spinner with no token count yet. That is busy, not idle (reviewer finding: this capture
# was first mislabelled `ready-after-bg-agents`).
state_row  claude  busy-agent-notification         1     0    1        1     1
state_row  claude  busy-agent-notification-styled  1     0    1        1     1
# The same capture with that spinner and its `⎿  Tip:` line cut out is what remains once
# the notification turn ends: no panel, claude-hud still showing a stale `◐`, the
# `/tasks to see subagents` hint → idle. Built from the real capture (no true capture of
# this exact moment exists); every remaining line is verbatim.
AFTER_BG="$(fixture claude busy-agent-notification | sed '/Beaming… (2s/,/Tip: Connect Claude/d')"
AFTER_BG_STYLED="$(fixture claude busy-agent-notification-styled | sed '/Beaming/,/Tip: Connect Claude/d')"
assert_true  "busy-agent-notification minus its spinner → idle"          pane_idle claude "$AFTER_BG"
assert_true  "busy-agent-notification-styled minus its spinner → idle"   pane_idle claude "$AFTER_BG_STYLED"
assert_false "busy-agent-notification minus its spinner → not busy"      pane_busy claude "$AFTER_BG"

echo "claude background shell still running (composer empty, turn ended):"
# A worker that ended its turn with a run_in_background shell still running (e.g. a CI
# watch) shows a bare composer, yet is working: claude re-invokes itself when the shell
# exits. The footer carries a `· 1 shell ·` segment while it runs. Real captures, plain
# and styled — see fixtures/README.md.
state_row  claude  busy-bg-shell         1     0    1        1     1
state_row  claude  busy-bg-shell-styled  1     0    1        1     1
# The same pane two 20 s polls after the shell exited (claude was woken, handled it, and
# ended its turn): footer back to `(shift+tab to cycle)` → idle. Real capture.
state_row  claude  ready-after-bg-shell         0     1    1        1     0
state_row  claude  ready-after-bg-shell-styled  0     1    1        1     0
# Not signals on their own: the `· 1 shell still running` suffix on the done line (only
# the footer is matched; built from the real capture by swapping just the footer line)
# and the `Ran 2 shell commands` summaries.
NO_FOOTER_SHELL="$(fixture claude busy-bg-shell | sed 's/^  ⏵⏵ auto mode on · 1 shell · ← for agents$/  ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents/')"
assert_true  "busy-bg-shell with a shell-less footer → idle (done-line text is not a signal)" \
    pane_idle claude "$NO_FOOTER_SHELL"
assert_false "busy-bg-shell with a shell-less footer → not busy" pane_busy claude "$NO_FOOTER_SHELL"
# Plural form — [inferred], never observed live.
assert_true  "footer '· 2 shells ·' → busy (inferred plural)" \
    pane_busy claude "$NO_FOOTER_SHELL"$'\n''  ⏵⏵ auto mode on · 2 shells · ← for agents'
assert_false "prose 'Ran 2 shell commands' → not busy" \
    pane_busy claude "$(fixture claude ready)"$'\n''  Ran 2 shell commands'

echo "claude spinner forms seen live (k counts, minutes, trailing segment, -e styling):"
# `(1m 0s · ↓ 4.2k tokens · thought for 1s)`; the styled copy splits the suffix with SGR.
state_row  claude  busy-thinking          1     0    1        1     1
state_row  claude  busy-thinking-styled   1     0    1        1     1
for L in '✻ Pouncing… (39s · ↓ 3.6k tokens)' '· Pouncing… (30s · ↓ 1.6k tokens · thinking)' \
         '✻ Beaming… (17s · ↓ 846 tokens)'   '✽ Pouncing… (2m 0s · ↓ 8.3k tokens · thinking)'; do
    assert_true "spinner '$L' → busy" pane_busy claude "$(fixture claude ready)"$'\n'"$L"
done
# Verb-ellipsis spinner with NO token count yet (the first seconds of a turn), seen live in
# fixtures/claude/busy-agent-notification.txt.
assert_true "spinner '✢ Beaming… (2s · thinking)' (no tokens) → busy" \
    pane_busy claude "$(fixture claude ready)"$'\n''✢ Beaming… (2s · thinking)'
assert_false "prose mentioning '(2s · thinking)' mid-line → not busy" \
    pane_busy claude "$(fixture claude ready)"$'\n''● The spinner said Beaming… (2s · thinking) earlier.'
assert_false "finished turn '✻ Crunched for 13m 4s · done 12:42' → not busy" \
    pane_busy claude "$(fixture claude ready)"$'\n''✻ Crunched for 13m 4s · done 12:42'
assert_false "'⎿  Backgrounded agent (↓ to manage · ctrl+o to expand)' → not busy" \
    pane_busy claude "$(fixture claude ready)"$'\n''  ⎿  Backgrounded agent (↓ to manage · ctrl+o to expand)'
assert_false "stale '✻ Waiting for 1 background agent to finish' → not busy" \
    pane_busy claude "$(fixture claude ready)"$'\n''✻ Waiting for 1 background agent to finish'
# The rows Claude Code's agent panel shows. RUNNING: `<elapsed> · ↓ <n> tokens` with no
# parentheses (the spinner's own suffix is parenthesised). Panel with no agents / only
# main: not busy. A footer `← for agents` hint alone (every idle pane on a recent build
# shows it) is never a busy signal.
BG_READY="$(fixture claude ready)"
assert_true  "panel row with a k-token count → busy" \
    pane_busy claude "$BG_READY"$'\n''  ◯ general-purpose  Rewriting mic.rs tests (red)                3m 6s · ↓ 75.5k tokens'
assert_true  "panel row with a plain token count → busy" \
    pane_busy claude "$BG_READY"$'\n''  ◯ general-purpose  Fixing lint                                 12s · ↓ 812 tokens'
assert_false "footer '← for agents' hint alone → not busy" \
    pane_busy claude "$BG_READY"$'\n''  ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents'
assert_true  "ready.txt + agents footer hint → still idle" \
    pane_idle claude "$BG_READY"$'\n''  ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents'
assert_false "a finished agent's notification line → not busy" \
    pane_busy claude "$BG_READY"$'\n''● Agent "Review Linux quiet probes diff" finished · 2m 41s'

echo "strip_dim_ghost:"
assert_eq  "strips a dim ghost span down to nothing" \
    "" "$(printf '\033[2mghost text\033[0m' | strip_dim_ghost)"
assert_eq  "leaves real (non-dim) content untouched" \
    "real text" "$(printf '\033[39mreal text' | strip_dim_ghost)"
assert_eq  "ready-ghost's composer line reduces to the bare composer line" \
    "$CLAUDE_COMPOSER_LINE" \
    "$(fixture claude ready-ghost | strip_dim_ghost | grep -xF "$CLAUDE_COMPOSER_LINE")"
assert_eq  "busy-draft's composer line does NOT reduce to the bare composer line" \
    "" "$(fixture claude busy-draft | strip_dim_ghost | grep -xF "$CLAUDE_COMPOSER_LINE")"

echo "pane_question_text:"
ESC=$'\033'
assert_eq "claude/question.txt → header: question [numbered options], free-text options dropped" \
    'Find brief: Should I look for the worker brief under a different name in the workers folder, such as the most recently edited one? [1 Yes / 2 No]' \
    "$(pane_question_text claude "$(fixture claude question)")"
assert_eq "omp/question.txt → box title: body [options numbered by position]" \
    'Allow tool: bash: Command: sleep 25 && echo SLEPT [1 Approve / 2 Deny]' \
    "$(pane_question_text omp "$(fixture omp question)")"
# A styled (-e) capture must give the same line: SGR codes are stripped first. The styled
# copy is built here (fixtures are never edited) by dimming the indented option
# descriptions and wrapping every line in colour codes, as a real `-e` capture would.
STYLED_Q="$(fixture claude question | sed "s/^     /${ESC}[2m     /" | sed "s/^/${ESC}[39m/; s/\$/${ESC}[0m/")"
assert_eq "claude/question.txt styled (-e) → same line" \
    'Find brief: Should I look for the worker brief under a different name in the workers folder, such as the most recently edited one? [1 Yes / 2 No]' \
    "$(pane_question_text claude "$STYLED_Q")"
STYLED_OQ="$(fixture omp question | sed "s/^/${ESC}[36m/; s/\$/${ESC}[0m/")"
assert_eq "omp/question.txt styled (-e) → same line" \
    'Allow tool: bash: Command: sleep 25 && echo SLEPT [1 Approve / 2 Deny]' \
    "$(pane_question_text omp "$STYLED_OQ")"
# Dialogs WITHOUT a lone `☐ <header>` line. Built from question.txt's own lines; the tab
# bar shape (`←  ☐ A  ☐ B  ✔ Submit  →`, multi-question AskUserQuestion) is
# REVIEWER-REPORTED, not captured — no fixture shows it.
Q_NOHDR='Should I look for the worker brief under a different name in the workers folder, such as the most recently edited one? [1 Yes / 2 No]'
assert_eq "claude question with a tab bar instead of a ☐ header → question [options]" \
    "$Q_NOHDR" \
    "$(pane_question_text claude "$(fixture claude question | sed 's/^ ☐ Find brief$/ ←  ☐ A  ☐ B  ✔ Submit  →/')")"
assert_eq "claude question with no header line at all → question [options]" \
    "$Q_NOHDR" \
    "$(pane_question_text claude "$(fixture claude question | sed '/^ ☐ Find brief$/d')")"
assert_eq "claude dialog with plain (no │) question lines → the lines before the options" \
    "$Q_NOHDR" \
    "$(pane_question_text claude "$(fixture claude question | sed '/^ ☐ Find brief$/d; s/^│ //')")"
# Permission-prompt-like dialog: question.txt's option shapes under a `Do you want to
# proceed?` line (the permission prompt itself was never captured — see pane_question).
PERM="$(fixture claude ready | sed "/^${CLAUDE_COMPOSER_LINE}\$/,\$d")"$'\n'' Do you want to proceed?'$'\n''❯ 1. Yes'$'\n''  2. No'
assert_true  "claude 'Do you want to proceed?' + numbered options → question" pane_question claude "$PERM"
assert_eq    "… and its text is the question + options" 'Do you want to proceed? [1 Yes / 2 No]' \
    "$(pane_question_text claude "$PERM")"
# The same words in assistant PROSE are not a dialog (sticky false ANSWER otherwise).
assert_false "prose '● Do you want to proceed?' on an idle pane → not a question" \
    pane_question claude "$(fixture claude ready | sed '1i\
● Do you want to proceed? I can also make this edit later.')"
assert_false "prose continuation '  Do you want to create it?' → not a question" \
    pane_question claude "  Do you want to create it?"$'\n'"$(fixture claude ready)"
for F in ready busy launch-typed trust ready-ghost busy-draft; do
    assert_false "claude/$F.txt → rc 1 (no question)" pane_question_text claude "$(fixture claude "$F")"
done
for F in ready busy launch-typed; do
    assert_false "omp/$F.txt → rc 1 (no question)" pane_question_text omp "$(fixture omp "$F")"
done
assert_false "claude '' → rc 1"              pane_question_text claude ""
assert_false "omp '' → rc 1"                 pane_question_text omp ""
assert_false "pane_question_text foo → rc 1" pane_question_text foo "$(fixture claude question)"

echo "pane_last_message:"
assert_eq "claude/ready.txt → first line of the last ● message" \
    "I couldn't find the brief, so I can't follow its priming yet." \
    "$(pane_last_message claude "$(fixture claude ready)")"
assert_eq "claude/question.txt → the LAST ● message, not an earlier one" \
    'The command ran and printed done after the 20 second sleep.' \
    "$(pane_last_message claude "$(fixture claude question)")"
assert_eq "claude/ready-ghost.txt (styled) → same as ready.txt" \
    "I couldn't find the brief, so I can't follow its priming yet." \
    "$(pane_last_message claude "$(fixture claude ready-ghost)")"
STYLED_R="$(fixture claude ready | sed "s/^/${ESC}[39m/; s/\$/${ESC}[0m/")"
assert_eq "claude/ready.txt styled (-e) → same line" \
    "I couldn't find the brief, so I can't follow its priming yet." \
    "$(pane_last_message claude "$STYLED_R")"
# OSC 8 hyperlinks: a `-e` capture keeps them (`ESC]8;id=<id>;<url>ESC\\<text>ESC]8;;ESC\\`,
# shape seen live in a budgebell worker's `I opened PR #11: <link>` reply and in the
# claude-hud statusline). The readers must print the link TEXT, never the escape bytes.
OSC_MSG="${ESC}[39m● I opened PR #11: ${ESC}]8;id=jvykft;https://github.com/x/y/pull/11${ESC}\\https://github.com/x/y/pull/11${ESC}]8;;${ESC}\\. CI is running."
assert_eq "OSC 8 hyperlink in a ● message → its text only" \
    'I opened PR #11: https://github.com/x/y/pull/11. CI is running.' \
    "$(pane_last_message claude "$OSC_MSG")"
assert_eq "strip_sgr drops an ESC-backslash-terminated OSC 8" 'a link b' \
    "$(printf 'a \033]8;;http://x\033\\link\033]8;;\033\\ b' | strip_sgr)"
assert_eq "strip_sgr drops a BEL-terminated OSC" 'a link b' \
    "$(printf 'a \033]8;;http://x\alink\033]8;;\a b' | strip_sgr)"
assert_eq "claude/busy-bg-agents.txt → last column-0 ● message, never the indented '  ● main' panel row" \
    'The review turned up two real issues, and a Sonnet subagent is fixing those plus three smaller ones now:' \
    "$(pane_last_message claude "$(fixture claude busy-bg-agents)")"
assert_eq "claude/busy-bg-agents-styled.txt → same line (bold '  ● main' row ignored)" \
    'The review turned up two real issues, and a Sonnet subagent is fixing those plus three smaller ones now:' \
    "$(pane_last_message claude "$(fixture claude busy-bg-agents-styled)")"
assert_false "panel rows alone ('  ● main') → rc 1" \
    pane_last_message claude $'  ● main\n  ◯ general-purpose  x    3m 6s · ↓ 75.5k tokens'
assert_false "claude/busy.txt → rc 1 (no ● line on screen)" pane_last_message claude "$(fixture claude busy)"
assert_false "claude/launch-typed.txt → rc 1"               pane_last_message claude "$(fixture claude launch-typed)"
assert_false "claude '' → rc 1"                             pane_last_message claude ""
# omp: no fixture shows an assistant message's chrome, so there is nothing to extract.
for F in ready busy question launch-typed; do
    assert_false "omp/$F.txt → rc 1 (no captured message chrome)" pane_last_message omp "$(fixture omp "$F")"
done
assert_false "pane_last_message foo → rc 1" pane_last_message foo "$(fixture claude ready)"

echo "unknown harness is never a state:"
assert_false "pane_ready foo → rc 1"        pane_ready foo "$(fixture claude ready)"
assert_false "pane_busy foo → rc 1"         pane_busy foo "$(fixture claude busy)"
assert_false "pane_question foo → rc 1"     pane_question foo "$(fixture claude question)"
assert_false "pane_trust_prompt foo → rc 1" pane_trust_prompt foo "$(fixture claude trust)"
assert_false "pane_idle foo → rc 1"         pane_idle foo "$(fixture claude ready)"

echo "empty pane is never ready/busy/question/trust:"
assert_false "pane_ready omp ''"           pane_ready omp ""
assert_false "pane_ready claude ''"        pane_ready claude ""
assert_false "pane_busy claude ''"         pane_busy claude ""
assert_false "pane_question claude ''"     pane_question claude ""
assert_false "pane_trust_prompt claude ''" pane_trust_prompt claude ""

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
