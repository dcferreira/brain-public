#!/usr/bin/env bash
#
# Tests for forge.sh — the forge axis (GitHub today): parse a PR reference into the
# normalised `github:<owner>/<repo>#<n>` form and read one PR's state as a single
# `<state> <head7> <mergeable> <checks>` line. Runs OFFLINE: gh is a stub (BRAIN_GH)
# that logs its argv and prints a canned `gh pr view --json` document, or fails.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# stub gh: logs argv; prints $GH_JSON, or with $GH_FAIL set prints it on stderr, rc 1.
GLOG="$TMP/gh.log"; : >"$GLOG"
cat >"$TMP/fake-gh" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$GLOG"
if [ -n "\${GH_FAIL:-}" ]; then printf '%s\n' "\$GH_FAIL" >&2; exit 1; fi
cat "\$GH_JSON"
EOF
chmod +x "$TMP/fake-gh"
export BRAIN_GH="$TMP/fake-gh"

# shellcheck source=forge.sh
source "$HERE/forge.sh"

PASS=0 FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
assert_false() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$d"; else ok "$d"; fi; }
assert_eq()    { local d="$1" want="$2" got="$3"; if [ "$want" = "$got" ]; then ok "$d"; else bad "$d (want '$want' got '$got')"; fi; }
assert_contains() { local d="$1" needle="$2" haystack="$3"; case "$haystack" in *"$needle"*) ok "$d" ;; *) bad "$d (missing '$needle' in '$haystack')" ;; esac; }

echo "pr_ref_parse:"
assert_eq "PR URL"                      "github:example/budgebell#9"  "$(pr_ref_parse https://github.com/example/budgebell/pull/9)"
assert_eq "PR URL + /files"             "github:example/budgebell#9"  "$(pr_ref_parse https://github.com/example/budgebell/pull/9/files)"
assert_eq "PR URL + #fragment"          "github:example/budgebell#9"  "$(pr_ref_parse 'https://github.com/example/budgebell/pull/9#issuecomment-1')"
assert_eq "PR URL + ?query"             "github:example/budgebell#9"  "$(pr_ref_parse 'https://github.com/example/budgebell/pull/9?w=1')"
assert_eq "PR URL, trailing /"          "github:example/budgebell#9"  "$(pr_ref_parse https://github.com/example/budgebell/pull/9/)"
assert_eq "dots/underscores in names"   "github:d.c_f/agent-pawl.go#123" "$(pr_ref_parse https://github.com/d.c_f/agent-pawl.go/pull/123)"
assert_eq "o/r#N short form"            "github:example/brain#4"      "$(pr_ref_parse example/brain#4)"
assert_eq "normalised form is idempotent" "github:example/brain#4"    "$(pr_ref_parse github:example/brain#4)"
assert_eq "owner/repo lowercased (GitHub names are case-insensitive)" "github:example/brain#4" "$(pr_ref_parse https://github.com/EXAMPLE/Brain/pull/4)"
assert_eq "…in the short form too"      "github:example/brain#4"      "$(pr_ref_parse EXAMPLE/Brain#4)"
assert_false "GitLab MR URL → rc 1"       pr_ref_parse https://gitlab.com/g/p/-/merge_requests/3
assert_false "GitHub issue URL → rc 1"    pr_ref_parse https://github.com/example/brain/issues/4
assert_false "GitHub repo URL → rc 1"     pr_ref_parse https://github.com/example/brain
assert_false "trailing junk after N → rc 1" pr_ref_parse 'https://github.com/example/brain/pull/9)'
assert_false "non-numeric N → rc 1"       pr_ref_parse 'example/brain#x'
assert_false "bare #N → rc 1"             pr_ref_parse '#4'
assert_false "empty → rc 1"               pr_ref_parse ''
assert_eq "unsupported prints nothing"   "" "$(pr_ref_parse https://gitlab.com/g/p/-/merge_requests/3 2>/dev/null)"

