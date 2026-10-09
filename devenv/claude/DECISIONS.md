# Sandboxed Claude — Design Decisions & Build Log

A decision record for how this directory's Docker sandbox is secured for
**lights-out** (unattended) Claude Code runs. Captures the *why* behind the
config, not just the *what* — intended to seed both `README.md` and a future
write-up.

_Last updated: 2026-07-14_

---

## 1. The goal: lights-out operation

The container runs `claude --dangerously-skip-permissions` so Claude is never
interrupted for approval mid-task. That is the whole point — frictionless,
unattended execution.

The consequence: **if you remove the approval prompt, prompts can no longer be
your safety mechanism.** Something else has to be the boundary. The entire
security design below follows from that single fact.

---

## 2. Threat model — what actually matters *here*

Generic hardening guides defend against everything equally. We instead asked:
what is *irrecoverable* for this specific user (open-source developer)?

| Risk | Verdict | Reason |
|------|---------|--------|
| Source code theft | **Don't care** | Everything is open source |
| `rm -rf` of the working copy | **Recoverable** | Re-clone from the remote |
| `git reset --hard` / `git clean` | **Recoverable** | Lost work is uncommitted only |
| `git push --force` to a remote | **Recoverable** | Reflog + other clones |
| **Mass deletion of GitHub remotes** | **The one real catastrophe** | The remote is the source of truth |

So the only thing worth engineering against is **destruction of the remotes
themselves.**

---

## 3. The catastrophe is already structurally impossible

Repo deletion is not a shell command — it is a REST API call requiring a
privileged credential. We audited every path that credential could take into
the container:

- **Container mounts** include `/workspace`, `~/.claude.json`, `/devenv`,
  `~/.config/gh:ro`, `~/.claude/plugins`, PulseAudio socket, and auth
  staging files (`~/.claude-state.json`, `~/.claude-credentials.json` → `/tmp/`)
  — but critically **no `~/.ssh`**, no PAT with admin scopes.
- **`GH_TOKEN` env var** — extracted from the host keyring via `gh auth token`
  at launch time and injected as `-e GH_TOKEN`. Scopes are `gist, read:org,
  repo` — **no `delete_repo`**. This enables `gh` CLI operations inside the
  container while preserving the catastrophe boundary: `repo` scope cannot
  delete repositories.
- **Host `gh` token** scopes are `gist, read:org, repo` — **lacks
  `delete_repo`**. The `repo` scope does not include deletion.
- **Git auth is SSH** (`git@github.com:…`). **SSH keys cannot delete repos** —
  deletion is an API administration operation, not a git-transport one.

Blocked three independent ways. No command denylist is needed for the one risk
that matters.

**Guardrails to preserve this (disciplines, not config):**
1. Keep `delete_repo` off the `gh` token — that is what closes the one
   dangerous path, not whether a token is present at all.
2. If push-from-container is ever needed, use an **SSH/deploy key** (still
   cannot delete) — never a PAT with `delete_repo` or Administration:write.
3. Never escalate the injected token's scopes beyond `gist, read:org, repo`.

---

## 4. Test, don't trust — the empirical gates

Before depending on any layer, we verified two assumptions instead of trusting
the docs.

**Gate 1 — Do `permissions.deny` rules and PreToolUse hooks still fire under
`--dangerously-skip-permissions`?**
✅ **Yes.** `bypassPermissions` mode skips *prompts*, not deny rules. Per the
official docs, deny rules take precedence in all modes, and PreToolUse hooks
fire in every mode (a hook exiting code 2 blocks before permission rules are
evaluated). So a denylist + hook are effective even in lights-out mode.

**Gate 2 — Can the OS sandbox (bubblewrap, Layer 3) run inside the container?**
❌ **No.** Tested in the actual image: `bwrap` is absent and unprivileged
namespace creation fails (`unshare: Operation not permitted`). The OS sandbox
cannot run nested without loosening Docker isolation — which would defeat the
purpose. **The container itself is the OS boundary; Layer 3 is redundant here.**

---

## 5. Why we did NOT adopt an off-the-shelf hardening project

We evaluated three sources of "security rules":

| Source | Ships a destructive-command denylist? | Approach | Maintenance |
|--------|:---:|----------|-------------|
| Anthropic `examples/settings` | ❌ No | Sandbox + approval | Canonical |
| Trail of Bits `claude-code-devcontainer` | ❌ No | Container isolation, run unrestricted inside | Active (reputable) |
| `psnluiz/secure-claude-code` | ✅ Yes | Denylist + regex hook | 1 commit, 0★, stale |

The decisive signal: **both reputable, maintained projects deliberately refuse
command denylists.** Pattern-matching is bypassable (the docs call it "fragile";
Ona research shows Claude routing around denylists via `/proc/self/root/`, the
ELF linker, etc.). They enforce at the isolation/sandbox boundary instead.

Trail of Bits' philosophy is, in fact, *exactly this setup*: "running Claude
with `bypassPermissions` safely enabled" via filesystem isolation. We had
already built a ToB-equivalent.

---

## 6. What we actually shipped (and why it's thin)

A deliberately small safety net, because the real protection (isolation +
credential hygiene) was already in place:

- **9 deny rules + one PreToolUse hook**, lifted *once* from secure-claude-code
  and **owned in-tree** (`claude-config-files/settings.json`) — not tracked as a
  live dependency. These patterns (`rm -rf`, `git push --force`, `dd`, `mkfs`,
  SQL `DROP`/`TRUNCATE`) never evolve, so "the repo is unmaintained" is moot.
- **`jq` added to the Dockerfile** — the hook is `jq … | grep …`; without `jq`
  the pipeline fails open and the hook silently allows everything. Installing
  `jq` is load-bearing, not cosmetic.

**Honest scope of this net:** it stops *accidental / hallucinated* destructive
commands against the mounted workspace. It is **not** a boundary against an
adversarial or prompt-injected agent — that is the container's job. It is polish
on top of a sound boundary, which is why it is so small.

---

## 7. Outstanding / parked

**Phase 2 — Tier 1 (container hardening flags): ✅ done (2026-06-21).**
`launch-claude-in-docker.sh` now runs with `/devenv:ro`, `--cap-drop=ALL`,
`--security-opt=no-new-privileges`, `--pids-limit=512`, and `--cpus=2`.
Verified: the startup script, the node/jq runtime, and the guardrails all work
under these flags, and `/devenv` is enforced read-only.

