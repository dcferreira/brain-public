#!/usr/bin/env bash
#
# revive-workers.sh — after a reboot, bring back exactly the brain workers whose harness
# sessions were alive at shutdown, by RESUMING THE SAME CONVERSATION (never a fresh one).
# Runs on any machine listed in hosts.conf (hosts are named by their real hosts.conf name;
# this machine is `self_host` from host.sh).
#
# Steps:
#   1. Read <vault>/workers/*.md and <vault>/private/workers/*.md frontmatter (read-only).
#      A file is a worker note only if its frontmatter has `tmux_session:` or
#      `project_dir:` — findings/reports filed under workers/ are skipped silently.
#      Candidates: worker notes on the chosen host(s) whose status is not `collected`
#      (trailing `# comments` on the status line are stripped). A note with `host: local`
#      or no host is legacy: it is read as self, with ONE warning line on stderr naming
#      the slug (plus, when its project_dir does not exist here, that it probably belongs
#      to another host); a missing harness is read as omp, in the same warning line.
#      A note whose host is not a hosts.conf row (a retired machine) gets one
#      `unknown host '<h>' (not in hosts.conf)` warning and is skipped (never fatal).
#      Collected notes and notes excluded by --only or --host never warn. When this
#      machine is not in hosts.conf, legacy notes cannot be placed: they are skipped and
#      counted in ONE stderr summary line.
#   2. A host this machine has no ssh route to (hosts.conf alias `-`, not self) is skipped
#      with an informational stderr line under --host all (not a host error); asked for
#      by name, it is an error naming the missing route.
#      Per host, pipe the candidates to find-live-sessions.sh ON that host (locally with
#      bash; remotely as `ssh <alias> bash -s -- <args>` with the script on stdin and the
#      candidate lines embedded in it as a here-doc — stdin is taken by the script itself).
#   3. find-live-sessions.sh judges each transcript against the shutdown that FOLLOWED its
#      mtime, across every journalled boot. Its `idle-at-shutdown` (no clean exit, idle
#      before that shutdown — an idle harness writes nothing, so mtime is last activity,
#      not death) stays revivable only for a note whose status is primed/working/blocked;
#      otherwise it reads `ended-before-shutdown`. Its `cluster:` lines are relayed.
#      Then, from one read-only `tmux list-sessions` + `list-panes -a` per host: a
#      candidate whose `brain-worker-<slug>` session exists is `already-running`, or
#      `resurrected-shell` when every pane of it runs a bare shell (tmux-resurrect restored
#      the session without its harness) and the verdict was live/idle-at-shutdown. A
#      `touched-since-boot` candidate with no session, or a bare-shell one, is
#      `dead-since-boot`: its harness died after boot — reported, never auto-revived.
#      An `idle-at-shutdown` matched to a shutdown OLDER than the latest becomes
#      `idle-older-shutdown` (as likely killed by hand — Ctrl-C ×2, kill-session — as by
#      that shutdown). Last, `status: parked` → `parked`, whatever else held: never offered
#      as a crash victim. (`status: collected` notes never get this far; `collect_state:`
#      is not consulted — `persisted` is written on every teardown, park included.)
#   4. Print a table: slug, host, harness, status, verdict, session_id, mtime, shutdown.
#      Unless --host all, each `no-transcript` row gets a hint to re-run with --host all
#      (the worker may have run on another host).
#   5. Only with --apply, sequentially: each `live`/`idle-at-shutdown` row (and an
#      `idle-older-shutdown` one only when --only names its slug) through
#        launch-worker.sh --host H --harness X --slug S --project-dir P --resume <id>
#      relaying its result line and any `note:` lines it prints on stderr; each
#      `resurrected-shell` row by typing `resume_cmd` into the existing pane (C-u, the
#      line, verify it arrived, Enter as its own keypress, trust prompt answered). Either
#      way the row is `verified=yes` only once the pane shows the composer ready (polled)
#      — keys typed while a resumed conversation is still loading get lost. Remote
#      Control's "already connected" dialog is answered Escape (never Enter) and reported
#      `rc_dialog=dismissed|stuck`; an `rc=no` connection is re-checked, never retyped
#      (claude is named at launch by `--remote-control <slug>`).
#
# NEVER calls launch-worker.sh without --resume (a plain launch primes a FRESH session
# from the brief — the exact failure this script exists to prevent). NEVER kills or
# creates tmux sessions itself; it types into an existing pane only for a
# `resurrected-shell` row (the pane is a bare shell) or after a resume it just made.
# Dry run is the default.
#
# Usage:
#   revive-workers.sh [--host <name|all>] [--dry-run | --apply] [--vault <dir>]
#                     [--only <slug,...>] [--window <sec>]
#                     [--shutdown-time <epoch>] [--boot-time <epoch>]
#
#   --host           host from skills/_shared/hosts.conf, or `all`   default: this machine
#                    (self_host; `local` is a deprecated alias for it). rc 2 when this
#                    machine is not in hosts.conf and the host is self.
#   --dry-run        report only (the default)
#   --apply          actually resume the `live` sessions
#   --vault          vault root                                      default: ~/Obsidian/vault
#   --only           comma-separated slugs to restrict to; naming an `idle-older-shutdown`
#                    slug here is what lets --apply revive it
#   --window, --shutdown-time, --boot-time   passed through to find-live-sessions.sh
#
# Env: REVIVE_LAUNCHER overrides the launch-worker.sh path (tests); REVIVE_READY_TRIES
# (default 30) × REVIVE_SLEEP (default 2 s) bound the composer-ready poll after a resume;
# BRAIN_SSH/BRAIN_TMUX/BRAIN_HOSTS/BRAIN_SELF_HOST/BRAIN_HOSTNAME as in host.sh.
#
# Exit: 0 all requested revivals verified (or dry run with every host reachable);
#       1 any revival failed or a host could not be queried; 2 usage error.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BRAIN_ROOT="${BRAIN_ROOT:-$(cd "$HERE/../../.." && pwd)}"
export BRAIN_ROOT
# shellcheck source=../../_shared/lib/host.sh
. "$HERE/../../_shared/lib/host.sh"
# shellcheck source=../../_shared/lib/harness-chrome.sh
. "$HERE/../../_shared/lib/harness-chrome.sh"