# view <state> <isDraft> <mergeable> <rollup-json-array> — writes the canned gh document
OID=0123456789abcdef0123456789abcdef01234567
view() {
    printf '{"state":"%s","isDraft":%s,"headRefOid":"%s","mergeable":"%s","statusCheckRollup":%s}\n' \
        "$1" "$2" "$OID" "$3" "$4" >"$TMP/view.json"
    export GH_JSON="$TMP/view.json"
}
CR_OK='{"__typename":"CheckRun","name":"test","status":"COMPLETED","conclusion":"SUCCESS"}'
CR_SKIP='{"__typename":"CheckRun","name":"lint","status":"COMPLETED","conclusion":"SKIPPED"}'
CR_RUN='{"__typename":"CheckRun","name":"test","status":"IN_PROGRESS","conclusion":""}'
CR_QUEUED='{"__typename":"CheckRun","name":"test","status":"QUEUED","conclusion":null}'
CR_FAIL='{"__typename":"CheckRun","name":"test","status":"COMPLETED","conclusion":"FAILURE"}'
CR_CANC='{"__typename":"CheckRun","name":"test","status":"COMPLETED","conclusion":"CANCELLED"}'
CR_TIME='{"__typename":"CheckRun","name":"test","status":"COMPLETED","conclusion":"TIMED_OUT"}'
CR_ACT='{"__typename":"CheckRun","name":"test","status":"COMPLETED","conclusion":"ACTION_REQUIRED"}'
SC_OK='{"__typename":"StatusContext","context":"ci/x","state":"SUCCESS"}'
SC_PEND='{"__typename":"StatusContext","context":"ci/x","state":"PENDING"}'
SC_ERR='{"__typename":"StatusContext","context":"ci/x","state":"ERROR"}'

echo "pr_status:"
view OPEN false MERGEABLE "[$CR_OK,$CR_SKIP]"
assert_eq "open, all passed/skipped, mergeable" "OPEN 0123456 MERGEABLE pass" "$(pr_status github:example/brain#4)"
assert_contains "one gh pr view call with -R and --json" \
    "pr view 4 -R example/brain --json state,isDraft,headRefOid,mergeable,statusCheckRollup" "$(cat "$GLOG")"
view OPEN true MERGEABLE "[$CR_OK]"
assert_eq "open + isDraft → DRAFT"            "DRAFT 0123456 MERGEABLE pass" "$(pr_status github:example/brain#4)"
view MERGED false UNKNOWN "[$CR_OK]"
assert_eq "merged"                            "MERGED 0123456 UNKNOWN pass" "$(pr_status github:example/brain#4)"
view CLOSED false UNKNOWN "[]"
assert_eq "closed unmerged, empty rollup → none" "CLOSED 0123456 UNKNOWN none" "$(pr_status github:example/brain#4)"
view OPEN false MERGEABLE null
assert_eq "null rollup → none"                "OPEN 0123456 MERGEABLE none" "$(pr_status github:example/brain#4)"
view OPEN false CONFLICTING "[$CR_OK]"
assert_eq "conflicting"                       "OPEN 0123456 CONFLICTING pass" "$(pr_status github:example/brain#4)"
view OPEN false MERGEABLE "[$CR_OK,$CR_RUN]"
assert_eq "one check in progress → pending"   "OPEN 0123456 MERGEABLE pending" "$(pr_status github:example/brain#4)"
view OPEN false MERGEABLE "[$CR_QUEUED]"
assert_eq "queued (null conclusion) → pending" "OPEN 0123456 MERGEABLE pending" "$(pr_status github:example/brain#4)"
view OPEN false MERGEABLE "[$CR_RUN,$CR_FAIL]"
assert_eq "a failure wins over pending → fail" "OPEN 0123456 MERGEABLE fail" "$(pr_status github:example/brain#4)"
for c in "$CR_CANC" "$CR_TIME" "$CR_ACT" "$SC_ERR"; do
    view OPEN false MERGEABLE "[$CR_OK,$c]"
    assert_eq "fail conclusion/state: $(printf '%s' "$c" | jq -r '.conclusion // .state')" \
        "OPEN 0123456 MERGEABLE fail" "$(pr_status github:example/brain#4)"
