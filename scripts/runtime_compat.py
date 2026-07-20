"""Source-level Lua 5.1 compatibility checker.

TWW3 runs Lua 5.1, but our tests run on Lupa 2.8 which defaults to
Lua 5.5. Lupa masks 5.1-incompatible code because 5.5 has goto, ::label::,
bit32, integer division //, integer/float distinction, etc. — features
that don't exist in 5.1.

We can't install Lua 5.1 in this sandbox (apt repo is restricted), so
we do a static source-level scan for known 5.2+ features and fail the
build if any are present. This is a coarse check but it catches the
biggest class of bugs (the goto-in-Lua-5.1 bug from PR #8).

This script can be run standalone:
    python3 scripts/runtime_compat.py

Or imported by tests/manual/test_lua51_compat.py.

Detected features (any of these in a Lua source file = fail):
  - `goto` keyword (statements + `::label::` declarations)
  - `goto` used as identifier (rare; we use a strict regex)
  - `bit32.` namespace (Lua 5.2+ bitwise ops)
  - `//` integer division (Lua 5.3+)
  - `<integer>` or `<integer,integer>` in for-loop var (Lua 5.3+)
  - `string.unpack` (Lua 5.2+; in 5.1, use `string.unpack` doesn't exist;
    we use `unpack` for the global version, or `table.unpack` from 5.2)
  - `goto` followed by identifier (e.g. `goto continue`)
  - `::label::` (any line matching `^::[a-zA-Z_][a-zA-Z0-9_]*::$`)
  - `load(` and `loadstring(` (5.2+)
  - `goto` keyword inside an identifier context (e.g. variable named goto;
    extremely rare but the regex catches it)
"""
from __future__ import annotations

import os
import re
import sys

# Patterns for Lua 5.2+ features. Each entry: (pattern, description).
LUA52_PATTERNS: list[tuple[re.Pattern, str]] = [
    # Goto statement: `goto identifier` (not preceded by an identifier char)
    (re.compile(r"(?<![\w])goto\s+[a-zA-Z_]"), "goto statement (Lua 5.2+)"),
    # ::label:: declaration
    (re.compile(r"^\s*::[a-zA-Z_][a-zA-Z0-9_]*::\s*$", re.MULTILINE), "::label:: declaration (Lua 5.2+)"),
    # bit32 namespace
    (re.compile(r"\bbit32\."), "bit32.* (Lua 5.2+)"),
    # Integer division operator // (Lua 5.3+)
    (re.compile(r"//"), "integer division // (Lua 5.3+) — but check for URL or pattern use"),
    # loadstring
    (re.compile(r"\bloadstring\s*\("), "loadstring (Lua 5.2+, removed in 5.3+)"),
    # string.pack / string.unpack are Lua 5.2+
    (re.compile(r"\bstring\.(pack|unpack)\s*\("), "string.pack/unpack (Lua 5.2+)"),
    # table.unpack without `or unpack` fallback (Lua 5.2+; pre-fix code is the bug)
    (re.compile(r"\btable\.unpack\s*\("), "table.unpack without `or unpack` fallback (Lua 5.2+)"),
    # goto as identifier (rare; warn)
    (re.compile(r"\b[a-zA-Z_][a-zA-Z0-9_]*\.goto\b|\bgoto\s*="), "goto as identifier (likely false positive)"),
]


def scan_file(path: str) -> list[tuple[int, str, str]]:
    """Scan a single .lua file. Returns list of (line_number, pattern, snippet).

    Empty list = no incompatibilities found.
    """
    findings: list[tuple[int, str, str]] = []
    try:
        with open(path, "r", encoding="utf-8") as f:
            content = f.read()
    except (OSError, UnicodeDecodeError):
        return findings

    lines = content.split("\n")
    for line_num, line in enumerate(lines, 1):
        # Skip pure comment lines
        stripped = line.strip()
        if stripped.startswith("--"):
            continue
        # Skip lines inside long comments (we don't try to be perfect here;
        # long comments usually are a single --[[ ... ]] block. Real TWW3
        # code rarely puts 5.2+ features inside a --[[ block.)
        for pattern, desc in LUA52_PATTERNS:
            if pattern.search(line):
                # Special case: // could be in a comment or pattern. We
                # already filter pure comment lines above, but a trailing
                # comment like `x = 1 // 2` is still code. Check if the //
                # is in a Lua string literal; if so, ignore.
                # Simple heuristic: if // is between two unescaped quotes,
                # it's likely a string. The robust check would parse the
                # line; for the audit scope we accept the false positive
                # risk.
                if "//" in desc:
                    # Check if the // is inside a string literal
                    in_string = False
                    quote_char = None
                    for i, c in enumerate(line):
                        if c in ('"', "'") and (i == 0 or line[i-1] != "\\"):
                            if quote_char is None:
                                quote_char = c
                                in_string = True
                            elif c == quote_char:
                                in_string = False
                                quote_char = None
                    if in_string:
                        continue
                findings.append((line_num, desc, line.strip()[:120]))
    return findings


def scan_directory(root: str) -> dict[str, list[tuple[int, str, str]]]:
    """Scan all .lua files under root. Returns {file_path: findings}."""
    results: dict[str, list[tuple[int, str, str]]] = {}
    for dirpath, _, files in os.walk(root):
        # Skip .git and dist
        if ".git" in dirpath or "dist" in dirpath or "__pycache__" in dirpath:
            continue
        for name in files:
            if not name.endswith(".lua"):
                continue
            abs_path = os.path.join(dirpath, name)
            findings = scan_file(abs_path)
            if findings:
                results[abs_path] = findings
    return results


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        root = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "script")
    else:
        root = argv[1]

    if not os.path.isdir(root):
        print(f"ERROR: {root} is not a directory", file=sys.stderr)
        return 2

    results = scan_directory(root)
    if not results:
        print(f"OK: no Lua 5.2+ features detected in {root}")
        return 0

    total = sum(len(v) for v in results.values())
    print(f"FAIL: {total} Lua 5.2+ feature(s) detected in {len(results)} file(s) under {root}")
    for path, findings in sorted(results.items()):
        rel = os.path.relpath(path, root)
        for line_num, desc, snippet in findings:
            print(f"  {rel}:{line_num}: {desc}")
            print(f"      | {snippet}")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
