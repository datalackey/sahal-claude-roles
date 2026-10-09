# Symlinks & Hardlinks — why this keeps tripping us up

A running account of a single root cause that produced most of this repo's
config-sync bugs, and the alternatives evaluated for it. Companion to
`DECISIONS.md` (which has the blow-by-blow for each incident); this file is
the consolidated "why does this whole class of bug keep happening" reference.

---

## The constraint that forces the whole design

**Claude Code ignores symlinked config files.** Not a style preference — an
established, load-bearing fact this repo's setup scripts have built around
from early on. If `~/.claude/CLAUDE.md` (or `settings.json`, or anything else
Claude Code reads at startup) is a symlink, Claude Code behaves as if it isn't
there. So a symlink — the obvious, simple way to keep a versioned source and a
live config location in sync — is off the table for anything Claude Code
reads directly. That single constraint is why this repo reaches for hardlinks
(host) and bind mounts (docker) instead, and both of those come with their own
sharp edges.

---

## Why hardlinks are fragile

A hardlink is two directory entries pointing at the same **inode** — not a
"connection" that tracks a path. As long as both entries point at the same
inode, editing either updates the other instantly, no sync step. The moment
*anything* replaces the file at either path via **unlink + create** (the
temp-file-then-rename pattern most tools use for crash-safe saves) rather than
**open + write in place**, the two paths silently diverge: one keeps the old
inode and serves stale content forever; the other gets a new inode. Nothing
about a stale hardlink *looks* broken — `ls -la` shows an ordinary regular
file, not a dangling arrow the way a broken symlink would. That silence is
what makes this bug class so persistent: it fails quiet, not loud.

**Quick diagnostic**, worth running any time a hardlinked config file was
touched by anything other than the git hook below:

```bash
stat -c '%i %n' ~/.claude/LLM/roles/DEV.md \
                /etc/nixos/devenv/claude/claude-config-files/LLM/roles/DEV.md
# same inode number on both lines = still linked; different = broken
```

---

## Confirmed instances hit in this repo's history

1. **`git checkout` / `merge` / `rebase`** — git never writes tracked files in
   place; every operation that updates the working tree does the
   temp+rename dance, orphaning any hardlink. This is the original, documented
   case (`DECISIONS.md` §11). Mitigated by a `post-merge` / `post-checkout` /
   `post-rewrite` hook (`git-hooks/sync-claude-configs`) that force-relinks
   after every such operation.

2. **The mitigation hook itself went stale.** `sync-claude-configs` hardcoded
   a relink for the old flat `LLM-directives.txt`, and was never updated when
   that file was replaced by the `LLM/COMMON` + `LLM/roles/` tree, or when
   `rules/` was added. It didn't error — its `[ -f "$src" ]` guard just
   skipped the now-missing source silently — so for some unknown period, a
   plain `git pull` stopped re-linking anything under `LLM/` or `rules/` at
   all, and nothing signaled that. Fixed 2026-07-14 to walk both trees
   generically instead of hardcoding filenames (`DECISIONS.md` §13). The fix
   for hardlink drift had itself drifted — same disease, one level up.

3. **`sed -i` during testing.** Used to corrupt a role file for a negative
   test; `sed -i` writes via temp+rename like everything else, so it silently
   broke the hardlink instead of reaching the file the consumer actually
   reads, producing a false-negative test result. (`DECISIONS.md` §12.)

4. **The `Edit` tool — a disproven assumption.** This file's sibling doc
   previously claimed Claude Code's `Edit`/`Write` tools always write in
   place. Empirically false: an `Edit` call on an ordinary hardlinked file (not
   a bind mount) broke the hardlink too. Best current model: these tools most
   likely only fall back to in-place writes when a rename would actually fail
   (`EBUSY` on a real bind-mount target) — on a plain hardlink, rename
   succeeds, so that's the path taken, silently orphaning the link. Corrected
   in `DECISIONS.md` §11.

