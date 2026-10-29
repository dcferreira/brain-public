#!/usr/bin/env bash
#
# Tests for the brain-revive-workers scripts — find-live-sessions.sh (runs ON a host,
# classifies each candidate worker's harness transcript as live-at-shutdown or not) and
# revive-workers.sh (the coordinator-side orchestrator that reads worker notes, asks each
# host which sessions were live, and — only with --apply — resumes them by id through
# launch-worker.sh --resume).
#
# Runs OFFLINE: fake HOME trees under a temp dir hold hand-built claude/omp transcripts
# (shaped like real ones: non-user entries before the first user entry, string AND array
# `message.content`, omp's `"type":"session"` line 2), mtimes are stamped relative to a
# fixed fake boot/shutdown passed as overrides, the vault is a temp dir, and tmux, ssh and
# the launcher are stubs that log their argv. No real tmux, ssh, harness or vault.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
FIND="$HERE/find-live-sessions.sh"
REVIVE="$HERE/revive-workers.sh"

PASS=0 FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
assert_eq()           { local d="$1" want="$2" got="$3"; if [ "$want" = "$got" ]; then ok "$d"; else bad "$d (want '$want' got '$got')"; fi; }
assert_contains()     { local d="$1" needle="$2" hay="$3"; case "$hay" in *"$needle"*) ok "$d" ;; *) bad "$d (missing '$needle' in '$hay')" ;; esac; }
assert_not_contains() { local d="$1" needle="$2" hay="$3"; case "$hay" in *"$needle"*) bad "$d (unexpected '$needle' in '$hay')" ;; *) ok "$d" ;; esac; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

TAB="$(printf '\t')"

# --- time axis ---------------------------------------------------------------------
SHUT=1790000000                # fake previous-boot end
BOOT=$((SHUT + 30000))         # fake current boot
T_LIVE=$((SHUT - 30))          # died with the machine
T_LIVE2=$((SHUT - 60))
T_ENDED=$((SHUT - 3600))       # ended an hour before shutdown
T_NEAR=$((SHUT - 300))         # 5 min before shutdown: outside the default 180 s window
T_TOUCHED=$((BOOT + 100))      # written after boot: already resumed / running

# stamp <file> <epoch> — portable mtime set (GNU `touch -d @N` is not on BSD; the
# `-t [[CC]YY]MMDDhhmm.SS` form is understood by both, fed a local-time string).
stamp() {
    local t
    t="$(date -d "@$2" +%Y%m%d%H%M.%S 2>/dev/null || date -r "$2" +%Y%m%d%H%M.%S)"
    touch -t "$t" "$1"
}
iso() { date -d "@$1" +%Y-%m-%dT%H:%M:%S%z 2>/dev/null || date -r "$1" +%Y-%m-%dT%H:%M:%S%z; }

sentence() { printf 'Read your worker brief at ~/Obsidian/vault/workers/%s.md and follow its priming, then greet me.' "$1"; }

# claude_transcript <home> <projdir-name> <id> <first-user-text> <epoch> [array]
# Real shape: a couple of non-user entries (snapshot, attachment) precede the first
# `"type":"user"` entry; content is a string, or with "array" an array of text parts.
claude_transcript() {
    local home="$1" proj="$2" id="$3" text="$4" t="$5" form="${6:-string}" f content
    mkdir -p "$home/.claude/projects/$proj"
    f="$home/.claude/projects/$proj/$id.jsonl"
    if [ "$form" = array ]; then content="[{\"type\":\"text\",\"text\":\"$text\"}]"; else content="\"$text\""; fi
    {
        printf '{"type":"file-history-snapshot","messageId":"m1","snapshot":{"trackedFileBackups":{}}}\n'
        printf '{"type":"attachment","attachment":{"type":"deferred_tools_delta"},"sessionId":"%s"}\n' "$id"
        printf '{"parentUuid":"p","isSidechain":false,"promptId":"x","type":"user","message":{"role":"user","content":%s},"uuid":"u1","cwd":"/home/x/projects/brain","sessionId":"%s"}\n' "$content" "$id"
        printf '{"parentUuid":"u1","type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"hi"}]},"sessionId":"%s"}\n' "$id"
        printf '{"type":"last-prompt","leafUuid":"u1","sessionId":"%s"}\n' "$id"
    } >"$f"
    stamp "$f" "$t"
    printf '%s\n' "$f"
}

# claude_append_user <file> <text> — a LATER user message (how a coordinator quotes a
# launch sentence: never as its first user message). Keeps the file's mtime param.
claude_append_user() {
    printf '{"type":"user","message":{"role":"user","content":"%s"},"sessionId":"x"}\n' "$2" >>"$1"
}

# claude_append_exit <file> <epoch> — a clean `/exit` typed by a human (Claude Code's own
# slash-command record), then re-stamps the file: the conversation ended on purpose.
claude_append_exit() {
    printf '{"type":"user","message":{"role":"user","content":"<command-name>/exit</command-name>\\n<command-message>exit</command-message>"},"sessionId":"x"}\n' >>"$1"
    printf '{"type":"cost-state","sessionId":"x"}\n' >>"$1"
    stamp "$1" "$2"
}

# omp_transcript <home> <projdir-name> <id> <first-user-text> <epoch>
omp_transcript() {
    local home="$1" proj="$2" id="$3" text="$4" t="$5" f
    mkdir -p "$home/.omp/agent/sessions/$proj"
    f="$home/.omp/agent/sessions/$proj/2026-09-20T10-00-00-000Z_$id.jsonl"
    {
        printf '{"type":"title","v":1,"title":"Read worker brief","source":"auto"}\n'
        printf '{"type":"session","version":3,"id":"%s","timestamp":"2026-09-20T10:00:00.000Z","cwd":"/home/x/projects/brain"}\n' "$id"
        printf '{"type":"model_change","id":"3242e563","parentId":null,"model":"deepseek/deepseek-flash"}\n'
        printf '{"type":"message","id":"ad63d14e","parentId":"2c","message":{"role":"user","content":[{"type":"text","text":"%s"}],"attribution":"user"}}\n' "$text"
        printf '{"type":"custom","customType":"session_exit","data":{"reason":"sighup","kind":"signal"},"id":"4e","parentId":"9d"}\n'
    } >"$f"
    stamp "$f" "$t"
    printf '%s\n' "$f"
}

# run_find <home> [extra args...] — stdin = candidate lines
run_find() {
    local home="$1"; shift
    bash "$FIND" --home "$home" --boot-time "$BOOT" --shutdown-time "$SHUT" "$@" 2>"$TMP/find.err"
}
field() { printf '%s\n' "$1" | awk -F'\t' -v s="$2" -v c="$3" '$1==s{print $c; exit}'; }

# =================================================================== find-live ====
echo "find-live-sessions.sh:"
H="$TMP/home1"
CID_LIVE=11111111-1111-4111-8111-111111111111
CID_FB=22222222-2222-4222-8222-222222222222
CID_ARR=33333333-3333-4333-8333-333333333333
CID_END=44444444-4444-4444-8444-444444444444
CID_TCH=55555555-5555-4555-8555-555555555555
CID_AMB1=66666666-6666-4666-8666-666666666666
CID_AMB2=77777777-7777-4777-8777-777777777777
CID_MIXL=88888888-8888-4888-8888-888888888888
CID_MIXE=99999999-9999-4999-8999-999999999999
CID_COORD=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa
CID_SUB=bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb
CID_NEAR=cccccccc-cccc-4ccc-8ccc-cccccccccccc
CID_PFX=dddddddd-dddd-4ddd-8ddd-dddddddddddd

P=-home-x-projects-brain
F_LIVE="$(claude_transcript "$H" "$P" "$CID_LIVE" "some unrelated first prompt" "$T_LIVE")"
F_FB="$(claude_transcript "$H" "$P" "$CID_FB" "$(sentence fb-worker)" "$T_LIVE")"
F_ARR="$(claude_transcript "$H" -home-x-projects-other "$CID_ARR" "$(sentence arr-worker)" "$T_LIVE" array)"
claude_append_exit "$(claude_transcript "$H" "$P" "$CID_END" "$(sentence ended-worker)" "$T_ENDED")" "$T_ENDED"
claude_transcript "$H" "$P" "$CID_TCH" "$(sentence touched-worker)" "$T_TOUCHED" >/dev/null
claude_transcript "$H" "$P" "$CID_AMB1" "$(sentence amb-worker)" "$T_LIVE" >/dev/null
claude_transcript "$H" "$P" "$CID_AMB2" "$(sentence amb-worker)" "$T_LIVE2" >/dev/null
claude_transcript "$H" "$P" "$CID_MIXL" "$(sentence mix-worker)" "$T_LIVE" >/dev/null
claude_transcript "$H" "$P" "$CID_MIXE" "$(sentence mix-worker)" "$T_ENDED" >/dev/null
claude_transcript "$H" "$P" "$CID_NEAR" "$(sentence near-worker)" "$T_NEAR" >/dev/null
claude_transcript "$H" "$P" "$CID_PFX" "$(sentence pfx-worker-long)" "$T_LIVE" >/dev/null
# The coordinator: its FIRST user message is something else; it quotes the launch
# sentences of coord-only-worker later. It is live (the coordinator always is).
F_COORD="$(claude_transcript "$H" "$P" "$CID_COORD" "plan my day" "$T_LIVE")"
claude_append_user "$F_COORD" "$(sentence coord-only-worker)"
stamp "$F_COORD" "$T_LIVE"
# A subagent transcript nested under a session dir, whose first user message IS a
# launch sentence — must never be treated as a worker transcript.
SUBF="$(claude_transcript "$H" "$P/$CID_COORD/subagents" "$CID_SUB" "$(sentence sub-only-worker)" "$T_LIVE")"

