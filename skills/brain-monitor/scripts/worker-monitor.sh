#!/usr/bin/env bash
#
# worker-monitor.sh — a change-only monitor of a named set of brain workers, for a
# coordinator session's Monitor tool. Every poll classifies each worker (note
# frontmatter + tmux pane chrome + claude transcript) and prints ONE stdout line
# summarising all of them — but only when the set of waiting workers, or any waiting
# worker's wait, differs from the last line it printed. Design:
# specs/2026-10-02-brain-monitor-design.md.
#
# Read-only on everything but its own state file: it only runs `tmux has-session` and
# `tmux capture-pane` (through host.sh, so remote hosts work) and reads worker notes and
# transcripts (mtime, last message). It never sends keys, attaches, or writes a pane or a note.
#
# Output (stdout, one line per event; diagnostics go to stderr):
#   <iso-utc-ts> <label> <W>/<N> waiting · <worker> · <worker> …
#     waiting, new/changed wait:   <name> <NEEDS> <dur> <detail>
#     waiting, already reported:   <name> <state> <dur> <detail>
#     not waiting:                 <name> <state> <dur>
#     host unreachable, last known state carried (any of the above):
#                                  <name> <state>? <dur> [<detail>] (stale: host <h> unreachable)
#     then one row per watched PR (see PR watch below):
#                                  <pr> <NEEDS|state>[?] @<head7> checks=<c> <mergeable> [(stale: gh)]
#   <iso-utc-ts> <label> monitor-error <message>     (once per distinct message)
#
# Usage:
#   worker-monitor.sh [--interval <s>] [--label <name>] [--stuck-after <min>]
#                     [--vault <dir>] [--state-dir <dir>] [--once] [--pr <url|o/r#n>]... [<slug>...]
#
#   --interval     seconds between polls                           default: 60
#   --label        2nd field of every line; names the state file   default: the slugs'
#                  longest common `-`-terminated prefix minus the `-` (the slug itself for
#                  a single slug), else `workers`; display names drop that prefix
#   --stuck-after  minutes of transcript silence while busy → stuck default: 30
#   --vault        vault root (reads <vault>/workers/<slug>.md, else private/workers/)  default: ~/Obsidian/vault
#   --state-dir    where <label>-<cksum of the sorted slugs>.state lives
#                  default: ${XDG_STATE_HOME:-~/.local/state}/brain/worker-monitor
#   --once         one poll; ALWAYS print the current line; never touch the state file
#   --pr           also watch this GitHub PR (repeatable; a PR no worker's note names,
#                  e.g. a release PR); with ≥1 --pr the slugs are optional (label: prs)
#
# Run it from a coordinator session as (one notification per printed line):
#
#   Monitor(command: "bash ~/projects/brain/skills/brain-monitor/scripts/worker-monitor.sh budgebell-log-utc budgebell-nudge-cooldown", description: "budgebell worker waits", timeout_ms: 1800000)
#
# A Monitor watch expires after at most 30 minutes: when it does, re-run the IDENTICAL
# command. The state file makes a re-run idempotent — it re-emits nothing already
# reported, and keeps each worker's state durations and idle debounce.
#
# Needs: CHECK (no note / host unreachable before any state / no ssh route to the host) · COLLECT (done) · REVIVE (session gone) ·
# ANSWER (question dialog) · REVIEW (blocked awaiting review) · UNBLOCK (blocked) ·
# NUDGE (idle pane on 2+ polls while primed/working) · INSPECT (busy, transcript silent).
# A NUDGE's said:"…" is the last line of the worker's last assistant text message, read
# from its claude transcript (session_id) on its host; with no transcript, jq or text it
# falls back to the pane's last `● ` message (always so for omp).
#
# PR watch: the PRs watched are the --pr ones plus every GitHub PR URL in a watched
# worker's note FRONTMATTER (`blocker:`, and `pr:` on ONE line, items split by commas
# and/or whitespace; never the body, whose links go stale), deduplicated (owner/repo
# case-insensitively), each read with ONE `gh pr view` per poll (forge.sh; gh runs here,
# not on the worker's host, under a timeout when timeout/gtimeout exists). Named `#<n>`;
# `<repo>#<n>` when they span repos; `<owner>/<repo>#<n>` when two owners' repos share a
# name. Unlike worker rows (printed when a wait starts), PR rows are CHANGE-triggered: a
# line prints whenever a PR's (state, head, mergeable, checks) differs from the last line
# (in any order), and the changed rows are in capitals: MERGED · CLOSED · RED (checks
# failed) · CONFLICT · HEAD (new commit on an open PR) · GREEN (checks pass + mergeable) ·
# CI (checks running) · DRAFT · OPEN (no checks reported, or mergeable unknown);
# unchanged rows lowercase. MERGED/CLOSED/RED/CONFLICT count as waiting. A flip of
# mergeable to UNKNOWN (GitHub recomputing) on the same head alone is not a change. A
# merged PR is not re-queried; it stays a row until nothing names it. PR state lives in
# <state-dir>/<label>.prs.state (per LABEL), so re-arming with a changed slug list
# re-announces no PR (pass an explicit --label: the derived one shifts with the slugs);
# monitors sharing a label merge their PR records. On a gh failure: one monitor-error (its
# digits ignored for the once-only check) and the last known row is carried
# `(stale: gh)`. A non-GitHub PR URL in a note is warned once per run on stderr.
#
# Env: BRAIN_TMUX/BRAIN_SSH/BRAIN_HOSTS as in host.sh; BRAIN_GH as in forge.sh; for tests MONITOR_NOW (fake epoch of
# the first poll; poll k is at MONITOR_NOW + k*MONITOR_NOW_STEP, step default --interval)
# and MONITOR_MAX_POLLS (stop after N polls, rc 0).
#
# Exit: never on a transient error (it reports `monitor-error` and keeps polling);
#       0 after --once or MONITOR_MAX_POLLS polls; 2 usage error.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BRAIN_ROOT="${BRAIN_ROOT:-$(cd "$HERE/../../.." && pwd)}"
export BRAIN_ROOT
# shellcheck source=../../_shared/lib/host.sh
. "$HERE/../../_shared/lib/host.sh"
# shellcheck source=../../_shared/lib/harness-chrome.sh
. "$HERE/../../_shared/lib/harness-chrome.sh"
# shellcheck source=../../_shared/lib/forge.sh
. "$HERE/../../_shared/lib/forge.sh"

