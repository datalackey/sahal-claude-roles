# Claude Code Setup

## Building the Docker image

Run from the directory containing the `Dockerfile` (or pass the path explicitly):

```bash
docker build -t claude-code-sandbox /etc/nixos/devenv/claude/
```

The image runs as the `node` user (uid 1000, provided by the base image), which
matches a typical single-user NixOS host. No build args are needed. Rebuild
whenever the `Dockerfile` changes.

---

## Launch architecture

`launch-claude-in-docker.sh` starts **two containers**:

1. **Network-filter sidecar** (`monadicalsas/network-filter`) — runs `dnsmasq` +
   `ipset` + `iptables`. Only allowlisted domains (`ALLOWED_SITES`) resolve;
   everything else is blocked at DNS. This container needs `NET_ADMIN`.
2. **Claude container** — joins the sidecar's network namespace via
   `--network=container:<filter>`, inheriting the egress restrictions while keeping
   `--cap-drop=ALL`.

The sidecar is cleaned up automatically when the Claude container exits (EXIT trap).
See DECISIONS.md §8 for the full rationale.

### Egress allowlist (`allowed-sites.conf`)

The permitted outbound domains live in `devenv/claude/allowed-sites.conf` — one
domain per line; blank lines and `#` comments are ignored. Edit this file to
tighten or extend allowed traffic; `ALLOWED_SITES` is assembled from it at
launch time.

**Pre-flight check:** before starting any container, the launch script opens a
TCP connection to port 443 for every listed domain, falling back to port 80 if
443 is refused (some allowed sites are HTTP-only). If any domain is unreachable
on both ports, it prints the failing domains and exits 1. Fix the conf file or
your network, then re-launch.

---

## Container configuration

### Runtime env: `ALLOWED_SITES`

Normally assembled from `allowed-sites.conf` and not set manually. To add domains
for a single session without editing the conf file, export `ALLOWED_SITES` before
launching — the listed domains are **appended** to the base list and subject to
the same pre-flight reachability check:

```bash
ALLOWED_SITES=foo.com,bar.com ./launch-claude-in-docker.sh
```

The final value (base + extras) is passed via `-e ALLOWED_SITES` to the
network-filter sidecar, which uses it to configure `dnsmasq` + `iptables` rules
at startup.

### Runtime env: `DISABLE_TELEMETRY`

Hardcoded to `1` in the launch script — always on for all dev sessions. Claude
Code sends telemetry to `statsig.anthropic.com`, which generates an unusually
high volume of DNS queries and retries aggressively if the domain is unreachable.
With telemetry disabled that traffic is suppressed entirely, so
`statsig.anthropic.com` is also excluded from `allowed-sites.conf`.

### Runtime env: `REF_API_KEY`

**Required — the launch script hard-fails if unset.** Export it before launching:

```bash
export REF_API_KEY=<your-key>
```

The key is injected via `-e REF_API_KEY` and referenced as `${REF_API_KEY:-}` in
the `~/.claude.json` MCP registration, so no secret is written to disk or git.

### Runtime env: `GH_TOKEN`

Extracted from the host keyring via `gh auth token` at launch time and passed
as `-e GH_TOKEN` into the container. The `gh` CLI honours this env var natively
for authentication, so no config-file writes are needed inside the container.
If the host is not authenticated, the launch script emits a warning and the var
is empty — `gh` commands will fail inside the container but the launch itself is
not blocked.

The host's `~/.config/gh` is also bind-mounted to `/home/node/.config/gh:ro`
so non-auth settings (e.g. `git_protocol: ssh`) are picked up by the correct
container user.

### Runtime env: `TERM`

The launch script passes `-e TERM="${TERM:-xterm-256color}"` into the container.
This is load-bearing, not cosmetic.

