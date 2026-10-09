# Run from: directory containing this Dockerfile
# Base: node:22-bookworm-slim (Debian Bookworm, Node 22 preinstalled)

FROM node:22-bookworm-slim

# Install git and basic tools Claude Code needs
RUN apt-get update && apt-get install -y \
    git \
    curl \
    ca-certificates \
    jq \
    pulseaudio-utils \
    sox \
    libsox-fmt-pulse \
    pandoc \
    chromium \
    --no-install-recommends \
    && rm -rf /var/lib/apt/lists/*

# Bake Chromium in at build time (root + full network here) since the runtime
# sandbox has neither (non-root `node` user, egress allowlist) — see COMMON
# directive "NixOS + Playwright Chromium" and DECISIONS.md §17.
ENV PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH=/usr/bin/chromium

# Install GitHub CLI (gh)
RUN mkdir -p -m 755 /etc/apt/keyrings \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
       | tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null \
    && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
       | tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
    && apt-get update \
    && apt-get install -y gh --no-install-recommends \
    && rm -rf /var/lib/apt/lists/*

# Set WORKDIR to /tmp BEFORE installing claude to prevent filesystem scan hang
WORKDIR /tmp

# Install Claude Code globally
RUN npm install -g @anthropic-ai/claude-code

# Non-root user required — claude refuses --dangerously-skip-permissions as root.
# The base image already provides USER node at uid 1000, which matches a typical
# single-user NixOS host (uid 1000) — no second user needed.

# Pre-create ~/.claude subdirs so Docker doesn't create bind-mount parents as root.
RUN mkdir -p /home/node/.claude/debug \
             /home/node/.claude/statsig \
             /home/node/.claude/projects \
             /home/node/.claude/projects/-workspace \
             /home/node/.claude/plugins \
             /home/node/.claude/LLM \
    && chown -R node:node /home/node/.claude

# chrome_crashpad_handler refuses to start ("--database is required") without
# a writable XDG cache/config dir — chromium alone (added above) isn't enough
# for a real launch, only for `ldd`-clean shared libs. See DECISIONS.md §17.
RUN mkdir -p /home/node/.cache /home/node/.config \
    && chown -R node:node /home/node/.cache /home/node/.config
ENV XDG_CACHE_HOME=/home/node/.cache
ENV XDG_CONFIG_HOME=/home/node/.config

# Give node user a writable npm prefix so auto-updates (npm install -g) succeed
RUN mkdir -p /home/node/.npm-global/bin \
    && chown -R node:node /home/node/.npm-global
ENV NPM_CONFIG_PREFIX=/home/node/.npm-global
ENV PATH=/home/node/.npm-global/bin:${PATH}
USER node
WORKDIR /workspace

CMD ["/bin/bash", "-c", "/devenv/claude/setup-claude-configs.sh && claude --dangerously-skip-permissions"]

