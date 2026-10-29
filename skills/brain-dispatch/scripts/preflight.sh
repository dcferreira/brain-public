#!/usr/bin/env bash
#
# preflight.sh — everything brain-dispatch must know about a host BEFORE it writes a
# worker note or launches anything (spec §5.7, ported from SKILL.md step 4).
#
# Host- and harness-neutral: the host axis (a name from hosts.conf, e.g. desktop, homeserver; `local` is a deprecated alias for this machine) comes from host.sh, the harness
# axis (omp | claude) from harness-chrome.sh, and every probe runs ON the target host via
# run_on_host — never a raw ssh, never an assumption about the target OS. Nothing
# probeable is stored in hosts.conf; it is all measured here, each time.
#
# Usage:
#   preflight.sh --host <host from hosts.conf> --harness <omp|claude> --project-dir <dir>
#
# Prints ONE line on stdout:
#   dir_exists=yes|no vcs=jj|git|none free_gb=<int> harness_bin=present|missing \
#   guardrail=active|inactive|n/a
#
# Exit codes:
#   0  all clear (a low free_gb or an inactive guardrail is a WARNING the caller judges)
#   1  dir_exists=no, or harness_bin=missing — do not launch
#   2  bad arguments, unknown host, unknown harness, or a harness the host does not run
#
# Judgement deliberately stays with the caller: this script measures, the dispatch skill
# decides (< ~20 GB warn, < ~5 GB refuse a code worker, inactive guardrail warn).

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BRAIN_ROOT="${BRAIN_ROOT:-$(cd "$HERE/../../.." && pwd)}"
export BRAIN_ROOT
# shellcheck source=../../_shared/lib/host.sh
. "$HERE/../../_shared/lib/host.sh"
# shellcheck source=../../_shared/lib/harness-chrome.sh
. "$HERE/../../_shared/lib/harness-chrome.sh"

die2() { printf 'preflight: %s\n' "$1" >&2; exit 2; }
# need_val <remaining argc> <flag> — a value-taking flag with nothing after it must be a
# hard rc-2 error: under `set -u` a bare `shift 2` on one remaining argument FAILS without
# consuming anything, and the `while [ $# -gt 0 ]` loop then spins forever.
need_val() { [ "$1" -ge 2 ] || die2 "$2 needs a value"; }
usage() { sed -n '/^# Usage:/,/^$/p' "$0"; }

host="" harness="" project_dir=""
while [ $# -gt 0 ]; do
    case "$1" in
        --host)        need_val $# "$1"; host="$2"; shift 2 ;;
        --harness)     need_val $# "$1"; harness="$2"; shift 2 ;;
        --project-dir) need_val $# "$1"; project_dir="$2"; shift 2 ;;
        -h|--help)     usage; exit 0 ;;
        *) die2 "unknown argument: $1" ;;
    esac
done

[ -n "$host" ] && [ -n "$harness" ] && [ -n "$project_dir" ] \
    || die2 "--host, --harness and --project-dir are all required"
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
valid_harness "$harness" || die2 "unknown harness: $harness (expected omp|claude)"
host_allows "$host" "$harness" \
    || die2 "host '$host' does not run harness '$harness' (see skills/_shared/hosts.conf)"

# $project_dir is interpolated UNQUOTED into the remote command so a leading `~` is
# expanded by the shell on the TARGET host, not locally (a `~` written for a remote host must
# not become this machine's $HOME). Project dirs are paths without spaces by convention.
D="$project_dir"

# --- dir_exists + vcs (one round trip) -------------------------------------------
# Colocated checkouts (.jj AND .git) are jj, matching the worker's step 0.
probe="$(run_on_host "$host" "if [ -d $D/.jj ]; then echo jj; elif [ -d $D/.git ]; then echo git; elif [ -d $D ]; then echo none; else echo ABSENT; fi" 2>/dev/null)"
probe="$(printf '%s' "$probe" | tr -d '[:space:]')"
case "$probe" in
    jj|git|none) dir_exists=yes; vcs="$probe" ;;
    *)           dir_exists=no;  vcs=none ;;
esac

# --- free_gb (df dialect chosen by the host's own uname) --------------------------
# macOS df is BSD (`df -g`, blocks in GiB); Linux df is GNU (`df -BG --output=avail`).
# Neither exists on the other, so the flavour is probed, never assumed from --host.
os="$(run_on_host "$host" 'uname -s' 2>/dev/null | tr -d '[:space:]')"
free_gb=0
if [ "$dir_exists" = yes ]; then
    case "$os" in
        Darwin) free_gb="$(run_on_host "$host" "df -g $D | awk 'NR==2{print \$4}'" 2>/dev/null)" ;;
        *)      free_gb="$(run_on_host "$host" "df -BG --output=avail $D | tail -1 | tr -dc 0-9" 2>/dev/null)" ;;
    esac
fi
free_gb="$(printf '%s' "$free_gb" | tr -dc '0-9')"
[ -n "$free_gb" ] || free_gb=0

# --- harness binary on the host's own login PATH ----------------------------------
# run_on_host uses `zsh -lc` remotely precisely so Homebrew / ~/.local/bin are visible;
# a bare `ssh host command -v claude` would report it missing on a host that has it.
if run_on_host "$host" "command -v $harness" >/dev/null 2>&1; then
    harness_bin=present
else
    harness_bin=missing
fi

# --- guardrail (omp on Linux only) -------------------------------------------------
# pi-automode supervises every omp tool call and FAILS CLOSED: with llama-classifier
# down, an unattended worker wedges on its first bash. It is a systemd user unit, so it
# exists only for omp on a Linux host — Darwin has no systemctl and must never be asked.
guardrail=n/a
if [ "$harness" = omp ] && [ "$os" = Linux ]; then
    if run_on_host "$host" 'systemctl --user is-active llama-classifier' >/dev/null 2>&1; then
        guardrail=active
    else
        # the unit is `enabled`, so an inactive one is usually just a login it missed
        run_on_host "$host" 'systemctl --user start llama-classifier' >/dev/null 2>&1
        if run_on_host "$host" 'systemctl --user is-active llama-classifier' >/dev/null 2>&1; then
            guardrail=active
        else
            guardrail=inactive
            printf 'preflight: llama-classifier inactive on %s — omp tool calls stay blocked until it is up\n' "$host" >&2
        fi
    fi
fi

printf 'dir_exists=%s vcs=%s free_gb=%s harness_bin=%s guardrail=%s\n' \
    "$dir_exists" "$vcs" "$free_gb" "$harness_bin" "$guardrail"

[ "$dir_exists" = yes ] || { printf 'preflight: project dir missing on %s: %s\n' "$host" "$D" >&2; exit 1; }
[ "$harness_bin" = present ] || { printf 'preflight: %s not on %s login PATH\n' "$harness" "$host" >&2; exit 1; }
exit 0
