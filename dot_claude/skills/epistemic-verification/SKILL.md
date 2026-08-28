---
name: epistemic-verification
description: Procedure for verifying library/framework versions, release dates, API signatures, model names, and deprecation status before stating them as fact. Use whenever the answer depends on something that could have changed since the training cutoff — questions about versions, "latest", release dates, "does X exist", "is Y still supported", deprecated vs current APIs, method/parameter signatures, or LLM model names and parameters. The always-on anti-hallucination rules live in the global CLAUDE.md; this skill is the detailed lookup procedure and response format.
---

# Epistemic Verification

The baseline anti-hallucination posture is always active (global CLAUDE.md). This skill is the **procedure** to follow once a question turns out to depend on a fact that may have changed since training. Training data is several months stale — the harness states the current date and the session model's cutoff in the system context.

## Epistemic Hierarchy (priority of truth sources)

1. **Project files & user context** (HIGHEST): `package.json`, `requirements.txt`, `go.mod`, `Cargo.toml`, lockfiles are authoritative. User-provided facts = ground truth. An unknown feature/API = assume NEW, not an error.
2. **External tools & docs**: web search, fetched docs, MCP responses (context7) override training data.
3. **Training data** (LOWEST): reliable for syntax, logic, algorithms; unreliable for versions, APIs, release dates, deprecations.

## When to verify before answering

Always verify before stating:
- Library/framework versions or release dates
- LLM model names, versions, and parameters
- API signatures, method parameters, return types
- Deprecated vs current approaches
- "Does X exist?" / "Is Y still supported?"
- Any fact that could have changed since the cutoff

## Verification procedure (version/API)

1. Check project files (`package.json`, `go.mod`, lockfiles, etc.) FIRST.
2. Version specified there → use THAT version's API.
3. No version info → ask the user, or search / fetch docs (prefer context7 for library docs).
4. User states a version → trust it, even if unfamiliar.

## Response format for version/API claims

- `VERIFIED (from [source]): [info]` — confirmed via search/docs/project files
- `FROM TRAINING (may be outdated): [info]` — not verified externally
- `UNCERTAIN: [info] — recommend verification` — low confidence

## Permission to say "I don't know"

Admitting uncertainty beats confident hallucination. Acceptable:
- "I'm not certain about the current API — let me check."
- "This might have changed since my training."
- "I don't recognize this syntax, but I'll assume it's valid."
