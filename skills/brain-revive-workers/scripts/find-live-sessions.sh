#!/usr/bin/env bash
#
# find-live-sessions.sh — which worker harness sessions were alive when this host last
# shut down? Runs ON the host in question: locally, or piped over ssh as `bash -s`.
# Therefore SELF-CONTAINED — it sources nothing from the repo — and portable between
# macOS (bash 3.2, BSD stat/date/awk) and Linux (GNU).
#
# The signal: on process death (including shutdown) Claude Code appends metadata lines to
# its transcript and omp appends a session_exit entry, so a BUSY session's mtime ≈ the
# moment its harness died. An IDLE one writes nothing, so its mtime is its last activity,
# which can be hours before the shutdown that killed it. So a transcript is judged against
# the shutdown that FOLLOWED its mtime (every journalled boot, not just the latest): within
# the window before it → live; older and without a clean-exit marker → idle-at-shutdown
# (still running when the machine went down, as far as the transcript can tell); a clean
# exit → ended-before-shutdown. One written after boot has already been resumed (or is
# running) and must not be revived again.
#
# Usage:
#   find-live-sessions.sh [--window <sec>] [--shutdown-time <epoch>] [--boot-time <epoch>]
#                         [--home <dir>]  < candidates
#
# stdin: one line per candidate worker: `slug<TAB>harness<TAB>session_id_or_empty`.
#
# stdout: one line per input line, in input order:
#   `slug<TAB>verdict<TAB>session_id<TAB>transcript_path<TAB>mtime_iso<TAB>shutdown_iso`
#   Every field is non-empty: an unknown one (no transcript, an omp transcript without a
#   `"type":"session"` line) is printed as `-`. Tab is IFS whitespace, so an empty field
#   would collapse under `IFS=<tab> read` and shift the path into session_id.
#   verdict ∈ live | idle-at-shutdown | ended-before-shutdown | touched-since-boot |
#             no-transcript | ambiguous
#   (ambiguous: session_id and transcript_path are comma-separated lists of the live ones)
#   shutdown_iso: the shutdown the transcript was matched to (`-` when none applies).
# stderr: `boot=<iso> shutdown=<iso> shutdown_source=<journal|proxy|override> window=<s>
#   shutdowns=<n>` (shutdown = the latest), then one `cluster: …` line per group of 2+
#   picked transcripts sharing an mtime minute — a strong hint they were killed together.
#
# Transcript lookup (top-level files only — subagent transcripts live deeper and are
# never considered):
#   claude  <home>/.claude/projects/*/<id>.jsonl                id = file basename
#   omp     <home>/.omp/agent/sessions/*/*_<id prefix>*.jsonl   id = the `"type":"session"` line's id
# With no session id (or one that no longer resolves), a transcript belongs to <slug>
# when its FIRST user message contains the worker launch sentence for <slug>. Only the
# first user message counts: a coordinator transcript quotes launch sentences later on.
#
# Liveness: mtime > boot → touched-since-boot. Otherwise S = the first shutdown at or after
# mtime (the latest if none): a clean-exit marker in the transcript's tail (claude: a
# `/exit` or `/quit` command record; omp: session_exit with `"kind":"normal"`) →
# ended-before-shutdown; S - window <= mtime → live; else idle-at-shutdown. Several
# matching transcripts: any touched-since-boot wins (something already runs this worker —
# never revive it twice); else exactly one live → live; more than one live → ambiguous;
# else the newest one's verdict.
#
# Times: boot = override | Linux /proc/stat btime | macOS `sysctl kern.boottime`.
# shutdowns = override (that one only) | Linux journal (every previous boot's last entry,
# each paired with the next boot's first) | proxy: the newest top-level transcript mtime
# older than boot (the coordinator session is always live, so on its host this tracks
# shutdown; on a host without one it is the last harness to die).
#
# Exit: 0 ok; 2 usage error.

set -u

