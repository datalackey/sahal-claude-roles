---
paths:
  - "**/*.md"
---

- Keep line length below 100 characters so files are readable without horizontal scrolling.

- When adding documentation that references any file in the same repo: add a 
local relative Markdown hyperlink to it (e.g. ``[`infra/scripts/foo.sh`](infra/scripts/foo.sh)``)
instead of leaving it as plain text or an inline code span. Skip this inside fenced 
code blocks (links don't render there) and for generic/conceptual path fragments that 
don't name one real file (e.g. describing a user-supplied content-directory
convention like `files/`).                     