die2() { printf 'worker-monitor: %s\n' "$1" >&2; exit 2; }
need_val() { [ "$1" -ge 2 ] || die2 "$2 needs a value"; }
is_uint() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; return 0; }
usage() { sed -n '/^# Usage:/,/^# Exit:/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

interval=60 label="" stuck_after=30 vault="$HOME/Obsidian/vault" state_dir="" once=0
SLUGS=() PR_ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --pr)          need_val $# "$1"
                       ref="$(pr_ref_parse "$2")" || die2 "unsupported --pr: '$2' (a GitHub PR URL or <owner>/<repo>#<n>)"
                       case " ${PR_ARGS[*]-} " in *" $ref "*) ;; *) PR_ARGS+=("$ref") ;; esac
                       shift 2 ;;
        --interval)    need_val $# "$1"; interval="$2"; shift 2 ;;
        --label)       need_val $# "$1"; label="$2"; shift 2 ;;
        --stuck-after) need_val $# "$1"; stuck_after="$2"; shift 2 ;;
        --vault)       need_val $# "$1"; vault="$2"; shift 2 ;;
        --state-dir)   need_val $# "$1"; state_dir="$2"; shift 2 ;;
        --once)        once=1; shift ;;
        -h|--help)     usage; exit 0 ;;
        --)            shift; while [ $# -gt 0 ]; do SLUGS+=("$1"); shift; done ;;
        -*)            die2 "unknown argument: $1" ;;
        *)             SLUGS+=("$1"); shift ;;
    esac
done
[ "${#SLUGS[@]}" -gt 0 ] || [ "${#PR_ARGS[@]}" -gt 0 ] || die2 "no worker slugs given (see --help)"
is_uint "$interval" || die2 "--interval must be a whole number of seconds"
is_uint "$stuck_after" || die2 "--stuck-after must be a whole number of minutes"
# (${a[@]+"${a[@]}"}: an empty array is "unbound" under set -u in bash < 4.4, e.g. macOS)
for s in ${SLUGS[@]+"${SLUGS[@]}"}; do
    case "$s" in ''|*/*|*[[:space:]]*) die2 "bad slug: '$s'" ;; esac
done
if [ -n "${MONITOR_NOW:-}" ]; then is_uint "$MONITOR_NOW" || die2 "MONITOR_NOW must be an epoch"; fi
max_polls="${MONITOR_MAX_POLLS:-0}"
is_uint "$max_polls" || die2 "MONITOR_MAX_POLLS must be a number"
now_step="${MONITOR_NOW_STEP:-$interval}"
is_uint "$now_step" || die2 "MONITOR_NOW_STEP must be a number"

NW="${#SLUGS[@]}"
# Common `-`-terminated prefix of all slugs (none for a single slug: it is the label).
prefix=""
if [ "$NW" -gt 1 ]; then
    prefix="${SLUGS[0]}"
    for s in "${SLUGS[@]}"; do
        while [ -n "$prefix" ] && [ "${s#"$prefix"}" = "$s" ]; do prefix="${prefix%?}"; done
    done
    case "$prefix" in *-*) prefix="${prefix%-*}-" ;; *) prefix="" ;; esac
    # never strip a whole slug down to nothing
    for s in "${SLUGS[@]}"; do [ "$s" = "${prefix%-}" ] && prefix=""; done
fi
if [ -z "$label" ]; then
    if [ "$NW" -eq 0 ]; then label="prs"
    elif [ "$NW" -eq 1 ]; then label="${SLUGS[0]}"
    elif [ -n "$prefix" ]; then label="${prefix%-}"
    else label=workers; fi
fi
case "$label" in */*|*[[:space:]]*) die2 "bad --label: '$label'" ;; esac
NAMES=()
for s in ${SLUGS[@]+"${SLUGS[@]}"}; do NAMES+=("${s#"$prefix"}"); done

[ -n "$state_dir" ] || state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/brain/worker-monitor"
# Keyed by label AND the worker set: two monitors that share a label (two coordinators, or
# one re-armed with a different slug list) must never clobber each other's state. The
# hash is of the SORTED slugs plus normalised --pr refs (C collation), so argument order
# does not matter; cksum is POSIX, so the name is the same on every host.
set_hash="$(for s in ${SLUGS[@]+"${SLUGS[@]}"} ${PR_ARGS[@]+"${PR_ARGS[@]}"}; do printf '%s\n' "$s"; done \
    | LC_ALL=C sort | cksum | awk '{ print $1 }')"
state_file="$state_dir/$label-$set_hash.state"

US="$(printf '\037')"   # field separator in the state file (non-whitespace: no collapsing)
RS="$(printf '\036')"   # separator between signature entries
NL='
'

