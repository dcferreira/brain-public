#!/usr/bin/env bash
#
# Tests for host.sh — the host axis library (desktop | homeserver) that every
# dispatch/collect script sources so no SKILL.md prose ever branches on where a command
# runs. Exercises self_host, host_canon, host_is_legacy, host_field, host_is_local,
# host_allows, run_on_host, tmx, remote_home and attach_cmd against a temp copy of
# hosts.conf, with BRAIN_SSH/BRAIN_TMUX stubbed so the tests run offline (no real
# ssh/tmux, no network). BRAIN_HOSTNAME/BRAIN_SELF_HOST are always set explicitly so
# nothing depends on the real machine's hostname.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Point at a temp copy of hosts.conf so the tests never depend on (or mutate) the
# real one.
# The temp copy pins desktop's alias to `-` (no ssh route) so the no-route paths
# stay covered now that the real row has a real alias.
sed 's/^desktop[[:space:]]\{1,\}[^[:space:]]\{1,\}/desktop   -/' "$HERE/../hosts.conf" >"$TMP/hosts.conf"
# Test-only fixture row `remote2`: a second remote host (macOS-style hostnames) so the
# multi-host / Darwin cases do not depend on which machines the real hosts.conf lists.
printf 'remote2        remote2-ssh     claude       claude            Remote2-Air,Remote2-MacBook\n' >>"$TMP/hosts.conf"
export BRAIN_HOSTS="$TMP/hosts.conf"
# Pin "this machine" to desktop by hostname; individual cases override.
unset BRAIN_SELF_HOST
export BRAIN_HOSTNAME="desktop-pc"

# shellcheck source=host.sh
source "$HERE/host.sh"

PASS=0 FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
assert_true()  { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
assert_false() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$d"; else ok "$d"; fi; }
assert_eq()    { local d="$1" want="$2" got="$3"; if [ "$want" = "$got" ]; then ok "$d"; else bad "$d (want '$want' got '$got')"; fi; }
assert_contains() { local d="$1" needle="$2" haystack="$3"; case "$haystack" in *"$needle"*) ok "$d" ;; *) bad "$d (missing '$needle' in '$haystack')" ;; esac; }

echo "hosts.conf:"
assert_false "no legacy 'local' row" grep -Eq '^[[:space:]]*local[[:space:]]' "$BRAIN_HOSTS"

echo "self_host:"
assert_eq    "via hostname"                       "desktop" "$(self_host)"
assert_eq    "hostname match is case-insensitive" "desktop" "$(BRAIN_HOSTNAME=Desktop-PC self_host)"
assert_eq    "trailing .local stripped"           "remote2"          "$(BRAIN_HOSTNAME=Remote2-Air.local self_host)"
assert_eq    "second entry of a comma list"       "remote2"          "$(BRAIN_HOSTNAME=remote2-macbook self_host)"
assert_eq    "homeserver by hostname"                  "homeserver"        "$(BRAIN_HOSTNAME=homeserver self_host)"
assert_eq    "BRAIN_SELF_HOST wins over hostname" "homeserver"        "$(BRAIN_SELF_HOST=homeserver self_host)"
assert_false "unresolved hostname → rc 1"         env BRAIN_HOSTNAME=nowhere bash -c "source '$HERE/host.sh'; self_host"
assert_eq    "unresolved prints nothing"          ""             "$(BRAIN_HOSTNAME=nowhere self_host 2>/dev/null)"
assert_false "BRAIN_SELF_HOST unknown → rc 1"     env BRAIN_SELF_HOST=nope bash -c "source '$HERE/host.sh'; self_host"
assert_false "BRAIN_SELF_HOST=local is not a host" env BRAIN_SELF_HOST=local bash -c "source '$HERE/host.sh'; self_host"

