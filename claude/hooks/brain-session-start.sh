#!/bin/bash
# SessionStart hook: injects vault context into the conversation, mirroring
# omp/brain-vault.ts's buildContext() so brain-persist reads either harness's
# output identically. Any text printed to stdout is added as context for Claude.
# Env overrides: BRAIN_VAULT (vault path), BRAIN_QMD (qmd binary path).

set -u

INPUT=$(cat)
VAULT="${BRAIN_VAULT:-$HOME/Obsidian/vault}"

# Resolve qmd: BRAIN_QMD override -> PATH -> known install locations.
if [ -n "${BRAIN_QMD:-}" ] && [ -x "${BRAIN_QMD}" ]; then
  qmd="$BRAIN_QMD"
elif command -v qmd >/dev/null 2>&1; then
  qmd="$(command -v qmd)"
elif [ -x "$HOME/.nodenv/shims/qmd" ]; then
  qmd="$HOME/.nodenv/shims/qmd"
elif [ -x "$HOME/.local/bin/qmd" ]; then
  qmd="$HOME/.local/bin/qmd"
else
  qmd=""
  echo "brain-session-start: qmd not found (checked BRAIN_QMD, PATH, ~/.nodenv/shims, ~/.local/bin) — skipping related-notes search" >&2
fi
[ -n "$qmd" ] && export BRAIN_QMD="$qmd"
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)

# Scope helpers. If either is missing we fall back to shared-only: no private content.
REPO="$(cd "$(dirname "$(readlink -f "$0")")/../.." 2>/dev/null && pwd)"
BIN="${BRAIN_BIN:-$REPO/bin}"
BSCOPE="$BIN/brain-scope"
BSEARCH="$BIN/brain-search"
scope=$("$BSCOPE" norm 2>/dev/null) || scope=""
case "$scope" in shared|private|all) ;; *) scope="shared" ;; esac
project="${BRAIN_PROJECT:-}"
include_private=0
if [ "$scope" != "shared" ] && "$BSCOPE" includes "$scope" private >/dev/null 2>&1; then
  include_private=1
fi

# The id goes FIRST: the full output is large, Claude Code persists it to a file and
# shows only a short preview, so a trailing id never reaches the session's context.
context="This session's id is ${SESSION_ID} (harness: claude-code)"$'\n'
# An oversized top-of-mind bloats every session: nudge towards brain-sweep.
tom_bytes=$(wc -c <"$VAULT/00-home/top-of-mind.md" 2>/dev/null || echo 0)
if [ "$tom_bytes" -gt $((40 * 1024)) ]; then
  context+="⚠ top-of-mind.md is $((tom_bytes / 1024)) KB — run brain-sweep (or brain-plan-day) to archive done items."$'\n'
fi
context+=$'\n'

# 1. Top of Mind — what the user is currently focused on
if [ -f "$VAULT/00-home/top-of-mind.md" ]; then
  context+="--- VAULT: TOP OF MIND ---"$'\n'
  context+="$(cat "$VAULT/00-home/top-of-mind.md")"
  context+=$'\n\n'
fi

# 1b. Private top of mind — only when the scope includes private
if [ "$include_private" = 1 ] && [ -f "$VAULT/private/private.md" ]; then
  context+="--- VAULT: PRIVATE TOP OF MIND ---"$'\n'
  context+="$(cat "$VAULT/private/private.md")"
  context+=$'\n\n'
fi

# 2. Latest session note — continuity from the last session (newest dated basename)
session_files=$(ls -1 "$VAULT/sessions/"*.md 2>/dev/null)
if [ "$include_private" = 1 ]; then
  session_files+=$'\n'$(ls -1 "$VAULT/private/sessions/"*.md 2>/dev/null)
fi
latest_session=$(printf '%s\n' "$session_files" | grep '/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' \
  | awk -F/ '{print $NF "\t" $0}' | sort -r | head -1 | cut -f2-)
if [ -n "$latest_session" ]; then
  context+="--- VAULT: LATEST SESSION ---"$'\n'
  context+="$(cat "$latest_session")"
  context+=$'\n\n'
fi

# 3. Related notes — scope-aware search for the project (or cwd basename)
query="$project"
if [ -z "$query" ] && [ -n "$CWD" ]; then
  query=$(basename "$CWD")
  if [ "$query" = "vault" ] || [ "$query" = "$(basename "$HOME")" ]; then query=""; fi
fi
if [ -n "$query" ] && [ -n "$qmd" ] && [ -x "$BSEARCH" ] && [ -x "$BSCOPE" ]; then
  args=(--scope "$scope" -n 3)
  [ -n "$project" ] && args+=(--project "$project")
  related=$(BUN_INSTALL="" "$BSEARCH" "${args[@]}" "$query" 2>/dev/null)
  if [ -n "$related" ]; then
    context+="--- VAULT: RELATED NOTES (project: $query) ---"$'\n'
    context+="$related"
    context+=$'\n\n'
  fi
fi

context+="--- END VAULT CONTEXT ---"$'\n'
context+="The knowledge vault is at $VAULT — read and write it with native file tools, search it with \`brain-search \"<query>\"\` (scope-aware; add \`--project <slug>\` to focus). Load and save session context with the brain-orient and brain-persist skills (/brain-orient, /brain-persist)."$'\n'
if [ "$include_private" = 1 ]; then
  today_loc="current (work and projects actions live in 00-home/top-of-mind.md, private ones in private/private.md)"
else
  today_loc="in top-of-mind (00-home/top-of-mind.md) current"
fi
context+="As you work, keep the Today list ${today_loc}: when you start on something, mark the matching Today action in-progress ([/]) — or, if it isn't listed, add it under Today as a new [/] action — and mark it [x] when done. State briefly what you changed; never edit silently."$'\n'
scope_line="Vault scope for this session: $scope"
[ -n "$project" ] && scope_line+=", project: $project"
scope_line+=". Private notes live under private/ and are only visible in private/all scope."
context+="$scope_line"
printf '%s' "$context"

exit 0