done
view OPEN false MERGEABLE "[$SC_OK]"
assert_eq "status context success → pass"     "OPEN 0123456 MERGEABLE pass" "$(pr_status github:example/brain#4)"
view OPEN false MERGEABLE "[$SC_OK,$SC_PEND]"
assert_eq "status context pending → pending"  "OPEN 0123456 MERGEABLE pending" "$(pr_status github:example/brain#4)"

echo "pr_status: superseded runs (same name / context) — only the most recent counts:"
# run <name> <conclusion> <startedAt> <completedAt> — a completed CheckRun with timestamps
run() { printf '{"__typename":"CheckRun","name":"%s","status":"COMPLETED","conclusion":"%s","startedAt":"%s","completedAt":"%s"}' "$@"; }
FRAG="Fragment + no hand-bumped version"
# agent-pawl PR 88's shape, with the newer SUCCESS listed BEFORE the older CANCELLED so
# array order alone would get it wrong
view OPEN false MERGEABLE "[$(run "$FRAG" SUCCESS 2026-10-16T10:22:50Z 2026-10-16T10:22:54Z),$(run Lint SUCCESS 2026-10-16T10:22:42Z 2026-10-16T10:23:30Z),$(run "$FRAG" CANCELLED 2026-10-16T10:22:42Z 2026-10-16T10:22:47Z)]"
assert_eq "cancelled run superseded by a success → pass" "OPEN 0123456 MERGEABLE pass" "$(pr_status github:example/brain#4)"
view OPEN false MERGEABLE "[$(run "$FRAG" FAILURE 2026-10-16T11:00:00Z 2026-10-16T11:01:00Z),$(run "$FRAG" SUCCESS 2026-10-16T10:00:00Z 2026-10-16T10:01:00Z)]"
assert_eq "success superseded by a failure → fail" "OPEN 0123456 MERGEABLE fail" "$(pr_status github:example/brain#4)"
view OPEN false MERGEABLE "[$(run "$FRAG" CANCELLED 2026-10-16T10:22:42Z 2026-10-16T10:22:47Z),$(run Lint SUCCESS 2026-10-16T10:22:42Z 2026-10-16T10:23:30Z)]"
assert_eq "the only run cancelled → fail" "OPEN 0123456 MERGEABLE fail" "$(pr_status github:example/brain#4)"
view OPEN false MERGEABLE "[$(run "$FRAG" SUCCESS 2026-10-16T10:00:00Z 2026-10-16T10:09:00Z),$(run "$FRAG" CANCELLED 2026-10-16T10:00:00Z 2026-10-16T10:01:00Z)]"
assert_eq "same startedAt → the later completedAt wins" "OPEN 0123456 MERGEABLE pass" "$(pr_status github:example/brain#4)"
view OPEN false MERGEABLE "[$(run "$FRAG" CANCELLED 2026-10-16T10:00:00Z 2026-10-16T10:01:00Z),$(run Other CANCELLED 2026-10-16T10:00:00Z 2026-10-16T10:01:00Z),$(run "$FRAG" SUCCESS 2026-10-16T10:05:00Z 2026-10-16T10:06:00Z)]"
assert_eq "a different name is not superseded" "OPEN 0123456 MERGEABLE fail" "$(pr_status github:example/brain#4)"
view OPEN false MERGEABLE "[$SC_ERR,$SC_OK]"
assert_eq "status contexts without timestamps → array position, later wins" "OPEN 0123456 MERGEABLE pass" "$(pr_status github:example/brain#4)"
view OPEN false MERGEABLE "[$SC_OK,{\"__typename\":\"StatusContext\",\"context\":\"ci/y\",\"state\":\"ERROR\"}]"
assert_eq "status contexts dedupe by context only" "OPEN 0123456 MERGEABLE fail" "$(pr_status github:example/brain#4)"
# wrun <workflow> <name> <conclusion> <startedAt> — a CheckRun of a named workflow
wrun() { printf '{"__typename":"CheckRun","workflowName":"%s","name":"%s","status":"COMPLETED","conclusion":"%s","startedAt":"%s","completedAt":"%s"}' "$1" "$2" "$3" "$4" "$4"; }
view OPEN false MERGEABLE "[$(wrun CI test FAILURE 2026-10-16T10:00:00Z),$(wrun Lint test SUCCESS 2026-10-16T10:05:00Z)]"
assert_eq "same job name in two workflows is not superseded" "OPEN 0123456 MERGEABLE fail" "$(pr_status github:example/brain#4)"
view OPEN false MERGEABLE "[$(wrun CI test FAILURE 2026-10-16T10:00:00Z),$(wrun CI test SUCCESS 2026-10-16T10:05:00Z)]"
assert_eq "…but a re-run within one workflow is" "OPEN 0123456 MERGEABLE pass" "$(pr_status github:example/brain#4)"