FIND="$HERE/find-live-sessions.sh"
LAUNCHER="${REVIVE_LAUNCHER:-$HERE/../../brain-dispatch/scripts/launch-worker.sh}"

die2() { printf 'revive-workers: %s\n' "$1" >&2; exit 2; }
need_val() { [ "$1" -ge 2 ] || die2 "$2 needs a value"; }
usage() { sed -n '/^# Usage:/,/^# Env:/p' "$0" | sed 's/^# \{0,1\}//'; }

host_sel="" apply=0 vault="$HOME/Obsidian/vault" only="" find_args=()
while [ $# -gt 0 ]; do
    case "$1" in
        --host)          need_val $# "$1"; host_sel="$2"; shift 2 ;;
        --dry-run)       apply=0; shift ;;
        --apply)         apply=1; shift ;;
        --vault)         need_val $# "$1"; vault="$2"; shift 2 ;;
        --only)          need_val $# "$1"; only="$2"; shift 2 ;;
        --window|--shutdown-time|--boot-time)
                         need_val $# "$1"; find_args+=("$1" "$2"); shift 2 ;;
        -h|--help)       usage; exit 0 ;;
        *) die2 "unknown argument: $1" ;;
    esac
done

# self: this machine's hosts.conf name (empty when unresolved — then legacy notes, which
# mean "self", cannot be placed and are left out).
self="$(self_host 2>/dev/null)" || self=""
if [ "$host_sel" = all ]; then
    hosts="$(awk '/^[[:space:]]*#/ || /^[[:space:]]*$/ { next } { print $1 }' "$BRAIN_HOSTS")"
    [ -n "$hosts" ] || die2 "no hosts in $BRAIN_HOSTS"
elif host_is_legacy "$host_sel"; then
    [ -n "$self" ] || die2 "cannot tell which hosts.conf host this machine is: add its hostname ($(hostname -s 2>/dev/null || uname -n)) to its row's hostnames column in $BRAIN_HOSTS, set BRAIN_SELF_HOST, or pass --host <name|all>"
    hosts="$self"
