#!/usr/bin/env bash
# Symlinks ~/.claude/skills/<name> -> $BRAIN_ROOT/skills/<name> for every skill
# directory that has a SKILL.md, skipping skills/_shared (the harness-neutral
# library, not a skill). Idempotent: re-running changes nothing when the
# symlink already points at the right place, and replaces a stale symlink that
# points elsewhere; prunes dangling links into $BRAIN_ROOT/skills/ left by a
# retired skill. Finally reports this machine's hosts.conf name (`self host:`),
# warning instead when it cannot be resolved. BRAIN_ROOT and HOME are overridable
# for testing.

set -euo pipefail

BRAIN_ROOT="${BRAIN_ROOT:-$HOME/projects/brain}"
TARGET_DIR="$HOME/.claude/skills"

mkdir -p "$TARGET_DIR"

# --- workbench: the plain non-repo cwd for project-less non-code workers ---
# (never ~/projects/brain: its .claude/settings.json forces BRAIN_SCOPE=all)
mkdir -p "$HOME/projects/workbench"
echo "workbench: ready"

for skill_dir in "$BRAIN_ROOT"/skills/*/; do
  name="$(basename "$skill_dir")"
  [ "$name" = "_shared" ] && continue
  [ -f "$skill_dir/SKILL.md" ] || continue

  src="$BRAIN_ROOT/skills/$name"
  dest="$TARGET_DIR/$name"

  if [ -L "$dest" ]; then
    current="$(readlink "$dest")"
    if [ "$current" = "$src" ]; then
      echo "up to date: $name"
      continue
    fi
    rm "$dest"
  elif [ -e "$dest" ]; then
    echo "skipping $name: $dest exists and is not a symlink" >&2
    continue
  fi

  ln -s "$src" "$dest"
  echo "linked: $name -> $src"
done

# --- prune: drop dangling skill links into this repo (a retired skill, e.g. brain-post-standup) ---
for dest in "$TARGET_DIR"/*; do
  [ -L "$dest" ] && [ ! -e "$dest" ] || continue
  case "$(readlink "$dest")" in "$BRAIN_ROOT/skills/"*) ;; *) continue ;; esac
  rm "$dest"
  echo "pruned: $(basename "$dest")"
done

# --- bin: link every executable brain-* CLI into ~/.local/bin (not *.py) ---
BIN_DIR="${BRAIN_BIN_DIR:-$HOME/.local/bin}"
mkdir -p "$BIN_DIR"

for src in "$BRAIN_ROOT"/bin/brain-*; do
  [ -e "$src" ] || continue
  case "$src" in *.py) continue ;; esac
  [ -f "$src" ] && [ -x "$src" ] || continue
  name="$(basename "$src")"
  dest="$BIN_DIR/$name"

  if [ -L "$dest" ]; then
    current="$(readlink "$dest")"
    if [ "$current" = "$src" ]; then
      echo "up to date: $name"
      continue
    fi
    rm "$dest"
  elif [ -e "$dest" ]; then
    echo "skipping $name: $dest exists and is not a symlink" >&2
    continue
  fi

  ln -s "$src" "$dest"
  echo "linked: $name -> $src"
done

# --- qmd: exclude private/ from the default index, give it its own `private` index ---
QMD_CONF="${XDG_CONFIG_HOME:-$HOME/.config}/qmd"
VAULT="${BRAIN_VAULT:-$HOME/Obsidian/vault}"
if [ -x "$BRAIN_ROOT/bin/brain-scope" ]; then
  python3 "$BRAIN_ROOT/bin/brain-scope" qmd-config "$QMD_CONF" "$VAULT"
else
  echo "warning: $BRAIN_ROOT/bin/brain-scope missing, skipping qmd config" >&2
fi

# --- self host: report which hosts.conf row this machine is (never fails the install) ---
HOST_LIB="$BRAIN_ROOT/skills/_shared/lib/host.sh"
if [ -r "$HOST_LIB" ]; then
  # shellcheck source=../skills/_shared/lib/host.sh
  source "$HOST_LIB"
  if self="$(self_host)"; then
    echo "self host: $self"
  else
    echo "warning: self host unresolved: add this machine's hostname ($(hostname -s 2>/dev/null || uname -n)) to its row in $BRAIN_HOSTS, or set BRAIN_SELF_HOST" >&2
  fi
else
  echo "warning: $HOST_LIB missing, cannot resolve self host" >&2
fi