window=180 shut_ovr="" boot_ovr="" home="${HOME:-}"
die2() { printf 'find-live-sessions: %s\n' "$1" >&2; exit 2; }
while [ $# -gt 0 ]; do
    case "$1" in
        --window)        [ $# -ge 2 ] || die2 "$1 needs a value"; window="$2"; shift 2 ;;
        --shutdown-time) [ $# -ge 2 ] || die2 "$1 needs a value"; shut_ovr="$2"; shift 2 ;;
        --boot-time)     [ $# -ge 2 ] || die2 "$1 needs a value"; boot_ovr="$2"; shift 2 ;;
        --home)          [ $# -ge 2 ] || die2 "$1 needs a value"; home="$2"; shift 2 ;;
        -h|--help)       sed -n '/^# Usage:/,/^# Exit:/p' "$0" 2>/dev/null; exit 0 ;;
        *) die2 "unknown argument: $1" ;;
    esac
done
case "$window" in ''|*[!0-9]*) die2 "--window must be a number of seconds" ;; esac
case "$shut_ovr" in *[!0-9]*) die2 "--shutdown-time must be an epoch" ;; esac
case "$boot_ovr" in *[!0-9]*) die2 "--boot-time must be an epoch" ;; esac

TAB="$(printf '\t')"
SENT_PREFIX='Read your worker brief at ~/Obsidian/vault/'
WORK="$(mktemp -d "${TMPDIR:-/tmp}/find-live.XXXXXX")" || die2 "mktemp failed"
trap 'rm -rf "$WORK"' EXIT

dash() { if [ -n "$1" ]; then printf '%s' "$1"; else printf -- '-'; fi; }
iso() { date -d "@$1" +%Y-%m-%dT%H:%M:%S%z 2>/dev/null || date -r "$1" +%Y-%m-%dT%H:%M:%S%z; }

# ---- boot -------------------------------------------------------------------------
if [ -n "$boot_ovr" ]; then
    boot="$boot_ovr"
elif [ -r /proc/stat ]; then
    boot="$(awk '/^btime/ {print $2; exit}' /proc/stat)"
else
    boot="$(sysctl -n kern.boottime 2>/dev/null | sed -n 's/.*{ *sec = \([0-9][0-9]*\).*/\1/p')"
fi
case "$boot" in ''|*[!0-9]*) boot="$(date +%s)" ;; esac

# ---- inventory: every top-level transcript, as harness<TAB>mtime<TAB>path ------------
# One batched stat per tree (GNU `stat -c`, else BSD `stat -f`).
if stat -c %Y / >/dev/null 2>&1; then STATFLAG=-c STATFMT='%Y %n'; else STATFLAG=-f STATFMT='%m %N'; fi
inventory() {  # inventory <harness> <root>
    [ -d "$2" ] || return 0
    find "$2" -mindepth 2 -maxdepth 2 -type f -name '*.jsonl' -exec stat "$STATFLAG" "$STATFMT" {} + 2>/dev/null \
        | awk -v h="$1" '{ m=$1; sub(/^[0-9]+ /, ""); print h "\t" m "\t" $0 }'
}
{
    inventory claude "$home/.claude/projects"
    inventory omp    "$home/.omp/agent/sessions"
} >"$WORK/all"

# ---- shutdowns: shutdown<TAB>next_boot, ascending ----------------------------------
shut="" src=""
: >"$WORK/shuts"
if [ -n "$shut_ovr" ]; then
    printf '%s\t%s\n' "$shut_ovr" "$boot" >"$WORK/shuts"; src=override
elif command -v journalctl >/dev/null 2>&1; then
    # every previous boot's last entry (µs → s by dropping 6 digits), paired with the
    # first entry of the boot after it; a "shutdown" after the current boot is ignored
    journalctl --list-boots -o json --no-pager 2>/dev/null | tr '{' '\n' | awk -v b="$boot" '
        function num(k,   v) { if (!match($0, "\"" k "\":-?[0-9]+")) return ""
            v = substr($0, RSTART + length(k) + 3, RLENGTH - length(k) - 3); return v }
        { i = num("index"); if (i == "") next
          f = num("first_entry"); l = num("last_entry")
          if (f != "") F[i + 0] = substr(f, 1, length(f) - 6)
          if (l != "") L[i + 0] = substr(l, 1, length(l) - 6) }
        END { for (i in L) if (i + 0 < 0 && L[i] + 0 <= b + 0)
                  print L[i] "\t" (((i + 1) in F) ? F[i + 1] : b) }' \
        | sort -n >"$WORK/shuts"
    [ -s "$WORK/shuts" ] && src=journal