else
    hosts="$(host_canon "$host_sel" 2>/dev/null)" || die2 "unknown host: $host_sel"
fi
[ -d "$vault/workers" ] || [ -d "$vault/private/workers" ] || die2 "no workers directory at $vault/workers"
[ -r "$FIND" ] || die2 "missing $FIND"

TAB="$(printf '\t')"
US="$(printf '\037')"   # a NON-whitespace IFS char: consecutive ones never collapse
WORK="$(mktemp -d)" || die2 "mktemp failed"
trap 'rm -rf "$WORK"' EXIT

# frontmatter <file> — the lines between the opening and closing `---` fences.
frontmatter() {
    awk 'NR==1 { if ($0 != "---") exit; next } $0 == "---" { exit } { print }' "$1"
}
# fm_get <frontmatter-text> <key> — value of <key>, with a trailing ` # comment` and
# surrounding whitespace removed.
fm_get() {
    printf '%s\n' "$1" | awk -v k="$2" '
        index($0, k ":") == 1 {
            v = substr($0, length(k) + 2)
            sub(/[[:space:]]+#.*$/, "", v)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
            print v; exit
        }'
}
in_only() {
    [ -z "$only" ] && return 0
    named "$1"
}
# named <slug> — rc 0 only when --only lists <slug> explicitly (no --only names nothing).
named() {
    [ -n "$only" ] || return 1
    case ",$only," in *",$1,"*) return 0 ;; esac
    return 1
}

self_label="${self:-this machine}"
no_route_msg() { printf 'no ssh route from %s to %s (hosts.conf alias -)' "$self_label" "$1"; }

