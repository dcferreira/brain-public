# Claude Code wiring

This directory replaces the pre-port `obsidian-session-start.sh` /
`obsidian-session-end.sh` hooks (formerly under `~/.claude/hooks` on the old macOS setup,
never committed to this repo) with the Claude Code equivalent of
`omp/brain-vault.ts`.

## Files

- `hooks/brain-session-start.sh` — `SessionStart` hook. Reads `session_id` and
  `cwd` from the hook's stdin JSON, applies `BRAIN_SCOPE` / `BRAIN_PROJECT`
  (default `shared`: no private content), prints the same vault-context blocks as
  `omp/brain-vault.ts`'s `buildContext()` (top of mind, latest session note,
  qmd hits for the project), then the session-id line, so `brain-persist`
  reads either harness's output identically.
- `hooks/brain-session-end.sh` — `SessionEnd` hook. Runs `qmd update` to
  reindex the vault; writes nothing. Both hooks resolve `qmd` in the same
  order — a `BRAIN_QMD` override, then `PATH`, then `~/.nodenv/shims/qmd`,
  then `~/.local/bin/qmd` — since Claude Code hooks on a remote machine such as
  `homeserver` do not see the interactive shell's `PATH`; when none are
  found, the start hook still prints its other context blocks and the end
  hook exits 0 silently.
- `settings.snippet.json` — the `hooks.SessionStart` / `hooks.SessionEnd`
  entries, plus `"attribution": {"sessionUrl": false}` (no claude.ai session links in
  commits/PRs), to merge into `~/.claude/settings.json`.
- `install.sh` — symlinks `~/.claude/skills/<name>` to
  `~/projects/brain/skills/<name>` for every skill directory with a
  `SKILL.md`, skipping `_shared`. It also symlinks every executable
  `bin/brain-*` (`brain-scope`, `brain-search`, `brain-migrate-scope`; not the
  `*.py` modules) into `~/.local/bin` (`BRAIN_BIN_DIR` overrides), and edits
  the qmd configs under `~/.config/qmd` (`XDG_CONFIG_HOME` honoured) via
  `brain-scope qmd-config`: it adds `ignore: ["private/**"]` to the `vault`
  collection in `index.yml` and creates `private.yml`, the config of the
  second `private` index. It also creates `~/projects/workbench` (prints
  `workbench: ready`), the plain non-repo cwd for project-less non-code workers.
  Idempotent.
- `install.test.sh` — plain bash tests for `install.sh`, using a temporary
  `HOME` and a fake `BRAIN_ROOT`.
- `hooks/brain-session-start.test.sh` — plain bash tests for the start hook
  against a fixture vault with private sentinels and a stub `qmd`.

## Coordinator scope and worker cwd

The repo's `.claude/settings.json` sets env `BRAIN_SCOPE=all`, so any Claude Code
session started in `~/projects/brain` is all-scope (this overrides an inherited
`BRAIN_SCOPE`; it replaces the old `claude-all` / `omp-all` alias guidance).
omp does not read `.claude` settings: an omp session in the brain dir stays
`shared` and fails closed, so coordinate in Claude Code. Consequently workers
that are not about the brain itself must never be rooted in `~/projects/brain`
(`launch-worker.sh` refuses a fresh non-`all` launch there); project-less
non-code workers use `~/projects/workbench`, and `~/projects/brain` is for
`project: brain` workers only.

## Installing on a machine

```sh
bash ~/projects/brain/claude/install.sh
```

Then merge `settings.snippet.json` into `~/.claude/settings.json` by hand
(Claude Code has no config-merge command; add the `SessionStart` and
`SessionEnd` entries under the existing `hooks` object without clobbering any
hooks already there).

## Testing

```sh
bash ~/projects/brain/claude/install.test.sh
bash ~/projects/brain/claude/hooks/brain-session-start.test.sh
```

The scope model is documented in the root `SETUP.md` ("Scopes: work / projects / private").
