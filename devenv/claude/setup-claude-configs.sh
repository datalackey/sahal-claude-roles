#!/usr/bin/env bash
set -euo pipefail

# Unified Claude Code setup — runs in two modes:
#
#   Default (no flag): container startup. Called by the Docker CMD after /devenv
#   is bind-mounted. Copies config files (cp, not ln — cross-filesystem) and
#   wires git config, gitignore, and the ref.tools MCP server.
#
#   --host-mode: fresh-machine bootstrap. Called by post-install-setup.sh after
#   Dropbox has synced. Hardlinks config files (same filesystem), installs
#   Claude Code via npm, and symlinks the memory directory to Dropbox.
#
# setup.sh has been retired. post-install-setup.sh now calls this script
# directly with --host-mode.

HOST_MODE=0
for arg in "$@"; do [[ "$arg" == "--host-mode" ]] && HOST_MODE=1; done

# ── source paths ──────────────────────────────────────────────────────────────
if [[ "$HOST_MODE" -eq 1 ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  CLAUDE_CONFIGS="$SCRIPT_DIR/claude-config-files"
else
  DEVENV="/devenv"
  CLAUDE_CONFIGS="$DEVENV/claude/claude-config-files"
fi

# ── prereqs ───────────────────────────────────────────────────────────────────
if [[ "$HOST_MODE" -eq 1 ]]; then
  if [ ! -e "$HOME/config" ]; then
    echo "❌ ~/config not found — run post-install-setup.sh first (Dropbox must be synced)."
    exit 1
  fi
else
  if [ ! -d "$DEVENV" ]; then
    echo "❌ /devenv not mounted — launch with: -v /etc/nixos/devenv:/devenv"
    exit 1
  fi
fi


# ── npm prefix + PATH + Claude Code install (host-mode only) ──────────────────
if [[ "$HOST_MODE" -eq 1 ]]; then
  if ! grep -q "^prefix=" "$HOME/.npmrc" 2>/dev/null; then
    echo "prefix=$HOME/.npm-global" >> "$HOME/.npmrc"
    echo "✅ Added prefix to ~/.npmrc"
  else
    echo "⏭️  ~/.npmrc prefix already set"
  fi

  if ! grep -q "npm-global/bin" "$HOME/.bashrc" 2>/dev/null; then
    echo 'export PATH="$HOME/.npm-global/bin:$PATH"' >> "$HOME/.bashrc"
    echo "✅ Added ~/.npm-global/bin to PATH in ~/.bashrc"
  else
    echo "⏭️  PATH already includes ~/.npm-global/bin"
  fi
  export PATH="$HOME/.npm-global/bin:$PATH"

  if [ -d "$HOME/.npm-global/lib/node_modules/@anthropic-ai/claude-code" ]; then
    echo "⏭️  Claude Code already installed"
  else
    echo "📦 Installing Claude Code..."
    npm install -g @anthropic-ai/claude-code
    echo "✅ Claude Code installed"
  fi
fi

# ── install helper ────────────────────────────────────────────────────────────
# Host: hardlinks. Source (claude-config-files/) and dest (~/.claude/) share a
# filesystem, so ln works — and is required because Claude Code ignores
# symlinked config files. Hardlinks also mean edits via /config or the settings
# UI reflect back to the versioned source instantly with no sync step.
#
# Container: cp only. /devenv is a bind mount (host filesystem); ~/.claude is on
# the container rootfs. That is a cross-filesystem boundary — ln fails with
# EXDEV (cross-device link). cp is not a style choice here; it is the only
# option.
install_file() {
  local src="$1" dst="$2"
  rm -f "$dst"
  if [[ "$HOST_MODE" -eq 1 ]]; then
    ln "$src" "$dst"
    echo "✅ $dst ⟵ (hardlink)"
  else
    cp "$src" "$dst"
    echo "✅ $dst"
  fi
}

# ── shared: ~/.claude/ config files ──────────────────────────────────────────
mkdir -p "$HOME/.claude"
for f in settings.json session-start.sh generate-preamble.js; do
  install_file "$CLAUDE_CONFIGS/$f" "$HOME/.claude/$f"
done

# ── shared: wire claude-hud statusLine if the plugin is present ──────────────
# The versioned settings.json has no statusLine, so we inject it here after
# install_file. Runs in both modes — see wire-hud-statusline.sh for why it's
# also called from the host-mode git hook.
"$(dirname "${BASH_SOURCE[0]}")/wire-hud-statusline.sh"

# ── host-only: CLAUDE.md, LLM/, rules/ (all bind-mounted :ro in container) ───
if [[ "$HOST_MODE" -eq 1 ]]; then
  install_file "$CLAUDE_CONFIGS/CLAUDE.md" "$HOME/.claude/CLAUDE.md"
  rm -rf "$HOME/.claude/LLM"
  mkdir -p "$HOME/.claude/LLM"
  while IFS= read -r -d '' src; do
    rel="${src#"$CLAUDE_CONFIGS/LLM/"}"
    dst="$HOME/.claude/LLM/$rel"
    mkdir -p "$(dirname "$dst")"
    install_file "$src" "$dst"
  done < <(find "$CLAUDE_CONFIGS/LLM" -type f -print0)
  echo "✅ ~/.claude/LLM/ ← $CLAUDE_CONFIGS/LLM/"

  rm -rf "$HOME/.claude/rules"
  mkdir -p "$HOME/.claude/rules"
  while IFS= read -r -d '' src; do
    rel="${src#"$CLAUDE_CONFIGS/rules/"}"
    dst="$HOME/.claude/rules/$rel"
    mkdir -p "$(dirname "$dst")"
    install_file "$src" "$dst"
  done < <(find "$CLAUDE_CONFIGS/rules" -type f -print0)
  echo "✅ ~/.claude/rules/ ← $CLAUDE_CONFIGS/rules/"
fi

# ── container-only: git config, gitignore, ref.tools MCP ─────────────────────
if [[ "$HOST_MODE" -eq 0 ]]; then
  # The image's claude-code is whatever was current at `docker build` time and
  # drifts as the image ages (npm install -g in the Dockerfile only runs once,
  # at build). Self-update on container start so long-lived images don't
  # silently diverge from the host's version — this divergence was confirmed
  # to change SessionStart hook failure behavior (host: hook errors surface as
  # a visible banner; stale 2.1.190 image: they were silently swallowed).
  # Capped at 1x/day via a host-mounted marker — npm's registry round-trip
  # costs a couple seconds even when already current, and that cost was being
  # paid on every single container start.
  UPDATE_MARKER="$HOME/.claude-code-update-marker"
  TODAY="$(date +%F)"
  if [[ -f "$UPDATE_MARKER" && "$(cat "$UPDATE_MARKER" 2>/dev/null)" == "$TODAY" ]]; then
    echo "⏭️  claude-code update check already ran today: $(claude --version 2>&1)"
  else
    echo "🔄 Updating claude-code..."
    npm install -g @anthropic-ai/claude-code \
      && echo "✅ claude-code updated: $(claude --version 2>&1)" \
      || echo "⚠️  claude-code self-update failed — continuing with existing version: $(claude --version 2>&1)"
    echo "$TODAY" > "$UPDATE_MARKER"
  fi

  sed 's|excludesfile = .*|excludesfile = /devenv/.gitignore|' \
    "$DEVENV/git.config" > "$HOME/.gitconfig"
  echo "✅ $HOME/.gitconfig (excludesfile → /devenv/.gitignore)"

  # Remap stereo mic to mono to prevent voice transcription doubling.
  # Laptop mics present as stereo (2ch) with the same signal on both channels.
  # Claude Code's voice transcription processes both channels and produces
  # doubled text. A virtual mono source from the left channel only fixes this.
  #
  # Purge any stale mono_mic remap modules first. Each session unconditionally
  # calls pactl load-module, so without this cleanup the host PipeWire daemon
  # accumulates one module per session. Once mono_mic becomes the default source
  # subsequent sessions create master=mono_mic chains (self-remap), which causes
  # sporadic transcription failures. The guard below also skips creation when
  # the default source is already mono_mic.
  pactl list modules short 2>/dev/null \
    | awk '/module-remap-source.*source_name=mono_mic/{print $1}' \
    | xargs -r -I{} pactl unload-module {} 2>/dev/null
  DEFAULT_SOURCE="$(pactl info 2>/dev/null | awk '/Default Source/{print $3}')"
  if [ -n "$DEFAULT_SOURCE" ] && [ "$DEFAULT_SOURCE" != "mono_mic" ]; then
    pactl load-module module-remap-source \
      source_name=mono_mic \
      master="$DEFAULT_SOURCE" \
      channels=1 \
      channel_map=mono \
      master_channel_map=front-left >/dev/null 2>/dev/null \
    && pactl set-default-source mono_mic 2>/dev/null \
    && echo "✅ audio: mono_mic ← $DEFAULT_SOURCE (stereo→mono remap)" \
    || echo "⚠️  audio: mono remap failed (voice input may double)"
  elif [ "$DEFAULT_SOURCE" = "mono_mic" ]; then
    echo "✅ audio: mono_mic already active (skipped reload)"
  fi

  # Restore main Claude config (oauthAccount, userID, feature flags, etc.) from host.
  # Staged via /tmp so ~/.claude.json stays a regular overlay file — Claude Code uses
  # atomic writes (temp+rename) on it, which fail if the file itself is a bind mount.
  if [ -s "/tmp/claude-state.json" ]; then
    cp /tmp/claude-state.json ~/.claude.json
    echo "✅ main config restored"
  fi

  # Restore OAuth credentials from host if available (non-empty).
  # Same staging pattern: not a bind mount so Claude Code can do atomic writes (temp+rename).
  # chmod 600 required — Claude Code refuses credentials readable by group/world.
  if [ -s "/tmp/claude-creds.json" ]; then
    cp /tmp/claude-creds.json ~/.claude/.credentials.json
    chmod 600 ~/.claude/.credentials.json
    echo "✅ credentials restored"
  fi

  # Register ref.tools MCP. Rewrite in place (cat >, not mv): ~/.claude.json is
  # a single-file bind mount — its mount point cannot be replaced by rename.
  CLAUDE_JSON="$HOME/.claude.json"
  [ -f "$CLAUDE_JSON" ] || echo '{}' > "$CLAUDE_JSON"
  tmp="$(mktemp)"
  jq '(.mcpServers //= {})
      | del(.mcpServers.context7)
      | .mcpServers.ref = {"type":"http","url":"https://api.ref.tools/mcp?apiKey=${REF_API_KEY:-}"}' \
    "$CLAUDE_JSON" > "$tmp" && cat "$tmp" > "$CLAUDE_JSON" && rm -f "$tmp" \
    && echo "✅ ref.tools MCP registered (context7 retired)"
fi

# ── host-only: git hooks ──────────────────────────────────────────────────────
if [[ "$HOST_MODE" -eq 1 ]]; then
  GIT_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ -n "$GIT_ROOT" && -d "$GIT_ROOT/.git/hooks" ]]; then
    HOOK_SRC="$SCRIPT_DIR/git-hooks/sync-claude-configs"
    for hook in post-checkout post-merge post-rewrite; do
      ln -sf "$HOOK_SRC" "$GIT_ROOT/.git/hooks/$hook"
      echo "✅ .git/hooks/$hook ⟵ (symlink)"
    done
    ln -sf "$SCRIPT_DIR/git-hooks/warn-dangling-refs" "$GIT_ROOT/.git/hooks/pre-commit"
    echo "✅ .git/hooks/pre-commit ⟵ (symlink)"
  else
    echo "⚠️  git hooks not installed — could not find .git/hooks"
  fi
fi

# ── host-only: memory → Dropbox ───────────────────────────────────────────────
# Handled generically by session-start.sh on every session (any project cwd),
# not here — see DECISIONS.md §16. This used to be a one-time migration for a
# single hardcoded project slug and is superseded.
if [[ "$HOST_MODE" -eq 1 ]]; then
  # shellcheck disable=SC1090
  source "$HOME/.bashrc" 2>/dev/null || true

  echo ""
  echo "🎯 Claude host setup complete."
  echo "⚠️  Run 'source ~/.bashrc' or open a new terminal before using the claude command."
else
  echo ""
  echo "🎯 Docker config setup complete."
fi