Claude Code's TUI queries **terminfo** at startup to determine which terminal
capabilities are available — in particular, whether to enable mouse-tracking
escape sequences (`\e[?1000h` basic, `\e[?1006h` SGR extended). Docker's
pseudo-TTY does not inherit `TERM` from the host; without it the terminfo lookup
either fails or resolves to a capability-poor entry, and the TUI silently
disables mouse support. The result: clicking inside the terminal has no effect
and text selection does not activate.

Passing `xterm-256color` as the fallback (rather than the raw host `$TERM`)
ensures the entry is always present in Debian's base ncurses inside the image.
If your host terminal is `xterm-kitty` and you want full kitty-protocol mouse
support inside the container, install `kitty-terminfo` in the Dockerfile and
change the flag to `-e TERM=$TERM` (no clamping).

### Runtime env: `ENABLE_CLAUDEAI_MCP_SERVERS`

Set to `false` to suppress the built-in claude.ai MCP connectors (Gmail, Calendar,
Drive). These are unused and add startup noise.

### Resource limits and security flags

The Claude container runs with:

| Flag | Value | Purpose |
|------|-------|---------|
| `--memory` | `4g` | OOM boundary |
| `--cpus` | `2` | CPU cap |
| `--pids-limit` | `512` | Prevents fork bombs |
| `--cap-drop` | `ALL` | Drops all Linux capabilities |
| `--security-opt` | `no-new-privileges` | Prevents privilege escalation |

### Audio / voice input (PulseAudio)

Voice input is enabled in `settings.json` (hold mode). The launch script wires
the host PulseAudio socket into the container:

| Mount / env var | Value |
|-----------------|-------|
| `-v` | `/run/user/1000/pulse:/run/user/1000/pulse` |
| `-v` | `~/.config/pulse/cookie:/tmp/pulse-cookie:ro` |
| `PULSE_SERVER` | `unix:/run/user/1000/pulse/native` |
| `PULSE_COOKIE` | `/tmp/pulse-cookie` |
| `PULSE_SOURCE` | `mono_mic` |

The Dockerfile installs `pulseaudio-utils`, `sox`, and `libsox-fmt-pulse` to
support playback and recording via the host daemon.

#### Stereo-to-mono remap

Laptop microphones present as stereo (2 ch) with identical signal on both
channels. Claude Code's `audio-capture-napi` native module can bypass the
PulseAudio server-side default source and capture directly from the hardware
stereo device, causing doubled transcription output. Two fixes work together:
`setup-claude-configs.sh` creates a virtual mono source at container startup,
and `PULSE_SOURCE=mono_mic` is passed as a container env var so libpulse
clients are forced to use it regardless of what device they request:

```bash
pactl load-module module-remap-source \
  source_name=mono_mic master=<alsa_input> \
  channels=1 channel_map=mono master_channel_map=front-left
pactl set-default-source mono_mic
```

**Module-accumulation pitfall:** each container session calls `pactl
load-module`, which always creates a *new* module even when one named `mono_mic`
already exists. Over many sessions this leaves dozens of stale remap modules on
the host PipeWire daemon. Worse, once `mono_mic` is the default source the next
session creates a module whose `master=mono_mic` — a self-remap chain that
produces unpredictable transcription failures.

The script guards against both by: (1) unloading all existing `mono_mic` remap
modules before creating a fresh one, and (2) skipping creation if the default
source is already `mono_mic`.

**Diagnose accumulation:**

```bash
pactl list modules short | grep 'source_name=mono_mic'
# each line is a remap module; there should be exactly one
```

**Manual cleanup (one-off):**

```bash
pactl list modules short \
  | awk '/module-remap-source.*source_name=mono_mic/{print $1}' \
  | xargs -r -I{} pactl unload-module {}
```

### Auth state persistence

Claude Code's auth state lives in two files that must survive container restarts:

| File | Contains |
|------|----------|
| `~/.claude.json` | OAuth account, user ID, feature flags, MCP registrations |
| `~/.claude/.credentials.json` | OAuth token (mode 600) |