OID_LIVE=01a0a4dc-5a6c-70da-bde2-a62afe728802
OID_FB=01a0a4dc-0000-70da-bde2-000000000001
F_OLIVE="$(omp_transcript "$H" -projects-brain "$OID_LIVE" "hello there" "$T_LIVE")"
F_OFB="$(omp_transcript "$H" -projects-brain "$OID_FB" "$(sentence omp-fb-worker)" "$T_LIVE")"

INPUT="note-id-worker${TAB}claude${TAB}$CID_LIVE
fb-worker${TAB}claude${TAB}
arr-worker${TAB}claude${TAB}
ended-worker${TAB}claude${TAB}
touched-worker${TAB}claude${TAB}
amb-worker${TAB}claude${TAB}
mix-worker${TAB}claude${TAB}
coord-only-worker${TAB}claude${TAB}
sub-only-worker${TAB}claude${TAB}
omp-id-worker${TAB}omp${TAB}01a0a4dc-5a6c
omp-fb-worker${TAB}omp${TAB}
nothing-worker${TAB}claude${TAB}
pfx-worker${TAB}claude${TAB}
near-worker${TAB}claude${TAB}
omp-fb-worker-as-claude${TAB}claude${TAB}"
OUT="$(printf '%s\n' "$INPUT" | run_find "$H")"; RC=$?
ERR="$(cat "$TMP/find.err")"
assert_eq "rc 0" "0" "$RC"
assert_eq "one output line per input line" "15" "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')"
assert_eq "output keeps input order" "note-id-worker" "$(printf '%s\n' "$OUT" | head -1 | cut -f1)"

assert_eq "session_id from note → live"            "live"      "$(field "$OUT" note-id-worker 2)"
assert_eq "session_id from note → same id"         "$CID_LIVE" "$(field "$OUT" note-id-worker 3)"
assert_eq "session_id from note → transcript path" "$F_LIVE"   "$(field "$OUT" note-id-worker 4)"
assert_eq "mtime_iso printed"                      "$(iso "$T_LIVE")" "$(field "$OUT" note-id-worker 5)"

assert_eq "fallback on first user msg (string content) → live" "live"    "$(field "$OUT" fb-worker 2)"
assert_eq "fallback → id is the transcript basename"          "$CID_FB" "$(field "$OUT" fb-worker 3)"
assert_eq "fallback → path"                                   "$F_FB"   "$(field "$OUT" fb-worker 4)"
assert_eq "fallback on array content, any project dir → live" "live"     "$(field "$OUT" arr-worker 2)"
assert_eq "array content → id"                                "$CID_ARR" "$(field "$OUT" arr-worker 3)"

assert_eq "older than window + clean /exit → ended-before-shutdown" "ended-before-shutdown" "$(field "$OUT" ended-worker 2)"
assert_eq "ended still reports its id"                "$CID_END"              "$(field "$OUT" ended-worker 3)"
assert_eq "mtime after boot → touched-since-boot"     "touched-since-boot"    "$(field "$OUT" touched-worker 2)"
assert_eq "two live matches → ambiguous"              "ambiguous"             "$(field "$OUT" amb-worker 2)"
assert_contains "ambiguous lists both ids"            "$CID_AMB1"             "$(field "$OUT" amb-worker 3)"
assert_contains "ambiguous lists both ids (2)"        "$CID_AMB2"             "$(field "$OUT" amb-worker 3)"
assert_eq "one live + one ended match → live"         "live"                  "$(field "$OUT" mix-worker 2)"
assert_eq "one live + one ended → the live one's id"  "$CID_MIXL"             "$(field "$OUT" mix-worker 3)"
assert_eq "coordinator quoting the sentence later is NOT matched" "no-transcript" "$(field "$OUT" coord-only-worker 2)"
assert_eq "subagent transcripts are excluded"         "no-transcript"         "$(field "$OUT" sub-only-worker 2)"
assert_eq "no transcript at all → no-transcript"      "no-transcript"         "$(field "$OUT" nothing-worker 2)"
assert_eq "slug is not a prefix match (pfx-worker vs pfx-worker-long)" "no-transcript" "$(field "$OUT" pfx-worker 2)"
assert_eq "5 min before shutdown, no exit marker → idle-at-shutdown (mtime is last activity, not death)" "idle-at-shutdown" "$(field "$OUT" near-worker 2)"
assert_eq "idle row names the shutdown it died at (field 6)" "$(iso "$SHUT")" "$(field "$OUT" near-worker 6)"
assert_eq "live row names its shutdown too" "$(iso "$SHUT")" "$(field "$OUT" note-id-worker 6)"
assert_eq "no-transcript row: died_at is '-'" "-" "$(field "$OUT" nothing-worker 6)"
assert_eq "harness scopes the fallback (omp transcript not seen as claude)" "no-transcript" "$(field "$OUT" omp-fb-worker-as-claude 2)"

assert_eq "omp id prefix from note → live"                  "live"      "$(field "$OUT" omp-id-worker 2)"
assert_eq "omp → full id from the \"type\":\"session\" line" "$OID_LIVE" "$(field "$OUT" omp-id-worker 3)"
assert_eq "omp → path"                                      "$F_OLIVE"  "$(field "$OUT" omp-id-worker 4)"
assert_eq "omp fallback on first user message → live"       "live"      "$(field "$OUT" omp-fb-worker 2)"
assert_eq "omp fallback → id from session line"             "$OID_FB"   "$(field "$OUT" omp-fb-worker 3)"

assert_contains "stderr header: shutdown_source=override" "shutdown_source=override" "$ERR"
assert_contains "stderr header: window=180"               "window=180"               "$ERR"
assert_contains "stderr header: boot iso"                 "boot=$(iso "$BOOT")"      "$ERR"
assert_contains "stderr header: shutdown iso"             "shutdown=$(iso "$SHUT")"  "$ERR"

OUT="$(printf 'near-worker\tclaude\t\n' | run_find "$H" --window 600)"
assert_eq "--window 600 widens liveness → live" "live" "$(field "$OUT" near-worker 2)"

# a note session_id that no longer exists falls back to the first-user-message search
OUT="$(printf 'fb-worker\tclaude\tdeadbeef-0000-4000-8000-000000000000\n' | run_find "$H")"
assert_eq "stale note id falls back to sentence search" "$CID_FB" "$(field "$OUT" fb-worker 3)"

# Shutdown proxy: no journal (stub journalctl fails), no override → max mtime of the
# top-level transcripts older than boot. The newest pre-boot one here is at T_LIVE.
NOJ="$TMP/nojournal"; mkdir -p "$NOJ"
printf '#!/bin/sh\nexit 1\n' >"$NOJ/journalctl"; chmod +x "$NOJ/journalctl"
OUT="$(printf 'fb-worker\tclaude\t\n' | PATH="$NOJ:$PATH" bash "$FIND" --home "$H" --boot-time "$BOOT" 2>"$TMP/find.err")"
ERR="$(cat "$TMP/find.err")"
assert_contains "no journal → shutdown_source=proxy"              "shutdown_source=proxy"      "$ERR"
assert_contains "proxy = newest pre-boot transcript mtime"        "shutdown=$(iso "$T_LIVE")" "$ERR"
assert_eq       "proxy liveness still classifies"                 "live" "$(field "$OUT" fb-worker 2)"

# The script must be self-contained (it is piped over ssh): no sourcing of repo libs.
if grep -qE '^[[:space:]]*(\.|source)[[:space:]]' "$FIND"; then bad "find-live-sessions.sh sources nothing"; else ok "find-live-sessions.sh sources nothing"; fi

# An omp transcript WITHOUT a `"type":"session"` line has no id: every empty field is
# printed as `-`, so a tab-splitting reader can never shift the path into session_id.
F_ONS="$(omp_transcript "$H" -projects-brain 01a0eeee-0000-70da-bde2-000000000001 "$(sentence omp-nosess-worker)" "$T_LIVE")"
sed -i.bak '/"type":"session"/d' "$F_ONS" && rm -f "$F_ONS.bak"; stamp "$F_ONS" "$T_LIVE"
OUT="$(printf 'omp-nosess-worker\tomp\t\nnothing-worker\tclaude\t\n' | run_find "$H")"
assert_eq "no session line → live"                "live"    "$(field "$OUT" omp-nosess-worker 2)"
assert_eq "no session line → session_id is '-'"   "-"       "$(field "$OUT" omp-nosess-worker 3)"
assert_eq "no session line → path still field 4"  "$F_ONS"  "$(field "$OUT" omp-nosess-worker 4)"
assert_eq "no-transcript → empty fields are '-'"  "nothing-worker${TAB}no-transcript${TAB}-${TAB}-${TAB}-${TAB}-" \
    "$(printf '%s\n' "$OUT" | grep '^nothing-worker')"

# empty stdin → no output, rc 0
OUT="$(printf '' | run_find "$H")"; RC=$?
assert_eq "empty input → rc 0" "0" "$RC"
assert_eq "empty input → no output" "" "$OUT"

# A private worker's launch sentence points at vault/private/workers/: the fallback must
# still extract the slug from it (and keep extracting the plain one).
CID_PRIV=eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee
claude_transcript "$H" "$P" "$CID_PRIV" \
    "Read your worker brief at ~/Obsidian/vault/private/workers/priv-fb-worker.md and follow its priming, then greet me." "$T_LIVE" >/dev/null
