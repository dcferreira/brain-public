#!/usr/bin/env bash
#
# host.sh — the host axis (desktop | homeserver, i.e. the rows of hosts.conf):
# where a command runs. Sourced by every dispatch/collect/status script so no SKILL.md
# prose ever branches on host; the `hosts.conf` registry plus the functions below are
# the only place that knowledge lives. Pure functions, no side effects beyond the
# command each one runs; safe to `source` under a caller's `set -euo pipefail`
# (functions return non-zero rather than exiting the caller's shell).
#
# Hosts are named by their real hosts.conf name. "This machine" (self) is resolved by
# self_host; the old name `local` (and an empty name) is a deprecated alias for self,
# accepted everywhere via host_canon — callers can spot it with host_is_legacy to warn.
#
# Env (overridable, e.g. by tests):
#   BRAIN_ROOT       repo root                            default: $HOME/projects/brain
#   BRAIN_HOSTS      path to hosts.conf                    default: $BRAIN_ROOT/skills/_shared/hosts.conf
#   BRAIN_SSH        ssh invocation (stubbed in tests)      default: command ssh
#   BRAIN_TMUX       tmux invocation                        default: command tmux
#   BRAIN_SELF_HOST  force self's hosts.conf name           default: resolved from hostname
#   BRAIN_HOSTNAME   this machine's hostname (test seam)    default: `hostname -s`, `hostname`, `uname -n`
#                                                           (+ `scutil --get LocalHostName` on Darwin)
#
# Functions:
#   self_host                                                    prints self's name; rc 1 if unresolved
#   host_canon    <name>                                         local|"" → self_host; known → itself; else rc 1
#   host_is_legacy <name>                                        rc 0 for `local` or empty
#   host_field   <name> <ssh_alias|harnesses|default_harness|hostnames>  prints value; rc 1 if unknown host/field
#   host_is_local <name>                                         rc 0 when host_canon name == self_host
#   host_allows   <name> <harness>                               rc 0 when harness in harnesses (comma list)
#   host_reachable <name>                                        rc 0 when name is self or has a real ssh alias
#   host_ssh_alias <name>                                        prints the ssh alias; rc 1 (+ message) for `-`
#   run_on_host   <name> <cmd-string>                            self: bash -c; remote: $BRAIN_SSH ...
#   tmx           <name> <tmux args...>                          run_on_host name "$BRAIN_TMUX <args>"
#   remote_home   <name>                                         $HOME on self; `echo $HOME` remotely
#   attach_cmd    <name> <session>                               "tmux attach -t S" | "ssh -t <alias> tmux attach -t S"
# A non-self host whose ssh_alias is `-` (no ssh route) makes run_on_host / tmx /
# remote_home / attach_cmd print `host.sh: host <name> has no ssh alias in hosts.conf`
# on stderr and return 1.

set -u

BRAIN_ROOT="${BRAIN_ROOT:-$HOME/projects/brain}"
BRAIN_HOSTS="${BRAIN_HOSTS:-$BRAIN_ROOT/skills/_shared/hosts.conf}"
BRAIN_SSH="${BRAIN_SSH:-command ssh}"
BRAIN_TMUX="${BRAIN_TMUX:-command tmux}"

# _host_col <name> <col> — raw hosts.conf lookup of column <col> for row <name>, with
# no alias handling. Prints the value; rc 1 if the row is missing.
_host_col() {
    local name="$1" col="$2"
    [ -r "$BRAIN_HOSTS" ] || return 1
    awk -v name="$name" -v col="$col" '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*$/ { next }
        $1 == name { print $col; found=1; exit }
        END { if (!found) exit 1 }
    ' "$BRAIN_HOSTS"
}

# self_host — prints this machine's hosts.conf name. $BRAIN_SELF_HOST wins when set
# (rc 1 if it names no row); otherwise each candidate hostname ($BRAIN_HOSTNAME, else
# `hostname -s`, `hostname`, `uname -n`, and on Darwin `scutil --get LocalHostName`), lowercased with a trailing `.local`
# stripped, is matched against every row's comma-separated hostnames column. Returns
# 1 with nothing printed when no row matches.
self_host() {
    if [ -n "${BRAIN_SELF_HOST:-}" ]; then
        _host_col "$BRAIN_SELF_HOST" 1 >/dev/null || return 1
        printf '%s\n' "$BRAIN_SELF_HOST"
        return 0
    fi
    [ -r "$BRAIN_HOSTS" ] || return 1
    local candidates
    if [ -n "${BRAIN_HOSTNAME:-}" ]; then
        candidates="$BRAIN_HOSTNAME"
    else
        candidates="$(hostname -s 2>/dev/null || true) $(hostname 2>/dev/null || true) $(uname -n 2>/dev/null || true)"
        # macOS: `hostname` can be a DHCP/network name; the LocalHostName is stable.
        if [ "$(uname -s 2>/dev/null)" = Darwin ] && command -v scutil >/dev/null 2>&1; then
            candidates="$candidates $(scutil --get LocalHostName 2>/dev/null || true)"
        fi
    fi
    awk -v candidates="$candidates" '
        BEGIN {
            n = split(candidates, c, " ")
            for (i = 1; i <= n; i++) { h = tolower(c[i]); sub(/\.local$/, "", h); if (h != "") want[h] = 1 }
        }
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*$/ { next }
        {
            m = split(tolower($5), names, ",")
            for (j = 1; j <= m; j++) if (names[j] in want) { print $1; found=1; exit }
        }
        END { if (!found) exit 1 }
    ' "$BRAIN_HOSTS"
}

