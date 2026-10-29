#!/usr/bin/env bash
#
# Tests for install.sh. Builds a fake BRAIN_ROOT with skills/{a,_shared,b}, only
# `a` and `b` having a SKILL.md, and a temp HOME, then runs install.sh against
# them — never the real ~/.claude. Covers: symlinks a and b, skips _shared,
# idempotent second run, replaces a stale symlink pointing elsewhere, prunes
# dangling links into BRAIN_ROOT/skills (only those), and reports
# this machine's hosts.conf name (`self host: <name>`) or warns without failing.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PASS=0 FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
assert_true()  { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
assert_false() { local d="$1"; shift; if "$@"; then bad "$d"; else ok "$d"; fi; }
assert_eq()    { local d="$1" want="$2" got="$3"; if [ "$want" = "$got" ]; then ok "$d"; else bad "$d (want '$want' got '$got')"; fi; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

BRAIN_ROOT="$TMP/brain-root"
HOME_DIR="$TMP/home"
mkdir -p "$BRAIN_ROOT/skills/a" "$BRAIN_ROOT/skills/_shared" "$BRAIN_ROOT/skills/b" "$HOME_DIR"
: >"$BRAIN_ROOT/skills/a/SKILL.md"
: >"$BRAIN_ROOT/skills/b/SKILL.md"
# _shared deliberately gets no SKILL.md, matching the real repo's shared lib dir.

run_install() {
  BRAIN_ROOT="$BRAIN_ROOT" HOME="$HOME_DIR" bash "$HERE/install.sh"
}

echo "first run:"
out1="$(run_install)"
rc1=$?
assert_eq   "exits 0"                      "0" "$rc1"
assert_true "links a"                      test -L "$HOME_DIR/.claude/skills/a"
assert_true "links b"                      test -L "$HOME_DIR/.claude/skills/b"
assert_false "does not link _shared"       test -e "$HOME_DIR/.claude/skills/_shared"
assert_eq   "a points at BRAIN_ROOT/skills/a" "$BRAIN_ROOT/skills/a" "$(readlink "$HOME_DIR/.claude/skills/a")"
assert_eq   "b points at BRAIN_ROOT/skills/b" "$BRAIN_ROOT/skills/b" "$(readlink "$HOME_DIR/.claude/skills/b")"

echo "idempotent second run:"
before_a="$(readlink "$HOME_DIR/.claude/skills/a")"
before_b="$(readlink "$HOME_DIR/.claude/skills/b")"
out2="$(run_install)"
rc2=$?
assert_eq "exits 0" "0" "$rc2"
assert_eq "a unchanged" "$before_a" "$(readlink "$HOME_DIR/.claude/skills/a")"
assert_eq "b unchanged" "$before_b" "$(readlink "$HOME_DIR/.claude/skills/b")"
assert_false "still does not link _shared" test -e "$HOME_DIR/.claude/skills/_shared"

echo "stale symlink replacement:"
rm "$HOME_DIR/.claude/skills/a"
ln -s "$TMP/somewhere-else" "$HOME_DIR/.claude/skills/a"
run_install >/dev/null
rc3=$?
assert_eq "exits 0" "0" "$rc3"
assert_eq "stale symlink replaced" "$BRAIN_ROOT/skills/a" "$(readlink "$HOME_DIR/.claude/skills/a")"

echo "dangling symlink pruning:"
mkdir -p "$TMP/elsewhere"
ln -s "$BRAIN_ROOT/skills/retired" "$HOME_DIR/.claude/skills/retired"
ln -s "$TMP/elsewhere/gone" "$HOME_DIR/.claude/skills/foreign"
mkdir -p "$HOME_DIR/.claude/skills/realdir"
outp="$(run_install)"; rcp=$?
assert_eq    "exits 0" "0" "$rcp"
assert_false "prunes dangling link into BRAIN_ROOT/skills" test -L "$HOME_DIR/.claude/skills/retired"
assert_true  "reports the prune" grep -qx 'pruned: retired' <<<"$outp"
assert_true  "keeps dangling link pointing outside BRAIN_ROOT" test -L "$HOME_DIR/.claude/skills/foreign"
assert_true  "keeps a real directory" test -d "$HOME_DIR/.claude/skills/realdir"
assert_true  "keeps live links" test -L "$HOME_DIR/.claude/skills/a"

echo "bin links + qmd config:"
mkdir -p "$BRAIN_ROOT/bin" "$TMP/xdg/qmd" "$TMP/vault"
printf '#!/bin/sh\n' >"$BRAIN_ROOT/bin/brain-x"; chmod +x "$BRAIN_ROOT/bin/brain-x"
ln -s "$HERE/../bin/brain_scope.py" "$BRAIN_ROOT/bin/brain_scope.py"
printf '#!/bin/sh\n' >"$BRAIN_ROOT/bin/brain-y.py"; chmod +x "$BRAIN_ROOT/bin/brain-y.py"
ln -s "$HERE/../bin/brain-scope" "$BRAIN_ROOT/bin/brain-scope"
cat >"$TMP/xdg/qmd/index.yml" <<'YML'
collections:
  vault:
    path: /somewhere/vault
    pattern: "**/*.md"
models:
  embed: hf:a
  generate: hf:b
  rerank: hf:c
YML
run_install2() {
  BRAIN_ROOT="$BRAIN_ROOT" HOME="$HOME_DIR" XDG_CONFIG_HOME="$TMP/xdg" BRAIN_VAULT="$TMP/vault" bash "$HERE/install.sh"
}
outb="$(run_install2)"; rcb=$?
assert_eq   "exits 0" "0" "$rcb"
assert_true "links brain-x into ~/.local/bin" test -L "$HOME_DIR/.local/bin/brain-x"
assert_eq   "brain-x points at source" "$BRAIN_ROOT/bin/brain-x" "$(readlink "$HOME_DIR/.local/bin/brain-x")"
assert_true "links brain-scope" test -L "$HOME_DIR/.local/bin/brain-scope"
assert_false "does not link brain_scope.py" test -e "$HOME_DIR/.local/bin/brain_scope.py"
assert_false "does not link executable brain-y.py" test -e "$HOME_DIR/.local/bin/brain-y.py"
assert_true "index.yml gets ignore line" grep -qx '      - "private/\*\*"' "$TMP/xdg/qmd/index.yml"
assert_true "index.yml keeps models" grep -q 'rerank: hf:c' "$TMP/xdg/qmd/index.yml"
assert_true "private.yml created" test -f "$TMP/xdg/qmd/private.yml"
assert_true "private.yml has models" grep -q 'embed: hf:a' "$TMP/xdg/qmd/private.yml"
assert_true "private.yml has private path" grep -qx "    path: $TMP/vault/private" "$TMP/xdg/qmd/private.yml"
h1="$(cat "$TMP/xdg/qmd/index.yml" "$TMP/xdg/qmd/private.yml" | sha256sum)"
outc="$(run_install2)"; rcc=$?
h2="$(cat "$TMP/xdg/qmd/index.yml" "$TMP/xdg/qmd/private.yml" | sha256sum)"
assert_eq   "second run exits 0" "0" "$rcc"
assert_eq   "second run changes no qmd config" "$h1" "$h2"
assert_true "second run reports up to date" grep -q 'qmd config: up to date' <<<"$outc"

echo "missing index.yml:"
rm "$TMP/xdg/qmd/index.yml" "$TMP/xdg/qmd/private.yml"
outd="$(run_install2 2>&1)"; rcd=$?
assert_eq   "exits 0" "0" "$rcd"
assert_true "warns" grep -qi 'warning' <<<"$outd"
assert_false "no private.yml created" test -e "$TMP/xdg/qmd/private.yml"

echo "workbench dir:"
assert_true "creates \$HOME/projects/workbench" test -d "$HOME_DIR/projects/workbench"
assert_true "prints workbench: ready" grep -qx 'workbench: ready' <<<"$out1"
echo "keep" >"$HOME_DIR/projects/workbench/keep.txt"
outw="$(run_install)"; rcw=$?
assert_eq   "second run exits 0" "0" "$rcw"
assert_true "second run keeps existing workbench content" test -f "$HOME_DIR/projects/workbench/keep.txt"
assert_true "second run prints workbench: ready" grep -qx 'workbench: ready' <<<"$outw"

echo "self host:"
# Never the real machine: BRAIN_HOSTNAME pins the hostname, BRAIN_HOSTS/BRAIN_SELF_HOST
# are cleared so install.sh resolves hosts.conf from the fake BRAIN_ROOT.
run_install_host() {
  env -u BRAIN_HOSTS -u BRAIN_SELF_HOST BRAIN_ROOT="$BRAIN_ROOT" HOME="$HOME_DIR" \
    BRAIN_HOSTNAME="$1" bash "$HERE/install.sh"
}
outn="$(run_install_host homeserver 2>&1)"; rcn=$?
assert_eq   "no host.sh in BRAIN_ROOT: exits 0" "0" "$rcn"
assert_true "no host.sh in BRAIN_ROOT: warns" grep -q 'warning:.*host\.sh' <<<"$outn"
mkdir -p "$BRAIN_ROOT/skills/_shared/lib"
cp "$HERE/../skills/_shared/lib/host.sh" "$BRAIN_ROOT/skills/_shared/lib/host.sh"
cp "$HERE/../skills/_shared/hosts.conf" "$BRAIN_ROOT/skills/_shared/hosts.conf"
outs="$(run_install_host homeserver 2>"$TMP/err")"; rcs=$?
assert_eq   "resolved: exits 0" "0" "$rcs"
assert_true "resolved: prints self host: homeserver" grep -qx 'self host: homeserver' <<<"$outs"
assert_false "resolved: no host warning on stderr" grep -qi 'self host' "$TMP/err"
outu="$(run_install_host nowhere-at-all 2>"$TMP/err")"; rcu=$?
assert_eq   "unresolved: exits 0" "0" "$rcu"
assert_false "unresolved: no self host line on stdout" grep -q '^self host:' <<<"$outu"
assert_true "unresolved: warns on stderr" grep -qi 'warning:.*self host' "$TMP/err"
assert_true "unresolved: says how to fix" grep -q 'BRAIN_SELF_HOST' "$TMP/err"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