# ---- 1. candidates: host<TAB>slug<TAB>harness<TAB>status<TAB>project_dir<TAB>session_id
: >"$WORK/cand"
legacy_skipped=0
for f in "$vault"/workers/*.md "$vault"/private/workers/*.md; do
    [ -f "$f" ] || continue   # also skips an unmatched glob (a missing workers dir)
    ndir=workers; case "$f" in "$vault"/private/workers/*) ndir=private/workers ;; esac
    fm="$(frontmatter "$f")"
    [ -n "$fm" ] || continue
    # not a worker note (findings, reports, comments filed under workers/)
    printf '%s\n' "$fm" | grep -qE '^(tmux_session|project_dir):' || continue
    slug="$(fm_get "$fm" slug)";          [ -n "$slug" ] || slug="$(basename "$f" .md)"
    status="$(fm_get "$fm" status)"
    [ "$status" = collected ] && continue
    in_only "$slug" || continue
    h="$(fm_get "$fm" host)"
    harness="$(fm_get "$fm" harness)"
    pdir="$(fm_get "$fm" project_dir)"
    warn=""
    if host_is_legacy "$h"; then
        # cannot place it (only possible with --host all or an explicit host): count it
        [ -n "$self" ] || { legacy_skipped=$((legacy_skipped + 1)); continue; }
        warn="legacy host '${h:-unset}' read as $self"
        xdir="$pdir"; case "$xdir" in "~"|"~/"*) xdir="$HOME${xdir#\~}" ;; esac
        if [ -n "$pdir" ] && [ ! -d "$xdir" ]; then
            warn="$warn — project_dir $pdir is not on this machine; it probably belongs to another host (fix its host:)"
        fi
        h="$self"
    fi
    # a host that is not a hosts.conf row at all (a retired machine): warn, skip, never fatal
    if ! host_canon "$h" >/dev/null 2>&1; then
        printf "warning: %s: unknown host '%s' (not in hosts.conf)\n" "$slug" "$h" >&2
        continue
    fi
    case " $(printf '%s ' $hosts)" in *" $h "*) ;; *) continue ;; esac
    if [ -z "$harness" ]; then
        harness=omp
        warn="${warn:+$warn; }no harness: — assuming omp"
    fi
    [ -z "$warn" ] || printf 'warning: %s: %s\n' "$slug" "$warn" >&2
    sid="$(fm_get "$fm" session_id)";     [ "$sid" = unknown ] && sid=""
    # Scope for the resumed worker, from the note's own frontmatter: private + project
    # brain -> all; private -> private; anything else -> shared, always explicit (a revived
    # tmux server may carry the coordinator's BRAIN_SCOPE=all). A valid project is kept.
    area="$(fm_get "$fm" area)"; nproj="$(fm_get "$fm" project)"; nscope=shared
    case "$nproj" in ''|[!a-z0-9]*|*[!a-z0-9-]*) nproj="" ;; esac
    # a note under private/workers with no area: is still private
    [ -n "$area" ] || [ "$ndir" != private/workers ] || area=private
    if [ "$area" = private ]; then
        if [ "$nproj" = brain ]; then nscope=all; else nscope=private; fi
    fi
    # optional model pinned at dispatch (`model: <id>`); only a plain id is ever passed on
    nmodel="$(fm_get "$fm" model)"
    case "$nmodel" in \"*\"|\'*\') nmodel="${nmodel#?}"; nmodel="${nmodel%?}" ;; esac
    case "$nmodel" in
        '') ;;
        -*|*[!]A-Za-z0-9._:/@[-]*)
            printf "warning: %s: model '%s' rejected, resuming on the harness default\n" "$slug" "$nmodel" >&2
            nmodel="" ;;
    esac
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$h" "$slug" "$harness" "${status:--}" "$pdir" "$sid" \
        "$ndir" "$nscope" "${nproj:--}" "${nmodel:--}" >>"$WORK/cand"
done

[ "$legacy_skipped" -eq 0 ] || printf '%s legacy notes skipped: this machine is not in hosts.conf (set BRAIN_SELF_HOST or add its hostname)\n' \
    "$legacy_skipped" >&2

# bare_shell <session> <panes-file> — rc 0 when the session has panes and every one runs a
# bare shell (a login shell shows as `-zsh`), i.e. no harness is running in it.
bare_shell() {
    awk -v s="$1" '$1 == s { n++; c = $2; sub(/^-/, "", c)
                              if (c !~ /^(bash|zsh|sh|fish|dash|ksh|tcsh|csh)$/) other++ }
                   END { exit !(n > 0 && other == 0) }' "$2"
}

# ---- 2+3. per host: ask find-live-sessions.sh, then mark already-running ----------
# rows: slug host harness status verdict session_id mtime note_dir scope project project_dir
#       shutdown bare (tab-separated; bare=yes: its session exists as a bare shell)
: >"$WORK/rows"
host_errors=""
for h in $hosts; do
    awk -F'\t' -v h="$h" '$1 == h' "$WORK/cand" >"$WORK/cand.$h"
    if ! host_reachable "$h"; then
        if [ "$host_sel" = all ]; then
            # expected from any other machine: inform, never count it as a host error
            [ ! -s "$WORK/cand.$h" ] || printf 'revive-workers: skipping host %s: %s; %s worker note(s) there not checked\n' \
                "$h" "$(no_route_msg "$h")" "$(grep -c . "$WORK/cand.$h")" >&2
        else
            printf 'revive-workers: could not query host %s: %s\n' "$h" "$(no_route_msg "$h")" >&2
            host_errors="$host_errors $h"
        fi
        continue
    fi
    [ -s "$WORK/cand.$h" ] || continue
    cut -f2,3,6 "$WORK/cand.$h" >"$WORK/in.$h"

    if host_is_local "$h"; then
        bash "$FIND" "${find_args[@]+"${find_args[@]}"}" <"$WORK/in.$h" >"$WORK/out.$h" 2>"$WORK/err.$h"
        frc=$?
    else
        if ! alias="$(host_ssh_alias "$h" 2>"$WORK/err.$h")"; then
            printf 'revive-workers: could not query host %s: %s\n' "$h" "$(tail -1 "$WORK/err.$h")" >&2
            host_errors="$host_errors $h"
            continue
        fi
        # The script arrives on bash's stdin, so the candidates cannot: wrap the script in
        # a brace group whose stdin is a here-doc carrying the candidate lines.
        {
            printf '{\n'
            cat "$FIND"
            printf '\n} <<'"'"'__REVIVE_CANDIDATES__'"'"'\n'
            cat "$WORK/in.$h"
            printf '__REVIVE_CANDIDATES__\n'
        } >"$WORK/remote.$h"
        # shellcheck disable=SC2086  # BRAIN_SSH is intentionally a multi-word invocation
        $BRAIN_SSH -o BatchMode=yes "$alias" bash -s -- "${find_args[@]+"${find_args[@]}"}" \
            <"$WORK/remote.$h" >"$WORK/out.$h" 2>"$WORK/err.$h"
        frc=$?
    fi
    if [ "$frc" -ne 0 ]; then
        printf 'revive-workers: could not query host %s (rc %s): %s\n' "$h" "$frc" \
            "$(grep -v '^\*\*' "$WORK/err.$h" | tail -1)" >&2
        host_errors="$host_errors $h"
        continue
    fi
    hdr="$(grep '^boot=' "$WORK/err.$h" | tail -1)"
    latest="$(printf '%s\n' "$hdr" | sed -n 's/.* shutdown=\([^ ]*\).*/\1/p')"
    printf '# %s: %s\n' "$h" "$hdr"
    grep '^cluster:' "$WORK/err.$h" | sed "s/^/# $h: /"

    sessions="$(tmx "$h" list-sessions -F "'#{session_name}'" 2>/dev/null)"
    trc=$?
    if [ "$trc" -eq 255 ]; then
        printf 'revive-workers: could not list tmux sessions on host %s\n' "$h" >&2
        host_errors="$host_errors $h"
        continue
    fi
    printf '%s\n' "$sessions" >"$WORK/sess.$h"
    # `<session> <pane_current_command>` per pane; on failure empty, so no session ever
    # reads as a bare shell (it stays already-running — the safe side)
    tmx "$h" list-panes -a -F "'#{session_name} #{pane_current_command}'" >"$WORK/panes.$h" 2>/dev/null \
        || : >"$WORK/panes.$h"

    # find-live-sessions.sh prints `-` for every empty field; still split on a
    # non-whitespace separator so an empty field could never shift the ones after it.
    while IFS="$US" read -r slug verdict sid path mtime shut; do
        [ -n "$slug" ] || continue
        [ "$sid" = - ] && sid=""
        [ "$mtime" = - ] && mtime=""
        c="$(awk -F'\t' -v s="$slug" '$2 == s { print; exit }' "$WORK/cand.$h")"
        harness="$(printf '%s\n' "$c" | cut -f3)"
        status="$(printf '%s\n' "$c" | cut -f4)"
        pdir="$(printf '%s\n' "$c" | cut -f5)"
        ndir="$(printf '%s\n' "$c" | cut -f7)"
        nscope="$(printf '%s\n' "$c" | cut -f8)"
        nproj="$(printf '%s\n' "$c" | cut -f9)"
        nmodel="$(printf '%s\n' "$c" | cut -f10)"
        # idle at shutdown is revivable only while the note says the work was under way
        if [ "$verdict" = idle-at-shutdown ]; then
            case "$status" in primed|working|blocked) ;; *) verdict=ended-before-shutdown ;; esac
        fi
        # ...and matched to an older shutdown than the latest it may have been killed by hand
        if [ "$verdict" = idle-at-shutdown ] && [ -n "$latest" ] && [ "${shut:--}" != - ] \
           && [ "$shut" != "$latest" ]; then
            verdict=idle-older-shutdown
        fi
        bare=no
        if grep -qxF "brain-worker-$slug" "$WORK/sess.$h"; then
            if bare_shell "brain-worker-$slug" "$WORK/panes.$h"; then
                case "$verdict" in
                    live|idle-at-shutdown) verdict=resurrected-shell ;;
                    idle-older-shutdown)   bare=yes ;;
                    touched-since-boot)    verdict=dead-since-boot ;;
                    *)                     verdict=already-running ;;
                esac
            else
                verdict=already-running
            fi
        elif [ "$verdict" = touched-since-boot ]; then verdict=dead-since-boot; fi
        [ "$status" = parked ] && verdict=parked
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$slug" "$h" "$harness" "$status" "$verdict" \
            "${sid:--}" "${mtime:--}" "$ndir" "$nscope" "$nproj" "$pdir" "${shut:--}" "$bare" "${nmodel:--}" >>"$WORK/rows"
    done < <(tr '\t' '\037' <"$WORK/out.$h")