# ---- helpers ------------------------------------------------------------------------
# frontmatter <file> — the lines between the opening and closing `---` fences.
frontmatter() {
    awk 'NR==1 { if ($0 != "---") exit; next } $0 == "---" { exit } { print }' "$1"
}
# fm_get <frontmatter-text> <key> — value of <key>: a quoted value is unquoted; an
# unquoted one loses a trailing ` # comment` (a `#` followed by a space or the end, so
# `PR #9` survives). Surrounding whitespace removed.
fm_get() {
    printf '%s\n' "$1" | awk -v k="$2" '
        index($0, k ":") == 1 {
            v = substr($0, length(k) + 2)
            gsub(/^[[:space:]]+/, "", v)
            q = substr(v, 1, 1)
            if (q == "\"" || q == "'"'"'") {
                v = substr(v, 2)
                if (q == "\"") sub(/"[[:space:]]*(#.*)?$/, "", v)
                else sub(/'"'"'[[:space:]]*(#.*)?$/, "", v)
                gsub(/\\"/, "\"", v)
            } else {
                sub(/[[:space:]]+#([[:space:]].*)?$/, "", v)
            }
            gsub(/[[:space:]]+$/, "", v)
            print v; exit
        }'
}
# clean <text> — whitespace collapsed, `"` (and state-file separators) removed,
# truncated to 160 CHARACTERS ending in `…`. bash's ${#s}/${s:0:n} count bytes under a
# non-UTF-8 locale (a bare `ssh`/`zsh -lc` on a remote host can have LANG unset), which would split
# a multibyte character, so the cut runs in a subshell under the first UTF-8 locale that
# works (MONITOR_UTF8_LOCALES overrides the list, for tests); with none at all it falls
# back to a byte cut minus any partial trailing UTF-8 sequence.
UTF8_LOCALES="${MONITOR_UTF8_LOCALES:-C.UTF-8 en_US.UTF-8 UTF-8}"
clean() {
    local s out loc
    s="$(printf '%s' "$1" | tr -d '"\036\037' | tr '\t\r\n' '   ' | tr -s ' ')"
    s="${s# }"; s="${s% }"
    for loc in $UTF8_LOCALES; do
        if out="$( { LC_ALL="$loc"; probe='…'; [ "${#probe}" -eq 1 ] || exit 1
                     if [ "${#s}" -gt 160 ]; then printf '%s…' "${s:0:159}"; else printf '%s' "$s"; fi
                   } 2>/dev/null )"; then
            printf '%s' "$out"; return 0
        fi
    done
    ( LC_ALL=C
      [ "${#s}" -gt 160 ] || { printf '%s' "$s"; exit 0; }
      s="${s:0:159}"
      # drop a trailing lead byte plus its continuation bytes if the sequence is short
      local k=0 n=${#s} b want
      while [ "$k" -lt 4 ] && [ "$k" -lt "$n" ]; do
          b="$(printf '%d' "'${s:n-1-k:1}")"; [ "$b" -lt 0 ] && b=$((b + 256))
          if [ "$b" -ge 128 ] && [ "$b" -lt 192 ]; then k=$((k + 1)); continue; fi
          if [ "$b" -ge 240 ]; then want=4; elif [ "$b" -ge 224 ]; then want=3
          elif [ "$b" -ge 192 ]; then want=2; else want=1; fi
          [ $((k + 1)) -lt "$want" ] && s="${s:0:n-1-k}"
          break
      done
      printf '%s…' "$s" )
}
fmt_dur() {
    local m=$(( ${1:-0} / 60 ))
    [ "$m" -lt 0 ] && m=0
    if [ "$m" -lt 60 ]; then printf '%sm' "$m"; else printf '%sh' $((m / 60)); fi
}
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
needs_of() {
    case "$1" in
        unknown) echo CHECK ;; done) echo COLLECT ;; gone) echo REVIVE ;;
        question) echo ANSWER ;; review) echo REVIEW ;; blocked) echo UNBLOCK ;;
        idle) echo NUDGE ;; stuck) echo INSPECT ;; *) return 1 ;;
    esac
}
add_err() {
    case "$NL$ERRS_NOW$NL" in *"$NL$1$NL"*) return 0 ;; esac
    ERRS_NOW="${ERRS_NOW:+$ERRS_NOW$NL}$1"
}
# transcript_mtime <host> <session_id> — on <host>, the NEWEST epoch mtime among the
# conversation's transcript ~/.claude/projects/*/<id>.jsonl and its background subagents'
# ~/.claude/projects/*/<id>/subagents/*.jsonl (a worker whose own transcript is quiet while
# its agent streams is working, not stuck), or nothing.
transcript_mtime() {
    local out
    out="$(run_on_host "$1" "find \"\$HOME/.claude/projects\" -maxdepth 4 -type f \\( -path '*/$2.jsonl' -o -path '*/$2/subagents/*.jsonl' \\) 2>/dev/null | while IFS= read -r f; do stat -c %Y \"\$f\" 2>/dev/null || stat -f %m \"\$f\"; done | sort -n | tail -1" 2>/dev/null)"
    out="$(printf '%s\n' "$out" | tail -1)"
    is_uint "$out" && printf '%s' "$out"
}
# transcript_last_said <host> <session_id> — on <host>, the LAST non-blank line (minus a
# leading `- `/`* `/`#`/`>` marker) of the last non-sidechain assistant entry with a
# non-blank text block in the conversation's MAIN transcript ~/.claude/projects/*/<id>.jsonl
# (never its subagents'). Only the last 200 lines are read (transcripts get huge); lines
# that are not JSON objects are skipped. jq runs on <host> (a remote's login PATH), so only
# the one line crosses ssh. Prints nothing (rc 1) when the file, jq or a text is missing.
TRANSCRIPT_SAID_JQ='[inputs | fromjson? | objects
  | select(.type == "assistant" and (.isSidechain != true))
  | [ (.message.content? | arrays | .[] | objects | select(.type == "text") | .text | strings
       | select(test("\\S"))) ] | last | strings ]
  | last // empty
  | [ split("\n")[] | select(test("\\S")) ] | last // empty
  | sub("^\\s*([-*>]|#+)\\s+"; "") | sub("\\s+$"; "")'
transcript_last_said() {
    local out
    out="$(run_on_host "$1" "f=\"\$(find \"\$HOME/.claude/projects\" -mindepth 2 -maxdepth 2 -type f -name '$2.jsonl' 2>/dev/null | head -1)\"; [ -n \"\$f\" ] || exit 1; tail -n 200 \"\$f\" 2>/dev/null | jq -Rnr '$TRANSCRIPT_SAID_JQ' 2>/dev/null" 2>/dev/null </dev/null)" || return 1
    out="$(printf '%s\n' "$out" | tail -1)"
    [ -n "$out" ] || return 1
    printf '%s' "$out"
}

# ---- persisted state (indexed by argument position) ---------------------------------
P_STATE=() P_KEY=() P_DETAIL=() P_ENTERED=() P_BUSY=() P_IDLEN=() P_IDLES=()
i=0; while [ "$i" -lt "$NW" ]; do
    P_STATE[i]="" P_KEY[i]="" P_DETAIL[i]="" P_ENTERED[i]="" P_BUSY[i]="" P_IDLEN[i]=0 P_IDLES[i]=""
    i=$((i + 1))
done
LAST_SIG="" PREV_ERRS=""
if [ -r "$state_file" ]; then
    while IFS="$US" read -r kind a b c d e f g h; do
        case "$kind" in
            sig) LAST_SIG="$a" ;;
            err) PREV_ERRS="${PREV_ERRS:+$PREV_ERRS$NL}$a" ;;
            w)
                i=0; while [ "$i" -lt "$NW" ]; do
                    if [ "${SLUGS[i]}" = "$a" ]; then
                        P_STATE[i]="$b" P_KEY[i]="$c" P_DETAIL[i]="$d" P_ENTERED[i]="$e"
                        P_BUSY[i]="$f" P_IDLEN[i]="${g:-0}" P_IDLES[i]="$h"
                        is_uint "${P_IDLEN[i]}" || P_IDLEN[i]=0
                    fi
                    i=$((i + 1))
                done ;;
        esac
    done <"$state_file"
