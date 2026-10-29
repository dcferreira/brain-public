#!/usr/bin/env bash
#
# Tests for brain-session-start.sh. Builds a temp vault with shared and private
# notes plus a stub qmd, and runs the hook against them — never the real vault
# or qmd. Covers: shared scope never leaks private content (top of mind, latest
# session, related notes), private/all include it, a missing private/ is fine,
# and the project header. The hook must exit 0 in every case.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
HOOK="$HERE/brain-session-start.sh"

PASS=0 FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
assert_true()  { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
assert_false() { local d="$1"; shift; if "$@"; then bad "$d"; else ok "$d"; fi; }
assert_eq()    { local d="$1" want="$2" got="$3"; if [ "$want" = "$got" ]; then ok "$d"; else bad "$d (want '$want' got '$got')"; fi; }
has() { printf '%s' "$OUT" | grep -qF -- "$1"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

V="$TMP/vault"
mkdir -p "$V/00-home" "$V/sessions" "$V/knowledge" "$V/private/sessions" "$V/private/knowledge"
echo "SHARED_TOM" >"$V/00-home/top-of-mind.md"
echo "PRIVATE_TOM_SENTINEL" >"$V/private/private.md"
echo "SHARED_SESSION" >"$V/sessions/2026-10-01 a.md"
echo "PRIVATE_SESSION_SENTINEL" >"$V/private/sessions/2026-10-02 b.md"
printf -- '---\nproject: clientco\n---\n# x\nbody\n' >"$V/knowledge/x.md"
printf '# p\nbody\n' >"$V/private/knowledge/p.md"

# Stub qmd: logs argv; default index -> shared hit, `--index private` -> private hit.
STUB="$TMP/qmd"
LOG="$TMP/qmd.log"
cat >"$STUB" <<'STUBEOF'
#!/usr/bin/env bash
echo "$*" >>"$QMD_LOG"
if [ "${1:-}" = "--index" ] && [ "${2:-}" = "private" ]; then
  echo '[{"score":0.8,"file":"qmd://private/knowledge/p.md?index=private","title":"p","snippet":"PRIVATE_HIT_SENTINEL"}]'
else
  echo '[{"score":0.9,"file":"qmd://vault/knowledge/x.md","title":"x","snippet":"SHARED_HIT"}]'
fi
STUBEOF
chmod +x "$STUB"

run_hook() { # env assignments as args
  : >"$LOG"
  OUT="$(printf '{"session_id":"s1","cwd":"/x/clientco"}' | env -u BRAIN_SCOPE -u BRAIN_PROJECT \
    BRAIN_VAULT="$V" BRAIN_QMD="$STUB" BRAIN_BIN="$REPO/bin" QMD_LOG="$LOG" "$@" bash "$HOOK" 2>/dev/null)"
  RC=$?
}

echo "scope unset:"
run_hook
assert_eq   "exits 0"                  "0" "$RC"
assert_true "top of mind"              has SHARED_TOM
assert_true "latest session"           has SHARED_SESSION
assert_true "scope line shared"        has "Vault scope for this session: shared"
assert_eq   "session id is line 1"     "This session's id is s1 (harness: claude-code)" "$(printf '%s\n' "$OUT" | head -1)"
assert_eq   "session id appears once"  "1" "$(printf '%s\n' "$OUT" | grep -c "This session's id is")"
assert_true "shared related hit"       has SHARED_HIT
assert_false "no private sentinel"     bash -c 'printf "%s" "$1" | grep -qE "PRIVATE_.*SENTINEL"' _ "$OUT"
assert_false "private index not queried" grep -q -- '--index private' "$LOG"

echo "scope garbage:"
run_hook BRAIN_SCOPE=garbage
assert_eq   "exits 0"                  "0" "$RC"
assert_true "scope line shared"        has "Vault scope for this session: shared"
assert_false "no private sentinel"     bash -c 'printf "%s" "$1" | grep -qE "PRIVATE_.*SENTINEL"' _ "$OUT"

echo "scope all:"
run_hook BRAIN_SCOPE=all
assert_eq   "exits 0"                  "0" "$RC"
assert_true "private top of mind"      has PRIVATE_TOM_SENTINEL
assert_true "private session"          has PRIVATE_SESSION_SENTINEL
assert_false "older shared session not latest" has SHARED_SESSION
assert_true "private hit"              has PRIVATE_HIT_SENTINEL
assert_true "scope line all"           has "Vault scope for this session: all"

echo "scope private:"
run_hook BRAIN_SCOPE=private
assert_eq   "exits 0"                  "0" "$RC"
assert_true "private top of mind"      has PRIVATE_TOM_SENTINEL

echo "private/ missing:"
mv "$V/private" "$TMP/private.away"
run_hook BRAIN_SCOPE=all
assert_eq   "exits 0"                  "0" "$RC"
assert_true "shared session present"   has SHARED_SESSION
mv "$TMP/private.away" "$V/private"

echo "project:"
run_hook BRAIN_PROJECT=clientco
assert_eq   "exits 0"                  "0" "$RC"
assert_true "header names project"     has "RELATED NOTES (project: clientco)"
assert_false "--project not passed to qmd" grep -q -- '--project' "$LOG"
assert_true "scope line has project"   has ", project: clientco"

echo "helpers missing:"
run_hook BRAIN_BIN="$TMP/nonexistent"
assert_eq   "exits 0"                  "0" "$RC"
assert_true "top of mind"              has SHARED_TOM
assert_false "no private sentinel"     bash -c 'printf "%s" "$1" | grep -qE "PRIVATE_.*SENTINEL"' _ "$OUT"
run_hook BRAIN_BIN="$TMP/nonexistent" BRAIN_SCOPE=all
assert_false "no private even with BRAIN_SCOPE=all" bash -c 'printf "%s" "$1" | grep -qE "PRIVATE_.*SENTINEL"' _ "$OUT"

echo "top-of-mind size warning:"
run_hook
assert_false "no warning under 40 KB"   has "top-of-mind.md is"
cp "$V/00-home/top-of-mind.md" "$TMP/tom.bak"
head -c 45000 /dev/zero | tr '\0' 'x' >>"$V/00-home/top-of-mind.md"
run_hook
assert_eq   "exits 0"                  "0" "$RC"
assert_eq   "warning is line 2"        "⚠ top-of-mind.md is 43 KB — run brain-sweep (or brain-plan-day) to archive done items." "$(printf '%s\n' "$OUT" | sed -n 2p)"
assert_eq   "session id still line 1"  "This session's id is s1 (harness: claude-code)" "$(printf '%s\n' "$OUT" | head -1)"
mv "$TMP/tom.bak" "$V/00-home/top-of-mind.md"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