done

# ---- 4. table ---------------------------------------------------------------------
{
    printf 'slug\thost\tharness\tstatus\tverdict\tsession_id\tmtime\tshutdown\n'
    cut -f1-7,12 "$WORK/rows"
} | awk -F'\t' '
    { for (i = 1; i <= NF; i++) { cell[NR, i] = $i; if (length($i) > w[i]) w[i] = length($i) } n = NR; nf = NF }
    END { for (r = 1; r <= n; r++) { line = ""
            for (i = 1; i <= nf; i++) line = line sprintf(i < nf ? "%-" w[i] "s  " : "%s", cell[r, i])
            print line } }'

live="$(awk -F'\t' -v only=",$only," '$5 ~ /^(live|idle-at-shutdown|resurrected-shell)$/ ||
    ($5 == "idle-older-shutdown" && index(only, "," $1 ",")) { print $1 }' "$WORK/rows" | tr '\n' ' ')"
amb="$(awk -F'\t' '$5 == "ambiguous" { print $1 }' "$WORK/rows" | tr '\n' ' ')"
dead="$(awk -F'\t' '$5 == "dead-since-boot" { print $1 }' "$WORK/rows" | tr '\n' ' ')"
[ -n "$dead" ] && printf 'dead since boot (harness died after boot, session gone or a bare shell — crash/logout/exit? ask the user; for a crash re-run with --boot-time <re-login epoch> --shutdown-time <just before the crash>): %s\n' "$dead"
[ -n "$amb" ] && printf 'ambiguous (several live transcripts — pick one by hand and add session_id: to the note): %s\n' "$amb"
awk -F'\t' -v only=",$only," '$5 == "idle-older-shutdown" && !index(only, "," $1 ",") {
    printf "hint: %s: idle at an OLDER shutdown (%s), not the latest — maybe killed by hand; --apply skips it: ask the user, then re-run with --apply --only %s\n", $1, $12, $1 }' "$WORK/rows"