fi
# PR state lives in a per-LABEL file, not the per-slug-set one: a coordinator re-arms
# with a changed slug list after every dispatch/collect, and that must not re-announce
# (in capitals) every PR already reported — a re-announced MERGED invites a second collect.
# Several monitors may share a label (default labels collide: `pawl-pm pawl-tl` and
# `pawl-feat pawl-fix` are both `pawl`), so the file is MERGED, never replaced: a run
# writes only the PRs named in its current poll (TOUCHED) and keeps every other PR's
# records — so a PR named again later (a collected worker's PR re-added with --pr)
# resumes from its last printed tuple, silently. A poll that names no PR never writes it.
# The read-modify-write is under a mkdir lock (flock is not on macOS), released by an
# EXIT trap if the monitor is killed while holding it; a lock whose mtime is 60 s or more
# old is a crashed writer's and is taken over by renaming it to a unique name first (so
# of two waiters only one wins). Bounded: a PR unseen for MONITOR_PR_TTL_DAYS (30) is dropped.
# The maps hold one `<ref>=<value>` line per PR, sorted (C collation):
#   KNOWN    the last successfully read `<state> <head7> <mergeable> <checks>` — what a gh
#            failure carries forward (and a MERGED PR is never re-read);
#   PRINTED  the `state:head:mergeable:checks` of each PR row in the last printed line —
#            what "changed" (capitals, and a new line) is measured against;
#   SEEN     the epoch the PR was last watched (for the TTL).
pr_state_file="$state_dir/$label.prs.state"
pr_ttl_days="${MONITOR_PR_TTL_DAYS:-30}"
is_uint "$pr_ttl_days" || die2 "MONITOR_PR_TTL_DAYS must be a number"
TOUCHED=""   # refs this run watched, one per line
# read_pr_state — sets R_K R_P R_S (KNOWN, PRINTED, SEEN) from the PR state file.
read_pr_state() {
    local kind a b c
    R_K="" R_P="" R_S=""
    [ -r "$pr_state_file" ] || return 0
    while IFS="$US" read -r kind a b c; do
        case "$kind" in
            p) R_K="${R_K:+$R_K$NL}$a=$b"; [ -z "$c" ] || R_S="${R_S:+$R_S$NL}$a=$c" ;;
            s) R_P="${R_P:+$R_P$NL}$a=$b" ;;
        esac
    done <"$pr_state_file"
}
read_pr_state; KNOWN="$R_K" PRINTED="$R_P" SEEN="$R_S"
# map_merge <base> <overlay> — <base> with <overlay>'s entries added or replacing; sorted.
map_merge() {
    { [ -z "$2" ] || printf '%s\n' "$2"; [ -z "$1" ] || printf '%s\n' "$1"; } \
        | awk '{ k = $0; sub(/=.*/, "", k); if (!(k in s)) { s[k] = 1; print } }' | LC_ALL=C sort
}
# map_keys <map> <keys> <keep|drop> — the entries whose ref is (keep) / is not (drop) in
# the newline-separated <keys>.
map_keys() {
    [ -n "$1" ] || return 0
    printf '%s\n' "$1" | MK_KEYS="$2" MK_MODE="$3" awk '
        BEGIN { n = split(ENVIRON["MK_KEYS"], a, "\n"); for (i = 1; i <= n; i++) if (a[i] != "") w[a[i]] = 1 }
        { k = $0; sub(/=.*/, "", k); if ((k in w) == (ENVIRON["MK_MODE"] == "keep")) print }'
}
PR_LOCKED=0
pr_unlock() { [ "$PR_LOCKED" -eq 1 ] && rmdir "$pr_state_file.lock" 2>/dev/null; PR_LOCKED=0; }
trap 'pr_unlock' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# lock_age <dir> — seconds since <dir>'s mtime (GNU or BSD stat), or nothing.
lock_age() {
    local m
    m="$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null)" || return 1
    is_uint "$m" && printf '%s' $(( $(date +%s) - m ))
}
pr_lock() {
    local l="$pr_state_file.lock" n=0 age side
    while ! mkdir "$l" 2>/dev/null; do
        n=$((n + 1)); [ "$n" -gt 50 ] && return 1
        age="$(lock_age "$l")" || age=""
        if [ -n "$age" ] && [ "$age" -ge 60 ]; then
            # take over a crashed writer's lock: rename first, so only one waiter wins
            side="$l.stale.$$.$n"
            if mv "$l" "$side" 2>/dev/null; then
                age="$(lock_age "$side")" || age=""
                if [ -n "$age" ] && [ "$age" -lt 60 ]; then
                    # lost a race: we moved a FRESH lock someone just took — put it back
                    [ -e "$l" ] || mv "$side" "$l" 2>/dev/null
                fi
                rm -rf "$side" 2>/dev/null
            fi
            continue
        fi
        sleep 0.1
    done
    PR_LOCKED=1
}
save_pr_state() {
    local tmp="$pr_state_file.tmp.$$" mk mp ms dead l rc=1
    pr_lock || return 1
    read_pr_state
    # this run's records win for the PRs it watched; every other PR's are kept
    mk="$(map_merge "$R_K" "$(map_keys "$KNOWN" "$TOUCHED" keep)")"
    mp="$(map_merge "$R_P" "$(map_keys "$PRINTED" "$TOUCHED" keep)")"
    ms="$(map_merge "$R_S" "$(map_keys "$SEEN" "$TOUCHED" keep)")"
    dead="$(printf '%s\n' "$ms" | awk -F= -v c=$((now - pr_ttl_days * 86400)) '$0 != "" && $2 < c { print $1 }')"
    if [ -n "$dead" ]; then
        mk="$(map_keys "$mk" "$dead" drop)" mp="$(map_keys "$mp" "$dead" drop)" ms="$(map_keys "$ms" "$dead" drop)"
    fi
    {
        printf 'v1\n'
        # p<US>ref<US>tuple<US>seen
        [ -z "$mk" ] || printf '%s\n' "$mk" | while IFS= read -r l; do
            printf 'p%s%s%s%s%s%s\n' "$US" "${l%%=*}" "$US" "${l#*=}" "$US" "$(map_get "$ms" "${l%%=*}")"
        done
        [ -z "$mp" ] || printf '%s\n' "$mp" | sed "s/=/$US/; s/^/s$US/"
    } >"$tmp" 2>/dev/null && mv -f "$tmp" "$pr_state_file" 2>/dev/null && rc=0
    [ "$rc" -eq 0 ] || rm -f "$tmp" 2>/dev/null
    pr_unlock
    return "$rc"
}

