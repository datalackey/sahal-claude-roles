# Modular Role Directives for Claude Code: Design Notes

> **Next-session context file.** Load this at the start of the implementation session.
> Nothing has been implemented yet — all changes described here are pending.

---

## The Problem

If you use Claude Code seriously, you probably have a `CLAUDE.md` file (or equivalent) that
tells Claude who you are, how you like to work, and what conventions to follow. Mine grew
organically into a single file called `LLM-directives.txt` — 131 lines covering my developer
persona, git conventions, debugging protocols, documentation preferences, and more.

The problem: that entire file loads into the context window at the start of every session,
regardless of what I am actually doing. Working on a TypeScript project? You get the debugging
protocol. Writing a wiki article? You get the eslint directives. None of that is relevant, but
the model pays attention to it anyway — or rather, pays *less* attention to everything else
because of it.

I am also planning to add more role types. I want a `WIKI-AUTHOR` mode for writing neutral
technical content for a community wiki, and a `BLOG-AUTHOR` mode for my own blog — where I
prefer a conversational "here is what I discovered" narrative with the occasional self-deprecating
aside rather than bullet points and formal structure. By year end, the directive corpus will be
roughly three times its current size.

That is when a modest inefficiency becomes a real problem, and when the right time to fix the
architecture is clearly *now*.

---

## Why This Matters More Than It Sounds

Before getting into the design, it is worth understanding why loading irrelevant directives is
worse than just wasteful. Two mechanisms compound.

**Softmax denominator growth (mathematical effect, real but partial).**
The attention weight each token receives is computed by softmax:

```
attention_weight_i = exp(q · k_i) / Σ_j exp(q · k_j)
```

When irrelevant tokens are added, the denominator grows. Even tokens that score low against a
given query contribute `exp(small_value)` to the denominator, which reduces the relative weight
on everything else. The ratio `relevant_denominator_mass / total_denominator_mass` — roughly
`relevant_tokens / total_tokens` when scores are similar magnitude — is the scale factor by
which each instruction's attention weight is degraded.

The honest caveat: a transformer can partially compensate. If irrelevant tokens truly score near
zero against relevant queries, their denominator contribution is small and the dilution is mild.
This is a real effect but not as mechanically severe as a naive 1/N framing suggests.

**Lost in the Middle (empirical effect, stronger evidence).**
Liu et al. (2023) demonstrated that language models follow instructions near the beginning and
end of context reliably, but performance degrades for content buried in the middle — regardless
of what the attention math says should be theoretically possible. A growing instruction file
pushes more directives into this degraded zone. This empirical result is the stronger argument
for modular loading; the softmax denominator analysis supports it but should not be
over-relied upon.

These two effects compound as corpus size grows, which is why the quality payback from selective
loading scales super-linearly — faster than the raw token count reduction would suggest.

**Connection to prompt caching.**
At the Anthropic API level (not directly controllable in Claude Code CLI, but relevant for the
Architect exam), the cache is prefix-based: everything before a `cache_control` breakpoint must
be byte-for-byte identical across requests for a hit to occur. A stable `COMMON` block, always
loaded first, forms a perfect cache prefix — near-zero cost on every subsequent session after
the first write. Role-specific content comes after it as a smaller variable suffix. The modular
structure maps naturally onto optimal cache breakpoint placement.

Cache pricing for reference (Sonnet 4.6):

| Operation | Rate |
|---|---|
| Base input tokens | $3.00 / MTok |
| 5-min cache write | $3.75 / MTok (1.25× base) |
| Cache read (hit) | $0.30 / MTok (0.10× base) |

The write premium covers VRAM reservation cost — the cache stores computed KV attention tensors
(gigabytes for large contexts), not the prompt text itself.

---

## The Design

### Directory Structure

```
claude-config-files/
  CLAUDE.md                    ← global session-start protocol (mounted into container)
  settings.json
  session-start.sh
  generate-preamble.js
  LLM/                         ← replaces flat LLM-directives.txt
    COMMON/
      directives.md            ← universal: who I am, git, always-on preferences
    roles/
      DEV.md                   ← software design, debugging protocols
      JS.md                    ← TypeScript/Node specifics
      WIKI-AUTHOR.md           ← neutral encyclopedic voice, community wiki style
      BLOG-AUTHOR.md           ← conversational narrative, first-person, self-deprecating
```

### Role Naming Convention

All role names are capitalized by convention: `DEV`, `JS`, `WIKI-AUTHOR`, `BLOG-AUTHOR`,
`COMMON`. Sub-roles follow the pattern `PARENT-SUBROLE` where relevant.

### What Goes Where

**COMMON** — applies regardless of what I am doing:
- Profile and background (math through vector calculus / linear algebra / probability;
  NixOS/Linux; Node.js as primary platform)
- Git conventions (Conventional Commits prefixes, `Fixes #N` for GitHub auto-close)
- Approval-before-changes protocol
- Thrash/debug reduction protocol (stop after two failed attempts, enumerate alternatives,
  identify smallest testable unit)
- Markdown line length under 100 characters

**DEV** (EXTENDS: COMMON):
- Software design stage protocol (incremental phases gated by tests for significant changes)
- Debugging directives
- Code formatting (observe eslint / project config)
- LOC thresholds: under ~50 LOC → inline diff + one sentence; over ~50 LOC → per-file summary
- Type/interface documentation rules (producer, consumer, trigger, branching)
- Dependency version checking via ref MCP before reading source
- README update suggestions as part of any change
- Claude Architect exam tie-in directive (anchor API concepts to day-to-day work)
- Local npm installs only — never global
- No global npm installs (npx or devDependencies only)

