# Post-Mortem: Wingman Not Appearing in MCT Panel (2026-07-06)

## TL;DR

`wingman_mct.lua` shipped in a syntactically broken state across two
diagnostic commits (`67c95bf` + `2fc43ef`). The Lua file had a stray
`end) -- END pcall wrapper` at the bottom because the outer `pcall(function()`
wrapper was removed but its closing block was not. The launcher's outer
loader (`!glib_init.lua:LoadModule`) reported `[wingman_mct.lua] loaded
successfully!` **even when the file body never executed**, which is how
the broken file silently shipped.

The real fix (`795de53`) removed 24 lines of dead code. This post-mortem
documents the process gap that allowed the bug and the three-layer fix
that prevents recurrence.

## What the test suite SHOULD have caught

`tests/manual/test_mct_integration.py` line 274:
```python
result = lua.eval(f"pcall(dofile, [=[{abs_path}]=])")
if not _pcall_ok(result):
    print(f"FAIL: load error: {_pcall_err(result)}", file=sys.stderr)
    return 1
```

This `pcall(dofile)` would have caught the stray `end)` and exited 1
with the exact syntax error. It was the correct test. I just never ran
it between the diagnostic instrumentation and the fix.

## The actual failure mode (chronological)

1. **`67c95bf` diag(mct): add debug out() calls** — added `out("[Wingman DEBUG] ...")`
   calls and wrapped the entire body in `pcall(function() ... end)`.
   The test would have passed at this point because the pcall wrapper
   was syntactically complete.

2. **`2fc43ef` diag(mct): wrap each section in pcall** — added more
   instrumentation. Still syntactically valid.

3. I (incorrectly) reasoned: "I can strip the outer pcall wrapper now
   that I have the inner per-section pcalls." I deleted the opening
   `local _wingman_ok, _wingman_err = pcall(function()` line but
   **forgot to delete the closing block at the bottom:**
   ```lua
   end) -- END pcall wrapper
   if not _wingman_ok then
       out("[Wingman FATAL] body threw error: " .. tostring(_wingman_err))
       out("[Wingman FATAL] stack: " .. debug.traceback("", 2))
   end
   ```
   Result: the file was syntactically broken. A stray `end)` at the
   bottom with no matching opening `function()`.

4. I pushed the broken state. The next time the user launched TWW3,
   the launcher tried to load the file, the Lua parser hit the stray
   `end)`, and silently bailed. The outer loader's
   `[wingman_mct.lua] loaded successfully!` log fired anyway (this
   is the misleading part — the loader's pcall catches the parse
   error, and its own log line runs even on failure).

5. I also shipped `19b28a6 fix(pack): use backslash path separators`
   as a separate fix. This was a real but unrelated bug — working
   packs use 100% backslash, my pack used 100% forward slash. It
   was NOT the root cause of "Wingman not in MCT" but it was still
   a real bug that should be kept.

6. I deployed the backslash fix, the user relaunched, and it still
   didn't work. That's when I ran lupa on the deployed pack, saw
   the body was 31,015 bytes vs disk 29,917 bytes (the stale
   diagnostic instrumentation still in the deployed file), and then
   noticed the `lupa COMPILE ERROR: <eof> expected near ')'`.

7. **`795de53` fix(mct): remove stray outer-pcall closing block** —
   removed the 24 lines of dead code. Verified with lupa compile
   + `test_mct_integration.py ALL CHECKS PASS`.

## Why the tests didn't catch it

The blunt answer: **I never ran them**. Between `2fc43ef` and `795de53`
I had four opportunities to run `test_mct_integration.py` and I didn't.
I told myself "the diagnostic is obviously just `out()` calls and pcall
wrappers — syntax is obviously fine." That was the failure. Edit errors
that involve unbalanced `do`/`end`/`function`/`end)` blocks are exactly
the kind of error that requires running the test, not eyeballing it.

The deeper process gap: `test_mct_integration.py` was a **manual** test
(`tests/manual/`) not wired into CI. There was no gate that would have
blocked the broken commit.

## Three-layer fix (2026-07-06)

### Layer 1: CI gate (`.github/workflows/release.yml`)

Added the MCT integration test as a required step in the `build` job,
right after the lupa smoke gate:

```yaml
- name: MCT integration test (Lua parse + register gate)
  run: python tests/manual/test_mct_integration.py
```

This catches the bug in ~3 seconds on every PR and every tag push.

### Layer 2: Pre-build syntax gate (`scripts/lupa_smoke.py`)

Added `script/mct/settings/wingman_mct.lua` to `SOURCE_FILES` so the
existing pre-build smoke test now pcall-loads the MCT file too. If the
file is syntactically broken, the smoke test fails before the pack
is built. This is the same test that's already wired into CI, so the
two layers are independent and both will catch a regression.

### Layer 3: Pre-commit hook (`.git/hooks/pre-commit`)

Installed via `bash scripts/install_pre_commit.sh`. Runs the same two
tests locally before any commit is accepted. Catches the bug at the
point of creation, not at CI time.

## How I verified the fix actually catches the bug

Injected the exact same bug class into `wingman_mct.lua`:
```bash
echo 'end) -- INJECTED STRAY SYNTAX ERROR' >> script/mct/settings/wingman_mct.lua
bash .git/hooks/pre-commit
# Output: FAIL script/mct/settings/wingman_mct.lua: "...:608: <eof> expected near 'end'"
#         FAIL: scripts/lupa_smoke.py -- Lua syntax error in one of the source files.
#         Exit code: 1
```

Restored the file, re-ran the hook, ALL CHECKS PASS, exit code 0.
The exact same error that shipped in `67c95bf` is now caught in
~1 second by both the pre-commit hook and the CI gate.

## Lessons

1. **Edit errors involving unbalanced blocks require running the test,
   not eyeballing it.** No amount of "this is obviously fine" reasoning
   replaces a 3-second `python test_mct_integration.py`.

2. **The launcher's "loaded successfully!" log is misleading.** It fires
   from the outer loader's pcall even when the file body never ran.
   Always check for `Registering mod X` or `Creating a new option X to
   mod Y` in the log to confirm the body actually executed.

3. **Manual tests not in CI are not tests.** They are documentation.
   `tests/manual/test_mct_integration.py` was a "manual" test that
   documented the expected behavior but had no enforcement. The
   `.github/workflows/release.yml` gate makes it a real test.

4. **A pre-commit hook is cheap insurance.** 30 lines of bash. Catches
   the bug at the point of creation instead of at CI time (which is
   10-30 seconds later and requires a round trip to the user).