fi
if [ -z "$src" ]; then
    src=proxy
    shut="$(awk -F'\t' -v b="$boot" '$2+0 < b+0 && $2+0 > m+0 { m=$2 } END { print m+0 }' "$WORK/all")"
    [ "$shut" -gt 0 ] || shut="$boot"
    printf '%s\t%s\n' "$shut" "$boot" >"$WORK/shuts"
fi
shut="$(tail -1 "$WORK/shuts" | cut -f1)"
printf 'boot=%s shutdown=%s shutdown_source=%s window=%s shutdowns=%s\n' "$(iso "$boot")" "$(iso "$shut")" \
    "$src" "$window" "$(grep -c . "$WORK/shuts")" >&2

# ---- fallback index: harness<TAB>slug<TAB>mtime<TAB>path, from FIRST user messages ---
first_user_line() {  # first_user_line <harness> <file>
    if [ "$1" = claude ]; then
        awk '/"type":"user"/ && /"role":"user"/ { print; exit }' "$2"
    else
        awk '/"type":"message"/ && /"role":"user"/ { print; exit }' "$2"
    fi
}
: >"$WORK/fb"
while IFS="$TAB" read -r h m p; do
    [ -n "$p" ] || continue
    grep -qF "${SENT_PREFIX}workers/" "$p" 2>/dev/null || grep -qF "${SENT_PREFIX}private/workers/" "$p" 2>/dev/null || continue
    s="$(first_user_line "$h" "$p" \
        | sed -n 's|.*Read your worker brief at ~/Obsidian/vault/\(private/\)\{0,1\}workers/\([^" \\]*\)\.md and follow its priming.*|\2|p')"
    [ -n "$s" ] && printf '%s\t%s\t%s\t%s\n' "$h" "$s" "$m" "$p" >>"$WORK/fb"
done <"$WORK/all"

session_id_of() {  # session_id_of <harness> <file>
    if [ "$1" = claude ]; then
        basename "$2" .jsonl
    else
        awk '/"type":"session"/ { if (match($0, /"id":"[^"]*"/)) print substr($0, RSTART+6, RLENGTH-7); exit }' "$2"
    fi
}

# clean_exit <harness> <file> — rc 0 when the transcript's tail records a deliberate exit
# (not a signal/shutdown): such a conversation is over and is never a revive candidate.
clean_exit() {
    if [ "$1" = claude ]; then
        tail -n 40 "$2" 2>/dev/null | grep -qE '<command-name>/(exit|quit)</command-name>'
    else
        tail -n 40 "$2" 2>/dev/null | grep '"customType":"session_exit"' | grep -q '"kind":"normal"'
    fi
}

