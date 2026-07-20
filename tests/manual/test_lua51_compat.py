#!/usr/bin/env python3
"""Lua 5.1 source-level compatibility test.

TWW3 runs Lua 5.1. Lupa 2.8 runs Lua 5.5 by default, so the runtime
masks 5.1-incompatible code. This test scans every .lua source file
for known 5.2+ features (goto, ::label::, bit32, //, etc.) and
fails if any are present.

This is the source-level equivalent of running a real Lua 5.1
interpreter. It catches the class of bugs that the lupa smoke test
cannot (e.g. the goto-in-Lua-5.1 bug fixed in PR #8 would have
been caught here).

Run from the repo root:
    python3 tests/manual/test_lua51_compat.py
"""
from __future__ import annotations

import os
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def _run() -> int:
    sys.path.insert(0, os.path.join(REPO_ROOT, "scripts"))
    import runtime_compat  # type: ignore

    # Scan the script/ directory (where the mod Lua source lives)
    script_dir = os.path.join(REPO_ROOT, "script")
    results = runtime_compat.scan_directory(script_dir)
    if results:
        total = sum(len(v) for v in results.values())
        print(f"FAIL: {total} Lua 5.2+ feature(s) detected in {len(results)} file(s) under {script_dir}")
        for path, findings in sorted(results.items()):
            rel = os.path.relpath(path, REPO_ROOT)
            for line_num, desc, snippet in findings:
                print(f"  {rel}:{line_num}: {desc}")
                print(f"      | {snippet}")
        return 1
    print(f"OK: no Lua 5.2+ features detected in {script_dir}")
    print("    (goto, ::label::, bit32, //, loadstring, string.pack, string.unpack, table.unpack)")

    # Also run the scanner via the CLI to verify it works
    print("\nVerifying CLI interface:")
    import subprocess
    res = subprocess.run(
        [sys.executable, "scripts/runtime_compat.py", script_dir],
        cwd=REPO_ROOT, capture_output=True, text=True,
    )
    if res.returncode != 0:
        print(f"FAIL: CLI exit {res.returncode}")
        print(f"  stdout: {res.stdout!r}")
        print(f"  stderr: {res.stderr!r}")
        return 1
    print(f"  OK: CLI exits 0: {res.stdout.strip()}")

    # Sanity check: synthetic 5.2+ source IS detected
    print("\nSanity: synthetic 5.2+ source IS detected")
    with open("/tmp/_lua52_test.lua", "w") as f:
        f.write("-- synthetic 5.2+ file\n")
        f.write("function go() goto skip end\n")
        f.write("::skip::\n")
        f.write("local x = 5 // 2\n")
    findings = runtime_compat.scan_file("/tmp/_lua52_test.lua")
    if len(findings) < 2:
        print(f"FAIL: expected >=2 findings on synthetic 5.2+ source, got {len(findings)}")
        return 1
    print(f"  OK: {len(findings)} findings on synthetic 5.2+ source")

    print("\nALL LUA-5.1-COMPAT CHECKS PASS")
    return 0


if __name__ == "__main__":
    sys.exit(_run())
