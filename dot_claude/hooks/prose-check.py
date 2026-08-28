#!/usr/bin/env python3
"""PreToolUse gate on Edit/Write: reject added prose that violates the CLAUDE.md text rules."""

import json
import os
import re
import sys

DASH_COMMENT_EXT = {".sql", ".lua", ".hs", ".lhs", ".adb", ".ads", ".elm", ".pls", ".pks"}
STAR_COMMENT_EXT = {".c", ".h", ".cc", ".cpp", ".hpp", ".java", ".cs", ".js", ".jsx",
                    ".ts", ".tsx", ".go", ".rs", ".php", ".swift", ".kt", ".scala", ".css"}

COMMENT_ALL = re.compile(r"^\s*(#|//|--|;|\*(?!/))\s*(.*)$")
COMMENT_NO_DASH = re.compile(r"^\s*(#|//|;|\*(?!/))\s*(.*)$")
COMMENT_NO_DASH_NO_STAR = re.compile(r"^\s*(#|//|;)\s*(.*)$")
BANNER = re.compile(r"^\s*(#|//|--|;)\s*[-=*#_~+]{4,}")
HASH_BANNER = re.compile(r"^\s*#{5,}")
CEREMONIAL = re.compile(r"^\s*(Args|Arguments|Returns|Raises|Parameters|Attributes)\s*:\s*$")
TODO = re.compile(r"\b(TODO|FIXME|XXX|NOTE|HACK)\b")
TEMPLATED = re.compile(r"\{\{.*?\}\}|\{%.*?%\}|<%.*?%>")
SHEBANG = re.compile(r"^#!")
TRIPLE_QUOTE = re.compile(r'"""|\'\'\'|`')
DIRECTIVE = re.compile(
    r"^\s*(?:"
    r"//\s*(?:nolint\b|go:|line\b|export\b|cgo\b|sys\b|revive:|lint:|exhaustruct:"
    r"|deadcode:|staticcheck|gopls:|ts-|eslint-|prettier-|@ts-|biome-|oxlint-)"
    r"|#\s*(?:noqa\b|type:|pragma\b|pylint:|mypy:|ruff:|fmt:|nosec\b|nosemgrep\b"
    r"|coding[:=]|!\[|\[|cython:|distutils:)"
    r"|--\s*(?:!|\+|@)"
    r"|;\s*(?:!|\+)"
    r")"
)
ANNOTATION = re.compile(r"^\s*(?:\*|//|/\*\*|#)?\s*@[A-Za-z][\w-]*(?:\s|$)")
TEMPLATE_EXT = {".tmpl", ".tpl", ".gotmpl", ".j2", ".jinja", ".jinja2", ".mustache",
                ".hbs", ".handlebars", ".erb", ".eta", ".liquid", ".twig", ".ejs"}
MAX_COMMENT_LINES = 2
UNSOLICITED_DOCS = re.compile(
    r"(^|/)(README|SUMMARY|CHANGELOG|NOTES|OVERVIEW|MIGRATION|DESIGN|ARCHITECTURE)"
    r"[^/]*\.(md|rst|txt)$",
    re.IGNORECASE,
)


def comment_re(path):
    """`--` is a comment only in SQL-likes; elsewhere it starts a long flag (nushell, argparse)."""
    root, ext = os.path.splitext(path or "")
    ext = ext.lower()
    if ext in TEMPLATE_EXT:
        ext = os.path.splitext(root)[1].lower()
    if ext in DASH_COMMENT_EXT:
        return COMMENT_ALL
    if ext in STAR_COMMENT_EXT:
        return COMMENT_NO_DASH
    return COMMENT_NO_DASH_NO_STAR


def comment_body(line, pattern):
    """Shebangs, tool directives, docblock tags (@param) and template output are not prose."""
    if (SHEBANG.match(line) or DIRECTIVE.match(line) or ANNOTATION.match(line)
            or TEMPLATED.search(line)):
        return None
    m = pattern.match(line)
    return m.group(2) if m else None


def code_lines(text):
    """Yield lines outside triple-quoted literals — those hold data, not prose."""
    fence = None
    for line in text.splitlines():
        if fence:
            if fence in line:
                fence = None
            continue
        marks = TRIPLE_QUOTE.findall(line)
        if len(marks) % 2:
            fence = marks[-1]
            continue
        yield line


def longest_comment_run(text, pattern):
    """A bare `*` or `#` carries no text — it separates a docblock, so it neither
    counts nor breaks the run."""
    best = run = 0
    for line in code_lines(text):
        body = comment_body(line, pattern)
        if body is None:
            run = 0
        elif body.strip():
            run += 1
            best = max(best, run)
    return best


PROSE_EXT = {".md", ".rst", ".txt", ".markdown", ".mdx"}


def check(tool, path, new_text, old_text):
    findings = []
    pattern = comment_re(path)

    # `#` opens a heading, not a comment — only the new-doc-file rule applies.
    if os.path.splitext(path or "")[1].lower() in PROSE_EXT:
        if (tool == "Write" and UNSOLICITED_DOCS.search(path or "")
                and not os.path.exists(path)):
            findings.append(f"new doc file {path.rsplit('/', 1)[-1]} — report in chat instead")
        return findings

    for line in code_lines(new_text):
        if BANNER.match(line) or HASH_BANNER.match(line):
            findings.append(f"banner/divider comment: {line.strip()[:60]}")
            break

    for line in code_lines(new_text):
        body = comment_body(line, pattern)
        if body and TODO.search(body):
            findings.append(f"unsolicited TODO/NOTE marker: {line.strip()[:60]}")
            break

    for line in new_text.splitlines():
        body = comment_body(line, pattern)
        if CEREMONIAL.match(line) or (body is not None and CEREMONIAL.match(body)):
            findings.append(f"ceremonial docstring block: {line.strip()[:40]}")
            break

    run = longest_comment_run(new_text, pattern)
    if run > MAX_COMMENT_LINES:
        findings.append(
            f"{run} consecutive comment lines (limit {MAX_COMMENT_LINES}) — "
            "compress to the one non-recoverable fact"
        )

    if old_text is not None:
        before = longest_comment_run(old_text, pattern)
        if run > before > 0:
            findings.append(
                f"comment block grew {before} -> {run} lines; rewrite it, do not append"
            )

    if (tool == "Write" and UNSOLICITED_DOCS.search(path or "")
            and not os.path.exists(path)):
        findings.append(f"new doc file {path.rsplit('/', 1)[-1]} — report in chat instead")

    return findings


def main():
    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        return 0

    tool = payload.get("tool_name", "")
    if tool not in ("Edit", "Write"):
        return 0

    ti = payload.get("tool_input") or {}
    path = ti.get("file_path", "")
    new_text = ti.get("new_string") or ti.get("content") or ""
    old_text = ti.get("old_string")
    if not new_text:
        return 0

    findings = check(tool, path, new_text, old_text)
    if not findings:
        return 0

    reason = "Prose rules (CLAUDE.md) violated in this edit:\n" + "\n".join(
        f"  - {f}" for f in findings
    ) + (
        "\n\nRetry with the text REPLACED, not extended:\n"
        "  - Keep the one fact a competent reader cannot recover from the code;"
        " delete the comment entirely if they can.\n"
        f"  - That fact gets {MAX_COMMENT_LINES} lines at most — no rationale,"
        " no alternatives tried, no restating the next line of code.\n"
        "  - Rewriting? Replace the old wording. Appending a shorter version next to"
        " the original leaves the same fact stated twice."
    )
    json.dump(
        {
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": reason,
            }
        },
        sys.stdout,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
