# Claude Code ROLE Framework — Setup and Role Authoring Guide

**Audience:** Doikayt developers and documentation contributors  
**Source:** [Setup and Role Authoring Guide](https://doikayt.miraheze.org/wiki/Software_Development_Process/Developer_Tooling/Claude_Code_Role_Framework/Setup_and_Role_Authoring_Guide)

## 1. Prerequisites

- Access to the framework repository and the target project repository.
- Claude Code and its required runtime, or the team's approved container environment.
- Docker if using the sandbox launcher.
- Required local tools documented by the repository's `README.md` and scripts.
- A way to provide credentials securely without committing them.

## 2. Locate the implementation

From the repository root:

```bash
cd devenv/claude
ls -la
```

Review the current `README.md`, `setup-claude-configs.sh`, `claude-config-files/`, and `launch-claude-in-docker.sh`. Do not assume a setup script is portable until its paths and dependencies have been checked.

## 3. Understand a role

A role is a set of instructions associated with a task or responsibility. Shared instructions belong in `COMMON`; engineering guidance can be inherited from `DEV`; a specialized `JS` role can add JavaScript-specific practices. The resolver combines applicable directives for session use.

```text
COMMON → DEV → JS
```

Use the actual role definition syntax and directory naming found in `claude-config-files/`; the chain above describes semantics rather than a literal file format.

## 4. Create a role

1. Choose a short, descriptive role name.
2. Identify an existing parent role, if inheritance is appropriate.
3. Add only the directives unique to the new role.
4. Keep shared requirements in the parent instead of duplicating them.
5. Avoid personal paths, private tokens, and machine-specific assumptions.
6. Validate the role using the repository's resolver and session hook.
7. Test from a fresh session, including failure cases.
8. Document intended use and submit changes for review.

### Suggested role content

A good role definition explains its purpose, applicable work, coding or writing conventions, validation steps, and what must be escalated to a human. Keep instructions concise and testable. Avoid claiming that role text itself enforces OS security boundaries.

## 5. SessionStart behavior

The `SessionStart` hook initializes role instructions for a new Claude Code session. Verify that it selects the requested role, resolves inherited instructions, and reports failures visibly. Do not assume a successful shell script exit means the effective instructions were injected correctly; inspect the hook's observable output and session behavior.

## 6. Troubleshooting

| Symptom | What to check |
|---|---|
| Role not found | Name, definition path, selection setting |
| Parent directives missing | Inheritance declaration and resolver output |
| Session starts without role | Hook registration and error propagation |
| Machine-specific failure | Absolute paths, permissions, Nix/Docker dependencies |
| Configuration overwritten | Synchronization order and local override policy |
| Sandbox cannot reach model | Approved proxy/endpoint and credential injection |

A previously documented failure diagnostic is `CLAUDE ROLE CONFIG ERROR`. Confirm the current script's exact message and exit-code contract before writing automation that depends on it.

## 7. Verification checklist

- [ ] Role selected explicitly or via a documented default.
- [ ] Shared and inherited directives present in resolved instructions.
- [ ] Hook executes at session startup.
- [ ] Invalid role or parent produces a clear failure.
- [ ] No sensitive values appear in tracked configuration.
- [ ] A second developer can reproduce the setup.
- [ ] Sandbox restrictions are independently validated where applicable.

## 8. Contribution workflow

Use a feature branch, add documentation and tests for behavior changes, and submit a PR. For substantial refactors, store the design rationale and audit in Markdown alongside the implementation rather than exclusively on the wiki.

## Related documents

- [Framework overview](framework-overview.md)
- [Framework audit](framework-audit.md)
- [Team configuration](team-configuration.md)