save_state() {
    local tmp i
    tmp="$state_file.tmp.$$"
    {
        printf 'v1\n'
        printf 'sig%s%s\n' "$US" "$LAST_SIG"
        i=0; while [ "$i" -lt "$NW" ]; do
            printf 'w%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s\n' "$US" "${SLUGS[i]}" "$US" "${P_STATE[i]}" \
                "$US" "${P_KEY[i]}" "$US" "${P_DETAIL[i]}" "$US" "${P_ENTERED[i]}" "$US" "${P_BUSY[i]}" \
                "$US" "${P_IDLEN[i]}" "$US" "${P_IDLES[i]}"
            i=$((i + 1))
        done
        if [ -n "$PREV_ERRS" ]; then printf '%s\n' "$PREV_ERRS" | sed "s/^/err$US/"; fi
    } >"$tmp" 2>/dev/null && mv -f "$tmp" "$state_file" 2>/dev/null && return 0
    rm -f "$tmp" 2>/dev/null
    return 1
}

WARNED=""   # slugs already warned about (legacy host / missing harness) this run
# note_file <slug> — <vault>/workers/<slug>.md, else the private/workers/ copy if only it exists.
note_file() {
    local f="$vault/workers/$1.md"
    [ -e "$f" ] || { [ ! -e "$vault/private/workers/$1.md" ] || f="$vault/private/workers/$1.md"; }
    printf '%s' "$f"
}

# ---- PR watch ------------------------------------------------------------------------
WARNED_PR=""   # `<slug> <ref>` pairs already warned about (unsupported PR reference) this run
# discover_prs — sets PR_REFS: the --pr refs, then every GitHub PR named in a watched
# worker's note frontmatter (`blocker:` URLs; `pr:` URLs or <o>/<r>#<n>), deduplicated,
# in that order. A PR URL that forge.sh cannot parse is warned once per slug per run.
discover_prs() {
    # (no `,` inside a URL: `…/pull/1,https://…/pull/2` is two URLs, not one)
    local s f fm x ref cands url_re='https?://[^[:space:]"<>,]*/(pull|pulls|merge_requests)/[0-9]+'
    PR_REFS=(${PR_ARGS[@]+"${PR_ARGS[@]}"})
    for s in ${SLUGS[@]+"${SLUGS[@]}"}; do
        f="$(note_file "$s")"
        [ -r "$f" ] && fm="$(frontmatter "$f" 2>/dev/null)" && [ -n "$fm" ] || continue
        # candidates, one per line: URLs in blocker:, and pr:'s items (URLs or o/r#n,
        # separated by any mix of commas and whitespace; `[…]` brackets ignored)
        cands="$( { fm_get "$fm" blocker | grep -oE "$url_re"
                    fm_get "$fm" pr | tr '[],\t' '    ' | tr -s ' ' '\n' | while IFS= read -r x; do
                        case "$x" in '') ;; *://*) printf '%s\n' "$x" | grep -oE "$url_re" ;; *) printf '%s\n' "$x" ;; esac
                    done; } )"
        while IFS= read -r x; do
            [ -n "$x" ] || continue
            if ref="$(pr_ref_parse "$x")"; then
                case " ${PR_REFS[*]-} " in *" $ref "*) ;; *) PR_REFS+=("$ref") ;; esac
            else
                case "$NL$WARNED_PR$NL" in *"$NL$s $x$NL"*) ;; *)
                    WARNED_PR="${WARNED_PR:+$WARNED_PR$NL}$s $x"
                    printf 'warning: %s: unsupported PR reference %s (only GitHub PRs are watched)\n' "$s" "$x" >&2 ;;
                esac
            fi
        done <<EOF
$cands
EOF
    done
}
# map_get <map> <ref> — the value of <ref> in a `<ref>=<value>` line map, or rc 1.
map_get() {
    local l
    while IFS= read -r l; do
        case "$l" in "$2="*) printf '%s' "${l#"$2="}"; return 0 ;; esac
    done <<EOF
$1
EOF
    return 1
}
# pr_word <state> <mergeable> <checks> — the row's lowercase state word. `green` needs
# checks that PASS: `none` (a new PR whose checks have not registered yet, or a repo with
# no CI) stays `open` — for a no-CI repo, `open … checks=none MERGEABLE` is its ready state.
pr_word() {
    case "$1" in MERGED) echo merged; return ;; CLOSED) echo closed; return ;; esac
    if [ "$3" = fail ]; then echo red
    elif [ "$2" = CONFLICTING ]; then echo conflict
    elif [ "$1" = DRAFT ]; then echo draft
    elif [ "$3" = pending ]; then echo ci
    elif [ "$2" = MERGEABLE ] && [ "$3" = pass ]; then echo green
    else echo open; fi
}
# pr_rows — reads every PR_REFS entry (one gh call each; MERGED ones are not re-read) and
# sets P_SEG (` · <row>…`), P_WAIT (rows waiting), P_CHG (1 when any row changed since
# the last printed line), P_NOW (the PRINTED map this line would record) and K_NOW (the
# new KNOWN, for the referenced PRs only); gh failures go to add_err.
pr_rows() {
    local ref t t2 res rc msg stale prev ph pm st h m c w word repo name one=1 q tail rnames dup=0
    P_SEG="" P_WAIT=0 P_CHG=0 P_NOW="" K_NOW=""
    # names: `#n` for one repo; `repo#n` across repos; `owner/repo#n` when two owners'
    # repos share a name
    repo="${PR_REFS[0]%#*}" rnames=""
    for ref in ${PR_REFS[@]+"${PR_REFS[@]}"}; do
        [ "${ref%#*}" = "$repo" ] || one=0
        name="${ref%#*}"; name="${name#github:}"
        case "$NL$rnames$NL" in
            *"$NL$name$NL"*) ;;
            *) case "$NL$(printf '%s\n' "$rnames" | sed 's#.*/##')$NL" in *"$NL${name##*/}$NL"*) dup=1 ;; esac
               rnames="${rnames:+$rnames$NL}$name" ;;
        esac
    done
    for ref in ${PR_REFS[@]+"${PR_REFS[@]}"}; do
        repo="${ref%#*}"; repo="${repo#github:}"
        if [ "$one" -eq 1 ]; then name="#${ref##*#}"
        elif [ "$dup" -eq 1 ]; then name="$repo#${ref##*#}"
        else name="${repo##*/}#${ref##*#}"; fi
        stale="" t="$(map_get "$KNOWN" "$ref")" || t=""
        case "$t" in MERGED\ *) ;; *)
            res="$(pr_status "$ref" 2>&1)"; rc=$?
            if [ "$rc" -eq 0 ] && t2="$(printf '%s\n' "$res" | tail -1)" \
                && [[ "$t2" =~ ^[A-Z]+\ [0-9a-f]{7}\ [A-Z]+\ [a-z]+$ ]]; then
                t="$t2"
            else
                msg="$(printf '%s\n' "$res" | grep -v '^[[:space:]]*$' | head -1)"
                add_err "gh ${ref#github:}: $(clean "${msg:-gh failed (rc $rc)}")"
                stale="gh"
            fi ;;
        esac
        q="" tail=""
        [ -n "$stale" ] && q="?" tail=" (stale: $stale)"
        if [ -z "$t" ]; then
            P_SEG="$P_SEG · $name unknown$q$tail"
            continue
        fi
        K_NOW="${K_NOW:+$K_NOW$NL}$ref=$t"
        read -r st h m c <<EOF