if [ "$host_sel" != all ]; then
    awk -F'\t' '$5 == "no-transcript" { printf "hint: %s: no transcript on %s — if it ran elsewhere, re-run with --host all\n", $1, $2 }' "$WORK/rows"
fi

if [ "$apply" -eq 0 ]; then
    if [ -n "$live" ]; then
        printf 'dry run: would resume %s— re-run with --apply to revive\n' "$live"
    else
        printf 'dry run: nothing to revive\n'
    fi
    [ -z "$host_errors" ] || exit 1
    exit 0
fi

# ---- 5. apply: resume each revivable session by id ----------------------------------
SLEEP="${REVIVE_SLEEP:-2}"
READY_TRIES="${REVIVE_READY_TRIES:-30}"
snooze() { [ "${1:-0}" = 0 ] || sleep "$1"; }
# Pane helpers on the current row's host/session/harness ($ph $ps $px). Literal text is
# `printf %q`-escaped so the shell that runs tmux on the target passes it through as one
# unexpanded argument (launch-worker.sh's convention).
cap()      { tmx "$ph" capture-pane -p $(pane_capture_flags "$px") -t "$ps" 2>/dev/null; }
send_lit() { local q; printf -v q '%q' "$1"; tmx "$ph" send-keys -t "$ps" "$q" >/dev/null 2>&1; }
send_key() { tmx "$ph" send-keys -t "$ps" "$1" >/dev/null 2>&1; }
# rc_dialog_check — on the last capture ($pane): if Remote Control's "already connected"
# dialog is up (it blocks the worker and vetoes pane_ready/pane_harness_up), answer it
# `Escape` — never Enter, which could pick `Disconnect` — and recapture. ONE Escape per
# sighting: while the same dialog stays up later calls only re-check (repeated Esc opens
# claude's rewind menu); rc_esc resets once it is gone. Sets rc_dialog to dismissed|stuck
# (launch-worker.sh's report). rc 0 when the dialog was there.
rc_esc=""
rc_dialog_check() {
    if ! pane_rc_dialog "$px" "$pane"; then
        [ -z "$rc_esc" ] || rc_dialog=dismissed
        rc_esc=""; return 1
    fi
    if [ -n "$rc_esc" ]; then rc_dialog=stuck; return 0; fi
    send_key Escape; rc_esc=yes; snooze "$SLEEP"
    pane="$(cap)"
    if pane_rc_dialog "$px" "$pane"; then rc_dialog=stuck; else rc_dialog=dismissed; rc_esc=""; fi
    return 0
}
# wait_ready — poll until pane_ready (composer up and free), dismissing the RC dialog on
# the way. Leaves the last capture in $pane. rc 1 when the composer never reads ready.
wait_ready() {
    local i=0
    while [ "$i" -lt "$READY_TRIES" ]; do
        i=$((i + 1))
        pane="$(cap)"
        rc_dialog_check
        pane_ready "$px" "$pane" && return 0
        snooze "$SLEEP"
    done
    return 1
}
# finish_ready <result-line> — the common tail of both revival paths: wait for the composer,
# then, for an `rc=no` row, re-check the Remote Control connection a few times (claude is
# named at launch by `--remote-control <slug>`: nothing is ever typed for it). Prints the
# (possibly amended) result line. rc 1 (result rewritten to verified=no) when the composer
# never reads ready.
finish_ready() {
    local result="$1" i=0
    rc_dialog=""
    if ! wait_ready; then
        printf '%s%s\n' "${result/verified=yes/verified=no}" "${rc_dialog:+ rc_dialog=$rc_dialog}"
        if [ "$rc_dialog" = stuck ]; then
            printf 'revive-workers: %s: Remote Control'"'"'s "already connected" dialog would not dismiss with Escape — attach with %s and pick Continue (never Disconnect)\n' \
                "$slug" "$(attach_cmd "$ph" "$ps")" >&2
        fi
        printf 'revive-workers: %s: composer not ready %s polls after the resume — session left running (%s)\n' \
            "$slug" "$READY_TRIES" "$(attach_cmd "$ph" "$ps")" >&2
        return 1
    fi
    case "$result" in
        *" rc=no "*)
            while :; do
                if pane_rc_connected "$px" "$pane"; then result="${result/ rc=no / rc=yes }"; break; fi
                i=$((i + 1)); [ "$i" -le 3 ] || break
                snooze "$SLEEP"; pane="$(cap)"; rc_dialog_check
            done ;;
    esac
    if [ -n "$rc_dialog" ]; then
        case "$result" in
            *" rc_dialog="*) result="$(printf '%s\n' "$result" | sed -E "s/ rc_dialog=[a-z]+/ rc_dialog=$rc_dialog/")" ;;
            *) result="$result rc_dialog=$rc_dialog" ;;
        esac
    fi
    printf '%s\n' "$result"
}
# resume_in_pane — a resurrected-shell row: type resume_cmd (claude: named with
# `--remote-control <slug>`, as launch-worker.sh --resume does) into the existing
# bare-shell pane (never kill or recreate the session), then the launcher's checks. Prints
# the result line; rc 1 on failure.
resume_in_pane() {
    local cmd marker rcn i typed="" up="" pmodel="$nmodel"
    [ "$pmodel" != - ] || pmodel=""
    local fail_line="verified=no session=$ps rc=n/a attach=$(attach_cmd "$ph" "$ps") session_id=$sid mode=resume-in-pane"
    if ! valid_session_id "$px" "$sid" || ! cmd="$(resume_cmd "$px" "$sid" "$pmodel" "$slug")" \
       || ! marker="$(resume_marker "$px" "$pmodel" "$slug")"; then
        printf '%s\n' "$fail_line"; printf 'revive-workers: %s: not a valid %s session id: %s\n' "$slug" "$px" "$sid" >&2; return 1
    fi
    case "$cmd" in *"--remote-control $slug "*) rcn="--remote-control $slug" ;; *) rcn="" ;; esac
    for i in 1 2 3; do
        send_key C-u; send_lit "$cmd"; snooze "$SLEEP"
        pane="$(cap)"
        if printf '%s\n' "$pane" | grep -qF -- "$marker" && printf '%s' "$pane" | tr -d '\n' | grep -qF -- "$sid" \
           && { [ -z "$rcn" ] || printf '%s' "$pane" | tr -d '\n' | grep -qF -- "$rcn"; }; then
            typed=yes; break
        fi
    done
    if [ -z "$typed" ]; then
        send_key C-u
        printf '%s\n' "$fail_line"; printf 'revive-workers: %s: resume line never arrived intact in %s\n' "$slug" "$ps" >&2; return 1
    fi
    send_key Enter
    rc_dialog=""
    i=0
    while [ "$i" -lt "$READY_TRIES" ]; do
        i=$((i + 1))
        pane="$(cap)"
        if pane_trust_prompt "$px" "$pane"; then send_key Down; send_key Enter; snooze "$SLEEP"; continue; fi
        rc_dialog_check
        if pane_harness_up "$px" "$pane"; then up=yes; break; fi
        snooze "$SLEEP"
    done
    if [ -z "$up" ]; then
        printf '%s\n' "$fail_line"; printf 'revive-workers: %s: %s never came up in %s\n' "$slug" "$px" "$ps" >&2; return 1
    fi
    printf '%s\n' "$pane" | grep -iF "didn't finish before the previous session ended" | sed -E 's/^[[:space:]]+//; s/^/note: /'
    local rc_state=n/a pre_dialog="$rc_dialog"
    rc_connect_text "$px" "$slug" >/dev/null && rc_state=no
    finish_ready "verified=yes session=$ps rc=$rc_state attach=$(attach_cmd "$ph" "$ps") session_id=$sid mode=resume-in-pane${pre_dialog:+ rc_dialog=$pre_dialog}"
}