OUT="$(printf 'priv-fb-worker\tclaude\t\nfb-worker\tclaude\t\n' | run_find "$H")"
assert_eq "private path sentence → live via fallback" "live" "$(field "$OUT" priv-fb-worker 2)"
assert_eq "private path sentence → id is the transcript basename" "$CID_PRIV" "$(field "$OUT" priv-fb-worker 3)"
assert_eq "plain path sentence still matches" "$CID_FB" "$(field "$OUT" fb-worker 3)"

# ---- every journalled boot, not just the latest -------------------------------------
# Three boots (the journal stub lists them as `journalctl --list-boots -o json` does, in
# microseconds): an EARLIER shutdown S1 that nobody revived after, the latest shutdown
# SHUT, and the current boot. Workers that died at S1, or sat idle for hours before a
# shutdown, used to read `ended-before-shutdown` and the dry run said "nothing to revive".
S1=$((SHUT - 200000)); B2=$((S1 + 900))
JB="$TMP/journal-boots"; mkdir -p "$JB"
cat >"$JB/journalctl" <<EOF
#!/bin/sh
[ "\$1" = --list-boots ] || exit 1
printf '[{"index":-2,"boot_id":"a","first_entry":%s000000,"last_entry":%s000000},{"index":-1,"boot_id":"b","first_entry":%s000000,"last_entry":%s000000},{"index":0,"boot_id":"c","first_entry":%s000000,"last_entry":%s000000}]\n' \
    $((S1 - 50000)) $S1 $B2 $SHUT $BOOT $((BOOT + 50))
EOF
chmod +x "$JB/journalctl"
HJ="$TMP/homej"
# cluster base: the start of a minute 8 h before S1, so +0/+10/+20 s share that minute
CL=$(( (S1 - 28800) / 60 * 60 ))
claude_transcript "$HJ" "$P" "$(printf 'cccc0000-0000-4000-8000-%012d' 1)" "$(sentence died-early)"  "$((S1 - 20))"   >/dev/null
claude_transcript "$HJ" "$P" "$(printf 'cccc0000-0000-4000-8000-%012d' 2)" "$(sentence idle-a)"      "$CL"            >/dev/null
claude_transcript "$HJ" "$P" "$(printf 'cccc0000-0000-4000-8000-%012d' 3)" "$(sentence idle-b)"      "$((CL + 10))"   >/dev/null
claude_transcript "$HJ" "$P" "$(printf 'cccc0000-0000-4000-8000-%012d' 4)" "$(sentence idle-c)"      "$((CL + 20))"   >/dev/null
claude_transcript "$HJ" "$P" "$(printf 'cccc0000-0000-4000-8000-%012d' 5)" "$(sentence idle-late)"   "$((SHUT - 10800))" >/dev/null
claude_transcript "$HJ" "$P" "$(printf 'cccc0000-0000-4000-8000-%012d' 6)" "$(sentence died-late)"   "$((SHUT - 30))" >/dev/null
claude_append_exit "$(claude_transcript "$HJ" "$P" "$(printf 'cccc0000-0000-4000-8000-%012d' 7)" "$(sentence exited)" "$((SHUT - 10800))")" "$((SHUT - 10800))"
F_OEX="$(omp_transcript "$HJ" -projects-brain 01a0cccc-0000-70da-bde2-000000000008 "$(sentence omp-exited)" "$((SHUT - 10800))")"
sed -i.bak 's/"reason":"sighup","kind":"signal"/"reason":"dispose","kind":"normal"/' "$F_OEX" && rm -f "$F_OEX.bak"; stamp "$F_OEX" "$((SHUT - 10800))"
omp_transcript "$HJ" -projects-brain 01a0cccc-0000-70da-bde2-000000000009 "$(sentence omp-killed)" "$((SHUT - 10800))" >/dev/null
JIN="died-early${TAB}claude${TAB}
idle-a${TAB}claude${TAB}
idle-b${TAB}claude${TAB}
idle-c${TAB}claude${TAB}
idle-late${TAB}claude${TAB}
died-late${TAB}claude${TAB}
exited${TAB}claude${TAB}
omp-exited${TAB}omp${TAB}
omp-killed${TAB}omp${TAB}"
OUT="$(printf '%s\n' "$JIN" | PATH="$JB:$PATH" bash "$FIND" --home "$HJ" --boot-time "$BOOT" 2>"$TMP/find.err")"; RC=$?
ERR="$(cat "$TMP/find.err")"
assert_eq "journal boots: rc 0" "0" "$RC"
assert_contains "journal boots: header shutdown = latest" "shutdown=$(iso "$SHUT") shutdown_source=journal" "$ERR"
assert_contains "journal boots: header counts the shutdowns" "shutdowns=2" "$ERR"
assert_eq "died at an EARLIER shutdown → live"           "live"             "$(field "$OUT" died-early 2)"
assert_eq "…matched to that earlier shutdown"             "$(iso "$S1")"     "$(field "$OUT" died-early 6)"
assert_eq "idle for hours before the earlier shutdown → idle-at-shutdown" "idle-at-shutdown" "$(field "$OUT" idle-a 2)"
assert_eq "…matched to the shutdown that followed its last activity" "$(iso "$S1")" "$(field "$OUT" idle-a 6)"
assert_eq "idle before the latest shutdown → idle-at-shutdown" "idle-at-shutdown" "$(field "$OUT" idle-late 2)"
assert_eq "…matched to the latest shutdown"               "$(iso "$SHUT")"   "$(field "$OUT" idle-late 6)"
assert_eq "died at the latest shutdown → live"            "live"             "$(field "$OUT" died-late 2)"
assert_eq "claude /exit marker → ended-before-shutdown"   "ended-before-shutdown" "$(field "$OUT" exited 2)"
assert_eq "omp session_exit kind normal → ended-before-shutdown" "ended-before-shutdown" "$(field "$OUT" omp-exited 2)"
assert_eq "omp session_exit kind signal (sighup) → idle-at-shutdown" "idle-at-shutdown" "$(field "$OUT" omp-killed 2)"
assert_contains "cluster: three transcripts sharing one mtime minute are printed" "cluster: 3 transcripts" "$ERR"
assert_contains "cluster names its slugs" "idle-a,idle-b,idle-c" "$ERR"
assert_contains "cluster away from its shutdown → ready-made override" \
    "--shutdown-time $((CL + 80)) --boot-time $B2" "$ERR"
assert_not_contains "a lone transcript is no cluster" "died-early" "$(printf '%s\n' "$ERR" | grep '^cluster:')"
# --shutdown-time still overrides the journal (one shutdown, the given one)
OUT="$(printf '%s\n' "$JIN" | PATH="$JB:$PATH" bash "$FIND" --home "$HJ" --boot-time "$BOOT" --shutdown-time "$SHUT" 2>"$TMP/find.err")"
assert_contains "override → shutdown_source=override, one shutdown" "shutdown_source=override window=180 shutdowns=1" "$(cat "$TMP/find.err")"
assert_eq "override: an earlier-shutdown death is idle against the given one" "idle-at-shutdown" "$(field "$OUT" died-early 2)"

# ================================================================ revive-workers ===
echo "revive-workers.sh:"
export BRAIN_ROOT="$REPO"
# A fixture hosts.conf: this machine is `desk`, found by the pinned hostname — never by
# the real machine's. `nossh` is a host with no ssh route (alias `-`) that is not self.
export BRAIN_HOSTS="$TMP/hosts.conf"
cat >"$BRAIN_HOSTS" <<'HOSTS'
# name  ssh_alias      harnesses   default_harness  hostnames
desk    -              omp,claude  omp              deskbox
remote2     remote2-ssh  claude      claude           remote2-box
homeserver   homeserver          claude      claude           homeserver
nossh   -              claude      claude           nossh-box
HOSTS
export BRAIN_HOSTNAME=deskbox
unset BRAIN_SELF_HOST

V="$TMP/vault"; mkdir -p "$V/workers"
note() {  # note <slug> <frontmatter lines...>
    local slug="$1"; shift
    { printf -- '---\nslug: %s\n' "$slug"; for l in "$@"; do printf '%s\n' "$l"; done
      printf -- '---\n\n# %s\n\nbody mentions status: collected and host: remote2\n' "$slug"; } >"$V/workers/$slug.md"
}
LH="$TMP/lhome"     # local host's fake HOME
MH="$TMP/mhome"     # remote2 host's fake HOME
MDH="$TMP/mdhome"   # homeserver host's fake HOME
RMD=aaaa0000-0000-4000-8000-0000000000fe
RA=aaaa0000-0000-4000-8000-00000000000a
RC_ID=aaaa0000-0000-4000-8000-00000000000c
RD=aaaa0000-0000-4000-8000-00000000000d
RE=aaaa0000-0000-4000-8000-00000000000e
RM=aaaa0000-0000-4000-8000-0000000000ff
RL=01a0ffff-0000-70da-bde2-00000000000b

note r-alpha   "host: desk" "harness: claude" "project_dir: ~/projects/alpha" "tmux_session: brain-worker-r-alpha" "status: working" "session_id: $RA"
note r-legacy  "project_dir: ~/projects/brain" "status: primed"
note r-coll    "host: desk" "harness: claude" "project_dir: ~/projects/brain" "status: collected"
note r-done    "host: desk" "harness: claude" "project_dir: ~/projects/brain" "status: done   # waiting for MR merge"
note r-running "host: desk" "harness: claude" "project_dir: ~/projects/brain" "status: working"
note r-old     "host: desk" "harness: claude" "project_dir: ~/projects/brain" "status: blocked"
note r-remote2     "host: remote2" "harness: claude" "project_dir: ~/projects/brain" "status: working" "session_id: $RM"
note r-media   "host: homeserver" "harness: claude" "project_dir: ~/projects/brain" "status: working" "session_id: $RMD"
# legacy `host: local` (written when `local` meant "the dispatching machine"): read as self
# with a warning; its project_dir is not on this machine, so the warning says so. No
# transcript here → a hint to look on the other hosts.
note r-local   "host: local" "harness: claude" "project_dir: ~/projects/elsewhere" "tmux_session: brain-worker-r-local" "status: working"
# collected legacy notes are the bulk of a real vault: never a warning for them
note r-lcoll   "host: local" "project_dir: ~/projects/elsewhere" "tmux_session: brain-worker-r-lcoll" "status: collected"
# not worker notes (findings/reports filed under workers/): no tmux_session: and no
# project_dir: → skipped silently, even with a status:
note r-findings "area: projects" "project: agent-pawl" "status: APPROVED by the tech lead"
note r-report   "type: findings" "worker: r-alpha" "date: 2026-10-14"
mkdir -p "$LH/projects/brain"   # r-legacy's project_dir exists on this machine

