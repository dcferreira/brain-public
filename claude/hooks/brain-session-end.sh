#!/bin/bash
# SessionEnd hook: re-indexes the vault (default and private indexes) so new/edited notes are searchable next
# session. Reindex only — writes nothing.
# Env overrides: BRAIN_QMD (qmd binary path).

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
fi

[ -n "$qmd" ] && "$qmd" update >/dev/null 2>&1
# The private index (private/ subtree); a missing index just fails silently.
[ -n "$qmd" ] && "$qmd" --index private update >/dev/null 2>&1
exit 0