# ---- classify each candidate ------------------------------------------------------
# picks: mtime<TAB>slug<TAB>shutdown<TAB>next_boot — the chosen transcript per candidate,
# for the cluster report at the end
: >"$WORK/picks"
while IFS="$TAB" read -r slug harness sid; do
    [ -n "$slug" ] || continue
    : >"$WORK/m"
    if [ -n "$sid" ]; then
        if [ "$harness" = claude ]; then
            awk -F'\t' -v id="$sid" '$1=="claude" { n=split($3, a, "/"); if (a[n] == id ".jsonl") print $2 "\t" $3 }' "$WORK/all" >"$WORK/m"
        elif [ -f "$sid" ]; then
            awk -F'\t' -v p="$sid" '$3==p { print $2 "\t" $3 }' "$WORK/all" >"$WORK/m"
        else
            awk -F'\t' -v id="$sid" '$1=="omp" { n=split($3, a, "/"); if (index(a[n], "_" id) > 0) print $2 "\t" $3 }' "$WORK/all" >"$WORK/m"
        fi
    fi
    if [ ! -s "$WORK/m" ]; then
        awk -F'\t' -v h="$harness" -v s="$slug" '$1==h && $2==s { print $3 "\t" $4 }' "$WORK/fb" >"$WORK/m"
    fi
    if [ ! -s "$WORK/m" ]; then
        printf '%s\tno-transcript\t-\t-\t-\t-\n' "$slug"
        continue
    fi
    # newest first; tag each match: verdict<TAB>mtime<TAB>path<TAB>shutdown<TAB>next_boot
    sort -t "$TAB" -k1,1nr "$WORK/m" | while IFS="$TAB" read -r _m _p; do
        _x=0; clean_exit "$harness" "$_p" && _x=1
        printf '%s\t%s\t%s\n' "$_m" "$_p" "$_x"
    done | awk -F'\t' -v b="$boot" -v w="$window" '
        NR == FNR { S[++n] = $1; NB[n] = $2; next }
        { m = $1 + 0; s = "-"; nb = "-"
          if (m > b + 0) v = "touched-since-boot"
          else {
              for (i = 1; i <= n; i++) if (S[i] + 0 >= m) { s = S[i]; nb = NB[i]; break }
              if (s == "-") { s = S[n]; nb = NB[n] }
              if ($3 == 1) v = "ended-before-shutdown"
              else if (m >= s - w) v = "live"
              else v = "idle-at-shutdown"
          }
          print v "\t" $1 "\t" $2 "\t" s "\t" nb }' "$WORK/shuts" - >"$WORK/v"
    if grep -q '^touched-since-boot' "$WORK/v"; then
        pick="$(grep '^touched-since-boot' "$WORK/v" | head -1)"; verdict=touched-since-boot
    else
        nlive="$(grep -c '^live' "$WORK/v")"
        if [ "$nlive" -eq 1 ]; then
            pick="$(grep '^live' "$WORK/v" | head -1)"; verdict=live
        elif [ "$nlive" -gt 1 ]; then
            ids="" paths=""
            while IFS="$TAB" read -r _v _m _p _rest; do
                ids="${ids:+$ids,}$(dash "$(session_id_of "$harness" "$_p")")"
                paths="${paths:+$paths,}$_p"
            done <<EOF
$(grep '^live' "$WORK/v")
EOF
            newest="$(grep '^live' "$WORK/v" | head -1 | cut -f2)"
            newest_s="$(grep '^live' "$WORK/v" | head -1 | cut -f4)"
            printf '%s\tambiguous\t%s\t%s\t%s\t%s\n' "$slug" "$ids" "$paths" "$(iso "$newest")" "$(iso "$newest_s")"
            continue
        else
            pick="$(head -1 "$WORK/v")"; verdict="$(printf '%s\n' "$pick" | cut -f1)"
        fi
    fi
    pm="$(printf '%s\n' "$pick" | cut -f2)"
    pp="$(printf '%s\n' "$pick" | cut -f3)"
    ps="$(printf '%s\n' "$pick" | cut -f4)"
    pnb="$(printf '%s\n' "$pick" | cut -f5)"
    if [ "$ps" = - ]; then psi=-; else psi="$(iso "$ps")"; printf '%s\t%s\t%s\t%s\n' "$pm" "$slug" "$ps" "$pnb" >>"$WORK/picks"; fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$slug" "$verdict" "$(dash "$(session_id_of "$harness" "$pp")")" "$(dash "$pp")" "$(iso "$pm")" "$psi"
done

# ---- clusters: 2+ picked transcripts sharing one mtime minute -----------------------
# count<TAB>minute_epoch<TAB>slugs<TAB>max_mtime<TAB>shutdown<TAB>next_boot
sort -n "$WORK/picks" | awk -F'\t' '
    function flush() { if (c >= 2) print c "\t" k * 60 "\t" sl "\t" mx "\t" s "\t" nb }
    { mk = int($1 / 60)
      if (NR == 1 || mk != k) { flush(); k = mk; c = 0; sl = ""; s = $3; nb = $4 }
      c++; sl = sl (sl == "" ? "" : ",") $2; mx = $1 }
    END { flush() }' | while IFS="$TAB" read -r c mk sl mx s nb; do
    line="cluster: $c transcripts last written in the minute of $(iso "$mk") ($sl) — likely killed together; next shutdown $(iso "$s")"
    if [ "$mx" -lt $((s - window)) ]; then
        line="$line, not at it: if they died at a crash the journal missed, re-run with --shutdown-time $((mx + 60)) --boot-time $nb"
    fi
    printf '%s\n' "$line" >&2
done
exit 0
