#!/usr/bin/env bash
#
# Smoke test for omp/brain-vault.ts buildContext(), mirroring
# claude/hooks/brain-session-start.test.sh: temp vault + stub qmd, never the real
# vault or qmd. Needs bun; without it the test is skipped (exit 0).

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
TS="$HERE/brain-vault.ts"

if ! command -v bun >/dev/null 2>&1; then
  echo "brain-vault.smoke.sh: bun not installed - skipping"
  exit 0
fi

PASS=0 FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
assert_true()  { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
assert_false() { local d="$1"; shift; if "$@"; then bad "$d"; else ok "$d"; fi; }
has() { printf '%s' "$OUT" | grep -qF -- "$1"; }
leaks() { printf '%s' "$OUT" | grep -qE "PRIVATE_.*SENTINEL"; }

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

STUB="$TMP/qmd"
cat >"$STUB" <<'STUBEOF'
#!/usr/bin/env bash
if [ "${1:-}" = "--index" ] && [ "${2:-}" = "private" ]; then
  echo '[{"score":0.8,"file":"qmd://private/knowledge/p.md?index=private","title":"p","snippet":"PRIVATE_HIT_SENTINEL"}]'
else
  echo '[{"score":0.9,"file":"qmd://vault/knowledge/x.md","title":"x","snippet":"SHARED_HIT"}]'
fi
STUBEOF
chmod +x "$STUB"

run() { # env assignments as args
  OUT="$(env -u BRAIN_SCOPE -u BRAIN_PROJECT BRAIN_VAULT="$V" BRAIN_QMD="$STUB" BRAIN_BIN="$REPO/bin" "$@" \
    bun -e 'const m = await import(process.argv[1]); process.stdout.write((await m.buildContext("/x/clientco", "s1")) ?? "")' "$TS" 2>"$TMP/err")"
  RC=$?
}

echo "scope unset:"
run
assert_true  "runs"                 test "$RC" -eq 0
assert_true  "top of mind"          has SHARED_TOM
assert_true  "latest session"       has SHARED_SESSION
assert_true  "scope line shared"    has "Vault scope for this session: shared"
assert_true  "shared related hit"   has SHARED_HIT
assert_true  "omp harness line"     has "(harness: omp)"
assert_false "no private sentinel"  leaks

echo "scope garbage:"
run BRAIN_SCOPE=garbage
assert_true  "scope line shared"    has "Vault scope for this session: shared"
assert_false "no private sentinel"  leaks

echo "scope all:"
run BRAIN_SCOPE=all
assert_true  "private top of mind"  has PRIVATE_TOM_SENTINEL
assert_true  "private session"      has PRIVATE_SESSION_SENTINEL
assert_false "older shared session not latest" has SHARED_SESSION
assert_true  "private hit"          has PRIVATE_HIT_SENTINEL
assert_true  "private today wording" has "private ones in private/private.md"

echo "private/ missing:"
mv "$V/private" "$TMP/private.away"
run BRAIN_SCOPE=all
assert_true  "runs"                 test "$RC" -eq 0
assert_true  "shared session present" has SHARED_SESSION
mv "$TMP/private.away" "$V/private"

echo "project:"
run BRAIN_PROJECT=clientco
assert_true  "header names project" has "RELATED NOTES (project: clientco)"
assert_true  "scope line has project" has ", project: clientco"

echo "brain-search missing:"
run BRAIN_BIN="$TMP/nonexistent" PATH="$TMP/emptybin:/usr/bin:/bin" BRAIN_SCOPE=all
assert_true  "runs"                 test "$RC" -eq 0
assert_true  "top of mind"          has SHARED_TOM
assert_false "no related notes"     has "RELATED NOTES"

echo "top-of-mind size warning:"
run
assert_false "no warning under 40 KB" has "top-of-mind.md is"
head -c 45000 /dev/zero | tr '\0' 'x' >>"$V/00-home/top-of-mind.md"
run
assert_true  "warning is line 2" test "$(printf '%s\n' "$OUT" | sed -n 2p)" = "⚠ top-of-mind.md is 43 KB — run brain-sweep (or brain-plan-day) to archive done items."

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
