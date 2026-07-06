#!/usr/bin/env bash
# Install the pre-commit hook. Idempotent — safe to re-run.
set -e
REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK="$REPO_ROOT/.git/hooks/pre-commit"
SOURCE="$REPO_ROOT/scripts/pre-commit"

if [ ! -f "$SOURCE" ]; then
    echo "FAIL: $SOURCE not found" >&2
    exit 1
fi

cp "$SOURCE" "$HOOK"
chmod +x "$HOOK"
echo "Installed: $HOOK"
echo "Test it:   $HOOK  (should pass; will fail if Lua syntax is broken)"
