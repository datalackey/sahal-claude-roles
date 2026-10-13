# Claude role framework: team-generic review

Review scope: the existing `devenv/claude` implementation in this checkout of the
nixos-config-derived framework. This checkout's origin is
`datalackey/sahal-claude-roles`; no separate upstream checkout was reviewed.
This is an assessment only; runtime configuration and role directives are unchanged.

## Chris-specific assumptions

| Finding | Evidence | Team implication |
|---|---|---|
| Every user has Chris's experience, mathematics background, NixOS/Linux environment, Node.js focus, and GAS/lights-out goal. | [Global profile](../claude-config-files/CLAUDE.md), `Who I am` | Personal profile must be optional; team policy cannot claim this identity for everyone. |
| Chris's learning goal applies to all developers. | [DEV](../claude-config-files/LLM/roles/DEV.md), `Claude Architect exam` | Exam coaching belongs in personal preferences. |
| Personal workflow and presentation preferences are universal. | [COMMON](../claude-config-files/LLM/COMMON/directives.md): approval before every edit, Node.js scripts, math explanations, two/three-attempt stop rule; [DEV](../claude-config-files/LLM/roles/DEV.md): size thresholds and lights-out prompts | Treat these as policy candidates requiring team agreement, rather than established team requirements. |
| Every host keeps the source repository at `/etc/nixos`. | [Session hook](../claude-config-files/session-start.sh), [launcher](../launch-claude-in-docker.sh) | Setup discovers its own location, but session repair, mounts, and status checks still assume this fixed path. |
| Everyone has Dropbox and Chris's directory layout. | [Setup](../setup-claude-configs.sh): `~/config` prerequisite; [hook](../claude-config-files/session-start.sh) and [launcher](../launch-claude-in-docker.sh): `$HOME/Dropbox/projects/devEnv/config/LLM/claude-memory` | Storage location and sync provider must be configurable; role selection should not require Dropbox. |
| All projects can share one memory pool. | [DECISIONS §16](../DECISIONS.md), explicitly justified by Chris's low project concurrency | Define per-user/per-project isolation and opt-in sharing. Current pool is cross-project for each configured user; it is not inherently a team-wide pool. |
| The status line runs from Chris's home and NixOS's Node path. | [Settings](../claude-config-files/settings.json): `/run/current-system/sw/bin/node /home/chris/.claude/hud-wrapper.js` | Resolve runtime paths locally. HUD wiring replaces this only when plugin discovery succeeds. |
| Host UID is 1000 and PulseAudio is available with the expected microphone layout. | [Launcher](../launch-claude-in-docker.sh), [Dockerfile](../Dockerfile), [setup](../setup-claude-configs.sh) | UID mapping and voice support need explicit environment requirements or optional configuration. `/home/node` itself is a container convention, not Chris's identity. |
| Every user has ref.tools access, uses GitHub, and needs Chris's publishing destination. | [DEV](../claude-config-files/LLM/roles/DEV.md), [launcher](../launch-claude-in-docker.sh), [allowlist](../allowed-sites.conf): `datalackey.github.io` | Document supported tools and credential provisioning; publishing domains and GitHub issue syntax are project-specific. The launcher currently requires `REF_API_KEY`. |
| Personal blog voice, handbook examples, and detailed writing preferences apply uniformly. | [BLOG-AUTHOR](../claude-config-files/LLM/roles/BLOG-AUTHOR.md), [WIKI-AUTHOR](../claude-config-files/LLM/roles/WIKI-AUTHOR.md), [WRITER](../claude-config-files/LLM/roles/WRITER.md) | Keep reusable role purposes, with agreed team editorial rules and optional personal voice. |
| One person's risk tolerance and tooling defaults apply to the team. | [Settings](../claude-config-files/settings.json): Sonnet, voice, skipped dangerous-mode prompt; [launcher](../launch-claude-in-docker.sh): `--dangerously-skip-permissions`, disabled connectors, resource limits | Team approval, sandbox, model, and integration policies must be explicit. Existing destructive-command guards do not establish team authorization. |