**Phase 2 — Tier 2 (network egress allowlist): ✅ implemented & egress-tested
(2026-06-22).** See §8. Verified: allowed domains (Anthropic API, ref.tools,
GitHub) connect; non-allowlisted domains (example.com, google.com) are blocked
at DNS resolution (curl exit 6).

**ref.tools MCP — ✅ verified end-to-end (2026-06-22).** context7 retired; `ref`
registered as an HTTP MCP server in `~/.claude.json` with the key injected from
`$REF_API_KEY` at runtime (placeholder only on disk; expansion confirmed
working). `/mcp` shows `ref` connected and `search_docs` returns live docs.

~~Repo moved: remote updated `buildlackey` → `datalackey`~~ ✅ done (2026-06-21).

---

## 8. Network egress — sidecar vs Docker Compose

Tier 2 restricts outbound traffic to an allowlist of domains, so a
prompt-injected agent cannot exfiltrate data even though it has working
internet for the Anthropic API.

**Chosen: a network-filter sidecar** (`monadicalsas/network-filter`), which
runs `dnsmasq` + `ipset` + `iptables`. dnsmasq resolves *only* allowlisted
domains and adds each resolved IP to an ipset at query time; iptables drops
everything else. The Claude container shares the filter's network namespace and
inherits the restrictions. Only the filter needs `NET_ADMIN`; the Claude
container keeps `--cap-drop=ALL`.

IPs are resolved dynamically at request time, **not baked in** — so CDN/IP
rotation is self-healing and there is nothing to update manually. (The common
worry that domain allowlists freeze IPs at startup describes the *static*
approach, not this one.)

**Wiring: single-script**, to match the rest of this setup. The launch script
starts the filter container, then runs Claude with
`--network=container:<filter>`. No extra tooling required.

**Considered and rejected: Docker Compose** (`network_mode: "service:network-filter"`).
Compose is the more declarative way to manage the two-container pair and would
be the natural choice if this grew to more services (e.g. a local stdio MCP
server — the very question that started this project). We rejected it **for
simplicity** — the single launch script already does the job and keeps
everything in one place. **Compose remains a clean future option** if the
container topology grows.

**ref.tools key handling.** The key is supplied via `$REF_API_KEY` (host env →
`-e` into the Claude container) and referenced as `apiKey=${REF_API_KEY:-}` in
the registration, so only a placeholder lands in `~/.claude.json` — no secret on
disk or in git. Claude Code documents `${VAR}` expansion for `.mcp.json`; if it
turns out not to expand in `~/.claude.json`, the one-line fallback is literal
substitution of the key at container startup (accepting that it then persists in
the host `~/.claude.json`).

Caveats accepted (all low-impact for this threat model): IPv4-only; domain- not
path-granular; a shared CDN IP serves any domain hosted on it; and the app must
resolve through dnsmasq (Claude/Node does, via the system resolver).

---

## 8a. Implementation gotchas (resolved 2026-06-22)

Bringing Tier 2 + ref.tools up surfaced several environment-specific snags, all
now fixed — and all worth remembering for the write-up:

- **`platform.claude.com` must be allowlisted.** Claude Code v2.1.185 connects
  there on startup; omitting it gives a misleading `ECONNREFUSED` that looks
  like a country geo-block but is actually the egress filter.
- **Container uid must match the host uid.** `~/.claude.json` is mode 600, so
  the container user must *be* uid 1000 to read/write it. The base `node` image
  already runs as `node` at uid 1000, which matches a typical single-user NixOS
  host — no second user is needed. **Updated 2026-06-24:** the `dev` user and the
  `DEV_UID`/`DEV_GID` build args were removed; the container now runs as `node`
  throughout, eliminating the `$HOME` split between `/home/dev` and `/home/node`.
- **`~/.claude.json` is a single-file bind mount** — rewrite it in place
  (`cat >`), never `mv` (the mount point is busy and rename fails).
- **MCP registration lives in `setup-claude-configs.sh` (via jq)** — the image
  has no python3, and MCP must be registered before Claude starts. The
  role-preamble system was also broken: the SessionStart hook was never in the
  versioned `settings.json` (only *documented* in the README; it lived in the
  hand-configured host `~/.claude/settings.json` and was lost when setup switched
  to hardlinking the versioned file), and `generate-preamble` was python — absent
  from the image, so it could never have run in Docker. **Fixed 2026-06-22:** hook
  now wired in `settings.json`, and the preamble ported python→Node
  (`generate-preamble.js`, byte-identical output) so it fires on host *and*
  in-container with no python dependency.
- **`ENABLE_CLAUDEAI_MCP_SERVERS=false`** drops the unused claude.ai connectors
  (Gmail/Calendar/Drive).
- **`${REF_API_KEY}` expansion works in `~/.claude.json`** (confirmed
  end-to-end), so the key stays env-only — no on-disk substitution fallback
  needed.

---

## 9. git push from inside the container

**Current state: not supported via SSH.** `openssh-client` is not installed and
`~/.ssh` is not mounted. Claude can read/write the workspace and commit, but
`git push` (SSH transport) will fail inside the container.

**Why this is acceptable:** The threat model (§2) already rates `git push --force`
as *recoverable* — reflog + other clones. And the `GH_TOKEN` injected at runtime
(scoped to `gist, read:org, repo`) covers the `gh` CLI operations Claude actually
needs (`gh pr create`, `gh issue`, etc.). Pushing to a remote is the one step best
left to the human on the host.

**To enable SSH push if ever needed — two options:**

1. **Install `openssh-client` + mount `~/.ssh:ro`** — native SSH, zero config
   change to remotes. Trade-off: the container gains access to all keys in `~/.ssh`,
   not just the GitHub deploy key. Still cannot delete repos (deletion is an API
   call), and force-push is already denied by the settings denylist. Low risk but
   a wider key footprint than necessary.

2. **Use a deploy key** — generate a key scoped to a single repo (or org), mount
   only that key. Narrowest footprint; extra setup per repo.

**Guardrail to preserve if SSH is ever enabled (§3, discipline 2):** use an SSH
or deploy key — never a PAT with `delete_repo` or `Administration:write`.