$t
EOF
        # GitHub flips mergeable to UNKNOWN while it recomputes: that alone is no change,
        # so the last printed value stands in for it in the signature and the word — but
        # only on the SAME head (after a rebase the old CONFLICTING no longer holds).
        prev="" ph="" pm=""
        if prev="$(map_get "$PRINTED" "$ref")"; then IFS=: read -r _ ph pm _ <<EOF
$prev
EOF
        fi
        w="$m"; [ "$m" = UNKNOWN ] && [ -n "$pm" ] && [ "$ph" = "$h" ] && w="$pm"
        P_NOW="${P_NOW:+$P_NOW$NL}$ref=$st:$h:$w:$c"
        word="$(pr_word "$st" "$w" "$c")"
        case "$word" in merged|closed|red|conflict) P_WAIT=$((P_WAIT + 1)) ;; esac
        if [ -z "$prev" ] || [ "$prev" != "$st:$h:$w:$c" ]; then
            P_CHG=1
            if [ -n "$prev" ] && [ "$st" = OPEN ] && [ "$ph" != "$h" ] && [ "$word" != red ] && [ "$word" != conflict ]; then
                word=HEAD
            else
                word="$(printf '%s' "$word" | tr '[:lower:]' '[:upper:]')"
            fi
        fi
        P_SEG="$P_SEG · $name $word$q @$h checks=$c $m$tail"
    done
    # stored sorted, so the order PRs are named in never matters
    [ -z "$P_NOW" ] || P_NOW="$(printf '%s\n' "$P_NOW" | LC_ALL=C sort)"
    [ -z "$K_NOW" ] || K_NOW="$(printf '%s\n' "$K_NOW" | LC_ALL=C sort)"
}
# err_key <message> — the monitor-error dedup key: a gh message's digits (a rate-limit
# reset time, a request id) vary from poll to poll, so they are folded out of the KEY
# (after the `gh <owner/repo#n>: ` prefix, which tells PRs apart); the printed text stays
# verbatim. Every other message is its own key.
err_key() {
    case "$1" in
        "gh "*": "*) printf '%s: %s' "${1%%: *}" "$(printf '%s' "${1#*: }" | sed -E 's/[0-9]+/0/g')" ;;
        *) printf '%s' "$1" ;;
    esac
}