claude_transcript "$LH" -home-x-projects-alpha "$RA" "first" "$T_LIVE" >/dev/null
omp_transcript    "$LH" -projects-brain "$RL" "$(sentence r-legacy)" "$T_LIVE" >/dev/null
claude_transcript "$LH" "$P" "$RC_ID" "$(sentence r-coll)" "$T_LIVE" >/dev/null
claude_transcript "$LH" "$P" "$RD" "$(sentence r-done)" "$T_LIVE" >/dev/null
claude_transcript "$LH" "$P" "$RE" "$(sentence r-running)" "$T_LIVE" >/dev/null
claude_append_exit "$(claude_transcript "$LH" "$P" "$(printf 'aaaa0000-0000-4000-8000-%012d' 1)" "$(sentence r-old)" "$T_ENDED")" "$T_ENDED"
claude_transcript "$MH" -Users-x-projects-brain "$RM" "first" "$T_LIVE" >/dev/null
claude_transcript "$MDH" -home-x-projects-brain "$RMD" "first" "$T_LIVE" >/dev/null

# stub tmux: sessions listed in $TSF exist; logs argv. Panes are simulated per session
# under $PD (all optional):
#   <s>.cmd    pane_current_command for list-panes (default: claude)
#   <s>.eN     pane text after N Enter keypresses (falls back to the highest N' <= N;
#              default: claude + omp ready fixtures, i.e. ready for either harness)
#   <s>.busy   a count: that many captures show the busy fixture first
#   <s>.drop-enter  the next Enter is swallowed (a keystroke lost while loading)
#   <s>.dialog the Remote Control "already connected" dialog shows (after any busy polls)
#              until Escape — or for good with <s>.dialog-stuck
# Literal send-keys text sits in the composer (claude's `❯`+NBSP line) or, on a pane
# without one, on a shell prompt line, until C-u or an Enter that is not swallowed.
FIX="$REPO/skills/_shared/lib/fixtures"
TSF="$TMP/tmux-sessions"; printf 'brain-worker-r-running\nsome-other\n' >"$TSF"
TLOG="$TMP/tmux.log"; : >"$TLOG"
PD="$TMP/panes"; mkdir -p "$PD"
cat "$FIX/claude/ready.txt" "$FIX/omp/ready.txt" >"$PD/default"
export FT_TSF="$TSF" FT_LOG="$TLOG" FT_PD="$PD" FT_FIX="$FIX"
cat >"$TMP/fake-tmux" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$FT_LOG"
tgt() { while [ $# -gt 0 ]; do [ "$1" = -t ] && { printf '%s' "$2"; return; }; shift; done; }
case "$1" in
  list-sessions) cat "$FT_TSF" ;;
  has-session)   grep -qxF -- "$3" "$FT_TSF" ;;
  list-panes)
    while read -r s; do
        [ -n "$s" ] || continue
        c=claude; [ -f "$FT_PD/$s.cmd" ] && c="$(cat "$FT_PD/$s.cmd")"
        printf '%s %s\n' "$s" "$c"
    done <"$FT_TSF" ;;
  capture-pane)
    s="$(tgt "$@")"; n="$(cat "$FT_PD/$s.stage" 2>/dev/null || echo 0)"
    b="$(cat "$FT_PD/$s.busy" 2>/dev/null || echo 0)"
    if [ "$b" -gt 0 ]; then echo $((b - 1)) >"$FT_PD/$s.busy"; cat "$FT_FIX/claude/busy.txt"; exit 0; fi
    if [ -f "$FT_PD/$s.dialog" ]; then cat "$FT_FIX/claude/rc-already-connected.txt"; exit 0; fi
    f="$FT_PD/default"; i="$n"
    while [ "$i" -ge 0 ]; do [ -f "$FT_PD/$s.e$i" ] && { f="$FT_PD/$s.e$i"; break; }; i=$((i - 1)); done
    t="$(cat "$FT_PD/$s.typed" 2>/dev/null)"
    if [ -z "$t" ]; then cat "$f"
    elif grep -q $'^\xe2\x9d\xaf\xc2\xa0$' "$f"; then sed $'s|^\xe2\x9d\xaf\xc2\xa0$|\xe2\x9d\xaf\xc2\xa0'"$t"'|' "$f"
    else cat "$f"; printf '%% %s\n' "$t"; fi ;;
  send-keys)
    s="$(tgt "$@")"; k="${!#}"
    case "$k" in
      C-u)   : >"$FT_PD/$s.typed" ;;
      Down)  ;;
      Escape) [ -f "$FT_PD/$s.dialog-stuck" ] || rm -f "$FT_PD/$s.dialog" ;;
      Enter) if [ -f "$FT_PD/$s.drop-enter" ]; then rm -f "$FT_PD/$s.drop-enter"
             else n="$(cat "$FT_PD/$s.stage" 2>/dev/null || echo 0)"; echo $((n + 1)) >"$FT_PD/$s.stage"; : >"$FT_PD/$s.typed"; fi ;;
      *)     printf '%s' "$k" >>"$FT_PD/$s.typed" ;;
    esac ;;
  *) echo "fake-tmux: refusing $1" >&2; exit 99 ;;
esac
EOF
chmod +x "$TMP/fake-tmux"
export BRAIN_TMUX="$TMP/fake-tmux"
export REVIVE_SLEEP=0 REVIVE_READY_TRIES=6

# stub ssh: logs argv; `<alias> bash -s -- args` runs the piped script locally with the
# fake HOME chosen by alias (remote2-ssh → $MH, homeserver → $MDH); `<alias> zsh -lc <cmd>` runs <cmd> under bash (tmux is the stub).
SLOG="$TMP/ssh.log"; : >"$SLOG"
cat >"$TMP/fake-ssh" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$SLOG"
[ "\$1" = "-o" ] && shift 2
ALIAS="\$1"; shift
case "\$ALIAS" in homeserver) FH="$MDH" ;; *) FH="$MH" ;; esac
if [ "\$1" = bash ] && [ "\$2" = -s ]; then shift 2; HOME="\$FH" exec bash -s "\$@"; fi
if [ "\$1" = zsh ] && [ "\$2" = -lc ]; then eval "exec bash -c \$3"; fi
echo "fake-ssh: unexpected \$*" >&2; exit 97
EOF
chmod +x "$TMP/fake-ssh"
export BRAIN_SSH="$TMP/fake-ssh"

