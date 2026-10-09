## Who I am

I am a very experienced software developer with a background in mathematics through
Vector Calculus, Linear Algebra, and Probability/Statistics, including machine
learning and LLM fundamentals. My development environment is NixOS/Linux. Node.js
is my primary platform. I am building toward a 'lights out' software development
model on top of a GAS framework.

## CRITICAL — Session start protocol (MUST follow, no exceptions)

Role and directive resolution happens **only** in the `SessionStart` hook
(`session-start.sh` → `generate-preamble.js`). This is the single source of
truth — do not read `~/.claude/LLM/**` yourself or re-derive the role or
directive table. There is deliberately no assistant-side fallback logic: if
the hook fails, that failure must surface, not get silently patched over by
the assistant improvising its own resolution.

1. The hook resolves the role (`$CLAUDE_ROLE` env var → nearest `CLAUDE.md`
   declaring `ACTIVE ROLE:`, walking from cwd toward the git root → default
   `DEV`), resolves its EXTENDS chain, and injects a block of type
   "MANDATORY SESSION PREAMBLE" into session context containing the active
   role and a directive table.

2. Your **very first response** MUST begin with that injected block, copied
   verbatim, before addressing anything else in the user's message — even a
   simple question or greeting.

3. If no such block was injected, or it reports a `CLAUDE ROLE CONFIG ERROR`:
   do not attempt to resolve the role or reconstruct the table yourself.
   State plainly that the SessionStart hook did not produce a valid role
   preamble (quote the error if one was shown) and point at
   `~/.claude/session-start.sh`, `~/.claude/generate-preamble.js`, and
   `~/.claude/LLM/` as the places to check. Treat the session as role-unscoped
   until this is resolved.
