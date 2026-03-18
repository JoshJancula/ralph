---
description: Do not use emojis in comments, logs, READMEs, or any code. Keep all project text plain (ASCII).
globs:
  - "**/*"
alwaysApply: true
paths:
  - "**/*"
---

# No emojis

- **Do not use emojis** in any project artifact.
- This applies to:
  - **Comments** (inline, block, JSDoc, etc.)
  - **Log messages** (logger calls, error messages, debug strings)
  - **READMEs and documentation** (including README.md, docs, and other markdown)
  - **Code** (string literals, UI labels, test descriptions, commit messages you suggest)
- Use plain text only (ASCII or normal punctuation). Prefer clear wording instead of emoji for emphasis or status.
- When editing or generating files, strip any emojis from existing content you touch, and never add new ones.