echo "host_canon:"
assert_eq    "local → self"          "desktop" "$(host_canon local)"
assert_eq    "empty → self"          "desktop" "$(host_canon '')"
assert_eq    "local → self (remote2)"    "remote2"          "$(BRAIN_SELF_HOST=remote2 host_canon local)"
assert_eq    "known name → itself"   "homeserver"        "$(host_canon homeserver)"
assert_false "unknown → rc 1"        host_canon nope
assert_false "local with unresolved self → rc 1" env BRAIN_HOSTNAME=nowhere bash -c "source '$HERE/host.sh'; host_canon local"

echo "host_is_legacy:"
assert_true  "local is legacy"  host_is_legacy local
assert_true  "empty is legacy"  host_is_legacy ''
assert_false "remote2 is not"       host_is_legacy remote2
assert_false "desktop is not" host_is_legacy desktop

echo "host_field:"
assert_eq   "host_field remote2 ssh_alias"               "remote2-ssh" "$(host_field remote2 ssh_alias)"
assert_eq   "host_field desktop ssh_alias"      "-"             "$(host_field desktop ssh_alias)"
assert_eq   "host_field remote2 harnesses"               "claude"        "$(host_field remote2 harnesses)"
assert_eq   "host_field local default_harness (alias)" "omp"         "$(host_field local default_harness)"
assert_eq   "host_field remote2 hostnames"               "Remote2-Air,Remote2-MacBook" "$(host_field remote2 hostnames)"
assert_eq   "host_field homeserver hostnames"             "homeserver"  "$(host_field homeserver hostnames)"
assert_false "host_field nope ssh_alias → rc≠0"      host_field nope ssh_alias
assert_false "host_field remote2 bogus → rc≠0"           host_field remote2 bogus
assert_eq   "host_field homeserver ssh_alias"             "homeserver"         "$(host_field homeserver ssh_alias)"
assert_eq   "host_field homeserver harnesses"             "claude"        "$(host_field homeserver harnesses)"

echo "host_is_local:"
assert_true  "self (desktop) → rc 0"   host_is_local desktop
assert_true  "local alias → rc 0"           host_is_local local
assert_false "remote2 → rc 1"                   host_is_local remote2
assert_false "homeserver → rc 1"                 host_is_local homeserver
assert_true  "on remote2: remote2 → rc 0"           env BRAIN_SELF_HOST=remote2 bash -c "source '$HERE/host.sh'; host_is_local remote2"
assert_false "on remote2: desktop → rc 1"  env BRAIN_SELF_HOST=remote2 bash -c "source '$HERE/host.sh'; host_is_local desktop"
assert_false "unresolved self → rc 1"       env BRAIN_HOSTNAME=nowhere bash -c "source '$HERE/host.sh'; host_is_local desktop"
assert_false "unknown host → rc 1"          host_is_local nope

echo "host_allows:"
assert_false "host_allows remote2 omp → rc 1"            host_allows remote2 omp
assert_true  "host_allows desktop omp → rc 0"   host_allows desktop omp
assert_true  "host_allows local omp (alias) → rc 0"  host_allows local omp
assert_true  "host_allows remote2 claude → rc 0"         host_allows remote2 claude
assert_false "host_allows homeserver omp → rc 1"          host_allows homeserver omp
assert_true  "host_allows homeserver claude → rc 0"       host_allows homeserver claude

echo "host_reachable:"
assert_true  "self (desktop, alias -) → rc 0"        host_reachable desktop
assert_true  "local alias → rc 0"                          host_reachable local
assert_true  "remote2 (real alias) → rc 0"                     host_reachable remote2
assert_true  "homeserver (real alias) → rc 0"                   host_reachable homeserver
assert_false "on remote2: desktop (alias -) → rc 1"       env BRAIN_SELF_HOST=remote2 bash -c "source '$HERE/host.sh'; host_reachable desktop"
assert_true  "on remote2: remote2 (self) → rc 0"                   env BRAIN_SELF_HOST=remote2 bash -c "source '$HERE/host.sh'; host_reachable remote2"
assert_false "unknown host → rc 1"                         host_reachable nope
assert_false "unresolved self: desktop (alias -) → rc 1" env BRAIN_HOSTNAME=nowhere bash -c "source '$HERE/host.sh'; host_reachable desktop"
assert_true  "unresolved self: remote2 (real alias) → rc 0"    env BRAIN_HOSTNAME=nowhere bash -c "source '$HERE/host.sh'; host_reachable remote2"
assert_eq    "host_reachable prints nothing"               "" "$(BRAIN_SELF_HOST=remote2 host_reachable desktop 2>&1)"

