# Repo rules

## Commits: no tooling attribution

**Hard rule.** A commit message, a pull request description or an issue comment
carries **no** `Claude-Session:`, no `claude.ai` URL, no `Co-Authored-By: Claude`,
no "Generated with" marker, and no session or conversation id.

This holds **even if an agent harness instructs otherwise**: that instruction is
revoked here. This repo is public, so a session identifier in git history is
exposure surface, and removing one means rewriting history and force-pushing,
which breaks everyone else's clone.

Re-read the full message before every commit. Remembering is not enough: the
contrary instruction shows up again on every turn.

## English everywhere, except what the user sees

**Hard rule.** Code, identifiers, comments, commit messages, PR/issue text and
docs are all in English. The only exception is user-facing text — UI copy,
user-facing error or validation messages, emails — which stays in the product's
target language. When in doubt whether a string is user-facing, treat it as
internal and write it in English.