## Team-generic requirements identified

These are requirements inferred from the ticket and implementation, not evidence
that the team has already approved a particular policy.

- A shared role catalog and common directives, with personal identity and preferences
  kept distinct from team and project requirements.
- Deterministic role selection and inheritance, with documented precedence and a
  clear decision on whether `DEV` remains the default.
- One authoritative resolver, visible configuration failures, and equivalent behavior
  on supported host/container installations.
- Configurable source/storage/runtime paths and documented prerequisites: Bash,
  Node.js, Git, and the GNU tools currently used by the hook; Docker, jq, and
  additional integrations where relevant.
- Explicit memory ownership, project isolation, sync policy, and collision handling.
- Reliable configuration installation and synchronization, with a stated conflict
  policy before local settings can propagate into versioned team configuration.
- Agreed commit, formatting, documentation, approval, dependency lookup, and editorial
  policies; optional features should have defined behavior when absent.
- A decision on whether the mandatory visible first-response table is team policy,
  plus verification that summaries retain the directives the team intends to enforce.

## Current inheritance behavior

[Role files](../claude-config-files/LLM/roles/DEV.md) and
[generator](../claude-config-files/generate-preamble.js) are authoritative:

```text
COMMON → DEV → JS
COMMON → WRITER → BLOG-AUTHOR
COMMON → WRITER → WIKI-AUTHOR
```

The generator follows one `EXTENDS` parent per role from leaf toward `COMMON`,
then emits sections root first, leaf last. `COMMON` is a special terminal file at
`LLM/COMMON/directives.md`; other names resolve to `LLM/roles/<NAME>.md` under
`~/.claude`. Names are case-sensitive; there is no multiple inheritance.

`ACTIVE ROLE: JS extends DEV` selects only `JS`. The shell extracts the first
non-whitespace token after `ACTIVE ROLE:`; the rest of that declaration is ignored.
The generator uses `JS.md`'s actual parent, so a mismatched project parent is not
validated. It appends rows without overriding or deduplicating matching headings;
root-first ordering is not a programmatic conflict-resolution mechanism.

Only `##` sections with nonempty summaries reach the table. Summaries use the first
bold span anywhere in the section, otherwise normalized body text, truncated to
160 characters. Full directive bodies, introductory text, and secondary rules may
therefore never reach the assistant. `JS` currently adds no sections: its role is
selected, but its table has only COMMON and DEV rows.

Missing COMMON/role files, missing `EXTENDS`, cycles, a 20-role hop limit, an empty
`HOOK_ROLE`, and no nonempty sections across the entire chain are explicit errors
with exit 2 and `CLAUDE ROLE CONFIG ERROR` on stderr. Individual empty roles are
allowed if other chain members supply rows. Unexpected filesystem errors are not
wrapped by this diagnostic handler.

## Current SessionStart behavior

[Settings](../claude-config-files/settings.json) register an unfiltered command
hook: `bash "$HOME/.claude/session-start.sh"`. It has no event-source matcher;
it is not limited by this configuration to initial startup only.

Execution order in [session-start.sh](../claude-config-files/session-start.sh):

1. Append a timestamp to `/tmp/claude-hook.log`.
2. Resolve and export `HOOK_ROLE`: nonempty `CLAUDE_ROLE`, then the nearest ancestor
   `CLAUDE.md` with `ACTIVE ROLE:`, then `DEV`. Search begins at `$PWD`, includes
   the Git root, and stops there; outside Git it continues to `/`. The hook does
   not parse incoming hook JSON for a working directory.
3. If `/devenv` is absent, treat this as host mode. Create the Dropbox pool and
   symlink the cwd-derived project memory directory into it. Existing memory is
   copied with `cp -n` (pool files win collisions), then moved to a timestamped
   backup. The wildcard copy excludes dotfiles and does not recursively copy
   directories. Any existing symlink is accepted without checking its target.
