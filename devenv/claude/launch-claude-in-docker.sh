#!/usr/bin/env bash
set -euo pipefail

# Launch the sandboxed Claude container behind a network egress filter.
#
#   ./launch-claude-in-docker.sh [STARTUP_DIR]
#
# Tier 2 hardening: a network-filter sidecar (dnsmasq + ipset + iptables)
# restricts outbound traffic to ALLOWED_SITES. The Claude container shares the
# filter's network namespace, so it inherits the restrictions while keeping
# --cap-drop=ALL (only the filter needs NET_ADMIN).

STARTUP_DIR="$(realpath "${1:-.}")"
GIT_ROOT="$(git -C "$STARTUP_DIR" rev-parse --show-toplevel 2>/dev/null || echo "$STARTUP_DIR")"
if [[ "$GIT_ROOT" != "$STARTUP_DIR" ]]; then
  echo "ℹ️  Mounting git root: $GIT_ROOT"
fi
STARTUP_DIR="$GIT_ROOT"
WORKSPACE_NAME="$(basename "$STARTUP_DIR")"

# ref.tools API key is supplied from the host environment and passed into the
# container env only — never written to git or any versioned file. Get one at
# https://ref.tools/keys
: "${REF_API_KEY:?Set REF_API_KEY (https://ref.tools/keys) before launching}"

# GitHub token extracted from the host keyring at launch time and injected as
# GH_TOKEN — the gh CLI honours this env var for auth, so no config writes are
# needed inside the (read-only-mounted) container.
GH_TOKEN="$(gh auth token 2>/dev/null || true)"
if [[ -z "$GH_TOKEN" ]]; then
  echo "⚠️  gh auth token returned empty — GitHub CLI will not be authenticated inside the container." >&2
fi

# Load outbound allowlist from config; pre-flight-check each domain from the host.
CONF="$(dirname "$(realpath "$0")")/allowed-sites.conf"
mapfile -t DOMAIN_LIST < <(grep -v '^\s*#' "$CONF" | grep -v '^\s*$')

# Additive override: ALLOWED_SITES=foo.com,bar.com appends to the base list.
if [[ -n "${ALLOWED_SITES:-}" ]]; then
  IFS=',' read -ra _EXTRA <<< "$ALLOWED_SITES"
  DOMAIN_LIST+=("${_EXTRA[@]}")
fi
ALLOWED_SITES="$(IFS=,; echo "${DOMAIN_LIST[*]}")"

FAILED=()
# /dev/tcp/HOST/PORT is a bash builtin pseudo-device: redirecting into it opens
# a raw TCP socket, so this forces a connection attempt with no curl/nc needed.
# `timeout 3` bounds a silently-dropping firewall (bash's /dev/tcp has no
# timeout of its own). `||` short-circuits: try 443 first, fall back to 80
# only if 443 refuses (some allowed sites are HTTP-only), and only record the
# domain as FAILED if both ports are unreachable.
for domain in "${DOMAIN_LIST[@]}"; do
  timeout 3 bash -c "cat </dev/null >/dev/tcp/${domain}/443" 2>/dev/null \
    || timeout 3 bash -c "cat </dev/null >/dev/tcp/${domain}/80" 2>/dev/null \
    || FAILED+=("$domain")
done
if [[ ${#FAILED[@]} -gt 0 ]]; then
  printf '❌ Pre-flight: these domains are unreachable from host — fix allowed-sites.conf or your network:\n' >&2
  printf '  %s\n' "${FAILED[@]}" >&2
  exit 1
fi

FILTER_NAME="claude-net-filter-$$"

cleanup() { docker rm -f "$FILTER_NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

# 1. Start the egress filter sidecar (only this container needs NET_ADMIN).
docker run -d --rm \
  --name "$FILTER_NAME" \
  --cap-add=NET_ADMIN \
  -e ALLOWED_DOMAINS="$ALLOWED_SITES" \
  monadicalsas/network-filter:latest >/dev/null

# Give dnsmasq/iptables a moment to come up before joining the namespace.
sleep 2

# Ensure the persistent memory directory exists on the host before mounting it.
mkdir -p "$HOME/Dropbox/projects/devEnv/config/LLM/claude-memory"

# Ensure the claude-code self-update marker exists on the host before mounting
# it — a single-file bind mount to a nonexistent path creates a directory
# instead, which breaks the date-stamp read/write in setup-claude-configs.sh.
touch -a "$HOME/.claude-code-update-marker"

# Write nixos devenv git status to a temp file; mounted :ro so session-start.sh
# can read it without env-var multiline issues or workspace-repo ambiguity.
_DEVENV_STATUS_FILE="$(mktemp)"
git -C /etc/nixos status --short -- devenv/ 2>/dev/null > "$_DEVENV_STATUS_FILE" || true

# 2. Run Claude, sharing the filter's network namespace.
# CMD override runs setup then claude; EXIT trap saves auth state to host-mounted
# staging files on every exit so the next launch skips browser re-auth.
docker run --rm -it \
  --network=container:"$FILTER_NAME" \
  -e TERM="${TERM:-xterm-256color}" \
  -e WORKSPACE_NAME="$WORKSPACE_NAME" \
  -v "$STARTUP_DIR":/workspace \
  -v "$HOME/.claude.json":/home/node/.claude.json \
  -v "$HOME/.claude-credentials.json":/tmp/claude-creds.json \
  -v "$HOME/.claude-state.json":/tmp/claude-state.json \
  -v "$HOME/.claude-code-update-marker":/home/node/.claude-code-update-marker \
  -v "$HOME/.claude/plugins":/home/node/.claude/plugins \
  -v /etc/nixos/devenv/claude/claude-config-files/CLAUDE.md:/home/node/.claude/CLAUDE.md \
  -v /etc/nixos/devenv/claude/claude-config-files/LLM:/home/node/.claude/LLM \
  -v /etc/nixos/devenv/claude/claude-config-files/rules:/home/node/.claude/rules:ro \
  -v "$HOME/Dropbox/projects/devEnv/config/LLM/claude-memory":/home/node/.claude/projects/-workspace/memory \
  -v "$HOME/.config/gh":/home/node/.config/gh:ro \
  -v "$_DEVENV_STATUS_FILE":/tmp/devenv-status.txt:ro \
  -e GH_TOKEN="$GH_TOKEN" \
  -v /etc/nixos/devenv:/devenv:ro \
  -v /run/user/1000/pulse:/run/user/1000/pulse \
  -e PULSE_SERVER=unix:/run/user/1000/pulse/native \
  -v "$HOME/.config/pulse/cookie":/tmp/pulse-cookie:ro \
  -e PULSE_COOKIE=/tmp/pulse-cookie \
  -e PULSE_SOURCE=mono_mic \
  -e REF_API_KEY="$REF_API_KEY" \
  -e CLAUDE_ROLE="${CLAUDE_ROLE:-}" \
  -e DISABLE_TELEMETRY=1 \
  -e ENABLE_CLAUDEAI_MCP_SERVERS=false \
  --memory=4g \
  --cpus=2 \
  --pids-limit=512 \
  --cap-drop=ALL \
  --security-opt=no-new-privileges \
  claude-code-sandbox \
  bash -c 'trap "cp ~/.claude/.credentials.json /tmp/claude-creds.json 2>/dev/null; cp ~/.claude.json /tmp/claude-state.json 2>/dev/null; true" EXIT; /devenv/claude/setup-claude-configs.sh && claude --dangerously-skip-permissions'
rm -f "$_DEVENV_STATUS_FILE"
