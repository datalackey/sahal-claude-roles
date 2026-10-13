# Claude Code ROLE Framework — Team Configuration

**Purpose:** Define a portable configuration approach for multiple Doikayt developers and projects.  
**Source:** [Team Configuration wiki page](https://doikayt.miraheze.org/wiki/Software_Development_Process/Developer_Tooling/Claude_Code_Role_Framework/Team_Configuration)

> This is a team configuration specification, not a claim that all proposed configuration variables are already implemented. Check the scripts before using example values.

## Configuration layers

| Layer | Responsibility | Example |
|---|---|---|
| Shared team | Common conduct and engineering expectations | `COMMON` |
| Functional role | Discipline-specific guidance | `DEV`, `WRITER` |
| Specialized role | Narrower workflow and tools | `JS`, `WIKI-AUTHOR`, `BLOG-AUTHOR` |
| Project | Repository-specific conventions | Tests, build commands, layout |
| Personal | Non-secret developer preferences | Editor and local working paths |

## Principles

1. Shared configuration must not depend on Chris's username, home directory, or machine-specific filesystem layout.
2. Project paths should be explicit and constrained to the selected checkout.
3. Team role files should be version-controlled and reviewed like code.
4. Secrets and provider credentials must not appear in role files, examples, or committed environment files.
5. Inheritance order must be documented and deterministic.
6. Personal preferences must not silently override mandatory team safety requirements.
7. Broken role configuration must generate actionable errors, not a silent fallback.

## Illustrative inheritance

```text
COMMON
├── DEV
│   └── JS
└── WRITER
    ├── WIKI-AUTHOR
    └── BLOG-AUTHOR
```

This tree illustrates intended composition, not a verified enumeration of the current resolver's supported roles.

## Suggested configuration contract

| Setting | Desired behavior |
|---|---|
| Role selection | Explicit role or documented default |
| Repo root | Discover or require the target repository path |
| Shared role location | Stable, versioned directory |
| Local overrides | Optional, separate, and ignored by Git if sensitive |
| Hook installation | Idempotent and easy to verify |
| Error reporting | Clear context, offending role/path, nonzero failure |
| Logging | Useful diagnostics without leaking credentials |

## Docker and network policy

The role framework and sandbox must remain separate concerns. For Docker sessions, specify allowed bind mounts, non-root execution, resource limits, credential injection, and approved outbound destinations. Network allowlisting should be enforced by the host, firewall, or controlled proxy rather than by instructions in a role prompt.

## Team onboarding verification

- A developer other than the original author can initialize a session.
- The same repository and role resolve consistently on another machine.
- A role with inherited directives loads the expected complete instruction set.
- Invalid role definitions fail with understandable diagnostics.
- No machine-specific paths or credentials are committed.
- The framework works independently of any future multi-agent orchestrator.

## Migration guidance

Generalize in small commits: inventory personal assumptions, isolate configuration, update setup, add tests, then validate on a second machine. Keep provider/model routing as a separate change to avoid conflating responsibilities.

## Related documents

- [Framework overview](framework-overview.md)
- [Framework audit](framework-audit.md)
- [Setup and role authoring](setup-and-role-authoring.md)