4. In host mode, reconcile existing source config files from the fixed `/etc/nixos`
   path with `~/.claude`. If inode numbers differ, newer whole-second mtime wins;
   ties favor the repository. A newer local file can replace the repository file
   through hardlinking. New files present only under `~/.claude` are not discovered.
5. Read `/tmp/devenv-status.txt` if present, otherwise inspect `/etc/nixos/devenv`.
6. Run the generator from `~/.claude` and return its exit code.

Success emits JSON with `hookSpecificOutput.hookEventName = SessionStart` and
`additionalContext` instructing the assistant to begin its first response with
an exact role/directive table. Optional dirty-devenv information goes into the
separate top-level `systemMessage`. The global CLAUDE.md prohibits assistant-side
resolution or fallback; on missing/invalid output it asks for a visible failure
statement and a role-unscoped session. The generator requests this behavior;
actual CLI delivery and assistant compliance were not tested in this review.

The shell has no `set -e`: failures during memory migration or hardlink repair do
not necessarily stop subsequent generation. Successful preamble generation is
therefore not proof that those side effects succeeded.

## Installation and container implications

[Host setup](../setup-claude-configs.sh) hardlinks configuration into `~/.claude`
and installs post-merge, post-checkout, and post-rewrite
[sync hooks](../git-hooks/sync-claude-configs). Git hooks relink from the repository;
SessionStart repair instead uses bidirectional mtime reconciliation. Atomic rename
writes can break hardlinks, and hardlinking requires the same filesystem. Repair
compares inode numbers without device IDs and does not remove obsolete destination
files. These limitations matter when team members use different layouts.

Container setup copies settings and helper scripts; the launcher bind-mounts
CLAUDE.md and LLM read-write, rules read-only, and `/devenv` read-only. Thus the
assistant can edit versioned directives through the separate writable mounts.
The launcher mounts the Git root as `/workspace`, losing the supplied subdirectory
as startup cwd; nested role selection differs from a host session started there.
Every container project uses the same `-workspace/memory` mount.

[HUD wiring](../wire-hud-statusline.sh) uses temp-file-plus-rename on settings,
which can itself break a host hardlink; later SessionStart repair may propagate
those machine-specific settings back into the repository.

## Documentation discrepancies to retain in the handoff

- [Original design notes](notes-role-system-design.md) still say nothing is implemented,
  describe project-declared parents, and omit the current WRITER inheritance layer.
- [README](../README.md) contains conflicting statements about host hardlinks and
  omits WRITER from its role inventory.
- Setup and sync-hook comments claim versioned settings have no statusLine, but the
  tracked file contains Chris's command.
- README describes auth files as staged regular files, while the launcher also
  bind-mounts `~/.claude.json` directly. This conflicts with its atomic-write rationale.
- Historical hook-error visibility in [DECISIONS §12](../DECISIONS.md) depended on
  CLI version; §20 records uncertainty about live `systemMessage` display. Neither
  behavior should be assumed verified for every current client.

## Verification and acceptance criteria

Isolated temporary-HOME generator checks succeeded for DEV, JS, WRITER,
BLOG-AUTHOR, WIKI-AUTHOR, and COMMON. Missing role, unset role, cycle, and missing
parent fixtures produced exit 2 with the expected diagnostic. Extracted shell
resolver checks confirmed environment override, nearest declaration, Git-root
lookup, default DEV, and ignoring a mismatched declared parent.

The full SessionStart script, setup, Docker launcher, and live Claude client were
not executed: those paths mutate memory/configuration or start external services.
Their behavior above was established by source inspection and compared with the
recorded decisions. No framework behavior changes are proposed by this review.

- Chris-specific assumptions: listed with evidence and team implications.
- Team-generic requirements: identified, with policy decisions marked as unconfirmed.
- Inheritance and SessionStart behavior: traced and resolver behavior checked before
  any implementation changes.
