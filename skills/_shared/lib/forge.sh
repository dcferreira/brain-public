#!/usr/bin/env bash
#
# forge.sh — the forge axis: where a pull request lives and what state it is in. GitHub
# only today, behind a normalised `<forge>:<owner>/<repo>#<n>` reference so a GitLab
# backend can be added by teaching pr_ref_parse its URLs and giving pr_status a
# `gitlab:` branch; callers never branch on the forge. Pure functions, no side effects
# beyond the one gh call; safe to `source` under a caller's `set -euo pipefail`
# (functions return non-zero rather than exiting the caller's shell).
#
# gh runs on THIS machine (the coordinator's), never over ssh to a worker's host.
#
# Env (overridable, e.g. by tests):
#   BRAIN_GH            gh invocation (stubbed in tests)              default: command gh
#   BRAIN_GH_TIMEOUT    seconds before a hung gh is killed (only when
#                       `timeout` or `gtimeout` exists; else unwrapped) default: 30
#   FORGE_TIMEOUT_CMDS  timeout commands tried, in order (test seam)    default: timeout gtimeout
#
# Functions:
#   pr_ref_parse <url-or-ref>   prints `github:<owner>/<repo>#<n>` (owner/repo lowercased: GitHub
#                               names are case-insensitive); rc 1 (silent) when unsupported.
#                               Accepts https://github.com/<o>/<r>/pull/<n>[/…|#…|?…], <o>/<r>#<n>
#                               and the normalised form itself.
#   pr_status <normalised-ref>  prints ONE line `<state> <head7> <mergeable> <checks>`:
#                                 state      OPEN | DRAFT (open + isDraft) | MERGED | CLOSED (unmerged)
#                                 head7      first 7 of the head commit
#                                 mergeable  MERGEABLE | CONFLICTING | UNKNOWN
#                                 checks     over the latest run per (workflow, check name) / status context:
#                                            fail (any FAILURE/ERROR/CANCELLED/TIMED_OUT/
#                                            ACTION_REQUIRED/STARTUP_FAILURE) > pending (any not
#                                            completed) > pass (≥1 check) > none (no checks)
#                               rc ≠ 0 with the reason on stderr (gh's own message on a gh failure,
#                               `gh timed out after <s>s` on a timeout).

set -u

BRAIN_GH="${BRAIN_GH:-command gh}"

# pr_ref_parse <url-or-ref> — see the header. Owner/repo names are [A-Za-z0-9_.-]; the
# number must be followed by nothing, or by `/`, `#` or `?` (a URL's tail).
pr_ref_parse() {
    local s="${1:-}" nm='[A-Za-z0-9_.-]+' o r n
    if [[ "$s" =~ ^https?://(www\.)?github\.com/($nm)/($nm)/pull/([0-9]+)([/#?].*)?$ ]]; then
        o="${BASH_REMATCH[2]}" r="${BASH_REMATCH[3]}" n="${BASH_REMATCH[4]}"
    elif [[ "$s" =~ ^(github:)?($nm)/($nm)#([0-9]+)$ ]]; then
        o="${BASH_REMATCH[2]}" r="${BASH_REMATCH[3]}" n="${BASH_REMATCH[4]}"
    else
        return 1
    fi
    # GitHub owner/repo names are case-insensitive: lowercase so one PR is one ref
    printf 'github:%s#%s\n' "$(printf '%s/%s' "$o" "$r" | tr '[:upper:]' '[:lower:]')" "$n"
}

# The checks verdict over gh's statusCheckRollup: CheckRuns carry status + conclusion,
# StatusContexts carry state. A re-run or re-push leaves the superseded runs in the rollup
# (e.g. a CANCELLED duplicate beside its SUCCESS), so only the most recent CheckRun per
# (workflow, name) / StatusContext per context counts — the same job name in two
# workflows is two checks: latest by startedAt, then completedAt, then array position
# (gh's rollup already carries workflowName and both timestamps for CheckRuns).
# Unknown PR states or a missing head are rejected (jq error).
# shellcheck disable=SC2016  # a jq program: its $vars are jq's, not the shell's
_FORGE_GH_JQ='
  def bad: . as $x | any(("FAILURE","ERROR","CANCELLED","TIMED_OUT","ACTION_REQUIRED","STARTUP_FAILURE"); . == $x);
  ((.statusCheckRollup // []) | to_entries
   | group_by([(.value.__typename // ""), (.value.workflowName // ""), (.value.name // .value.context // "")])
   | map(sort_by([(.value.startedAt // ""), (.value.completedAt // ""), .key]) | last | .value)) as $r
  | (if any($r[]; ((.conclusion // "") | bad) or ((.state // "") | bad)) then "fail"
     elif any($r[]; (has("status") and .status != "COMPLETED")
                    or ((.state // "") == "PENDING") or ((.state // "") == "EXPECTED")) then "pending"
     elif ($r | length) > 0 then "pass"
     else "none" end) as $c
  | (if .state == "OPEN" and .isDraft == true then "DRAFT" else .state end) as $s
  | (.mergeable // "UNKNOWN") as $m
  | if ($s | IN("OPEN","DRAFT","MERGED","CLOSED")) and ((.headRefOid // "") | length) >= 7
    then "\($s) \(.headRefOid[0:7]) \(if ($m | IN("MERGEABLE","CONFLICTING")) then $m else "UNKNOWN" end) \($c)"
    else error("bad") end'

# pr_status <normalised-ref> — see the header.
pr_status() {
    local ref="${1:-}" out rc
    case "$ref" in
        github:*) ;;
        *) printf 'forge.sh: unsupported PR reference %s\n' "$ref" >&2; return 1 ;;
    esac
    [[ "$ref" =~ ^github:([^/#]+/[^/#]+)#([0-9]+)$ ]] || {
        printf 'forge.sh: malformed PR reference %s\n' "$ref" >&2; return 1; }
    local repo="${BASH_REMATCH[1]}" n="${BASH_REMATCH[2]}" gh="$BRAIN_GH" tmo="" t secs
    # A hung gh would stall the caller's poll loop: wrap it in timeout/gtimeout when this
    # machine has one (macOS may have neither; then it runs unwrapped, no new dependency).
    # timeout execs its argument, so a leading `command ` (a shell builtin) is dropped.
    secs="${BRAIN_GH_TIMEOUT:-30}"
    for t in ${FORGE_TIMEOUT_CMDS:-timeout gtimeout}; do
        command -v "$t" >/dev/null 2>&1 && { tmo="$t -k 5 $secs"; gh="${gh#command }"; break; }
    done
    # gh's stderr passes straight through: on a failure it is the caller's message
    # shellcheck disable=SC2086  # BRAIN_GH / the timeout prefix are intentionally multi-word
    out="$($tmo $gh pr view "$n" -R "$repo" --json state,isDraft,headRefOid,mergeable,statusCheckRollup)"; rc=$?
    if [ -n "$tmo" ] && { [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; }; then
        printf 'gh timed out after %ss\n' "$secs" >&2
        return 1
    fi
    [ "$rc" -eq 0 ] || return "$rc"
    if ! out="$(printf '%s' "$out" | jq -r "$_FORGE_GH_JQ" 2>/dev/null)" || [ -z "$out" ]; then
        printf 'forge.sh: unexpected gh output for %s/pull/%s\n' "$repo" "$n" >&2
        return 1
    fi
    printf '%s\n' "$out"
}