---

## 11. Host config sync — why hardlinks break and how the git hook fixes it

### The problem

On the host machine, `setup-claude-configs.sh --host-mode` links config files
from the versioned source (`devenv/claude/claude-config-files/`) into
`~/.claude/` using **hardlinks** (`ln`, not `ln -s`). Hardlinks are required
because Claude Code ignores symlinked config files.

A hardlink is not a copy and not a pointer to a path — it is a second directory
entry pointing at the same **inode** (the on-disk data block). As long as both
entries point at the same inode, editing either one immediately updates the
other, with no sync step.

The problem is how **git updates files**. Git never modifies a tracked file in
place. Instead, it writes the new content to a temporary file, then atomically
renames that file over the original (`rename(2)`). The rename gives the new
content a **new inode**. The old inode — and anything pointing at it, including
your hardlink in `~/.claude/` — is left behind with stale content.

Concretely: after a `git pull` that updates `LLM-directives.txt`, the
versioned source has a new inode with new content. The hardlink at
`~/.claude/LLM/LLM-directives.txt` still points at the old inode. The host
Claude Code reads stale directives until `--host-mode` is re-run manually.

### The fix: a post-operation git hook

Git fires hook scripts automatically after operations that update the working
tree:

| Hook | When it fires |
|------|---------------|
| `post-merge` | After `git pull` or `git merge` |
| `post-checkout` | After `git checkout` or `git switch` |
| `post-rewrite` | After `git rebase` or `git commit --amend` |

A single script (`devenv/claude/git-hooks/sync-claude-configs`) is symlinked
into `.git/hooks/` under all three names. It runs `ln -f` (force-replace) for
each config file — atomically replacing the destination with a new hardlink to
the current source inode. Because the hook fires immediately after git finishes,
`~/.claude/` is always in sync with HEAD — no manual step needed.

### Corner case: atomic-rename writes fail on bind-mounted files

A bind-mounted file is a mount point. You can write to it in place (open +
write), but you cannot `rename(2)` another file over it — the kernel returns
`EBUSY` because the mount point is busy.

If you ever see an EBUSY error when trying to update `CLAUDE.md` or a file
under `LLM/` from inside a container session, the tool used an atomic rename.
The fix is to use the source path instead:
`/workspace/devenv/claude/claude-config-files/<file>` — that path is a regular
file (not a mount point) and accepts any write pattern.

**Correction (2026-07-14):** this section previously claimed "the Claude Code
`Edit` and `Write` tools work correctly (they open the file and write content
in place)" as a general property of those tools. That's too broad, and was
disproven empirically while running the `EXTENDS`-cycle negative test in §12:
an `Edit` call on an ordinary **hardlinked** file (not a bind mount) still
broke the hardlink — `~/.claude/LLM/roles/DEV.md` ended up on a different
inode than the versioned source it was linked to. The likely correct model:
Edit/Write don't unconditionally avoid rename; they (or the underlying editor
libraries) most likely attempt the normal write pattern and only fall back to
an in-place write when a rename would actually fail (`EBUSY` on a real bind
mount). On a plain hardlink, rename succeeds, so the tool takes that path and
silently orphans the link — the same failure mode as git's checkout/merge
(§11 above), just via a different tool. **Practical consequence:** don't trust
hardlink survival after *any* edit — of a hardlinked file, by any tool —
without checking. `stat -c '%i %n' <path1> <path2>` before/after is cheap
insurance; §12 has a concrete case where skipping this check produced a false
test result.

---

**Why symlink the hook itself instead of hardlinking it?**
Git hooks live in `.git/hooks/`, which is not tracked. Git replaces only
tracked files on checkout/merge. The hook script itself (`sync-claude-configs`)
is versioned, but `.git/hooks/post-merge` etc. are symlinks managed by
`setup-claude-configs.sh --host-mode`. A symlink is correct here: it survives
git operations on the target (since the target's path doesn't change), and a
broken symlink is visibly broken (unlike a stale hardlink, which silently serves
old content).

---

## 10. The thesis (for the write-up)

As coding agents move to lights-out autonomy, the security boundary shifts from
**"ask permission"** to **"constrain capability."** Once you remove the human in
the loop, prompts are gone — so isolation and credential scoping, not
command-pattern blocklists, are what actually protect you. The interesting
engineering is figuring out *which* capabilities to remove, which requires a
real threat model rather than generic hardening.

---

## 12. SessionStart role hook: from silent fallback to fail-loud, and diagnosing host vs. docker drift (2026-07-14)

### The symptom

Host sessions showed no role/directive table at session start; docker sessions
showed a full, nicely-formatted table. The obvious read — "docker's hook works,
host's doesn't" — was wrong. Investigation showed **both were broken**, in
different ways that happened to look like success or failure.

### Root cause: an incomplete migration

An earlier migration (see `docs/notes-role-system-design.md`) replaced a flat
`LLM-directives.txt` (`## ROLE: X` sections) with the current
`LLM/COMMON/directives.md` + `LLM/roles/*.md` (`EXTENDS:` chain) layout, and
moved role-resolution instructions into `CLAUDE.md` for the assistant to follow
directly. Nobody updated the consumer: `generate-preamble.js` still parsed the
deleted `LLM-directives.txt`. Finding nothing, it silently fell through to a
one-line stub (`"Session started. Active role: DEV"`) instead of erroring.

Separately, `~/.claude/CLAUDE.md` on the host had been hand-edited at some
point to add a richer, assistant-side role-resolution protocol (env var →
directory walk-up → default) — almost certainly as an ad hoc workaround once
someone noticed the hook had gone quiet, without diagnosing *why*. That edit
was never carried back into the versioned `claude-config-files/CLAUDE.md`. The
docker table users saw was this workaround firing (the assistant self-resolving
and hand-building a table each session) — not the hook, which was equally
broken in both environments.

### Decision: the hook is the single source of truth; no assistant-side fallback

Two independent mechanisms computing "the role" is exactly how the drift above
happened. Rather than keep both (hook + assistant self-resolution as a
"defense in depth" fallback), we removed the duplicate entirely:

- **`generate-preamble.js`** rewritten to parse the actual `COMMON`/`roles`
  layout, resolving the `EXTENDS` chain (e.g. `JS → DEV → COMMON`) and
  rendering a `Directive | Source | Summary` table from each file's `##`
  sections.