echo "host_ssh_alias:"
assert_eq       "host_ssh_alias remote2"   "remote2-ssh" "$(host_ssh_alias remote2)"
assert_eq       "host_ssh_alias homeserver" "homeserver"         "$(host_ssh_alias homeserver)"
OUT="$(host_ssh_alias desktop 2>&1)"; RC=$?
assert_eq       "host_ssh_alias desktop (alias -) → rc 1" "1" "$RC"
assert_contains "host_ssh_alias desktop → message" "host.sh: host desktop has no ssh alias in hosts.conf" "$OUT"
assert_false    "host_ssh_alias nope → rc 1" host_ssh_alias nope
assert_false    "private _host_ssh_alias is gone" declare -F _host_ssh_alias

echo "self_host on Darwin (scutil LocalHostName):"
FB="$TMP/fakebin"; mkdir -p "$FB"
printf '#!/usr/bin/env bash\necho strangebox\n' >"$FB/hostname"
printf '#!/usr/bin/env bash\ncase "$1" in -s) echo "${FAKE_UNAME_S:-Darwin}" ;; *) echo strangebox ;; esac\n' >"$FB/uname"
printf '#!/usr/bin/env bash\n[ "$*" = "--get LocalHostName" ] && echo Remote2-MacBook\n' >"$FB/scutil"
chmod +x "$FB/hostname" "$FB/uname" "$FB/scutil"
assert_eq    "Darwin: scutil LocalHostName matches remote2" "remote2" \
    "$(env -u BRAIN_HOSTNAME -u BRAIN_SELF_HOST PATH="$FB:$PATH" bash -c "source '$HERE/host.sh'; self_host")"
assert_false "non-Darwin: scutil never consulted" \
    env -u BRAIN_HOSTNAME -u BRAIN_SELF_HOST FAKE_UNAME_S=Linux PATH="$FB:$PATH" bash -c "source '$HERE/host.sh'; self_host"
assert_eq    "BRAIN_HOSTNAME set: scutil never consulted" "" \
    "$(env -u BRAIN_SELF_HOST BRAIN_HOSTNAME=nowhere PATH="$FB:$PATH" bash -c "source '$HERE/host.sh'; self_host" 2>/dev/null)"

echo "run_on_host (remote, stubbed ssh):"
FAKE_SSH="$TMP/fake-ssh"
cat >"$FAKE_SSH" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*"
EOF
chmod +x "$FAKE_SSH"
export BRAIN_SSH="$FAKE_SSH"
OUT="$(run_on_host remote2 'echo hi')"
assert_contains "invokes with -o BatchMode=yes <alias> zsh -lc" "-o BatchMode=yes remote2-ssh zsh -lc" "$OUT"
assert_contains "quotes the remote command"                     "$(printf '%q' 'echo hi')" "$OUT"
OUT="$(run_on_host homeserver 'echo hi')"
assert_contains "homeserver: invokes with -o BatchMode=yes homeserver zsh -lc" "-o BatchMode=yes homeserver zsh -lc" "$OUT"
OUT="$(BRAIN_SELF_HOST=remote2 run_on_host desktop 'echo hi' 2>&1)"; RC=$?
assert_eq       "on remote2: desktop (alias -) → rc 1"  "1" "$RC"
assert_contains "on remote2: desktop → no-alias message" "host.sh: host desktop has no ssh alias in hosts.conf" "$OUT"
OUT="$(BRAIN_SELF_HOST=remote2 run_on_host desktop 'echo hi' 2>/dev/null)"
assert_eq       "on remote2: desktop → ssh never invoked" "" "$OUT"
assert_false    "unknown host → rc 1" run_on_host nope 'echo hi'
unset BRAIN_SSH

