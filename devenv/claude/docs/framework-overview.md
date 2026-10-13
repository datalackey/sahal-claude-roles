# Claude Code ROLE Framework

**Project:** Doikayt · Software Development Process / Developer Tooling  
**Status:** Team adoption documentation  
**Source:** [Framework overview](https://doikayt.miraheze.org/wiki/Software_Development_Process/Developer_Tooling/Claude_Code_Role_Framework)

## Purpose

The ROLE framework provides reusable, role-specific instructions for Claude Code sessions. It separates common team directives from specialized work instructions and resolves a selected role at session initialization. The objective is repeatable development behavior without duplicating guidance across repositories or developers.

This framework is **not** a multi-agent orchestrator or a security sandbox. Its role directives influence assistant behavior; filesystem and network restrictions must be enforced separately by the runtime/container.

## Conceptual architecture

```text
Shared directives (COMMON)
         |
Developer directives (DEV)
         |
Specialized role (e.g. JS)
         |
Resolved session instructions
         |
Claude Code SessionStart initialization
```

The `COMMON → DEV → JS` chain illustrates inheritance: more specialized roles incorporate applicable parent instructions. Other roles may include `WRITER`, `WIKI-AUTHOR`, and `BLOG-AUTHOR`, subject to their actual definitions in the repository.

## Lifecycle

1. A developer selects or configures a role.
2. The role resolver locates its definition and inherited parents.
3. The SessionStart integration prepares the effective instructions.
4. The coding session receives the resolved role guidance.
5. Invalid or missing role configuration should fail explicitly rather than silently proceed with incomplete instructions.

## Where to find the implementation

The relevant checkout places the framework under [`devenv/claude/`](../). Inspect `claude-config-files/`, `setup-claude-configs.sh`, and the SessionStart hook configuration for authoritative runtime details. Docker isolation is implemented separately in `launch-claude-in-docker.sh` and related configuration.

## Documentation

- [Framework audit](framework-audit.md)
- [Team configuration](team-configuration.md)
- [Setup and role authoring](setup-and-role-authoring.md)
- [Existing role system design notes](notes-role-system-design.md)

## Boundaries and future direction

Team generalization, sandbox security, and model/provider independence are distinct workstreams. Preserve existing inheritance and failure behavior during team generalization. Investigate model routing (OpenCode, OpenRouter, LiteLLM) separately; do not make this documentation migration dependent on those tools.