- **`session-start.sh`** now implements the full priority chain in code —
  `$CLAUDE_ROLE` env var → nearest `CLAUDE.md` declaring `ACTIVE ROLE:`,
  walking from cwd toward the git root → default `DEV` — instead of leaving it
  only as documentation the assistant was supposed to re-implement itself
  every session.
- **`CLAUDE.md`** rewritten to tell the assistant to consume the hook's
  injected block verbatim and, if it's missing or reports an error, to *say
  so plainly and stop* — not to reconstruct the role or table by reading
  `LLM/**` itself. **Explicit user decision: no fallback code.** A hook that
  fails silently produces confidently wrong behavior (this whole incident); a
  hook that fails loud is diagnosable.
- **Fail-loud contract**: any missing file, missing `EXTENDS:` declaration,
  `EXTENDS` cycle, or a chain that resolves to zero directive sections now
  exits 2 with a `CLAUDE ROLE CONFIG ERROR: …` line on stderr and **no**
  stdout — consistent with Claude Code's documented hook exit-code contract
  (0 = success/stdout used, 2 = blocking error/stderr fed back to Claude,
  other = non-blocking error). Verified empirically (see below), not assumed
  from docs alone — consistent with this file's "test, don't trust" precedent
  in §4.

### Empirical gates

Before trusting the rewrite, each path was exercised directly rather than
inferred:

**Happy path** (against the real `~/.claude/LLM`, read-only): all four roles
(`DEV`, `JS`, `BLOG-AUTHOR`, `WIKI-AUTHOR`) resolve their correct `EXTENDS`
chain and produce the right row set; `$CLAUDE_ROLE` correctly overrides
directory-based discovery; walk-up correctly prefers the nearest `CLAUDE.md`
over a farther one toward the git root; no `CLAUDE.md` anywhere falls back to
`DEV` (not an error).

**Failure path** (fixtures in an isolated fake `$HOME`, so the real config was
never at risk): missing `COMMON/directives.md`, a role file that doesn't
exist, a role file with no `EXTENDS:` line, `EXTENDS` pointing at a
nonexistent parent, a real `EXTENDS` cycle, a chain with zero `##` sections
anywhere, and an unset `HOOK_ROLE` — all seven exit 2, all with zero stdout
bytes and a clear stderr diagnostic.

**Live test**: a real typo'd role (`ACTIVE ROLE: aDEV`) in two different
repos' `CLAUDE.md` correctly produced the `SessionStart:startup hook error`
banner in host mode, both under normal permissions and under
`--dangerously-skip-permissions` — ruling out bypass-permissions mode as a
factor in what came next.

### The docker/host discrepancy, take two

After the fix, the *same* live typo test still showed the loud error on host
but stayed silent in docker. Ruled out: stale `cp`'d scripts (docker's setup
output showed a fresh `cp` of the fixed files), and `CLAUDE.md`/`LLM`/`rules`
staleness (these are live bind mounts in docker, not copies — they cannot go
stale by construction).

Confirmed cause: **CLI version skew**. The docker image
(`claude-code-sandbox:latest`) was built 2026-06-28 and never rebuilt; its
`RUN npm install -g @anthropic-ai/claude-code` step baked in whatever was
current then (`2.1.190`). The host's globally-installed CLI had since updated
to `2.1.209`. The Dockerfile's writable npm prefix comment ("so auto-updates
succeed") implied the CLI's own self-updater was supposed to keep the image
current, but nothing was actually invoking it — and it may also be blocked by
the egress allowlist not covering whatever endpoint the self-updater needs
(the allowlist does cover `registry.npmjs.org` itself, which is what matters
for the fix below).

**Fix**: added an explicit `npm install -g @anthropic-ai/claude-code` step to
`setup-claude-configs.sh`'s container-only block, so every container launch —
even reusing a weeks-old image — re-syncs to the latest CLI before `claude`
starts. Verified in isolation (`docker run --rm claude-code-sandbox …`,
outside any live session): a clean `2.1.190` → `2.1.209` bump, matching host
exactly.

**Confirmed 2026-07-14:** a freshly-launched (post-fix) docker container —
`claude-code` self-updated `2.1.190 → 2.1.209` on startup, as designed — hit
the same `aDEV` typo and produced the identical `SessionStart:startup hook
error` / `CLAUDE ROLE CONFIG ERROR: Role file not found for 'aDEV'` banner as
host mode (container path `/home/node/.claude/LLM/roles/aDEV.md` vs. host's
`/home/chris/.claude/LLM/roles/aDEV.md` — same failure, same message shape).
Host and docker now behave identically for this case.

### The `EXTENDS`-cycle test, and a false negative along the way

The most targeted negative test available: a real cycle in the live role
hierarchy, not a synthetic fixture. `JS.md` already declares `EXTENDS: DEV`,
so flipping `DEV.md`'s `EXTENDS: COMMON` → `EXTENDS: JS` creates
`DEV → JS → DEV` using the actual files every session resolves against.

**First attempt produced a false negative.** The corruption was applied with
`sed -i` on the *repo* path
(`devenv/claude/claude-config-files/LLM/roles/DEV.md`). `sed -i` writes via
temp-file + rename — the exact hardlink-breaking pattern this file already
documents for git (§11) — so it silently orphaned
`~/.claude/LLM/roles/DEV.md` from the repo file mid-test. `generate-preamble.js`
reads via `os.homedir()`, i.e. the `~/.claude` path, which still held the
original, uncorrupted content. The hook reported `exit=0` — true, but it had
never seen the corrupted hierarchy at all. A subsequent `git checkout --` on
the repo path (intended as cleanup) restored the repo file's *content* but,
being itself a rename, did nothing to reunite the two paths — they were left
as two different inodes that merely happened to hold identical text.
**Lesson:** after any edit intended to reach a hardlinked config file, verify
with `stat -c '%i %n' <path1> <path2>` that the edit actually landed on the
inode the consumer reads — matching *content* between the two paths is not
sufficient evidence, since a broken-then-independently-restored hardlink shows
identical content while reading from different inodes.

