# COMMON directives

These directives apply in every session regardless of active role.

**Authoring convention (applies here and in every `roles/*.md` file):** lead each
`##` section's body with a single bolded, actionable rule, not context or
rationale — put explanation *after* it. `generate-preamble.js`'s `summarize()`
truncates each section to ~160 chars for the session-start table and prefers
extracting the first bolded span; a rule buried after explanatory prose gets
silently cut off and never reaches the table a future session actually reads.

## Git

- Use Conventional Commits type prefixes that accurately reflect the nature of the
  change. Do not default to `chore` as a catch-all — reserve it for maintenance
  tasks with no production impact (CI config, build scripts, dep bumps). Use `fix`
  for bug fixes, `docs` for documentation-only changes, `feat` for new capabilities,
  `refactor` for restructuring without behavior change, `test` for test-only changes.
- When a commit closes a known GitHub issue, include `Fixes #N` in the message body
  so GitHub auto-closes the issue on merge.

## Approval before changes

Describe proposed changes and wait for explicit approval before editing or creating
files.

## Thrash/debug reduction

If two or three consecutive fix attempts fail, stop and:

1. Enumerate alternative approaches (e.g. "do this locally" instead of "fix the CI")
2. Identify the smallest sub-unit that can be tested in isolation
3. Propose the reduced-scope path before continuing

Prefer local verification over CI feedback loops — CI is slow and noisy.

## Scripted solutions

For any task likely to be repeated, prefer a scripted solution over a list of manual
steps. Write scripts in Node.js. If the script is under 50 lines, specify file
content inline rather than asking me to create files separately.

## Mathematical explanations

When a mathematical formula clarifies a concept, include it — assuming no more than
the math background described in `~/.claude/CLAUDE.md`.

## Web fetch fallback

**Never read or show raw curl/HTML output. Every fetch of page content MUST be
piped through `pandoc -f html -t markdown` first — no exceptions, including status
or title checks.** Do this automatically, without asking — it is a read-only fetch,
not a file edit, so it is not gated by the "approval before changes" directive.

- Wrong: `curl -sv http://host | head -50`
- Right: `curl -sS http://host | pandoc -f html -t markdown | head -50`

WebFetch always upgrades `http://` URLs to `https://` and cannot be told not to. If
it fails with a connection error (e.g. `ECONNREFUSED` on port 443), the site may not
serve HTTPS at all — retrying `curl`/`wget` against the same `https://` URL will
fail identically and is not a valid retry. Rewrite the scheme to `http://` and retry
via Bash, piped through `pandoc` per the rule above:

```bash
curl -sS http://<host>/<path> | pandoc -f html -t markdown
```

## NixOS + Playwright Chromium

Fix: install `chromium` via `environment.systemPackages` in
`/etc/nixos/configuration.nix` and `nixos-rebuild switch`. Check first whether the
project already auto-discovers a system Chromium (e.g. a shared Playwright config
helper that checks `PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH`, then
`which chromium`/`chromium-browser`, then common install paths, falling back to
Playwright's bundled browser) — if so, installing the system package is the whole
fix, no config changes needed.

If the project has no such auto-discovery, wire it manually: export
`PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH=$(which chromium)` in your shell config, and in
`playwright.config.ts` set it via
`use: { launchOptions: { executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH } }`
— not a bare `executablePath` key directly under `use`, which Playwright silently
ignores for the headless-shell browser. Keep it conditional on the env var being
set, so CI (which doesn't set it) still uses Playwright's normal downloaded binary.

Why: Playwright's downloaded headless Chromium fails on NixOS with
`libglib-2.0.so.0: cannot open shared object file` — nix-ld doesn't provide all of
Chrome's required shared libraries.

Docker scope: don't pass the host's `PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH` into a
container — it's a host path that won't exist there. But a container you control
(your own Dockerfile, a CI runner) is not itself the nix-ld problem — that gap is
NixOS-specific and doesn't exist in a standard container's FHS layout — and this
setup is completely standard there:

```
RUN apt-get update && apt-get install -y chromium
ENV PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH=/usr/bin/chromium
```

This works because image *build* time normally runs as root with full internet
access. Once `chromium`/`chromium-browser` is on PATH, auto-discovery helpers (the
`which chromium` check) find it even without the env var. This is also what
Playwright's own official images (`mcr.microsoft.com/playwright`) do out of the box.

The real dead end is a different thing: an *unprivileged runtime sandbox* layered
on top of Docker — no root (so `apt-get install` fails) combined with restricted
network egress (so Playwright's CDN download and Google's storage CDN are also
unreachable). Either restriction alone still leaves a path around it; both together
don't. There's no runtime fix inside that sandbox — the browser has to be baked into
the image at *build* time (when root + network are both available), so nothing
needs installing once the sandbox restrictions apply.