These cannot be simple bind-mounts because Claude Code does atomic writes
(temp+rename) on them, which fail if the file itself is the bind-mount point.

**The staging pattern:**
- Host files `~/.claude-state.json` and `~/.claude-credentials.json` are mounted
  read-write into the container at `/tmp/`.
- `setup-claude-configs.sh` copies them to their live locations on startup.
- An EXIT trap in the launch command copies them back to `/tmp/` on every container
  exit, so the host staging files are always up to date for the next launch.

---

## Overview

`setup-claude-configs.sh` is the single setup script for Claude Code. It runs in
two modes:

- **`--host-mode`** — fresh-machine bootstrap. Called by `post-install-setup.sh`
  after Dropbox has confirmed syncing. Requires `~/config` to already exist as a
  symlink before it runs.
- **Default (no flag)** — container startup. Called by the Docker `CMD` after
  `/devenv` is bind-mounted.

> ⚠️ **After running in host mode**, the `claude` command won't be available in
> the current shell. Run `source ~/.bashrc` or open a new terminal before using it.

---

## What `setup-claude-configs.sh` does

### Shared (both modes)

| Step | Detail |
|------|--------|
| Install config files | `settings.json`, `session-start.sh`, `generate-preamble.js` → `~/.claude/` |
| Plugin statusLine wiring | `wire-hud-statusline.sh` injects `statusLine` if `claude-hud` is present (runs in both modes, and from the git hook) |

**Install method differs by mode:**
- **Host:** hardlinks — Claude Code ignores symlinked config files, and hardlinks
  mean edits via `/config` or the settings UI reflect back to the versioned source
  instantly with no sync step. Hardlinks are repaired automatically after every
  `git pull` / `checkout` / `rebase` by a git hook (see §Host config sync below).
- **Container:** `cp` only — `/devenv` is a bind mount (host filesystem) and
  `~/.claude` is on the container rootfs. That is a cross-filesystem boundary;
  `ln` fails with `EXDEV`. `cp` is not a style choice here; it is the only option.

**`CLAUDE.md` and `LLM-directives.txt` are handled differently** — see the
table below. They are not copied or hardlinked in either mode; instead they are
bind-mounted directly from the source (container) or left for the git hook (host).

### Host mode only (`--host-mode`)

1. **Prereq check** — `~/config` must exist (Dropbox must be synced)
2. **Backup** — existing Claude config files copied to a timestamped dir under `/tmp/`
3. **npm global prefix + PATH** — adds `prefix=$HOME/.npm-global` to `~/.npmrc` and
   `~/.npm-global/bin` to `PATH` in `~/.bashrc` (NixOS workaround for read-only global prefix)
4. **Install Claude Code** — `npm install -g @anthropic-ai/claude-code` (skipped if already present)
5. **Memory → Dropbox** — handled generically by `session-start.sh` on every host-mode
   session (see below), not a one-time step here; kept as a reminder that step 4
   only makes the `claude` command available, not memory portability

### Container mode only (default)

1. **Prereq check** — `/devenv` must be mounted
2. **Git config** — sets `excludesfile = /devenv/.gitignore` (points directly at
   the bind-mounted source; no copy to `/workspace` needed)
3. **Auth state restore** — copies `/tmp/claude-state.json` → `~/.claude.json` and
   `/tmp/claude-creds.json` → `~/.claude/.credentials.json` (if non-empty); sets
   mode 600 on credentials
4. **claude-code self-update** — `npm install -g @anthropic-ai/claude-code`,
   capped at 1x/day via a date stamp in `~/.claude-code-update-marker`
   (bind-mounted from the host so it persists across container starts); keeps
   long-lived images from drifting from the host's version without paying
   npm's registry round-trip on every single start
5. **ref.tools MCP** — registers the `ref` HTTP MCP server in `~/.claude.json` via
   `jq`, retiring `context7`; the API key is injected from `$REF_API_KEY` at
   runtime — no secret written to disk or git

