#!/usr/bin/env bash
set -euo pipefail

# Wire claude-hud's statusLine into ~/.claude/settings.json, if the plugin is
# present in the plugin cache. Idempotent — safe to call on every run.
#
# Called from two places, both of which can overwrite settings.json without
# knowing about statusLine:
#   - setup-claude-configs.sh (both modes), right after settings.json is
#     installed from the versioned source (which has no statusLine key)
#   - git-hooks/sync-claude-configs, right after it re-hardlinks
#     settings.json on the host (a plain git pull/checkout/rebase would
#     otherwise silently wipe statusLine until the next full setup run)
#
# Plugin files live under plugins/cache/<marketplace-hash>/<name>/<semver>/dist/index.js.
HUDDIST="$(find "$HOME/.claude/plugins/cache" -path "*/claude-hud/*/dist/index.js" -not -path "*/node_modules/*" 2>/dev/null | sort -V | tail -1)"
if [ -n "$HUDDIST" ]; then
  NODE_BIN="$(command -v node)"
  # Write a CJS wrapper that patches stdin.cwd with the real workspace name
  # (inside the container cwd is /workspace; WORKSPACE_NAME carries the real
  # name). On the host, WORKSPACE_NAME is unset and this is a no-op — cwd is
  # already correct.
  WRAPPER="$HOME/.claude/hud-wrapper.js"
  cat > "$WRAPPER" << WRAPPER_SCRIPT
'use strict';
const { spawnSync } = require('child_process');
const fs = require('fs');
const chunks = [];
process.stdin.on('data', d => chunks.push(d));
process.stdin.on('end', () => {
  let input = Buffer.concat(chunks).toString();
  const name = process.env.WORKSPACE_NAME;
  if (name && name !== 'workspace') {
    try {
      const d = JSON.parse(input);
      if (d.cwd === '/workspace') {
        // Symlink /tmp/<name> -> /workspace so git resolves correctly
        // while claude-hud displays the short project name.
        const sym = '/tmp/' + name;
        try { fs.symlinkSync('/workspace', sym); } catch (e) {}
        d.cwd = sym;
      }
      input = JSON.stringify(d);
    } catch (e) {}
  }
  const r = spawnSync(process.execPath, ['$HUDDIST'], {
    input, stdio: ['pipe', 'inherit', 'inherit'], env: process.env,
  });
  process.exit(r.status ?? 0);
});
WRAPPER_SCRIPT
  tmp="$(mktemp)"
  jq --arg cmd "$NODE_BIN $WRAPPER" \
    '.statusLine = {"type": "command", "command": $cmd}' \
    "$HOME/.claude/settings.json" > "$tmp" \
    && mv "$tmp" "$HOME/.claude/settings.json" \
    && echo "✅ claude-hud statusLine wired via workspace-name wrapper ($HUDDIST)"
fi