**JS** (EXTENDS: DEV):
- TypeScript/Node.js specific conventions
- (To be filled out during implementation)

**WIKI-AUTHOR** (EXTENDS: COMMON):
- Neutral encyclopedic voice — no first person
- Technical accuracy as the primary constraint
- Define terms before elaborating
- Structured output preference: headers, tables, code blocks
- Consistent terminology throughout a document

**BLOG-AUTHOR** (EXTENDS: COMMON):
- First-person conversational voice
- Narrative arc: problem → exploration → discovery/insight
- Self-deprecating humor is appropriate
- Prose-heavy; bullets are a last resort not a default
- Opinionated takes are fine; hedging is not the default

---

## The EXTENDS Mechanism (Option C)

Each project's `CLAUDE.md` declares an active role:

```
ACTIVE ROLE: JS extends DEV
```

This declares the leaf role (`JS`) and its immediate parent (`DEV`). Deeper ancestry is resolved
by consulting role files themselves — `DEV.md` declares `EXTENDS: COMMON`; `COMMON` has no
parent. Three options were considered:

- **Option A** — full chain in project CLAUDE.md: `ACTIVE ROLE: JS extends DEV extends COMMON`.
  Explicit but requires updating every project file if the chain restructures.
- **Option B** — leaf only in project CLAUDE.md; all ancestry in role files. Maximally flexible
  but opaque at a glance.
- **Option C** ✓ — partial chain in project CLAUDE.md (leaf + immediate parent); role files
  handle deeper ancestry. Chosen for balance between readability and maintainability.

For single-level roles: `ACTIVE ROLE: WIKI-AUTHOR extends COMMON`

---

## Load Order: Root First, Despite Resolving Leaf First

**Resolution** follows the declaration from leaf to root:

```
JS → DEV → COMMON    (follow EXTENDS pointers to find the full chain)
```

**Loading** happens in reverse — root first, leaf last:

```
COMMON → DEV → JS    (read files into context in this order)
```

The reversal serves two purposes:

**Caching.** COMMON always loads first, forming a stable prefix shared by every session type.
A cache breakpoint after COMMON produces a hit for WIKI-AUTHOR, DEV, and JS sessions alike.
If JS loaded first, no two session types would share a prefix.

**Inheritance semantics.** Later content refines earlier content. Loading general → specific
means the most targeted directives land last and carry the most weight in any ambiguous case —
same as class inheritance in OOP, where the subclass method wins.

**The global `CLAUDE.md` must explicitly state this protocol:**

> Resolve the full EXTENDS chain from leaf to root first. Collect all role files in that order.
> Then load them in reverse (root first, leaf last) before addressing the user's first message.

---

## Infrastructure Changes Required

Three files need updating. **Nothing has been changed yet.**

### 1. `launch-claude-in-docker.sh`

```bash
# Before — single file mount
-v /etc/nixos/devenv/claude/claude-config-files/LLM-directives.txt:/home/node/.claude/LLM/LLM-directives.txt

# After — directory mount
-v /etc/nixos/devenv/claude/claude-config-files/LLM:/home/node/.claude/LLM:ro
```

### 2. `setup-claude-configs.sh` (host mode)

```bash
# Before — walks entire claude-config-files/ (incorrectly puts settings.json etc. in LLM/)
find "$CLAUDE_CONFIGS" -type f -print0

# After — walks only the LLM/ subdirectory
find "$CLAUDE_CONFIGS/LLM" -type f -print0
```

### 3. Global `CLAUDE.md`

Replace the current directive (read `LLM-directives.txt`) with the loading protocol described
in the EXTENDS section above.

---

## What We Are Not Doing (And Why)

**File-pattern / folder-hierarchy rules** trigger based on which file or directory you are
working in. These are complementary to the role system, not an alternative. The role system
sets *who you are* for the session. Folder-level CLAUDE.md files refine *what applies locally*.

The build-tools monorepo is a candidate for eventually splitting its task-routing table
(currently all in the root CLAUDE.md) into per-package CLAUDE.md files that activate via folder
descent — but that is a separate effort, not part of this implementation.

---

## Implementation Checklist

- [ ] Create `claude-config-files/LLM/COMMON/directives.md`
- [ ] Create `claude-config-files/LLM/roles/DEV.md` (`EXTENDS: COMMON`)
- [ ] Create `claude-config-files/LLM/roles/JS.md` (`EXTENDS: DEV`)
- [ ] Create `claude-config-files/LLM/roles/WIKI-AUTHOR.md` (`EXTENDS: COMMON`)
- [ ] Create `claude-config-files/LLM/roles/BLOG-AUTHOR.md` (`EXTENDS: COMMON`)
- [ ] Migrate content from `LLM-directives.txt` into appropriate role files
- [ ] Update global `CLAUDE.md` with resolve-then-load protocol
- [ ] Update `launch-claude-in-docker.sh` — directory mount
- [ ] Update `setup-claude-configs.sh` — scope `find` to `LLM/` only
- [ ] Delete `LLM-directives.txt` once migration verified

---

*Designed over one long session. The mic doubled every phrase for the entire second half.
We persevered.*