---

## `CLAUDE.md`, `LLM/`, and `rules/` — live sync, not copies

These need to be readable by Claude Code in both modes, but they are **never
copied or hardlinked** — doing so would mean edits land in a dead copy rather
than the versioned source.

| Mode | Mechanism |
|------|-----------|
| **Container** | Bind-mounted (read-write for `CLAUDE.md`/`LLM/`, read-only for `rules/`) directly from the source in `launch-claude-in-docker.sh`. Changes in either direction — host edits the source, or Claude edits via `~/.claude/` — go to the same inode. No restart needed. |
| **Host** | Hardlinked by `setup-claude-configs.sh --host-mode` on first run. A git hook (`devenv/claude/git-hooks/sync-claude-configs`) re-establishes the hardlinks after every `git pull`, `checkout`, or `rebase`, because git replaces files via inode-swap (not in-place write), which silently orphans hardlinks. See DECISIONS.md §11 for the full explanation. |

### Container bind mounts (in `launch-claude-in-docker.sh`)

```
/etc/nixos/devenv/claude/claude-config-files/CLAUDE.md
    → /home/node/.claude/CLAUDE.md

/etc/nixos/devenv/claude/claude-config-files/LLM
    → /home/node/.claude/LLM

/etc/nixos/devenv/claude/claude-config-files/rules
    → /home/node/.claude/rules  (:ro)
```

---

## Host config sync — git hook

`devenv/claude/git-hooks/sync-claude-configs` is a shell script that re-runs
`ln -f` for each config file. It is installed as a symlink under three hook
names by `setup-claude-configs.sh --host-mode`:

```
.git/hooks/post-merge     → devenv/claude/git-hooks/sync-claude-configs
.git/hooks/post-checkout  → devenv/claude/git-hooks/sync-claude-configs
.git/hooks/post-rewrite   → devenv/claude/git-hooks/sync-claude-configs
```

If you set up a new machine and run `--host-mode`, the hooks are installed
automatically. If the hook is ever missing (e.g. after a fresh clone), re-run
`--host-mode` to restore it.

---

## Config files (`claude-config-files/`)

| File                   | Purpose |
|------------------------|---------|
| `CLAUDE.md`            | States that role/directive resolution happens *only* in the `SessionStart` hook, and that Claude must consume its injected output verbatim rather than re-deriving the role itself. No fallback logic — see DECISIONS.md §12. |
| `settings.json`        | Voice input (hold mode), one `allow` permission (`Read`), nine `deny` patterns for destructive commands, a `PreToolUse` hook that double-checks for destructive patterns, and the `SessionStart` hook. |
| `session-start.sh`     | Runs on every session start: resolves the active role (`$CLAUDE_ROLE` env var → nearest `CLAUDE.md` declaring `ACTIVE ROLE:`, walking from cwd toward the git root → default `DEV`); in host mode (detected by the absence of `/devenv`), symlinks the current project's memory dir into the shared Dropbox pool if not already linked (see DECISIONS.md §16); then invokes `generate-preamble.js`. |
| `generate-preamble.js` | Resolves the role's `EXTENDS` chain across `LLM/COMMON/directives.md` + `LLM/roles/*.md`, and emits a mandatory preamble table that Claude must output verbatim as its first response. Exits 2 with a stderr diagnostic (not a silent fallback) on any missing file, missing `EXTENDS`, cycle, or empty result. |
| `LLM/COMMON/directives.md` | Directives that apply to every role, regardless of `EXTENDS` chain. |
| `LLM/roles/*.md`       | One file per role (`DEV`, `JS`, `BLOG-AUTHOR`, `WIKI-AUTHOR`), each declaring `EXTENDS: <parent>` and its own `##`-sectioned directives. |

---

## Session start flow