# ---- classification ------------------------------------------------------------------
# classify <i> <now> — sets C_STATE C_KEY C_DETAIL and the new streak values
# C_BUSY (busy-since epoch) C_IDLEN (consecutive idle polls) C_IDLES (idle-since epoch);
# C_STALE is non-empty (the reason) when the row was carried over an unreachable host.
classify() {
    local i="$1" now="$2" slug f fm status host harness sess sid err rc pane flags blocker pr msg mt
    slug="${SLUGS[i]}" f="$(note_file "$slug")"
    C_STATE="" C_KEY="" C_DETAIL="" C_BUSY="" C_IDLEN=0 C_IDLES="" C_STALE=""
    if [ ! -r "$f" ] || ! fm="$(frontmatter "$f" 2>/dev/null)" || [ -z "$fm" ]; then
        C_STATE=unknown C_KEY="no note" C_DETAIL="no note"; return
    fi
    status="$(fm_get "$fm" status)"; status="${status%%[[:space:]]*}"
    case "$status" in
        collected) C_STATE=collected; return ;;
        done)      C_STATE=done; return ;;
    esac
    host="$(fm_get "$fm" host)"; host="${host%%[[:space:]]*}"
    harness="$(fm_get "$fm" harness)"
    # Legacy `host: local` / no host is read as THIS machine; a missing harness as omp.
    # Both are warned in ONE line (revive-workers.sh's shape), once per slug per run
    # (stderr only — stdout stays one line per event).
    local warn="" legacy pd xpd
    if host_is_legacy "$host"; then
        legacy="${host:-unset}"
        if ! host="$(host_canon "$host")"; then
            C_STATE=unknown C_KEY="no self host" C_DETAIL="legacy host $legacy but this machine is not in hosts.conf"
            add_err "worker $slug: legacy host $legacy but this machine's host is unresolved (add its hostname to hosts.conf or set BRAIN_SELF_HOST)"
            return
        fi
        warn="legacy host '$legacy' read as $host"
        pd="$(fm_get "$fm" project_dir)"; pd="${pd%%[[:space:]]*}"
        xpd="$pd"; case "$xpd" in "~"|"~/"*) xpd="$HOME${xpd#\~}" ;; esac
        if [ -n "$pd" ] && [ ! -d "$xpd" ]; then
            warn="$warn — project_dir $pd is not on this machine; it probably belongs to another host (fix its host:)"
        fi
    fi
    if [ -z "$harness" ]; then
        harness=omp
        warn="${warn:+$warn; }no harness: — assuming omp"
    fi
    if [ -n "$warn" ]; then
        case " $WARNED " in *" $slug "*) ;; *)
            WARNED="$WARNED $slug"
            printf 'warning: %s: %s\n' "$slug" "$warn" >&2 ;;
        esac
    fi
    sess="$(fm_get "$fm" tmux_session)";  [ -n "$sess" ] || sess="brain-worker-$slug"
    sid="$(fm_get "$fm" session_id)"
    if ! host_field "$host" ssh_alias >/dev/null 2>&1; then
        add_err "worker $slug: unknown host $host"
        C_STATE=unknown C_KEY="unknown host $host" C_DETAIL="unknown host $host"; return
    fi
    if ! valid_harness "$harness"; then
        C_STATE=unknown C_KEY="unknown harness $harness" C_DETAIL="unknown harness $harness"; return
    fi
    case "$sess" in *[!A-Za-z0-9._-]*) C_STATE=unknown C_KEY="bad tmux_session" C_DETAIL="bad tmux_session"; return ;; esac
    if ! host_reachable "$host"; then
        # hosts.conf alias `-` and not this machine: say so, not "tmux unreachable (rc 1)"
        msg="no ssh route from $(self_host 2>/dev/null || echo 'this machine') to $host (hosts.conf alias -)"
        add_err "$msg"
        C_STATE=unknown C_KEY="no ssh route to $host" C_DETAIL="$msg"; return
    fi

    err="$(tmx "$host" has-session -t "'=$sess'" 2>&1 >/dev/null)"; rc=$?
    if [ "$rc" -ne 0 ]; then
        if [ "$rc" -eq 1 ] && { [ -z "$err" ] || printf '%s' "$err" | grep -qiE "can't find session|no server running|no such file or directory"; }; then
            if [ "$status" = parked ]; then C_STATE=parked; else
                C_STATE=gone C_KEY="${status:--}" C_DETAIL="note=${status:--}"; fi
            return
        fi
        add_err "tmux on host $host unreachable (rc $rc)"
        if [ -n "${P_STATE[i]}" ] && [ "${P_KEY[i]}" != "host $host unreachable" ]; then
            # carry the last known classification forward, visibly marked: the row reads
            # `<name> <state>? <dur> … (stale: host <h> unreachable)`. The signature is
            # the carried one, so going stale alone never re-emits a line (the host's
            # one-off monitor-error already announced it).
            C_STATE="${P_STATE[i]}" C_KEY="${P_KEY[i]}" C_DETAIL="${P_DETAIL[i]}"
            C_BUSY="${P_BUSY[i]}" C_IDLEN="${P_IDLEN[i]}" C_IDLES="${P_IDLES[i]}"
            C_STALE="host $host unreachable"
        else
            C_STATE=unknown C_KEY="host $host unreachable" C_DETAIL="host $host unreachable"
        fi
        return
    fi
    # The state predicates read the VISIBLE screen only: assistant prose or an old dialog
    # that scrolled off (`Do you want to proceed?`, a question footer) would otherwise
    # read as an open question forever. The history capture (-S -60) is taken only for
    # the detail text — the question's header can sit above a tall dialog's top edge, and
    # the last message above the fold.
    flags="$(pane_capture_flags "$harness")"
    pane="$(tmx "$host" capture-pane -p $flags -t "'=$sess:'" 2>/dev/null)"
    deep_pane() { tmx "$host" capture-pane -p $flags -t "'=$sess:'" -S -60 2>/dev/null; }

    if pane_question "$harness" "$pane"; then
        msg="$(pane_question_text "$harness" "$(deep_pane)")" \
            || msg="$(pane_question_text "$harness" "$pane")" || msg="(unrecognised dialog)"
        msg="$(clean "$msg")"
        C_STATE=question C_KEY="$msg" C_DETAIL="\"$msg\""; return
    fi
    if [ "$status" = blocked ]; then
        blocker="$(clean "$(fm_get "$fm" blocker)")"
        case "$(lower "$blocker")" in
            *"awaiting review"*)
                pr="$(printf '%s' "$blocker" | grep -oE '/(pull|pulls|merge_requests)/[0-9]+' | head -1 | grep -oE '[0-9]+$')"
                C_STATE=review
                if [ -n "$pr" ]; then C_KEY="PR#$pr" C_DETAIL="PR#$pr"; else C_KEY="$blocker" C_DETAIL="\"$blocker\""; fi
                return ;;
        esac
        [ -n "$blocker" ] || blocker="(no blocker given)"
        C_STATE=blocked C_KEY="$blocker" C_DETAIL="\"$blocker\""; return
    fi
    [ "$status" = parked ] && { C_STATE=parked; return; }
    if pane_idle "$harness" "$pane"; then
        case "$status" in
            primed|working)
                C_IDLEN=$(( ${P_IDLEN[i]:-0} + 1 ))
                C_IDLES="${P_IDLES[i]:-$now}"
                if [ "$C_IDLEN" -ge 2 ]; then
                    C_STATE=idle C_KEY="$status" C_DETAIL="note=$status"
                    msg=""
                    if [ "$harness" = claude ] && valid_session_id claude "$sid"; then
                        msg="$(transcript_last_said "$host" "$sid")" || msg=""
                    fi
                    if [ -n "$msg" ] || { msg="$(pane_last_message "$harness" "$(deep_pane)")" && [ -n "$msg" ]; }; then
                        C_DETAIL="$C_DETAIL said:\"$(clean "$msg")\""
                    fi
                    return
                fi ;;
        esac
    elif pane_busy "$harness" "$pane"; then
        C_BUSY="${P_BUSY[i]:-$now}"
        if [ "$harness" = claude ] && valid_session_id claude "$sid"; then
            mt="$(transcript_mtime "$host" "$sid")"
            if [ -n "$mt" ] && [ $((now - mt)) -gt $((stuck_after * 60)) ]; then
                C_STATE=stuck C_KEY=""
                C_DETAIL="busy $(fmt_dur $((now - C_BUSY))), transcript silent $(fmt_dur $((now - mt)))"
                return
            fi
        fi
    fi
    C_STATE=busy
}