# host_canon <name> — the canonical hosts.conf name for <name>: `local` or empty (the
# deprecated "this machine") resolves through self_host; a known host prints itself.
# Returns 1 with nothing printed for an unknown host or an unresolved self.
host_canon() {
    local name="${1:-}"
    if host_is_legacy "$name"; then
        self_host
        return $?
    fi
    _host_col "$name" 1 >/dev/null || return 1
    printf '%s\n' "$name"
}

# host_is_legacy <name> — true (rc 0) for the pre-real-name spellings of self: `local`
# or empty. Callers use it to warn before normalising.
host_is_legacy() {
    [ -z "${1:-}" ] || [ "$1" = "local" ]
}

# host_field <name> <field> — reads a column (ssh_alias|harnesses|default_harness|
# hostnames) from hosts.conf for host <name> (canonicalised first, so `local` still
# reads self's row). Prints the value on stdout; returns 1 with nothing printed if the
# host or field is unknown.
host_field() {
    local name="$1" field="$2" col canon
    case "$field" in
        ssh_alias)       col=2 ;;
        harnesses)       col=3 ;;
        default_harness) col=4 ;;
        hostnames)       col=5 ;;
        *) return 1 ;;
    esac
    canon="$(host_canon "$name")" || return 1
    _host_col "$canon" "$col"
}

# host_is_local <name> — true (rc 0) when host <name> is this machine (host_canon
# <name> == self_host). Returns 1 if either side is unresolved.
host_is_local() {
    local canon self
    canon="$(host_canon "$1")" || return 1
    self="$(self_host)" || return 1
    [ "$canon" = "$self" ]
}

# host_allows <name> <harness> — true (rc 0) when <harness> is one of host <name>'s
# comma-separated harnesses list.
host_allows() {
    local name="$1" harness="$2" list
    list="$(host_field "$name" harnesses)" || return 1
    local IFS=,
    local h
    for h in $list; do
        [ "$h" = "$harness" ] && return 0
    done
    return 1
}

# host_reachable <name> — true (rc 0) when this machine can run commands on host <name>:
# it is self, or its ssh_alias is a real alias (not `-`). Returns 1, silently, for a
# non-self host with no ssh route, or an unknown host. Callers use it to refuse/skip up
# front instead of failing deep inside run_on_host.
host_reachable() {
    local alias
    host_is_local "$1" && return 0
    alias="$(host_field "$1" ssh_alias)" || return 1
    [ "$alias" != "-" ]
}

# host_ssh_alias <name> — prints the ssh alias of host <name>. A `-` alias (no ssh
# route) prints `host.sh: host <name> has no ssh alias in hosts.conf` on stderr and
# returns 1; so does nothing for an unknown host (rc 1, silent).
host_ssh_alias() {
    local canon alias
    canon="$(host_canon "$1")" || return 1
    alias="$(_host_col "$canon" 2)" || return 1
    if [ "$alias" = "-" ]; then
        printf 'host.sh: host %s has no ssh alias in hosts.conf\n' "$canon" >&2
        return 1
    fi
    printf '%s\n' "$alias"
}

# run_on_host <name> <cmd-string> — runs <cmd-string> on host <name>. Self:
# `bash -c "$cmd"`. Remote host: `$BRAIN_SSH -o BatchMode=yes <alias> zsh -lc <quoted>`,
# quoted with `printf %q` so the remote shell sees exactly one argument.
run_on_host() {
    local name="$1" cmd="$2" alias quoted
    if host_is_local "$name"; then
        bash -c "$cmd"
        return $?
    fi
    alias="$(host_ssh_alias "$name")" || return 1
    printf -v quoted '%q' "$cmd"
    # shellcheck disable=SC2086  # BRAIN_SSH is intentionally a multi-word invocation
    $BRAIN_SSH -o BatchMode=yes "$alias" zsh -lc "$quoted"
}

# tmx <name> <tmux args...> — runs `$BRAIN_TMUX <args>` on host <name> via run_on_host;
# the only way scripts touch tmux.
tmx() {
    local name="$1"
    shift
    run_on_host "$name" "$BRAIN_TMUX $*"
}

# remote_home <name> — prints $HOME: the local value on self, or the remote host's
# $HOME (so `~`-relative paths written for the other OS can be expanded) remotely.
remote_home() {
    local name="$1"
    if host_is_local "$name"; then
        printf '%s\n' "$HOME"
        return 0
    fi
    run_on_host "$name" 'echo $HOME'
}

# attach_cmd <name> <session> — prints the command a human types to attach to tmux
# session <session> on host <name>: on self `tmux attach -t <session>`, or
# `ssh -t <alias> tmux attach -t <session>` remotely.
attach_cmd() {
    local name="$1" session="$2" alias
    if host_is_local "$name"; then
        printf 'tmux attach -t %s\n' "$session"
        return 0
    fi
    alias="$(host_ssh_alias "$name")" || return 1
    printf 'ssh -t %s tmux attach -t %s\n' "$alias" "$session"
}