5. **Cross-filesystem boundary (docker, structurally different problem).**
   `/devenv` is a host bind mount; `~/.claude` is on the container rootfs —
   crossing that boundary, `ln` fails outright with `EXDEV`. Docker's setup
   script uses `cp` instead of a hardlink, which sidesteps the rename-fragility
   problem entirely but trades it for a different one: the copy is a
   **snapshot**, frozen at container-CMD time, not continuously synced. That's
   what let the docker image's `claude-code` CLI drift two minor versions
   behind host without anyone noticing — a time-based staleness, not a
   rename-based one, but the same underlying lesson (a sync mechanism that
   only fires at specific trigger points has blind spots between those
   triggers).

## What does *not* break a hardlink

Plain `open()` + `write()` + `close()` with no temp file and no rename — e.g.
appending, or `dd conv=notrunc`. Rare in practice: most tools default to the
rename pattern specifically *because* it's safer against crashes mid-write,
which is exactly what defeats hardlinks. There is no tooling convention we
found that reliably avoids this without deliberately choosing rename-free I/O.

---

## Alternatives considered

### Symlinks — rejected
**Pro:** fails loud. A broken symlink is visibly broken (`ls -la` shows the
dangling arrow); a broken hardlink is invisible. **Con:** hard-blocked by the
constraint at the top of this doc — Claude Code ignores them outright, so this
isn't a trade-off, it's a non-starter for anything Claude Code reads directly.

### Hardlinks + git hook repair — current approach, host
**Pro:** a real regular file from every program's perspective, satisfying the
"Claude Code ignores symlinks" constraint; edits sync instantly with zero lag
as long as the inode stays shared. **Con:** fragile to *any* rename-based
write, not just git's, as items 3–4 above demonstrate — the git hook only
covers git-triggered breaks; a stray `sed -i`, an editor's autosave, or even
Claude's own `Edit` tool can silently break it outside the hook's visibility
entirely.

### Bind mounts — current approach, docker (directory-level)
**Pro:** genuinely live — the destination path resolves through the mount
table to the source inode at access time, not via a directory entry that can
go stale, and *directory*-level mounts (`LLM/`, `rules/`) transparently
reflect files added/removed/renamed within them since each lookup is live, not
frozen at mount time. **Con:** setting one up needs privilege (`CAP_SYS_ADMIN`
inside Docker's own mount namespace is free; on bare host, `mount --bind` is a
privileged operation, or you'd reach for a FUSE tool like `bindfs` for
non-root). **Untested hypothesis — not confirmed this session:** the
*single-file* bind mount used specifically for `CLAUDE.md` (as opposed to the
directory-level mounts for `LLM/`/`rules/`) may share the hardlink's
rename-fragility — if the host source is replaced via rename while a container
is already running, the mount may keep resolving to the pre-rename inode
rather than following to the new one. Worth an empirical check before trusting
that pattern for anything edited by rename-based tools mid-session.

### Health-check / periodic re-link — not implemented
A cron job or session-start check that unconditionally compares inodes and
repairs on *any* mismatch, regardless of cause, would catch `sed -i`, the
`Edit` tool, or anything else — not just git operations. **Con:** reactive on
a timer rather than immediate, and it's one more moving part. Plausible as
cheap insurance layered on top of the existing git hook, not a replacement for
it.

### inotify-based live daemon — not implemented, likely overkill
Would catch a break the instant it happens, regardless of cause. **Con:** a
persistent background process is a lot of standing complexity for a failure
mode that, so far, a git hook plus the occasional manual `stat` check (as
literally done live while running the negative test in `DECISIONS.md` §12)
has been enough to catch.

---

## Where this leaves things

Hardlinks + git hook remains the pragmatic choice given the symlink
constraint — but "hardlinked" should be treated as a claim about a moment in
time, not a standing guarantee. Run the `stat` diagnostic above after any edit
to a hardlinked config file by *any* tool, not just after git operations. If
this class of bug keeps recurring, directory-level `mount --bind` (or
`bindfs`) on the host — mirroring what already works cleanly for docker's
`LLM/`/`rules/` mounts — is the one alternative worth actually piloting. That
needs a privilege/tooling spike first; right now it's a reasoned guess, not a
tested proposal.