revived="" failed=""
while IFS="$TAB" read -r slug h harness status verdict sid mtime ndir nscope nproj pdir shut bare nmodel; do
    case "$verdict" in
        live|idle-at-shutdown|resurrected-shell) ;;
        idle-older-shutdown) named "$slug" || continue
                             [ "$bare" = yes ] && verdict=resurrected-shell ;;
        *) continue ;;
    esac
    if [ -z "$pdir" ] || [ -z "$sid" ] || [ "$sid" = - ]; then
        printf 'revive-workers: %s: missing project_dir or session id — not revived\n' "$slug" >&2
        failed="$failed $slug"
        continue
    fi
    ph="$h" ps="brain-worker-$slug" px="$harness" rc_esc=""
    if [ "$verdict" = resurrected-shell ]; then
        printf '== reviving %s on %s in its existing bare-shell pane (%s --resume %s)\n' "$slug" "$h" "$harness" "$sid"
        if resume_in_pane </dev/null; then revived="$revived $slug"; else failed="$failed $slug"; fi
        continue
    fi
    printf '== reviving %s on %s (%s --resume %s)\n' "$slug" "$h" "$harness" "$sid"
    xargs_=()
    [ "$ndir" = workers ] || xargs_+=(--note-dir "$ndir")
    [ "$nscope" = - ] || xargs_+=(--scope "$nscope")
    [ "$nproj" = - ] || [ -z "$nproj" ] || xargs_+=(--project "$nproj")
    [ "$nmodel" = - ] || [ -z "$nmodel" ] || xargs_+=(--model "$nmodel")
    out="$("$LAUNCHER" --host "$h" --harness "$harness" --slug "$slug" --project-dir "$pdir" \
        --resume "$sid" ${xargs_[@]+"${xargs_[@]}"} </dev/null 2>"$WORK/lerr")"
    lrc=$?
    result="$(printf '%s\n' "$out" | tail -1)"
    if [ "$lrc" -eq 0 ] && printf '%s\n' "$result" | grep -q '^verified=yes'; then
        grep '^note:' "$WORK/lerr"
        if finish_ready "$result" </dev/null; then revived="$revived $slug"; else failed="$failed $slug"; fi
    else
        printf '%s\n' "$result"
        grep '^note:' "$WORK/lerr"
        grep -v '^note:' "$WORK/lerr" >&2
        failed="$failed $slug"
    fi
done <"$WORK/rows"

printf 'revived:%s\n' "${revived:- (none)}"
printf 'failed:%s\n' "${failed:- (none)}"
[ -n "$host_errors" ] && printf 'unreachable hosts:%s\n' "$host_errors"
[ -z "$failed" ] && [ -z "$host_errors" ] && exit 0
exit 1