**Second attempt, done correctly:** re-established the hardlink (`ln -f`
repo → `~/.claude`), edited `~/.claude/LLM/roles/DEV.md` directly with the
`Edit` tool (confirmed via `stat`/`grep` that the corruption actually landed
on the consumed path this time — and, per the §11 correction above, `Edit`
broke the hardlink too, which no longer matters here since the *repo* copy,
the restore source, was untouched throughout). Result:

```
exit=2  stdout_bytes=0
CLAUDE ROLE CONFIG ERROR: EXTENDS cycle detected: DEV → JS → DEV
```

Correct on both counts: it walked both hops of the real chain before
detecting the repeat, and produced zero stdout (no misleading fallback
alongside the error). Restored via `ln -f` back to the repo's inode (never
touched by either attempt); `git diff` on `DEV.md`/`JS.md` stayed empty
throughout, and the hook succeeds again post-restore.

### Outstanding / parked

- `build-tools/CLAUDE.md` still has `ACTIVE ROLE: aDEV` from testing and needs
  restoring to a real role.

---

## 13. Self-update caching, and closing the host-mode HUD gap (2026-07-14)

Two related fixes, both instances of the same failure class this file already
flagged: a mechanism that only runs in *one* of the two startup paths
(container script vs. host git hook) silently drifts from the other. This is
the same drift pattern §11 documents for hardlinks and that the git hook's
own comments forward-referenced as "§13" before this section existed.

### Self-update: correct but expensive on every start

§12 added an unconditional `npm install -g @anthropic-ai/claude-code` to the
container-only branch of `setup-claude-configs.sh` so long-lived images don't
drift from the host's CLI version. That fix was correct but ran on *every*
container start, paying npm's registry round-trip (a couple of seconds) even
when already current — noticeable purely as startup latency, not a
correctness bug.

**Fix:** capped at 1x/day via a date-stamp marker
(`~/.claude-code-update-marker`), bind-mounted from the host in
`launch-claude-in-docker.sh` so the cap survives container restarts (an
un-mounted marker would reset every launch, since only specific paths persist
into the container — see the mount list in that script). `touch -a` ensures
the marker exists on the host before Docker tries to bind-mount it; a
single-file bind mount to a nonexistent path creates a directory instead,
silently breaking the read/write.

### HUD statusLine: wired in one mode, forgotten in the other

`claude-hud`'s `statusLine` injection (§ "Example: `statusLine` plugin" in
`README.md`) lived entirely inside `setup-claude-configs.sh`'s
`HOST_MODE -eq 0` (container-only) branch. Host-mode sessions never got a
HUD — not a regression, just something that was only ever built for the
container path.

Moving the block into the shared section fixed the *first* run, but exposed
the deeper version of this file's recurring lesson: host mode's steady-state
sync isn't the full setup script, it's the lighter `git-hooks/sync-claude-configs`
hook (fires on `post-merge`/`post-checkout`/`post-rewrite`), which only
re-hardlinks `settings.json` from the versioned source — a copy with no
`statusLine` key. Any git pull, checkout, or rebase after the initial fix
would silently wipe the HUD again, with `setup-claude-configs.sh --host-mode`
as the only way back, and no signal that anything had broken.

**Fix:** extracted the wiring into a standalone, idempotent
`wire-hud-statusline.sh` and call it from **both** places that can touch
`settings.json` on the host: the shared block in `setup-claude-configs.sh`,
and immediately after the relink step in `git-hooks/sync-claude-configs`.
Same principle as §11's fix for stale hardlinks — the hook needs to actively
redo whatever the full setup script does to that file, not just the parts it
was written to know about at the time.

### Guardrail (generalizing §11's lesson)

Anything injected into `settings.json` (or any other file both
`setup-claude-configs.sh` and the git hook can write) needs to be re-applied
from **every** code path that can overwrite that file — not just the one that
happened to be tested. When adding a new plugin-wiring step, mirror it into
the git hook in the same change, not as a follow-up.

---

## 14. Egress preflight false positive: checking port 443 only (2026-07-26)

### The symptom

`ALLOWED_SITES=datalackey.com` on top of the base allowlist made
[`launch-claude-in-docker.sh`](launch-claude-in-docker.sh)'s preflight report
the domain unreachable, even though `curl datalackey.com` worked fine from
the same host.

### Root cause

The preflight only ever probed port 443:

```bash
timeout 3 bash -c "cat </dev/null >/dev/tcp/${domain}/443"
```

`curl datalackey.com` with no scheme defaults to port 80 (http). Confirmed
empirically that the two probes disagree for this domain:

```
curl -v https://datalackey.com   -> connect to ...:443 ... Connection refused
/dev/tcp/datalackey.com/443      -> Connection refused (exit 1)
/dev/tcp/datalackey.com/80       -> succeeds (exit 0)
```

datalackey.com simply has no TLS listener on 443. The preflight's job is to
predict whether the *egress filter* (§8, allowlist by domain, not by port)
will actually let the container reach a site — checking only 443 produces
false positives for any allowed site that is HTTP-only.

### Fix

Fall back to port 80 when 443 refuses, mirroring what a plain `curl` does:

```bash
timeout 3 bash -c "cat </dev/null >/dev/tcp/${domain}/443" 2>/dev/null \
  || timeout 3 bash -c "cat </dev/null >/dev/tcp/${domain}/80" 2>/dev/null \
  || FAILED+=("$domain")
```

This only changes the host-side *preflight* check — the egress filter itself
(§8) already allows a domain on any port dnsmasq resolves it for, so no
filter-side change is needed.

### A deeper limitation surfaced along the way: WebFetch cannot use plain HTTP

Fixing the preflight didn't fully solve the original problem. Claude Code's
built-in `WebFetch` tool documents that it "automatically upgrades HTTP URLs
to HTTPS" — unconditionally, with no override. So even with the egress filter
and preflight both correctly allowing datalackey.com, `WebFetch` still fails
with `ECONNREFUSED`: it insists on port 443, which this domain doesn't serve.
This is a Claude Code tool behavior, not something `devenv/claude` controls.

