#!/usr/bin/env python3
"""Static documentation checks — no cluster required, so CI can run them.

Checks, across every Markdown file in the tree:

  1. local links resolve to a real path (relative links only; http/mailto are
     assumed fine — CI should not depend on third-party availability);
  2. in-page anchors (#section) point at a real heading in the same file;
  3. reference-style links ([text][ref]) have a matching [ref]: definition.

These are the checks that catch "the doc links to a file that was renamed" —
the class of breakage a reader hits first.

Live assertions (do the documented counts match the running cluster?) are
deliberately NOT here: they need a kubeconfig. Run those with
scripts/verify-docs.sh from a machine with cluster access.

Usage:  scripts/check-docs.py [root]
Exit:   0 = clean, 1 = problems found (each printed on its own line).
"""

from __future__ import annotations

import os
import re
import sys
from pathlib import Path

SKIP_DIRS = {".git", "node_modules", "_site", ".jekyll-cache", "vendor"}
HEADING_RE = re.compile(r"^#{1,6}\s+(.*)$", re.MULTILINE)
INLINE_LINK_RE = re.compile(r"\[([^\]]*)\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")
REF_USE_RE = re.compile(r"\[([^\]]+)\]\[([^\]]+)\]")
REF_DEF_RE = re.compile(r"^\[([^\]]+)\]:\s*(\S+)", re.MULTILINE)


def slugify(heading: str) -> str:
    """GitHub-style anchor slug: lowercase, strip punctuation, spaces to dashes."""
    text = heading.strip().lower()
    text = re.sub(r"[^\w\s-]", "", text)
    return re.sub(r"\s+", "-", text)


def markdown_files(root: Path) -> list[Path]:
    out = []
    for path in sorted(root.rglob("*.md")):
        if any(part in SKIP_DIRS for part in path.parts):
            continue
        out.append(path)
    return out


def check_file(path: Path, root: Path) -> list[str]:
    problems: list[str] = []
    text = path.read_text(encoding="utf-8", errors="replace")
    rel = path.relative_to(root)

    headings = {slugify(m.group(1)) for m in HEADING_RE.finditer(text)}
    definitions = dict(REF_DEF_RE.findall(text))

    # 1. local links
    for _label, target in INLINE_LINK_RE.findall(text):
        if target.startswith(("http://", "https://", "mailto:", "#")):
            continue
        local = target.split("#", 1)[0]
        if not local:
            continue
        resolved = (path.parent / local).resolve()
        if not resolved.exists():
            problems.append(f"{rel}: broken link -> {target}")

    # 2. in-page anchors (both inline and reference style)
    for target in re.findall(r"\]\(#([^)]+)\)", text):
        if target not in headings:
            problems.append(f"{rel}: dead anchor -> #{target}")

    # 3. reference-style usage needs a definition
    for _label, ref in REF_USE_RE.findall(text):
        if ref not in definitions:
            problems.append(f"{rel}: undefined reference link -> [{ref}]")

    return problems


def main(argv: list[str]) -> int:
    root = Path(argv[1] if len(argv) > 1 else ".").resolve()
    files = markdown_files(root)
    if not files:
        print(f"no Markdown files found under {root}")
        return 1

    problems: list[str] = []
    for path in files:
        problems.extend(check_file(path, root))

    checked = len(files)
    if problems:
        print(f"FAIL — {len(problems)} problem(s) in {checked} file(s):\n")
        for problem in problems:
            print(f"  {problem}")
        return 1

    print(f"OK — {checked} Markdown file(s): links, anchors and references all resolve")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
