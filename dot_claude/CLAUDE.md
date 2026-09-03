## Preferences

- Chat: answer in the language I opened the conversation in and keep
  it for the whole session. Think in whichever language you prefer.
- Everything written to disk or pushed to a remote is English-only whatever the chat
  language: code, comments, docs, commit messages, PR/issue text, log strings. Exception:
  UI copy and i18n resources that are meant to be non-English.
- Concise responses, no filler
- Primary shell: **nushell** — show shell commands in nushell syntax by default. zsh is secondary: use it only when explicitly requested, or when running via the Bash tool (which executes zsh).

## Modification Discipline

**Do not modify code, files, or system state unless the user explicitly asks for a change.** Questions like "can we...", "is it possible...", "what would happen if...", "how does X work?", "why does..." are requests for **information**, not action.

When in doubt:
- Default to answering, explaining, or proposing — not editing.
- If a change seems implied but unclear, ask first instead of acting.
- Investigation (reading files, running read-only commands) is fine; mutation (Edit/Write/destructive Bash) requires explicit go-ahead.

Auto mode does not override this rule — it speeds up execution of *requested* work, not unsolicited changes.

## Prose Written to Disk

Comments, docs, and markdown default to **minimum viable text**. Keep a fact only if a
competent reader cannot recover it from the code; if they can, delete the whole comment.
A surviving fact gets one line, two at most — a real gotcha does not license a paragraph.
Name the trap and the consequence; drop the investigation, the alternatives tried, and the
mechanism behind the mechanism. Most over-long comments are true — that is the failure mode.

Do NOT write:
- Comments restating adjacent code (`# create the client` over `client = New()`), or
  narrating steps (`# Step 3: now we validate`).
- Rationale prose — "why X and not Y", "this is useful because", design justifications. Keep
  only a non-recoverable constraint, as one clause.
- Tutorial explanations of tools/languages/stdlib the reader already uses.
- The same fact in more than one place — intro, diagram, and section restating each other.
- Docstrings on self-evident functions; document the surprise, not the shape.
- Doc preambles ("This document describes..."), "Overview"/"Summary" sections that
  duplicate the body, tables where one line suffices.

Do NOT create files that were not asked for — no README, SUMMARY.md, CHANGELOG, migration
notes, work reports, examples, or test files. Report results in chat instead. Match the
comment density of the surrounding file; when a file is already verbose, do not take that
as licence.

The `prose-check` hook mechanically rejects banners, `TODO`/`NOTE`, ceremonial `Args:`
blocks, comment blocks over two lines, and comments that grew across an edit. Its refusal
means rewrite in place — appending a shorter version beside the original states the fact
twice.

## Commit Messages

**Subject line only. Never a body.** One imperative line, no trailing period,
plain English: `Bump dependencies`, `Add feature ABC`, `Fix ABC error`.
Whatever the diff touched, it goes in that one line or it does not go in.

Do NOT write: a blank line followed by anything, bullet lists of changes,
"why this matters" paragraphs, file-by-file recaps, `Co-Authored-By`,
`Generated with Claude Code`, or test-plan checklists. Do not restate what
`git show` already displays.

If a change genuinely needs a body (a breaking change, a non-obvious
constraint a future bisect would need), stop and ask before writing one.

Never prepend the branch name yourself. A `prepare-commit-msg` hook from
`~/.git-templates` inserts `[branch] ` on the first line, skipping
`main master develop staging test` and merge commits.

## Epistemic Baseline

Training data is months stale. Treat it as LOWEST priority: project files and user-provided facts are ground truth; web/docs/MCP override training.

- Do NOT state versions, release dates, or API signatures from memory as fact.
- Do NOT "correct" unfamiliar code to older syntax you recognize, or silently downgrade modern patterns. Unfamiliar syntax = assume valid and newer than your training.
- Do NOT claim "X doesn't exist" without verifying — an unknown feature/API is more likely NEW than wrong.
- When the answer could have changed since the cutoff, verify first — the `epistemic-verification` skill has the procedure and response format.