**Fix:** a new `## Web fetch fallback` directive in
[`claude-config-files/LLM/COMMON/directives.md`](claude-config-files/LLM/COMMON/directives.md)
instructs the assistant to retry a failed `WebFetch` call with `curl` over
plain HTTP, piped through `pandoc -f html -t markdown`, before reporting
failure. `pandoc` was added to [`Dockerfile`](Dockerfile) for this — chosen
over `html2text` because Debian's `html2text` package strips a page down to
plain text (no links, no headers), while `pandoc -f html -t markdown`
produces real Markdown, matching WebFetch's own output shape. This is
enforced as a verbal directive rather than a hook: the failure mode (an
occasional missed retry) is a workflow inconvenience, not a
destructive-or-silent risk, so it doesn't clear the bar this file uses
elsewhere (§5, §10) to justify hard enforcement over discipline.

---

## 15. A directive can be correctly written and still never be read (2026-07-26)

### The symptom

Even after §14's fix, live sessions kept fetching `datalackey.com` with raw
`curl | head` and quoting from unconverted HTML — sometimes self-correcting
only after being told "you violated the directive," sometimes asking
permission to run `pandoc` after confirming it was available, rather than
just running it. Rewording the directive with stronger MUST language (twice)
didn't fix it.

### Root cause: `summarize()` truncates before the rule is ever stated

[`generate-preamble.js`](claude-config-files/generate-preamble.js)'s
`summarize()` takes each `##` section's body and truncates it to ~160 chars
for the session-start table — and `CLAUDE.md` explicitly tells the assistant
not to read the full `LLM/**` files itself (§12: the hook's output is the
single source of truth). So the truncated table row *is* the entire rule a
session ever sees. The "Web fetch fallback" directive opened with two
sentences of WebFetch-upgrade context before ever stating the actual
MUST-pipe-through-pandoc rule — comfortably past the 160-char cutoff. No
amount of rewording the *rule itself* could fix this while the rule stayed
in paragraph two.

### Fix: two changes, not one

**1. Content — lead with the rule.** Reordered the directive so a single
bolded, actionable sentence is the first thing in the section body;
explanation and the WebFetch-upgrade context now follow it.

**2. Mechanism — `summarize()` prefers the first bolded span.** Rather than
trust every future directive to be hand-ordered correctly (this file's own
recurring lesson, per §11/§13: a fix that depends on remembering to do it
right every time eventually doesn't get done right), `summarize()` now
extracts the first `**bolded**` span if one exists, falling back to head
truncation only when a section has no bold text at all — no regression for
existing directives that were already fine (verified empirically: all four
roles still resolve, and the non-bold "Approval before changes" directive is
byte-for-byte unchanged).

**Bug found while implementing #2:** the pre-existing bullet-marker stripper
(meant to strip `- ` / `* ` list markers) used `^[-*]\s*` — zero-or-more
whitespace — which also matched the *first* asterisk of a `**bold**` opener,
turning it into a lone `*` and breaking the bold-pair regex entirely. Caught
by testing against the real config in an isolated fake `$HOME` rather than
assuming the regex worked (this file's "test, don't trust" precedent, §4).
Fixed by requiring at least one whitespace after the marker (`\s+`), which
list bullets always have and `**bold**` never does.

**3. Convention, documented where it'll actually be read.** Added an
authoring-convention note at the top of
[`LLM/COMMON/directives.md`](claude-config-files/LLM/COMMON/directives.md)
itself (applies to `roles/*.md` too): lead with a bolded rule, explanation
after. The `summarize()` fix only pays off going forward if whoever writes
the *next* directive knows the convention — documenting it only in the
script's source comments wouldn't reach an assistant asked to "add a rule
that..." in a future session.

---

## 16. Auto-memory only survived a machine loss for one hardcoded project (2026-07-26)

### The symptom

Chris realized memory persistence had a gap: he assumed Dropbox-backed sync
covered all auto-memory, the way it already covers `CLAUDE.md`/`settings.json`/
`LLM/`. It didn't, uniformly.

### What was actually true

**Docker sessions (launched via the `cld` wrapper around
`launch-claude-in-docker.sh`) were already fine.** Verified directly: this
session's own `/home/node/.claude/projects/-workspace/memory` is a real bind
mount (confirmed via `/proc/mounts`), matching `launch-claude-in-docker.sh`'s
hardcoded `-v .../Dropbox/.../claude-memory:/home/node/.claude/projects/-workspace/memory`.
Because the container's cwd is always `/workspace` regardless of which repo
was mounted, every docker session — from any project — already lands in the
same synced pool.

**Host-mode sessions (bare `claude`, no Docker) were not.** Claude Code names
each project's memory dir after the real cwd (e.g. `/home/chris/qwiki` →
`~/.claude/projects/-home-chris-qwiki/memory/`). Only one such directory had
ever been manually symlinked into Dropbox — `-home-chris-build-tools`, a
leftover from an old repo path. This was already a known, unresolved item
from an earlier portability audit (`FIX: symlink into Dropbox + add to
post-install-setup.sh`) — it just hadn't been generalized yet.

### Decision: one shared pool, not per-project isolation

Chris doesn't run enough concurrent projects for per-project memory isolation
to be worth the complexity — a single shared pool (matching what docker mode
already does) is simpler and was his stated preference. So the fix makes
host mode converge on the *same* Dropbox folder docker mode already uses,
rather than giving host-mode projects their own separate Dropbox subfolders.

### Fix: session-start.sh, not a one-time setup step

The earlier attempt (the single hardcoded symlink) failed exactly because it
was a one-time manual step for one project — the same class of problem this
file has already hit twice (§11 hardlinks, §13 HUD wiring): a fix that only
runs once, for one known case, silently doesn't cover the next one.

Instead, the check now runs in `session-start.sh`, which already executes on
every session in every mode. On each host-mode start (detected by the
absence of `/devenv`, which only exists inside the docker sandbox), it
computes the current project's memory path from `pwd`, and if it isn't
already a symlink into the shared Dropbox folder, links it — so the *first*
session in any new project directory self-heals, with no manual step and no
need to remember this file exists.

**Safety choices, deliberate:**
- Any pre-existing local-only memory content is merged into the Dropbox pool
  first (`cp -n`, so an existing Dropbox file wins on a name collision rather
  than being silently overwritten).
- The original directory is renamed to a timestamped `.bak.<epoch>`, not
  deleted (`mv`, not `rm -rf`) — reversible, in keeping with this project's
  general preference for backups over destructive operations, and sidesteps
  needing to reason about whether an automated `rm -rf` in a hook script
  could ever target the wrong path.
- The check is idempotent: a project already linked is a no-op on every
  subsequent session.

**Verified empirically** (isolated fake `$HOME`, real script logic, not
assumed): a fresh project with no existing memory dir links cleanly; a
project with pre-existing local memory content merges into the Dropbox pool
and the original is preserved as a backup, not lost; running the check twice
produces no duplicate backup and no change on the second run.

### Outstanding

~~The old memory audit's finding (`~/.claude/projects/-home-chris-build-tools/memory/`
manually symlinked) is now superseded by this generalized fix and can be
considered resolved.~~ ✅ done (2026-07-28) — the leftover one-time migration
block removed from `setup-claude-configs.sh` (it also referenced an undefined
`$BACKUP_DIR`, which would have hard-crashed the script under `set -euo
pipefail` had it ever executed).