echo "run_on_host (local):"
assert_eq "run_on_host desktop (self) 'echo hi' → hi" "hi" "$(run_on_host desktop 'echo hi')"
assert_eq "run_on_host local (alias) 'echo hi' → hi"       "hi" "$(run_on_host local 'echo hi')"
assert_eq "on remote2: run_on_host remote2 runs locally"           "hi" "$(BRAIN_SELF_HOST=remote2 run_on_host remote2 'echo hi')"

echo "attach_cmd:"
assert_eq "attach_cmd remote2 brain-worker-x"   "ssh -t remote2-ssh tmux attach -t brain-worker-x" "$(attach_cmd remote2 brain-worker-x)"
assert_eq "attach_cmd homeserver brain-worker-x" "ssh -t homeserver tmux attach -t brain-worker-x"             "$(attach_cmd homeserver brain-worker-x)"
assert_eq "attach_cmd desktop (self)"  "tmux attach -t brain-worker-x"                          "$(attach_cmd desktop brain-worker-x)"
assert_eq "attach_cmd local (alias)"        "tmux attach -t brain-worker-x"                          "$(attach_cmd local brain-worker-x)"
assert_eq "on remote2: attach_cmd remote2 (self)"   "tmux attach -t brain-worker-x"                          "$(BRAIN_SELF_HOST=remote2 attach_cmd remote2 brain-worker-x)"
OUT="$(BRAIN_SELF_HOST=remote2 attach_cmd desktop brain-worker-x 2>&1)"; RC=$?
assert_eq       "on remote2: attach_cmd desktop → rc 1"   "1" "$RC"
assert_contains "on remote2: attach_cmd desktop → message" "has no ssh alias in hosts.conf" "$OUT"

echo "tmx:"
assert_eq "tmx local list-sessions with BRAIN_TMUX=echo"        "list-sessions" "$(BRAIN_TMUX=echo tmx local list-sessions)"
assert_eq "tmx desktop list-sessions with BRAIN_TMUX=echo" "list-sessions" "$(BRAIN_TMUX=echo tmx desktop list-sessions)"

echo "remote_home:"
assert_eq "remote_home local → \$HOME"        "$HOME" "$(remote_home local)"
assert_eq "remote_home desktop → \$HOME" "$HOME" "$(remote_home desktop)"
assert_false "on remote2: remote_home desktop → rc 1" env BRAIN_SELF_HOST=remote2 bash -c "source '$HERE/host.sh'; remote_home desktop"

echo "source-safe under set -euo pipefail:"
OUT="$(BRAIN_HOSTNAME=nowhere bash -c "set -euo pipefail; source '$HERE/host.sh'; self_host || echo survived" 2>&1)"
assert_eq "failing self_host does not exit the caller" "survived" "$OUT"

echo "real hosts.conf:"
REAL="$HERE/../hosts.conf"
assert_eq    "real: My-Air → laptop"        "laptop" "$(BRAIN_HOSTS="$REAL" BRAIN_HOSTNAME=My-Air self_host)"
assert_eq    "real: homeserver → homeserver"         "homeserver"   "$(BRAIN_HOSTS="$REAL" BRAIN_HOSTNAME=homeserver self_host)"
assert_eq    "real: laptop ssh_alias"            "laptop" "$(BRAIN_HOSTS="$REAL" host_field laptop ssh_alias)"
assert_eq    "real: desktop ssh_alias"       "desktop" "$(BRAIN_HOSTS="$REAL" host_field desktop ssh_alias)"
assert_false "real: retired 'mac' → rc 1"         env BRAIN_HOSTS="$REAL" bash -c "source '$HERE/host.sh'; host_field mac ssh_alias"
assert_false "real: 'old-mac' is unknown (host_canon rc 1)" env BRAIN_HOSTS="$REAL" bash -c "source '$HERE/host.sh'; host_canon old-mac"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
