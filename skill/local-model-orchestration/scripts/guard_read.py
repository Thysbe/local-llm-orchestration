#!/usr/bin/env python3
"""PreToolUse hook for local-model runs: refuse whole-file Reads of big files.

A Read is refused when the file is larger than READ_MAX_BYTES (default 15000)
and no `limit` was given, or the limit is above READ_MAX_LINES (default 400).
The refusal message tells the model to use Grep or a line range instead, so it
can correct itself. Anything unexpected (bad input, missing file) is allowed
through, so the guard never breaks a run.
"""
import json
import os
import sys

MAX_BYTES = int(os.environ.get("READ_MAX_BYTES", "15000"))
MAX_LINES = int(os.environ.get("READ_MAX_LINES", "400"))
# Images and PDFs are read differently; leave them alone.
SKIP_EXT = {".png", ".jpg", ".jpeg", ".gif", ".webp", ".pdf", ".ipynb"}


def deny(reason):
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": reason,
    }}))
    sys.exit(0)


def main():
    try:
        event = json.load(sys.stdin)
        if event.get("tool_name") != "Read":
            return
        inp = event.get("tool_input") or {}
        path = inp.get("file_path") or ""
        if os.path.splitext(path)[1].lower() in SKIP_EXT:
            return
        size = os.path.getsize(path)
    except Exception:
        return
    if size <= MAX_BYTES:
        return
    limit = inp.get("limit")
    if isinstance(limit, int) and limit <= MAX_LINES:
        return
    name = os.path.basename(path)
    deny(
        f"{name} is {size // 1000}K, too big to read whole (it would fill your context "
        f"and slow every later step). Use Grep on it to find the part you need "
        f"(e.g. a heading or function name, with -n and head_limit), then Read it "
        f"with offset and a limit of at most {MAX_LINES} lines."
    )


if __name__ == "__main__":
    main()