---

## 17. Playwright/Chromium baked into the image at build time, not runtime (2026-07-26)

### The problem

Projects mounted into this sandbox may use Playwright, which needs a Chromium
binary. Playwright's default behavior — download its own bundled browser on
first use — cannot work inside the *running* container: the runtime user is
non-root (`USER node`, no second user — see §12's note on uid matching), so
`apt-get install` is unavailable, and Tier 2's egress allowlist (§8) does not
include Playwright's CDN or Google's storage CDN. Either restriction alone
would still leave a path around it (root without network, or network without
root); both together, as they are here, leave none. This is the general case
captured in the "NixOS + Playwright Chromium" directive in
[`claude-config-files/LLM/COMMON/directives.md`](claude-config-files/LLM/COMMON/directives.md).

### Fix: install at image build time instead

`docker build` runs as root with full network access, before any of the
runtime restrictions apply. So [`Dockerfile`](Dockerfile) now installs
`chromium` alongside the other apt packages and sets
`ENV PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH=/usr/bin/chromium`, baking the binary
into the image itself rather than depending on anything happening at
container start.

This also means a project's Playwright config doesn't need any
container-specific logic: one that auto-discovers a system Chromium (checking
the env var, then `which chromium`, then common paths) finds it with zero
extra wiring; one that doesn't can still reference
`process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH` directly, per the directive.

### Requires a rebuild

Because this only takes effect at build time, existing running/cached
`claude-code-sandbox` images predate it — the image must be rebuilt
(`docker build`) before any container launched from it has Chromium
available.

### Addendum: the binary alone doesn't launch (2026-07-26)

A Claude session running *inside* a container launched from the rebuilt image
(working in the `qwiki` project, mounted at `/workspace`) found the fix above
was necessary but not sufficient. `ldd` on `/usr/bin/chromium` showed no
missing shared libraries (unlike the unrelated `@sparticuz/chromium` failure
mode this directive was originally modeled on), but an actual
launch-and-screenshot attempt still failed:

```
chrome_crashpad_handler: --database is required
```

Chromium's crash-reporting handler needs a writable XDG cache/config
directory and refuses to start without one. The image had never set
`XDG_CACHE_HOME`/`XDG_CONFIG_HOME`, so Chromium fell back to a location that
either doesn't exist or isn't writable by the non-root `node` user.

**Fix:** [`Dockerfile`](Dockerfile) now pre-creates `/home/node/.cache` and
`/home/node/.config` (chowned to `node`, same pattern as the `~/.claude`
subdirs above) and sets `ENV XDG_CACHE_HOME=/home/node/.cache` /
`ENV XDG_CONFIG_HOME=/home/node/.config`.

**Lesson for the write-up:** "no missing shared libraries" only proves the
binary can be *loaded* — it says nothing about whether it can actually
*launch*. The empirical gate for "Chromium works in this sandbox" has to be a
real launch-and-screenshot round trip, not `ldd`, matching this file's
existing "test, don't trust" precedent (§4).

### Another hardlink-drift instance, caught before commit

While drafting this directive, `~/.claude/LLM/COMMON/directives.md` (host) and
[`claude-config-files/LLM/COMMON/directives.md`](claude-config-files/LLM/COMMON/directives.md)
(repo) were found on different inodes — each had content the other lacked
(repo had §15's authoring-convention note and the "Web fetch fallback"
directive; host had this section's first draft). Same recurring class as
§11/§13/§15: an edit broke the hardlink at some earlier point and nothing
re-synced it. Fixed by merging both files' unique content into the repo copy
and re-running `ln -f` repo → host, verified identical via `diff` and matching
inodes via `stat -c '%i %n'` on both paths — not assumed from content alone,
per this file's own §11 correction about false-positive content matches.

---

## 18. Self-healing bidirectional hardlink check in `session-start.sh` (2026-07-26)

### Why: manual catch-and-fix doesn't scale

§17's addendum was the third time this file documents the same class of bug
(§11, §13, now §17): a hardlink between the repo and `~/.claude/` silently
breaks whenever either side is written via temp-file+rename — which includes
Claude Code's own `Edit`/`Write` tools, not just git — and nothing notices
until someone manually diffs and `stat`s both paths. The existing repair
(`git-hooks/sync-claude-configs`) only fires on `post-merge`/`post-checkout`/
`post-rewrite` — real git tree operations — so a plain edit to either copy,
with no git operation involved, drifts forever with no signal.

### Fix: verify + self-heal on every session start, not just on git operations

[`session-start.sh`](claude-config-files/session-start.sh) already runs on
every session in every mode (it emits the mandatory role preamble). Host mode
(`/devenv` absent) now also walks every hardlinked file
(`settings.json`, `session-start.sh`, `generate-preamble.js`, `CLAUDE.md`, and
everything under `LLM/` and `rules/`) and compares inode numbers between the
repo path and the `~/.claude` path. A mismatch means the hardlink broke at
some point; **whichever side has the newer mtime wins** and gets `ln -f`'d
onto the other — repo-always-wins would silently discard a direct edit to the
`~/.claude` copy, which is exactly the bug being fixed.

This is deliberately the same pattern as §16 (auto-memory Dropbox linking):
push the check into code that runs unconditionally on every session, rather
than trusting a human or a future session to remember to run a one-off repair
script.

### Verified empirically, not assumed

Isolated fixture test (four scenarios against a scratch repo/host pair, not
the live config): fresh hardlink → no-op; repo edited → host correctly
adopts repo's content; **host edited directly → repo correctly adopts host's
content** (the direction that would have silently broken under a
repo-always-wins design); new repo-only file → host copy created.

Live test against the real config: deliberately broke the
`LLM/COMMON/directives.md` hardlink (rename-based edit, matching how the bug
actually occurs) and ran the real `session-start.sh`. It correctly detected
the drift, propagated the newer repo content to `~/.claude`, and converged
the inodes — then cleanly reverted, leaving only the intended directive
content in the diff.

**Bonus finding**: the same live run also caught and healed two *pre-existing*
real drifts nobody had noticed: `generate-preamble.js` (repo was newer →
host updated) and `settings.json` (host was newer → repo updated). The
`settings.json` case was a genuine gap — the HUD `statusLine` wiring from
§13 and a `"model": "sonnet"` pin existed only on the host and had never made
it back into the versioned file. This is direct evidence the bidirectional
design was necessary, not just defensive: a repo-always-wins version would
have silently discarded that host-side config on the next session start.

### Known residual limitations

- **Propagation happens at the next session start, not instantly.** There is
  no filesystem watcher; if both copies are edited within the same session
  before another one starts, only the last-run `session-start.sh` invocation
  reconciles them.
- **1-second mtime resolution**: `stat -c '%Y'` is whole seconds. Two edits to
  opposite sides within the same wall-clock second would tie-break toward
  repo (`-gt` is strict). Not a realistic risk for sequential human/assistant
  edits, but a real one for scripted/automated writes to both sides at once.
- **Brand-new files created only under `~/.claude/LLM/**` are not picked up.**
  The check walks the repo's file listing to find what to compare, so it can
  heal drift in files that exist in both places, but a wholesale new file
  authored directly on the host side (never added to the repo) has no
  counterpart to compare against and is silently skipped. Editing an
  *existing* directive file (the actual case that motivated this fix) is
  fully covered.
- **Container mode is unaffected and doesn't need this.** `/home/node/.claude/LLM`
  is a live bind-mount of the repo path (`launch-claude-in-docker.sh`), not a
  hardlink — there is nothing to drift.

## 19. Pre-create `/home/node/.claude/projects/-workspace` in the Dockerfile (2026-07-26)

### Symptom: session transcripts silently failing to write in every docker session

`launch-claude-in-docker.sh` bind-mounts the host Dropbox memory directory to
`/home/node/.claude/projects/-workspace/memory` (`-workspace` because the
container's `cwd` is always `/workspace`, so Claude Code's project-slug naming
turns that into `-workspace`). The Dockerfile already pre-creates
`/home/node/.claude/projects` and `chown`s the whole `~/.claude` tree to
`node:node`, specifically to stop Docker from auto-creating bind-mount parent
directories as root — but it never covered the deeper `-workspace` path
component, so Docker still created *that* directory itself, as root, every
time the mount was set up. The non-root `node` user could then read/write
inside `-workspace/memory` (that part *is* the mount, inheriting the host
dir's ownership) but not create sibling files directly under `-workspace/`
— which is exactly where Claude Code writes its own session transcript
`.jsonl` files, producing a permission-denied banner on every launch.

### Why this wasn't caught sooner

The bind-mount line and the Dockerfile precreate list have been unchanged
since 2026-06-24, when the mount was introduced — this has been broken since
then. It only became *visible* around 2026-07-14, when a separate change
(self-updating `claude-code` inside the container, see the update-marker
logic in [`setup-claude-configs.sh`](setup-claude-configs.sh))
started running current `claude-code` versions instead of a stale cached
image; the stale version silently swallowed this exact failure instead of
reporting it as a banner. So the bug is old, but nothing in the visible
symptom pointed at its actual (much older) origin.

### Fix

Add `/home/node/.claude/projects/-workspace` to the Dockerfile's existing
precreate-and-chown block (same pattern as the other `~/.claude` subdirs) —
no new logic, just closing the gap in what was already being pre-created.

## 20. Devenv-status warning moved from `additionalContext` to `systemMessage` (2026-08-23)

### Symptom: uncommitted `devenv/` changes were fed to the LLM for no reason

[`generate-preamble.js`](claude-config-files/generate-preamble.js) previously
prepended the `git status --short -- devenv/` output onto the same
`hookSpecificOutput.additionalContext` string as the mandatory role/directive
preamble, with an instruction telling the assistant to echo the warning back
verbatim as the first line of its response. That accomplishes the goal (the
human sees the warning) only by round-tripping it through the model, and it
burns prompt-cache-ineligible tokens doing so — not within a single session
(the hook fires once at session start, so the combined text is fixed for
that session's remaining turns, and turn-to-turn caching works regardless of
tree state), but across sessions. Anthropic's prompt cache is keyed by the
hash of the prefix bytes server-side, not scoped to one conversation, so any
two requests anywhere — different sessions, different terminal tabs, the
same session hours apart within the TTL — can share a cache entry if their
prefixes are byte-identical. Baking live git-status text ahead of the
otherwise-stable directive table meant every distinct `devenv/` working-tree
state produced a distinct prefix hash: a session started right after a
commit shared nothing with one started against a dirty tree, and two dirty
sessions didn't share unless the modified-file list matched exactly. In
practice this made the directive-table cache entry useless for reuse across
almost any two sessions, regardless of whether the table itself had changed.

The warning has no bearing on anything the assistant needs to reason about;
it exists purely to tell the human "you have uncommitted changes here,"
information they already have from their own shell. There was no reason for
it to touch the model's context at all.

### Fix

Claude Code's `SessionStart` hook JSON supports a top-level `systemMessage`
field, distinct from `hookSpecificOutput.additionalContext`: it is displayed
to the user in the terminal and never enters the model's context. Moved the
devenv-status text there, and dropped the "echo this warning" instruction
from the LLM-facing preamble since the assistant no longer receives it.

Known caveat (unverified against the currently installed Claude Code
version): third-party reports describe an open bug where the VS Code
extension ignores `systemMessage` for `SessionStart` specifically (CLI is
reportedly unaffected), and one report claims display behavior changed
across a Claude Code release. Confirmed working via direct invocation of the
hook script; not yet confirmed against a live `SessionStart` firing in the
terminal.
