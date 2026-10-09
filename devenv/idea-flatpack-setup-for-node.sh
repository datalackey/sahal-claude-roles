#!/usr/bin/env bash
# Setup Flatpak overrides for IntelliJ IDEA Ultimate on NixOS
# Fixes: NX Console daemon failing because npx not found in /bin/sh PATH
# TODO:  not yet incorp'd into setup scripts for new machine

APP=com.jetbrains.IntelliJ-IDEA-Ultimate
VERSIONS_DIR="$HOME/.var/app/$APP/config/JetBrains/IntelliJIdea2025.3/node/versions"

NODE_BIN=$(ls -d "$VERSIONS_DIR"/*/bin 2>/dev/null | sort -V | tail -1)

if [[ -z "$NODE_BIN" ]]; then
  echo "ERROR: No bundled Node.js found under $VERSIONS_DIR" >&2
  exit 1
fi
  
echo "Using Node bin: $NODE_BIN"

# Mount the Nix store read-only so IntelliJ can reference /nix/store paths
flatpak override --user --filesystem=/nix:ro "$APP"

# Expose npx (and node/npm) to subshells spawned by IntelliJ plugins (e.g. NX Console)
flatpak override --user \
  --env=PATH="$NODE_BIN:/app/bin:/app/jre/bin:/run/current-system/sw/bin:/usr/local/bin:/usr/bin:/bin" \
  "$APP"

echo "Done. Restart IntelliJ for changes to take effect."
echo ""
flatpak override --user --show "$APP"

