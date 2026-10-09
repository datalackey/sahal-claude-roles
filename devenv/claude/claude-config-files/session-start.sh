#!/usr/bin/env bash
date >> /tmp/claude-hook.log

# Resolve the active role. This is the ONLY place role resolution happens —
# CLAUDE.md tells the assistant to consume the table this script's node
# helper injects, not to re-derive the role itself (see claude-config-files/
# CLAUDE.md's session start protocol). Priority order:
#   a. $CLAUDE_ROLE env var override
#   b. nearest CLAUDE.md declaring "ACTIVE ROLE:", walking from cwd toward
#      the git root
#   c. default DEV
resolve_role() {
  if [ -n "${CLAUDE_ROLE:-}" ]; then
    printf '%s' "$CLAUDE_ROLE"
    return
  fi

  local root dir role
  root=$(git rev-parse --show-toplevel 2>/dev/null)
  dir="$PWD"
  while true; do
    if [ -f "$dir/CLAUDE.md" ]; then
      role=$(grep -oP 'ACTIVE ROLE:\s*\K\S+' "$dir/CLAUDE.md" 2>/dev/null | head -1)
      if [ -n "$role" ]; then
        printf '%s' "$role"
        return
      fi
    fi
    [ -n "$root" ] && [ "$dir" = "$root" ] && break
    [ "$dir" = "/" ] && break
    dir=$(dirname "$dir")
  done

  printf 'DEV'
}

export HOOK_ROLE="$(resolve_role)"

# Host-mode auto-memory portability: docker sessions already get a Dropbox-
# backed memory dir via a hardcoded bind mount in launch-claude-in-docker.sh
# (cwd inside the container is always /workspace, so every docker session
# shares that one mount). Host-mode sessions have no such mount — Claude Code
# names each project's memory dir after the real cwd, so a project run
# outside Docker gets a fresh, local-only memory dir unless we link it to the
# same shared Dropbox pool here. /devenv only exists inside the container, so
# its absence is how we detect host mode.
if [ ! -d /devenv ]; then
  PROJECT_SLUG="$(pwd | sed 's/\//-/g')"
  MEMORY_DIR="$HOME/.claude/projects/$PROJECT_SLUG/memory"
  DROPBOX_MEMORY="$HOME/Dropbox/projects/devEnv/config/LLM/claude-memory"
  mkdir -p "$DROPBOX_MEMORY" "$(dirname "$MEMORY_DIR")"
  if [ ! -L "$MEMORY_DIR" ]; then
    if [ -d "$MEMORY_DIR" ]; then
      # Merge any pre-existing local-only memory into the shared pool before
      # replacing the dir with a symlink. cp -n never overwrites, so an
      # existing Dropbox file wins on a name collision. mv (not rm -rf) keeps
      # the original as a reversible backup rather than deleting it outright.
      cp -n "$MEMORY_DIR"/* "$DROPBOX_MEMORY"/ 2>/dev/null
      mv "$MEMORY_DIR" "$MEMORY_DIR.bak.$(date +%s)"
    fi
    ln -s "$DROPBOX_MEMORY" "$MEMORY_DIR"
  fi
fi

# Host-mode hardlink integrity: setup-claude-configs.sh --host-mode hardlinks
# settings.json/session-start.sh/generate-preamble.js/CLAUDE.md/LLM/**/rules/**
# in from the repo, and git-hooks/sync-claude-configs re-links after git pull/
# checkout/rebase. But any edit that writes via temp-file+rename (many tools
# do, including Claude Code's own Edit/Write) on either side silently orphans
# the hardlink with no git operation involved at all — so the hook never
# fires and nothing catches the drift (see DECISIONS.md §11/§18). Since this
# script already runs on every session, re-verify + self-heal here too,
# instead of relying solely on git-triggered resync.
if [ ! -d /devenv ]; then
  CLAUDE_CONFIGS="/etc/nixos/devenv/claude/claude-config-files"
  if [ -d "$CLAUDE_CONFIGS" ]; then
    # Bidirectional: whichever side was written to more recently wins and gets
    # propagated to the other. Repo-unconditionally-wins would silently discard
    # a direct edit to the ~/.claude copy (the exact drift this is meant to fix).
    relink_if_drifted() {
      local repo="$1" host="$2"
      [ -f "$repo" ] || return 0
      if [ ! -e "$host" ]; then
        mkdir -p "$(dirname "$host")"
        ln -f "$repo" "$host"
        echo "$(date) 🔗 linked new config: $host" >> /tmp/claude-hook.log
        return 0
      fi
      [ "$(stat -c '%i' "$repo" 2>/dev/null)" = "$(stat -c '%i' "$host" 2>/dev/null)" ] && return 0
      if [ "$(stat -c '%Y' "$host")" -gt "$(stat -c '%Y' "$repo")" ]; then
        ln -f "$host" "$repo"
        echo "$(date) 🔗 host was newer — re-linked repo ⟵ host: $repo" >> /tmp/claude-hook.log
      else
        ln -f "$repo" "$host"
        echo "$(date) 🔗 repo was newer — re-linked host ⟵ repo: $host" >> /tmp/claude-hook.log
      fi
    }
    for f in settings.json session-start.sh generate-preamble.js CLAUDE.md; do
      relink_if_drifted "$CLAUDE_CONFIGS/$f" "$HOME/.claude/$f"
    done
    for subdir in LLM rules; do
      while IFS= read -r -d '' src; do
        rel="${src#"$CLAUDE_CONFIGS/$subdir/"}"
        relink_if_drifted "$src" "$HOME/.claude/$subdir/$rel"
      done < <(find "$CLAUDE_CONFIGS/$subdir" -type f -print0 2>/dev/null)
    done
  fi
fi

if [ -f /tmp/devenv-status.txt ]; then
  HOOK_DEVENV_STATUS="$(cat /tmp/devenv-status.txt)"
else
  HOOK_DEVENV_STATUS="$(git -C /etc/nixos status --short -- devenv/ 2>/dev/null || true)"
fi
export HOOK_DEVENV_STATUS

# Emit the mandatory role preamble. Node (not python3): it runs unchanged on the
# host and inside the slim node:* container image. MCP registration is handled
# separately — in the container by setup-claude-configs.sh (jq); the host keeps
# its own MCP config untouched.
node "$HOME/.claude/generate-preamble.js"
exit $?