# stub launcher: logs argv, prints a launch-worker style result line + a note: on stderr
LLOG="$TMP/launcher.log"; : >"$LLOG"
cat >"$TMP/fake-launcher" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$LLOG"
slug=""; id=""
while [ \$# -gt 0 ]; do case "\$1" in --slug) slug="\$2"; shift 2;; --resume) id="\$2"; shift 2;; *) shift;; esac; done
if [ -n "\${FAIL_SLUG:-}" ] && [ "\$slug" = "\$FAIL_SLUG" ]; then
  echo "verified=no session=brain-worker-\$slug rc=n/a attach=tmux attach -t brain-worker-\$slug session_id=\$id mode=resume"
  exit 1
fi
echo "note: Tool call didn't finish before the previous session ended" >&2
rc=yes; [ "\$slug" = "\${RC_NO_SLUG:-}" ] && rc=no
echo "verified=yes session=brain-worker-\$slug rc=\$rc attach=tmux attach -t brain-worker-\$slug session_id=\$id mode=resume"
EOF
chmod +x "$TMP/fake-launcher"
export REVIVE_LAUNCHER="$TMP/fake-launcher"

revive() { HOME="$LH" bash "$REVIVE" --vault "$V" --boot-time "$BOOT" --shutdown-time "$SHUT" "$@"; }
row() { printf '%s\n' "$1" | awk -v s="$2" '$1==s{print; exit}'; }

OUT="$(revive 2>&1)"; RC=$?
assert_eq "dry run (default) → rc 0" "0" "$RC"
assert_contains "dry run says so"                     "dry run"  "$OUT"
assert_eq "dry run makes NO launcher calls"           ""         "$(cat "$LLOG")"
assert_contains "table: r-alpha live with note id"    "$RA"      "$(row "$OUT" r-alpha)"
assert_contains "table: r-alpha live"                 "live"     "$(row "$OUT" r-alpha)"
assert_eq "table: legacy (unset) host → self name"     "desk"     "$(row "$OUT" r-legacy | awk '{print $2}')"
assert_eq "table: legacy host: local → self name"      "desk"     "$(row "$OUT" r-local | awk '{print $2}')"
assert_contains "table: legacy note → harness omp"    "omp"      "$(row "$OUT" r-legacy)"
assert_contains "table: legacy omp live via fallback" "$RL"      "$(row "$OUT" r-legacy)"
assert_eq "table: collected note skipped"             ""         "$(row "$OUT" r-coll)"
assert_contains "table: status comment stripped"      "done"     "$(row "$OUT" r-done)"
assert_not_contains "table: status comment stripped (no #)" "#"  "$(row "$OUT" r-done)"
assert_contains "table: existing tmux session → already-running" "already-running" "$(row "$OUT" r-running)"
assert_contains "table: old transcript → ended-before-shutdown"  "ended-before-shutdown" "$(row "$OUT" r-old)"
assert_eq "table: default host (self) hides remote2 notes" ""        "$(row "$OUT" r-remote2)"
assert_eq "self host never touches ssh"               ""         "$(cat "$SLOG")"
if grep -qvE '^(list-sessions|has-session|list-panes)' "$TLOG"; then bad "dry run: only read-only tmux calls"; else ok "dry run: only read-only tmux calls"; fi
assert_eq "non-worker note (status, no project_dir/tmux_session) skipped" "" "$(row "$OUT" r-findings)"
assert_eq "non-worker report note skipped"            ""         "$(row "$OUT" r-report)"
assert_not_contains "non-worker notes never named"    "r-findings" "$OUT"
assert_not_contains "non-worker report never named"   "r-report"   "$OUT"
ERR="$(revive 2>&1 >/dev/null)"
assert_contains "warning: unset host read as self, harness defaulted, one line" \
    "warning: r-legacy: legacy host 'unset' read as desk; no harness: — assuming omp" "$ERR"
assert_not_contains "r-legacy's project_dir exists here → no other-host suffix" "projects/brain is not on this machine" "$ERR"
assert_contains "warning: host: local read as self + project_dir elsewhere" \
    "warning: r-local: legacy host 'local' read as desk — project_dir ~/projects/elsewhere is not on this machine; it probably belongs to another host (fix its host:)" "$ERR"
assert_eq "one warning line per legacy slug" "1" "$(printf '%s\n' "$ERR" | grep -c 'r-local')"
assert_not_contains "no warning for a collected legacy note" "r-lcoll" "$ERR"
assert_not_contains "warnings go to stderr, not the table" "warning:" "$(revive 2>/dev/null)"
assert_contains "no-transcript row gets a --host all hint" \
    "hint: r-local: no transcript on desk — if it ran elsewhere, re-run with --host all" "$OUT"
assert_not_contains "a row with a transcript gets no hint" "hint: r-old" "$OUT"
OUT2="$(revive --host local 2>&1)"
assert_eq "--host local = self (same table)" "$(printf '%s\n' "$OUT" | grep -v '^# ')" "$(printf '%s\n' "$OUT2" | grep -v '^# ')"
assert_eq "--host desk = self (same table)" "$(printf '%s\n' "$OUT" | grep -v '^# ')" "$(revive --host desk 2>&1 | grep -v '^# ')"
ERR="$(revive --only r-alpha 2>&1 >/dev/null)"
assert_not_contains "--only excluding legacy notes → no legacy warnings" "warning:" "$ERR"

: >"$LLOG"
OUT="$(revive --apply 2>&1)"; RC=$?
assert_eq "--apply all verified → rc 0" "0" "$RC"
assert_eq "--apply launches exactly the live ones (alpha, legacy, done)" "3" "$(wc -l <"$LLOG" | tr -d ' ')"
assert_contains "--apply: status done but live → still revived (only collected is excluded)" "--slug r-done " "$(cat "$LLOG")"
assert_contains "--apply r-alpha: --resume <note id>" "--host desk --harness claude --slug r-alpha --project-dir ~/projects/alpha --resume $RA" "$(cat "$LLOG")"
assert_contains "--apply r-legacy: omp --resume <session-line id>" "--host desk --harness omp --slug r-legacy --project-dir ~/projects/brain --resume $RL" "$(cat "$LLOG")"
assert_not_contains "--apply never passes --host local" "--host local" "$(cat "$LLOG")"
if grep -qv -- '--resume ' "$LLOG"; then bad "every launcher call carries --resume (never a fresh launch)"; else ok "every launcher call carries --resume (never a fresh launch)"; fi
assert_not_contains "--apply never launches already-running" "r-running" "$(cat "$LLOG")"
assert_not_contains "--apply never launches ended"           "r-old"     "$(cat "$LLOG")"
assert_contains "--apply relays note: lines" "note: Tool call didn't finish" "$OUT"
assert_contains "--apply shows result lines" "verified=yes session=brain-worker-r-alpha" "$OUT"
if grep -qE '^(new-session|kill-session|kill-server|kill-pane|respawn)' "$TLOG"; then bad "orchestrator itself never kills/creates sessions"; else ok "orchestrator itself never kills/creates sessions"; fi
if grep -q '^send-keys' "$TLOG"; then bad "--apply: launcher-path rows with rc=yes and a ready pane get no keystrokes"; else ok "--apply: launcher-path rows with rc=yes and a ready pane get no keystrokes"; fi
assert_contains "--apply polls the resumed pane for composer readiness" "capture-pane -p -e -t brain-worker-r-alpha" "$(cat "$TLOG")"

: >"$LLOG"
OUT="$(FAIL_SLUG=r-legacy revive --apply 2>&1)"; RC=$?
assert_eq "--apply with a failed revival → rc 1" "1" "$RC"
assert_eq "--apply keeps going after a failure" "3" "$(wc -l <"$LLOG" | tr -d ' ')"
assert_contains "summary reports the failure" "r-legacy" "$(printf '%s\n' "$OUT" | tail -3)"

: >"$LLOG"
OUT="$(revive --apply --only r-alpha,r-old 2>&1)"; RC=$?
assert_eq "--only rc 0" "0" "$RC"
assert_eq "--only restricts launches" "1" "$(wc -l <"$LLOG" | tr -d ' ')"
assert_eq "--only restricts table" "" "$(row "$OUT" r-legacy)"
assert_contains "--only table keeps listed" "ended-before-shutdown" "$(row "$OUT" r-old)"

# remote host through the stub ssh
: >"$LLOG"; : >"$SLOG"
OUT="$(revive --host remote2 2>&1)"; RC=$?
assert_eq "--host remote2 dry run rc 0" "0" "$RC"
assert_contains "remote2: find-live piped over ssh as bash -s" "-o BatchMode=yes remote2-ssh bash -s --" "$(cat "$SLOG")"
assert_contains "remote2: r-remote2 live from remote2 HOME" "live" "$(row "$OUT" r-remote2)"
assert_contains "remote2: r-remote2 id" "$RM" "$(row "$OUT" r-remote2)"
assert_eq "remote2: self notes hidden" "" "$(row "$OUT" r-alpha)"
assert_not_contains "remote2: no warnings for legacy notes on another host" "warning:" "$OUT"
assert_not_contains "remote2: legacy notes (self) hidden" "r-legacy" "$OUT"
assert_eq "remote2: dry run no launches" "" "$(cat "$LLOG")"
OUT="$(revive --host remote2 --apply 2>&1)"; RC=$?
assert_eq "remote2 --apply rc 0" "0" "$RC"
assert_contains "remote2 --apply: --host remote2 --resume" "--host remote2 --harness claude --slug r-remote2 --project-dir ~/projects/brain --resume $RM" "$(cat "$LLOG")"

: >"$LLOG"; : >"$SLOG"
OUT="$(revive --host homeserver 2>&1)"; RC=$?
assert_eq "--host homeserver dry run rc 0" "0" "$RC"
assert_contains "homeserver: find-live piped over ssh to alias homeserver" "-o BatchMode=yes homeserver bash -s --" "$(cat "$SLOG")"
assert_contains "homeserver: r-media live from homeserver HOME" "live" "$(row "$OUT" r-media)"
assert_contains "homeserver: r-media host column" "homeserver" "$(row "$OUT" r-media)"
assert_contains "homeserver: r-media id" "$RMD" "$(row "$OUT" r-media)"
assert_eq "homeserver: remote2 notes hidden" "" "$(row "$OUT" r-remote2)"
assert_eq "homeserver: self notes hidden" "" "$(row "$OUT" r-alpha)"

OUT="$(revive --host all 2>&1)"; RC=$?
assert_eq "--host all rc 0" "0" "$RC"
assert_contains "--host all includes self" "live" "$(row "$OUT" r-alpha)"
assert_eq "--host all: legacy note on self row" "desk" "$(row "$OUT" r-legacy | awk '{print $2}')"
assert_not_contains "--host all: no --host all hint" "hint:" "$OUT"
assert_contains "--host all includes remote2"   "live" "$(row "$OUT" r-remote2)"
assert_contains "--host all includes homeserver" "live" "$(row "$OUT" r-media)"
assert_eq "--host all: homeserver row has host=homeserver" "homeserver" "$(row "$OUT" r-media | awk '{print $2}')"

# ssh failure on the remote host is reported, never read as "nothing live"
cat >"$TMP/dead-ssh" <<'EOF'
#!/usr/bin/env bash
echo "ssh: connect to host remote2-ssh: No route to host" >&2
exit 255
EOF
chmod +x "$TMP/dead-ssh"
: >"$LLOG"
OUT="$(BRAIN_SSH="$TMP/dead-ssh" revive --host remote2 --apply 2>&1)"; RC=$?
assert_eq "unreachable host → rc 1" "1" "$RC"
assert_contains "unreachable host reported" "remote2" "$OUT"
assert_eq "unreachable host → no launches" "" "$(cat "$LLOG")"

# ---- a second vault: sessions lost WITHOUT a reboot, and a transcript with no id -----
V2="$TMP/vault2"; mkdir -p "$V2/workers"
note2() { local slug="$1"; shift; note "$slug" "$@"; mv "$V/workers/$slug.md" "$V2/workers/"; }
revive2() { HOME="$LH" bash "$REVIVE" --vault "$V2" --boot-time "$BOOT" --shutdown-time "$SHUT" "$@"; }
RX=aaaa0000-0000-4000-8000-0000000000c1
RY=aaaa0000-0000-4000-8000-0000000000c2
T_CRASH=$((BOOT + 5000))          # a gnome-shell crash / logout long after boot
note2 r-crashed "host: desk" "harness: claude" "project_dir: ~/projects/brain" "status: working" "session_id: $RX"
note2 r-resumed "host: desk" "harness: claude" "project_dir: ~/projects/brain" "status: working" "session_id: $RY"
note2 r-nosess  "host: desk" "harness: omp" "project_dir: ~/projects/brain" "status: working"
claude_transcript "$LH" "$P" "$RX" "first" "$((T_CRASH - 20))" >/dev/null
claude_transcript "$LH" "$P" "$RY" "first" "$((T_CRASH - 20))" >/dev/null
F_RNS="$(omp_transcript "$LH" -projects-brain 01a0eeee-0000-70da-bde2-0000000000c3 "$(sentence r-nosess)" "$T_LIVE")"
sed -i.bak '/"type":"session"/d' "$F_RNS" && rm -f "$F_RNS.bak"; stamp "$F_RNS" "$T_LIVE"
printf 'brain-worker-r-resumed\n' >>"$TSF"

: >"$LLOG"
OUT="$(revive2 2>&1)"; RC=$?
assert_eq "vault2 dry run → rc 0" "0" "$RC"
assert_contains "touched since boot, no tmux session → dead-since-boot" "dead-since-boot" "$(row "$OUT" r-crashed)"
assert_contains "touched since boot, tmux session up → already-running" "already-running" "$(row "$OUT" r-resumed)"
assert_contains "no-id omp transcript → table session_id '-'" " - " "$(row "$OUT" r-nosess)"
assert_not_contains "no-id omp transcript → path never in the table" "$F_RNS" "$(row "$OUT" r-nosess)"
assert_contains "dead-since-boot gets a hint line" "dead since boot" "$OUT"
OUT="$(revive2 --apply 2>&1)"; RC=$?
assert_not_contains "--apply never revives dead-since-boot" "r-crashed" "$(cat "$LLOG")"
assert_not_contains "--apply never passes a path as --resume" "--resume /" "$(cat "$LLOG")"
assert_contains "--apply: live row without an id is refused" "r-nosess: missing project_dir or session id" "$OUT"
note2 r-nossh "host: nossh" "harness: claude" "project_dir: ~/projects/brain" "tmux_session: brain-worker-r-nossh" "status: working"
OUT="$(revive2 --host nossh 2>&1)"; RC=$?
assert_eq "host with no ssh route → rc 1" "1" "$RC"
assert_contains "host with no ssh route reported with the real reason" "no ssh route from desk to nossh (hosts.conf alias -)" "$OUT"
# the crash re-run the skill prescribes: boot := re-login, shutdown := just before the crash
: >"$LLOG"
OUT="$(HOME="$LH" bash "$REVIVE" --vault "$V2" --only r-crashed --boot-time "$((T_CRASH + 60))" --shutdown-time "$T_CRASH" 2>&1)"
assert_contains "crash re-run with --boot-time/--shutdown-time → live" "live" "$(row "$OUT" r-crashed)"

# ---- a third vault: notes under private/workers (and NO workers/ dir at all) ---------
V3="$TMP/vault3"; mkdir -p "$V3/private/workers"
PA=aaaa0000-0000-4000-8000-0000000000d1
PB=aaaa0000-0000-4000-8000-0000000000d2
PC=aaaa0000-0000-4000-8000-0000000000d3
pnote() {  # pnote <slug> <frontmatter lines...>
    local slug="$1"; shift
    { printf -- '---\nslug: %s\n' "$slug"; for l in "$@"; do printf '%s\n' "$l"; done
      printf -- '---\n\n# %s\n' "$slug"; } >"$V3/private/workers/$slug.md"
}
pnote r-pall  "host: desk" "harness: claude" "project_dir: ~/projects/brain" "status: working" "session_id: $PA" "area: private" "project: brain"
pnote r-ppriv "host: desk" "harness: claude" "project_dir: ~/projects/brain" "status: working" "session_id: $PB" "area: private" "project: clientco"
pnote r-pnone "host: desk" "harness: claude" "project_dir: ~/projects/brain" "status: working" "session_id: $PC"
claude_transcript "$LH" "$P" "$PA" "first" "$T_LIVE" >/dev/null
claude_transcript "$LH" "$P" "$PB" "first" "$T_LIVE" >/dev/null
claude_transcript "$LH" "$P" "$PC" "first" "$T_LIVE" >/dev/null
: >"$LLOG"
OUT="$(HOME="$LH" bash "$REVIVE" --vault "$V3" --boot-time "$BOOT" --shutdown-time "$SHUT" 2>&1)"; RC=$?
assert_eq "private-only vault dry run → rc 0 (no workers/ dir needed)" "0" "$RC"
assert_contains "private note is a candidate (live)" "live" "$(row "$OUT" r-pall)"
assert_eq "private dry run makes no launcher calls" "" "$(cat "$LLOG")"
OUT="$(HOME="$LH" bash "$REVIVE" --vault "$V3" --boot-time "$BOOT" --shutdown-time "$SHUT" --apply 2>&1)"; RC=$?
assert_eq "private --apply → rc 0" "0" "$RC"
assert_contains "area private + project brain → --scope all --note-dir private/workers" \
    "--slug r-pall --project-dir ~/projects/brain --resume $PA --note-dir private/workers --scope all --project brain" "$(cat "$LLOG")"
assert_contains "area private + other project → --scope private --project clientco" \
    "--slug r-ppriv --project-dir ~/projects/brain --resume $PB --note-dir private/workers --scope private --project clientco" "$(cat "$LLOG")"
assert_contains "private-dir note without area → --scope private" \
    "--resume $PC --note-dir private/workers --scope private" "$(grep -- '--slug r-pnone' "$LLOG")"
# a plain workers/ note keeps today's launcher argv exactly
: >"$LLOG"
HOME="$LH" bash "$REVIVE" --vault "$V" --boot-time "$BOOT" --shutdown-time "$SHUT" --only r-alpha --apply >/dev/null 2>&1
assert_eq "workers/ note → only an explicit --scope shared is added" \
    "--host desk --harness claude --slug r-alpha --project-dir ~/projects/alpha --resume $RA --scope shared" "$(cat "$LLOG")"
# a shared note with a valid project passes --scope shared --project <p>
pnote r-pshared "host: desk" "harness: claude" "project_dir: ~/projects/brain" "status: working" "session_id: $PC" "area: work" "project: clientco"
: >"$LLOG"
HOME="$LH" bash "$REVIVE" --vault "$V3" --boot-time "$BOOT" --shutdown-time "$SHUT" --only r-pshared --apply >/dev/null 2>&1
assert_contains "shared note with project → --scope shared --project clientco" \
    "--slug r-pshared --project-dir ~/projects/brain --resume $PC --note-dir private/workers --scope shared --project clientco" "$(cat "$LLOG")"

# ---- a fourth vault: idle workers, parked/collected, resurrected shells, lost keys ----
V4="$TMP/vault4"; mkdir -p "$V4/workers"
note4() { local slug="$1"; shift; note "$slug" "$@"; mv "$V/workers/$slug.md" "$V4/workers/"; }
revive4() { HOME="$LH" bash "$REVIVE" --vault "$V4" --boot-time "$BOOT" --shutdown-time "$SHUT" "$@"; }
I1=aaaa0000-0000-4000-8000-0000000004a1; I2=aaaa0000-0000-4000-8000-0000000004a2
I3=aaaa0000-0000-4000-8000-0000000004a3; I4=aaaa0000-0000-4000-8000-0000000004a4
I5=aaaa0000-0000-4000-8000-0000000004a5; I6=aaaa0000-0000-4000-8000-0000000004a6
I7=aaaa0000-0000-4000-8000-0000000004a7; I8=aaaa0000-0000-4000-8000-0000000004a8
c4() { note4 "$1" "host: desk" "harness: claude" "project_dir: ~/projects/brain" "tmux_session: brain-worker-$1" "session_id: $2" "${@:4}"
       claude_transcript "$LH" "$P" "$2" "first" "$3" >/dev/null; }
c4 r-idle     "$I1" "$T_ENDED" "status: working" "model: claude-sonnet-5-5  # pinned at dispatch"
c4 r-zshm     "aaaa0000-0000-4000-8000-0000000004b1" "$((T_ENDED - 600))" "status: blocked" "model: claude-opus-5-5[1m]"
c4 r-badm1    "aaaa0000-0000-4000-8000-0000000004b2" "$T_LIVE" "status: working" "model: -x"
c4 r-badm2    "aaaa0000-0000-4000-8000-0000000004b3" "$T_LIVE" "status: working" "model: a;b"
c4 r-brk      "aaaa0000-0000-4000-8000-0000000004b4" "$T_LIVE" "status: working" "model: claude-opus-5-5[1m]"
c4 r-dq       "aaaa0000-0000-4000-8000-0000000004b5" "$T_LIVE" "status: working" 'model: "claude-sonnet-5-5"  # pinned'
c4 r-sq       "aaaa0000-0000-4000-8000-0000000004b6" "$T_LIVE" "status: working" "model: 'claude-sonnet-5-5'"
c4 r-idledone "$I2" "$((T_ENDED + 5))" "status: done"
c4 r-parked   "$I3" "$T_LIVE"  "status: parked"
c4 r-cstate   "$I4" "$T_LIVE"  "status: working" "collect_state: persisted"
c4 r-zsh      "$I5" "$((T_ENDED - 600))" "status: blocked"
c4 r-zshrun   "$I6" "$T_LIVE"  "status: working"
c4 r-rcno     "$I7" "$T_LIVE"  "status: working"
c4 r-never    "$I8" "$T_LIVE"  "status: working"
c4 r-stuck    "aaaa0000-0000-4000-8000-0000000004a9" "$T_LIVE"  "status: working"
printf 'brain-worker-r-zsh\nbrain-worker-r-zshrun\nbrain-worker-r-zshm\n' >>"$TSF"
for zs in r-zsh r-zshm; do
printf 'zsh\n' >"$PD/brain-worker-$zs.cmd"
printf 'example@desk ~/projects/brain %%\n' >"$PD/brain-worker-$zs.e0"
{ cat "$PD/default"; printf '  /remote-control is active · claude.ai/code\n'; } >"$PD/brain-worker-$zs.e1"
done
printf '2\n' >"$PD/brain-worker-r-rcno.busy"; : >"$PD/brain-worker-r-rcno.dialog"
{ cat "$PD/default"; printf '  /remote-control is active · claude.ai/code\n'; } >"$PD/brain-worker-r-rcno.e0"
printf '999\n' >"$PD/brain-worker-r-never.busy"
: >"$PD/brain-worker-r-stuck.dialog"; : >"$PD/brain-worker-r-stuck.dialog-stuck"

: >"$LLOG"; : >"$TLOG"
OUT="$(revive4 --only r-idle,r-idledone,r-parked,r-cstate,r-zsh,r-zshm,r-zshrun,r-rcno 2>&1)"; RC=$?
assert_eq "vault4 dry run → rc 0" "0" "$RC"
assert_contains "idle for an hour before shutdown, status working → idle-at-shutdown" "idle-at-shutdown" "$(row "$OUT" r-idle)"
assert_contains "idle row shows the shutdown it is matched to" "$(iso "$SHUT")" "$(row "$OUT" r-idle)"
assert_contains "table header has a shutdown column" "shutdown" "$(printf '%s\n' "$OUT" | grep '^slug')"
assert_contains "idle but the note says done → ended-before-shutdown" "ended-before-shutdown" "$(row "$OUT" r-idledone)"
assert_contains "status parked → parked (even when live)" "parked" "$(row "$OUT" r-parked)"
# only `status: collected` is authoritative; `collect_state: persisted` is set on every
# teardown (park included) and never means the worker is finished
assert_eq "collect_state persisted + status working → still live (not collected)" "live" "$(row "$OUT" r-cstate | awk '{print $5}')"
assert_contains "session up, every pane a bare shell → resurrected-shell" "resurrected-shell" "$(row "$OUT" r-zsh)"
assert_contains "session up, harness in the pane → already-running" "already-running" "$(row "$OUT" r-zshrun)"
assert_contains "dry run lists the revivable rows" "would resume r-cstate r-idle r-rcno r-zsh r-zshm" "$OUT"
assert_contains "cluster of transcripts sharing a minute is relayed per host" "# desk: cluster: 2 transcripts" "$OUT"
assert_eq "vault4 dry run: no launcher calls" "" "$(cat "$LLOG")"
if grep -q '^send-keys' "$TLOG"; then bad "vault4 dry run: no keystrokes"; else ok "vault4 dry run: no keystrokes"; fi

: >"$LLOG"; : >"$TLOG"
OUT="$(RC_NO_SLUG=r-rcno revive4 --apply --only r-idle,r-idledone,r-parked,r-cstate,r-zsh,r-zshm,r-zshrun,r-rcno 2>&1)"; RC=$?
assert_eq "vault4 --apply → rc 0" "0" "$RC"
assert_contains "--apply resumes an idle-at-shutdown worker by id" "--slug r-idle --project-dir ~/projects/brain --resume $I1" "$(cat "$LLOG")"
assert_not_contains "--apply never resumes parked"    "r-parked"    "$(cat "$LLOG")"
assert_contains "--apply resumes a collect_state: persisted working note" "--slug r-cstate " "$(cat "$LLOG")"
assert_not_contains "--apply never resumes idle+done" "r-idledone"  "$(cat "$LLOG")"
assert_not_contains "resurrected shell: no launcher (its session exists)" "r-zsh" "$(cat "$LLOG")"
assert_contains "resurrected shell: resume line (named --remote-control <slug>) typed into the existing pane" \
    "send-keys -t brain-worker-r-zsh claude --remote-control r-zsh --resume $I5" "$(cat "$TLOG")"
assert_eq "resurrected shell: Enter sent as its own keypress" "send-keys -t brain-worker-r-zsh Enter" \
    "$(grep '^send-keys -t brain-worker-r-zsh ' "$TLOG" | grep -A1 -- '--resume' | tail -1)"
assert_contains "resurrected shell: verified result line" \
    "verified=yes session=brain-worker-r-zsh rc=yes attach=tmux attach -t brain-worker-r-zsh session_id=$I5 mode=resume-in-pane" "$OUT"
assert_not_contains "already-running pane never typed into" "brain-worker-r-zshrun" "$(grep '^send-keys' "$TLOG")"
# P2: the resumed pane was busy for two polls, then showed RC's "already connected" dialog;
# the only keystroke is the Escape that dismisses it — no `/rc` is ever typed for claude
first_send="$(grep -n -- 'send-keys -t brain-worker-r-rcno' "$TLOG" | head -1 | cut -d: -f1)"
caps_before="$(head -n "$((first_send - 1))" "$TLOG" | grep -c 'capture-pane .*-t brain-worker-r-rcno')"
assert_eq "P2: three polls (busy, busy, dialog) before the first keystroke" "3" "$caps_before"
assert_eq "P2: the only keystroke is one Escape (dialog dismissed, never Enter)" "send-keys -t brain-worker-r-rcno Escape" \
    "$(grep 'send-keys -t brain-worker-r-rcno' "$TLOG")"
if grep -q 'send-keys .*/rc' "$TLOG"; then bad "no /rc ever typed for claude"; else ok "no /rc ever typed for claude"; fi
assert_contains "P2: verified only after the composer is ready; rc rechecked → yes; dialog reported" \
    "verified=yes session=brain-worker-r-rcno rc=yes attach=tmux attach -t brain-worker-r-rcno session_id=$I7 mode=resume rc_dialog=dismissed" "$OUT"
assert_contains "revived summary names all five" "revived: r-cstate r-idle r-rcno r-zsh r-zshm" "$OUT"
# the note's optional `model:` (trailing ` # comment` stripped) rides along on both resume paths;
# an absent one leaves both command lines exactly as before
assert_contains "model: on the note → launcher gets --model <id> (comment stripped)" \
    " --model claude-sonnet-5-5" "$(grep -- '--slug r-idle ' "$LLOG")"
assert_not_contains "no model: on the note → launcher gets no --model" "--model" "$(grep -- '--slug r-cstate ' "$LLOG")"
assert_not_contains "comment text never leaks into the launcher call" "pinned" "$(cat "$LLOG")"
assert_contains "model: on the note → resurrected-shell line carries --model <id>" \
    "send-keys -t brain-worker-r-zshm claude --model 'claude-opus-5-5[1m]' --remote-control r-zshm --resume aaaa0000-0000-4000-8000-0000000004b1" "$(cat "$TLOG")"
assert_not_contains "no model: on the note → resurrected-shell line carries no --model" "--model" "$(grep -- 'send-keys -t brain-worker-r-zsh claude' "$TLOG")"

# a bracketed id survives the filter (the launcher quotes it for the typed line); unsafe ids are dropped
: >"$LLOG"
OUT="$(revive4 --apply --only r-badm1,r-badm2,r-brk,r-dq,r-sq 2>&1)"; RC=$?
assert_contains "double-quoted model: is unquoted → --model <id>" " --model claude-sonnet-5-5" "$(grep -- '--slug r-dq ' "$LLOG")"
assert_contains "single-quoted model: is unquoted → --model <id>" " --model claude-sonnet-5-5" "$(grep -- '--slug r-sq ' "$LLOG")"
assert_not_contains "a quoted model never reaches the launcher with its quotes" "\"claude" "$(cat "$LLOG")"
assert_contains "a rejected model warns on stderr" "warning: r-badm1: model '-x' rejected, resuming on the harness default" "$OUT"
assert_contains "a rejected model warns (metacharacters)" "warning: r-badm2: model 'a;b' rejected, resuming on the harness default" "$OUT"
assert_not_contains "an accepted model does not warn" "r-brk: model" "$OUT"
assert_contains "bracketed model id survives the filter → launcher gets it" \
    "--model claude-opus-5-5[1m]" "$(grep -- '--slug r-brk ' "$LLOG")"
assert_not_contains "model: -x is rejected (no --model)" "--model" "$(grep -- '--slug r-badm1 ' "$LLOG")"
assert_not_contains "model: a;b is rejected (no --model)" "--model" "$(grep -- '--slug r-badm2 ' "$LLOG")"

: >"$LLOG"
OUT="$(revive4 --apply --only r-never 2>&1)"; RC=$?
assert_eq "composer never ready after resume → rc 1" "1" "$RC"
assert_contains "…reported verified=no" "verified=no session=brain-worker-r-never" "$OUT"
assert_contains "…with the reason" "r-never: composer not ready" "$OUT"
assert_contains "…and counted as failed" "failed: r-never" "$OUT"
: >"$TLOG"
OUT="$(revive4 --apply --only r-stuck 2>&1)"; RC=$?
assert_eq "RC dialog that will not dismiss → rc 1" "1" "$RC"
assert_contains "…reported stuck" "verified=no session=brain-worker-r-stuck rc=yes attach=tmux attach -t brain-worker-r-stuck session_id=aaaa0000-0000-4000-8000-0000000004a9 mode=resume" "$OUT"
assert_contains "…with the human fix (Continue, never Disconnect)" "pick Continue (never Disconnect)" "$OUT"
if grep -q 'send-keys -t brain-worker-r-stuck Enter' "$TLOG"; then bad "dialog never answered with Enter"; else ok "dialog never answered with Enter"; fi
# one Escape per sighting of the dialog, then only re-check: repeated Esc opens claude's
# rewind menu
assert_eq "stuck dialog: exactly one Escape across every ready poll" "1" \
    "$(grep -cx 'send-keys -t brain-worker-r-stuck Escape' "$TLOG")"

# ---- a fifth vault: idle at an OLDER journalled shutdown (the journal stub's S1) -------
# No clean exit and a note still `working`, but its last activity predates the latest
# shutdown: as likely a worker the user killed by hand (Ctrl-C ×2, kill-session) as one
# an unrevived earlier shutdown took. Shown, never auto-revived; `--only <slug>` revives it.
V5="$TMP/vault5"; mkdir -p "$V5/workers"
note5() { local slug="$1"; shift; note "$slug" "$@"; mv "$V/workers/$slug.md" "$V5/workers/"; }
revive5() { PATH="$JB:$PATH" HOME="$LH" bash "$REVIVE" --vault "$V5" --boot-time "$BOOT" "$@"; }
O1=aaaa0000-0000-4000-8000-0000000005a1; O2=aaaa0000-0000-4000-8000-0000000005a2
note5 r-oldidle "host: desk" "harness: claude" "project_dir: ~/projects/brain" "status: working" "session_id: $O1"
note5 r-newidle "host: desk" "harness: claude" "project_dir: ~/projects/brain" "status: working" "session_id: $O2"
claude_transcript "$LH" "$P" "$O1" "first" "$((S1 - 20000))" >/dev/null
claude_transcript "$LH" "$P" "$O2" "first" "$((SHUT - 10800))" >/dev/null
: >"$LLOG"
OUT="$(revive5 2>&1)"; RC=$?
assert_eq "vault5 dry run → rc 0" "0" "$RC"
assert_contains "idle before an OLDER shutdown → idle-older-shutdown" "idle-older-shutdown" "$(row "$OUT" r-oldidle)"
assert_contains "…shows the older shutdown it matched" "$(iso "$S1")" "$(row "$OUT" r-oldidle)"
assert_contains "idle before the latest shutdown → idle-at-shutdown" "idle-at-shutdown" "$(row "$OUT" r-newidle)"
assert_contains "idle-older-shutdown gets a hint naming --only" "--apply --only r-oldidle" "$OUT"
assert_contains "dry run would resume only the latest-shutdown row" "would resume r-newidle —" "$OUT"
OUT="$(revive5 --apply 2>&1)"; RC=$?
assert_not_contains "--apply never auto-revives idle-older-shutdown" "r-oldidle" "$(cat "$LLOG")"
assert_contains "--apply still revives idle-at-shutdown" "--slug r-newidle " "$(cat "$LLOG")"
: >"$LLOG"
OUT="$(revive5 --apply --only r-oldidle 2>&1)"; RC=$?
assert_eq "--apply --only <older slug> → rc 0" "0" "$RC"
assert_contains "--apply --only <slug> revives idle-older-shutdown by id" "--slug r-oldidle --project-dir ~/projects/brain --resume $O1" "$(cat "$LLOG")"

# ---- self = remote2: a host with no ssh route (desk, alias -) is not self ---------------
: >"$LLOG" ; : >"$SLOG"
OUT="$(BRAIN_SELF_HOST=remote2 revive --host all 2>"$TMP/nr.err")"; RC=$?
ERR="$(cat "$TMP/nr.err")"
assert_eq "self=remote2, --host all: a no-route host is not a host error (rc 0)" "0" "$RC"
assert_contains "self=remote2, --host all: no-route host skipped with an info line" \
    "revive-workers: skipping host desk: no ssh route from remote2 to desk (hosts.conf alias -)" "$ERR"
assert_not_contains "self=remote2, --host all: no 'could not query' for desk" "could not query host desk" "$ERR"
assert_eq "self=remote2, --host all: desk rows absent" "" "$(row "$OUT" r-alpha)"
assert_not_contains "self=remote2, --host all: no unreachable-hosts summary" "unreachable hosts" "$OUT"
assert_not_contains "self=remote2, --host all: ssh never asked for desk" " - bash" "$(cat "$SLOG")"
OUT="$(BRAIN_SELF_HOST=remote2 revive --host desk 2>&1)"; RC=$?
assert_eq "self=remote2, explicit --host desk (no route) → rc 1" "1" "$RC"
assert_contains "self=remote2, explicit --host desk → clear reason" "no ssh route from remote2 to desk (hosts.conf alias -)" "$OUT"
assert_eq "self=remote2, explicit --host desk → no launches" "" "$(cat "$LLOG")"

# ---- self unresolved: legacy notes are skipped, and the skip is summarised once -------
OUT="$(BRAIN_HOSTNAME=strangebox revive --host all 2>&1)"; RC=$?
assert_contains "self unresolved, --host all: legacy skip summary" \
    "2 legacy notes skipped: this machine is not in hosts.conf (set BRAIN_SELF_HOST or add its hostname)" "$OUT"
assert_eq "…printed once" "1" "$(printf '%s\n' "$OUT" | grep -c 'legacy notes skipped')"
OUT="$(BRAIN_HOSTNAME=strangebox revive --host homeserver 2>&1)"; RC=$?
assert_contains "self unresolved, explicit --host homeserver: legacy skip summary" \
    "2 legacy notes skipped: this machine is not in hosts.conf" "$OUT"
OUT="$(BRAIN_HOSTNAME=strangebox revive --host homeserver --only r-media 2>&1)"
assert_not_contains "no legacy notes in scope → no summary" "legacy notes skipped" "$OUT"
OUT="$(revive --host all 2>&1)"
assert_not_contains "self resolved → no legacy skip summary" "legacy notes skipped" "$OUT"

# ---- a note whose host is not in hosts.conf (a retired machine) -----------------------
# Collected: historic record, ignored silently. Uncollected: ONE warning naming slug + host,
# skipped, never fatal. A separate vault so the notes above keep their counts.
V6="$TMP/vault6"; mkdir -p "$V6/workers"
{ printf -- '---\nslug: r-retired-coll\nhost: mac\nharness: claude\nproject_dir: ~/projects/brain\ntmux_session: brain-worker-r-retired-coll\nstatus: collected\n---\n'; } >"$V6/workers/r-retired-coll.md"
{ printf -- '---\nslug: r-retired-live\nhost: mac\nharness: claude\nproject_dir: ~/projects/brain\ntmux_session: brain-worker-r-retired-live\nstatus: working\n---\n'; } >"$V6/workers/r-retired-live.md"
: >"$LLOG"
for sel in all desk; do
    OUT="$(HOME="$LH" bash "$REVIVE" --vault "$V6" --boot-time "$BOOT" --shutdown-time "$SHUT" --host "$sel" --apply 2>"$TMP/uh.err")"; RC=$?
    ERR="$(cat "$TMP/uh.err")"
    assert_eq "unknown host (--host $sel): rc unaffected" "0" "$RC"
    assert_not_contains "unknown host (--host $sel): collected note never mentioned" "r-retired-coll" "$ERR$OUT"
    assert_contains "unknown host (--host $sel): uncollected note warns slug + host" "warning: r-retired-live: unknown host 'mac' (not in hosts.conf)" "$ERR"
    assert_eq "unknown host (--host $sel): exactly one warning" "1" "$(printf '%s\n' "$ERR" | grep -c 'unknown host')"
    assert_eq "unknown host (--host $sel): no row for it" "" "$(row "$OUT" r-retired-live)"
    assert_eq "unknown host (--host $sel): never launched" "" "$(cat "$LLOG")"
done

# usage errors
revive --bogus >/dev/null 2>&1; RC=$?
assert_eq "unknown flag → rc 2" "2" "$RC"
revive --host nowhere >/dev/null 2>&1; RC=$?
assert_eq "unknown host → rc 2" "2" "$RC"
OUT="$(BRAIN_HOSTNAME=strangebox revive 2>&1)"; RC=$?
assert_eq "self host unresolved, default --host → rc 2" "2" "$RC"
assert_contains "unresolved self names the fix" "BRAIN_SELF_HOST" "$OUT"
OUT="$(BRAIN_HOSTNAME=strangebox revive --host local 2>&1)"; RC=$?
assert_eq "self host unresolved, --host local → rc 2" "2" "$RC"
OUT="$(BRAIN_HOSTNAME=strangebox BRAIN_SELF_HOST=remote2 revive --host homeserver 2>&1)"; RC=$?
assert_eq "BRAIN_SELF_HOST=remote2: --host homeserver still works" "0" "$RC"
OUT="$(BRAIN_HOSTNAME=strangebox BRAIN_SELF_HOST=nowhere revive 2>&1)"; RC=$?
assert_eq "BRAIN_SELF_HOST naming no row → rc 2" "2" "$RC"
revive --window >/dev/null 2>&1; RC=$?
assert_eq "flag missing its value → rc 2" "2" "$RC"
HOME="$LH" bash "$REVIVE" --vault "$TMP/novault" >/dev/null 2>&1; RC=$?
assert_eq "missing vault workers dir → rc 2" "2" "$RC"

echo
printf 'revive-scripts: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
