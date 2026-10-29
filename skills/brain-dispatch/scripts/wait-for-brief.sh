#!/usr/bin/env bash
#
# wait-for-brief.sh — wait until the worker note for <slug> is visible ON THE HOST that
# is about to launch the worker (spec §5.7).
#
# Why it exists: the launcher writes the worker note into the LOCAL vault, but a remote
# worker reads it from the remote host's copy, which Syncthing populates a few seconds later.
# Launching before the file has landed gives the worker a "file not found" as its first
# action. Locally there is nothing to wait for and the answer is immediate.
#
# Usage:
#   wait-for-brief.sh --host <host from hosts.conf> --slug <slug> [--timeout <seconds, default 90>]
#                    [--note-dir workers|private/workers]
#
# Prints ONE line: `synced=yes|no`.   rc 0 on yes, 1 on no, 2 on bad arguments.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BRAIN_ROOT="${BRAIN_ROOT:-$(cd "$HERE/../../.." && pwd)}"
export BRAIN_ROOT
# shellcheck source=../../_shared/lib/host.sh
. "$HERE/../../_shared/lib/host.sh"

POLL="${DISPATCH_BRIEF_POLL:-3}"   # seconds between checks

die2() { printf 'wait-for-brief: %s\n' "$1" >&2; exit 2; }
# need_val <remaining argc> <flag> — see preflight.sh: a trailing value-taking flag would
# otherwise make `shift 2` fail under `set -u` and spin the parse loop forever.
need_val() { [ "$1" -ge 2 ] || die2 "$2 needs a value"; }
usage() { sed -n '/^# Usage:/,/^$/p' "$0"; }

host="" slug="" timeout=90 note_dir=workers
while [ $# -gt 0 ]; do
    case "$1" in
        --host)    need_val $# "$1"; host="$2"; shift 2 ;;
        --slug)    need_val $# "$1"; slug="$2"; shift 2 ;;
        --timeout) need_val $# "$1"; timeout="$2"; shift 2 ;;
        --note-dir) need_val $# "$1"; note_dir="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die2 "unknown argument: $1" ;;
    esac
done

[ -n "$host" ] && [ -n "$slug" ] || die2 "--host and --slug are required"
# Canonicalise: `local` (deprecated alias) becomes this machine's real hosts.conf name, so
# everything below (and every message) uses the real name. An unknown host, or a self that
# cannot be resolved, is refused here — before any probe, note or launch.
if ! canon="$(host_canon "$host")"; then
    if host_is_legacy "$host"; then
        die2 "cannot resolve which host this machine is: its hostname is not in skills/_shared/hosts.conf — add it to that row's hostnames column or set BRAIN_SELF_HOST"
    fi
    die2 "unknown host: $host (see skills/_shared/hosts.conf)"
fi
host="$canon"
case "$note_dir" in workers|private/workers) ;; *) die2 "--note-dir must be workers or private/workers" ;; esac
case "$timeout" in ''|*[!0-9]*) die2 "--timeout must be an integer" ;; esac

# Locally the vault path is overridable (BRAIN_VAULT) so tests never touch the real one;
# remotely the path is written with `~` and left UNQUOTED so the TARGET shell expands it.
present() {
    if host_is_local "$host"; then
        [ -f "${BRAIN_VAULT:-$HOME/Obsidian/vault}/$note_dir/$slug.md" ]
    else
        run_on_host "$host" "test -f ~/Obsidian/vault/$note_dir/$slug.md" >/dev/null 2>&1
    fi
}

deadline=$((SECONDS + timeout))
while :; do
    if present; then
        printf 'synced=yes\n'
        exit 0
    fi
    [ "$SECONDS" -lt "$deadline" ] || break
    sleep "$POLL"
done

printf 'synced=no\n'
printf 'wait-for-brief: %s/%s.md not visible on %s after %ss\n' "$note_dir" "$slug" "$host" "$timeout" >&2
exit 1