view OPEN false WEIRD "[$CR_OK]"
assert_eq "unknown mergeable value → UNKNOWN" "OPEN 0123456 UNKNOWN pass" "$(pr_status github:example/brain#4)"

echo "pr_status failures:"
ERR="$(GH_FAIL='GraphQL: Could not resolve to a PullRequest with the number of 4.' pr_status github:example/brain#4 2>&1 >/dev/null)"; RC=$?
assert_eq       "gh failure → rc ≠ 0" "1" "$([ "$RC" -ne 0 ] && echo 1 || echo 0)"
assert_contains "gh's message on stderr" "Could not resolve to a PullRequest" "$ERR"
assert_eq       "gh failure prints nothing on stdout" "" "$(GH_FAIL=boom pr_status github:example/brain#4 2>/dev/null)"
printf 'not json\n' >"$TMP/bad.json"
ERR="$(GH_JSON="$TMP/bad.json" pr_status github:example/brain#4 2>&1 >/dev/null)"; RC=$?
assert_eq       "unparseable gh output → rc ≠ 0" "1" "$([ "$RC" -ne 0 ] && echo 1 || echo 0)"
assert_contains "…and says so" "unexpected gh output" "$ERR"
assert_false    "unsupported ref → rc ≠ 0" pr_status gitlab:g/p#3
assert_false    "garbage ref → rc ≠ 0"     pr_status nonsense

echo "pr_status: a hung gh is cut off (when timeout/gtimeout exists):"
printf '#!/usr/bin/env bash\nexec sleep 20\n' >"$TMP/slow-gh"; chmod +x "$TMP/slow-gh"
view OPEN false MERGEABLE "[$CR_OK]"
if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
    S0=$SECONDS
    ERR="$(BRAIN_GH="$TMP/slow-gh" BRAIN_GH_TIMEOUT=1 pr_status github:example/brain#4 2>&1 >/dev/null)"; RC=$?
    assert_eq       "hung gh → rc ≠ 0" "1" "$([ "$RC" -ne 0 ] && echo 1 || echo 0)"
    assert_contains "…saying it timed out" "gh timed out after 1s" "$ERR"
    assert_eq       "…within a few seconds" "1" "$([ $((SECONDS - S0)) -lt 8 ] && echo 1 || echo 0)"
    assert_eq       "a 'command <gh>' BRAIN_GH still runs under the timeout" "OPEN 0123456 MERGEABLE pass" \
        "$(BRAIN_GH="command $TMP/fake-gh" pr_status github:example/brain#4)"
else
    ok "no timeout/gtimeout on this machine: gh runs unwrapped (skipped)"
fi
assert_eq "without any timeout command gh still runs" "OPEN 0123456 MERGEABLE pass" \
    "$(FORGE_TIMEOUT_CMDS=none pr_status github:example/brain#4)"

echo "source-safe under set -euo pipefail:"
OUT="$(bash -c "set -euo pipefail; source '$HERE/forge.sh'; pr_ref_parse nope || echo survived" 2>&1)"
assert_eq "failing pr_ref_parse does not exit the caller" "survived" "$OUT"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