# ---- poll loop -----------------------------------------------------------------------
poll=0
while :; do
    if [ -n "${MONITOR_NOW:-}" ]; then now=$((MONITOR_NOW + poll * now_step)); else now="$(date +%s)"; fi
    ts="$(iso "$now")"
    ERRS_NOW=""
    writable=1
    if [ "$once" -eq 0 ]; then
        { mkdir -p "$state_dir" 2>/dev/null && [ -w "$state_dir" ]; } || {
            writable=0; add_err "state dir $state_dir unwritable"; }
    fi

    if [ "$NW" -gt 0 ] && [ ! -d "$vault/workers" ] && [ ! -d "$vault/private/workers" ]; then
        add_err "vault $vault/workers missing"
        have_line=0
    else
        have_line=1
        N_STATE=() N_KEY=() N_DETAIL=() N_ENTERED=() N_BUSY=() N_IDLEN=() N_IDLES=() N_STALE=()
        i=0; while [ "$i" -lt "$NW" ]; do
            classify "$i" "$now"
            N_STATE[i]="$C_STATE" N_KEY[i]="$C_KEY" N_DETAIL[i]="$C_DETAIL"
            N_BUSY[i]="$C_BUSY" N_IDLEN[i]="$C_IDLEN" N_IDLES[i]="$C_IDLES" N_STALE[i]="$C_STALE"
            if [ "$C_STATE" = "${P_STATE[i]}" ] && [ "$C_KEY" = "${P_KEY[i]}" ] && [ -n "${P_ENTERED[i]}" ]; then
                N_ENTERED[i]="${P_ENTERED[i]}"
            else
                case "$C_STATE" in
                    idle) N_ENTERED[i]="${C_IDLES:-$now}" ;;
                    busy) N_ENTERED[i]="${C_BUSY:-$now}" ;;
                    *)    N_ENTERED[i]="$now" ;;
                esac
            fi
            i=$((i + 1))
        done
        # signature + line
        sig="" wseg="" rseg="" nwait=0
        i=0; while [ "$i" -lt "$NW" ]; do
            st="${N_STATE[i]}" dur="$(fmt_dur $((now - ${N_ENTERED[i]})))"
            q="" tail=""
            [ -n "${N_STALE[i]}" ] && q="?" tail=" (stale: ${N_STALE[i]})"
            if needs="$(needs_of "$st")"; then
                entry="${SLUGS[i]}=$st:${N_KEY[i]}"
                sig="${sig:+$sig$RS}$entry"
                case "$RS$LAST_SIG$RS" in *"$RS$entry$RS"*) word="$st" ;; *) word="$needs" ;; esac
                s="${NAMES[i]} $word$q $dur"
                [ -n "${N_DETAIL[i]}" ] && s="$s ${N_DETAIL[i]}"
                wseg="$wseg · $s$tail"; nwait=$((nwait + 1))
            else
                rseg="$rseg · ${NAMES[i]} $st$q $dur$tail"
            fi
            i=$((i + 1))
        done
        # PR rows, after the worker rows (none named → the line is exactly as before)
        discover_prs
        P_SEG="" K_NOW="" P_NOW="" P_CHG=0
        if [ "${#PR_REFS[@]}" -gt 0 ]; then
            pr_rows
            nwait=$((nwait + P_WAIT))
        fi
        line="$ts $label $nwait/$((NW + ${#PR_REFS[@]})) waiting$wseg$rseg$P_SEG"
    fi

    # errors: once per distinct message (re-armed when the message clears)
    if [ -n "$ERRS_NOW" ]; then
        while IFS= read -r e; do
            [ -n "$e" ] || continue
            if [ "$once" -eq 1 ]; then printf '%s %s monitor-error %s\n' "$ts" "$label" "$e"; continue; fi
            case "$NL$PREV_ERRS$NL" in *"$NL$(err_key "$e")$NL"*) ;; *) printf '%s %s monitor-error %s\n' "$ts" "$label" "$e" ;; esac
        done <<EOF
$ERRS_NOW
EOF
    fi

    # a line when the worker waits changed (sig) or any PR row changed (P_CHG)
    if [ "$have_line" -eq 1 ]; then
        if [ "$once" -eq 1 ]; then
            printf '%s\n' "$line"
        elif [ "$sig" != "$LAST_SIG" ] || [ "$P_CHG" -eq 1 ]; then
            printf '%s\n' "$line"
            # PRs not named now keep their last printed tuple (named again → resume)
            LAST_SIG="$sig" PRINTED="$(map_merge "$PRINTED" "$P_NOW")"
        fi
    fi
    [ "$once" -eq 1 ] && exit 0

    PREV_ERRS=""   # the dedup KEYS of this poll's errors
    if [ -n "$ERRS_NOW" ]; then
        while IFS= read -r e; do
            [ -n "$e" ] && PREV_ERRS="${PREV_ERRS:+$PREV_ERRS$NL}$(err_key "$e")"
        done <<EOF
$ERRS_NOW
EOF
    fi
    if [ "$have_line" -eq 1 ]; then
        i=0; while [ "$i" -lt "$NW" ]; do
            P_STATE[i]="${N_STATE[i]}" P_KEY[i]="${N_KEY[i]}" P_DETAIL[i]="${N_DETAIL[i]}"
            P_ENTERED[i]="${N_ENTERED[i]}" P_BUSY[i]="${N_BUSY[i]}"
            P_IDLEN[i]="${N_IDLEN[i]}" P_IDLES[i]="${N_IDLES[i]}"
            i=$((i + 1))
        done
        if [ "${#PR_REFS[@]}" -gt 0 ]; then
            KNOWN="$(map_merge "$KNOWN" "$K_NOW")"
            SEEN="$(map_merge "$SEEN" "$(for r in "${PR_REFS[@]}"; do printf '%s=%s\n' "$r" "$now"; done)")"
        fi
        # only the PRs named THIS poll: a PR this run stopped naming may be watched by
        # another monitor on the label, whose newer record must not be overwritten
        TOUCHED="$(for r in ${PR_REFS[@]+"${PR_REFS[@]}"}; do printf '%s\n' "$r"; done)"
    fi
    if [ "$writable" -eq 1 ] && ! save_state; then
        printf 'worker-monitor: could not write %s\n' "$state_file" >&2
    fi
    # (a run that has watched no PR never writes the label's PR state)
    if [ "$writable" -eq 1 ] && [ -n "$TOUCHED" ] && ! save_pr_state; then
        printf 'worker-monitor: could not write %s\n' "$pr_state_file" >&2
    fi

    poll=$((poll + 1))
    [ "$max_polls" -gt 0 ] && [ "$poll" -ge "$max_polls" ] && exit 0
    [ "$interval" -gt 0 ] && sleep "$interval"
done