```
Claude Code launches
       │
       ▼
SessionStart hook (settings.json)
       │
       ▼
session-start.sh
  ├─ resolve role: $CLAUDE_ROLE env var → nearest CLAUDE.md walking to git root → default DEV
  └─ run generate-preamble.js
             │
             ├─ success: resolve EXTENDS chain (COMMON → ... → role), build directive
             │   table, inject as additionalContext (exit 0)
             │
             └─ failure: missing file / missing EXTENDS / cycle / empty chain →
                 stderr diagnostic, exit 2 — no stdout, no fallback table
                             │
                             ▼
       Claude's first response: role declaration + directives table verbatim,
       OR (on failure) a plain statement that the hook failed, quoting the error
```

**Testing this hook** (isolated fixtures, safe fixture pattern in an isolated
`$HOME`, plus live tests against the real config): see DECISIONS.md §12.

---

## Adding plugins

The launch script bind-mounts `~/.claude/plugins` from the host into the container,
so plugin files survive across sessions automatically. Most plugins (slash commands,
tool providers) need no further wiring — just install them once.

### One-time host setup (already done)

```bash
mkdir -p ~/.claude/plugins
```

### Installing any plugin

Launch a container session and run:

```
/plugin marketplace add <owner>/<repo>
/plugin install <plugin-name>
/reload-plugins
```

The plugin files are written into the bind-mounted directory and are present on
every subsequent launch. In Docker, `/tmp` is on the same overlay filesystem as
the home directory so no EXDEV error occurs. If you install plugins on the NixOS
host instead, run `mkdir -p ~/.cache/tmp && TMPDIR=~/.cache/tmp claude` first —
NixOS mounts `/tmp` as tmpfs which triggers the error.

### When extra wiring is needed

Most plugins need nothing beyond the above. The exceptions are plugins that write
additional keys into `settings.json`:

| Plugin type | Extra step |
|---|---|
| Slash-command / tool plugins | None — bind-mount is sufficient |
| `statusLine` plugins | Add a detection block, call it from every path that can touch `settings.json` (see below) |
| MCP-registering plugins | Add a `jq` step to `~/.claude.json`, same pattern as the ref.tools block |

**Why `settings.json` needs help:** on every container start, and on every
host-mode `--host-mode` run or git hook re-link, `settings.json` gets
replaced with the plain versioned copy. Any key a plugin writes there (e.g.
`statusLine`) gets wiped every time. The fix is to re-inject it after each of
those paths, not just one of them.

### Example: `statusLine` plugin (claude-hud)

After installing and running `/claude-hud:setup` once, the HUD is wired
automatically — in both modes, and after every git pull/checkout/rebase on the
host — by `wire-hud-statusline.sh`, called from two places:
- `setup-claude-configs.sh`, right after `settings.json` is installed (shared,
  not gated on `HOST_MODE`)
- `git-hooks/sync-claude-configs`, right after it re-hardlinks `settings.json`
  on the host (a plain `git pull` doesn't invoke the full setup script)

```bash
HUDDIST="$(find "$HOME/.claude/plugins/cache" -path "*/claude-hud/*/dist/index.js" -not -path "*/node_modules/*" 2>/dev/null | sort -V | tail -1)"
if [ -n "$HUDDIST" ]; then
  NODE_BIN="$(command -v node)"
  # writes $HOME/.claude/hud-wrapper.js, a CJS wrapper that remaps cwd from
  # /workspace to /tmp/$WORKSPACE_NAME so claude-hud shows the real project
  # name (container-only; a no-op on the host where cwd is already correct)
  jq --arg cmd "$NODE_BIN $HOME/.claude/hud-wrapper.js" \
    '.statusLine = {"type": "command", "command": $cmd}' \
    "$HOME/.claude/settings.json" > "$tmp" \
    && mv "$tmp" "$HOME/.claude/settings.json"
fi
```

To swap in a different `statusLine` plugin, update the path in
`wire-hud-statusline.sh`. To configure the HUD display, run
`/claude-hud:configure` in any session — it writes to the bind-mounted
`config.json` and the change persists.
