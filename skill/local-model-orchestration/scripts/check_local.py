#!/usr/bin/env python3
"""Summarize a headless local-model run log (stream-json) without reading it whole.

usage: check_local.py <log.jsonl> [N]   N = how many recent actions to show (default 8)
Prints: status/result, counts (tool calls, compactions, permission denials),
context size and pace (with a warning when the run is bloating), the largest
tool results, the last N actions, test attempts from run_local.sh, and git state.
"""
import json
import os
import subprocess
import sys
import time


def main():
    path = sys.argv[1]
    n = int(sys.argv[2]) if len(sys.argv) > 2 else 8
    cwd, result, tools, compacts, denials, tests, recent = None, None, 0, 0, [], [], []
    ctx, big, retries = 0, [], 0  # latest prompt size in tokens; (chars, tool) of each tool result
    names, start = {}, None  # start: first timestamp of the latest run
    for line in open(path, encoding="utf-8", errors="replace"):
        try:
            e = json.loads(line)
        except ValueError:
            continue
        t, sub = e.get("type"), e.get("subtype")
        if start is None and e.get("timestamp"):
            start = e["timestamp"]
        if t == "system" and sub == "init":
            # A log can hold several runs (run scripts append): count only the latest.
            cwd, result, tools, compacts, denials, tests, recent = e.get("cwd"), None, 0, 0, [], [], []
            ctx, big, retries, names, start = 0, [], 0, {}, None
        elif t == "system" and sub == "compact_boundary":
            compacts += 1
        elif t == "system" and sub == "api_retry":
            retries += 1
        elif t == "system" and sub == "permission_denied":
            denials.append(e.get("message", ""))
        elif t == "orchestrator":
            tests.append(e)
        elif t == "result":
            result = e
        elif t == "user":
            for x in (e.get("message") or {}).get("content", []) or []:
                if isinstance(x, dict) and x.get("type") == "tool_result":
                    c = x.get("content")
                    size = len(c) if isinstance(c, str) else len(json.dumps(c))
                    big.append((size, names.get(x.get("tool_use_id"), "?")))
        elif t == "assistant":
            u = e["message"].get("usage") or {}
            if u:
                ctx = (u.get("input_tokens") or 0) + (u.get("cache_read_input_tokens") or 0)
            for x in e["message"].get("content", []):
                if x.get("type") == "tool_use":
                    tools += 1
                    names[x.get("id")] = "%s %s" % (x["name"], json.dumps(x.get("input"))[:80])
                    recent.append("TOOL %s %s" % (x["name"], json.dumps(x.get("input"))[:140]))
                elif x.get("type") == "text" and x["text"].strip():
                    recent.append("SAY  " + x["text"].strip().replace("\n", " ")[:140])
    age = time.time() - os.path.getmtime(path)
    print("log last written %.0f min ago" % (age / 60))
    if result:
        print("RESULT %s, turns %s, %s min" % (result.get("subtype"), result.get("num_turns"),
                                              round(result.get("duration_ms", 0) / 60000)))
        print(str(result.get("result"))[:2500])
    else:
        print("RUNNING (no result event yet)")
    print("tool calls %d | compactions %d | permission denials %d | API retries %d"
          % (tools, compacts, len(denials), retries))
    st = os.stat(path)
    began = getattr(st, "st_birthtime", st.st_ctime)
    if start:
        from datetime import datetime
        began = datetime.fromisoformat(start.replace("Z", "+00:00")).timestamp()
    hours = max((st.st_mtime - began) / 3600, 1e-6)
    print("context %dK tokens (latest step) | pace %.0f tool calls/hour" % (ctx / 1000, tools / hours))
    commits = 0
    if cwd:
        r = subprocess.run(["git", "log", "--oneline", "--since=%d.minutes.ago" % (hours * 60 + 1)],
                           cwd=cwd, capture_output=True, text=True)
        commits = len(r.stdout.splitlines())
    warn = []
    if ctx > 60000:
        warn.append("context over 60K: generation slows and steps get longer")
    if hours > 0.75 and tools / hours < 20:
        warn.append("under 20 tool calls/hour")
    if retries >= 3:
        warn.append("%d API retries: steps are being cancelled and redone" % retries)
    if hours > 1.5 and commits == 0:
        warn.append("no commits after %.1f h" % hours)
    if warn:
        print("WARNING: " + "; ".join(warn) + ". See SKILL.md 'Context bloat'.")
    if big:
        print("largest tool results:", "; ".join("%dK %s" % (n // 1000, w) for n, w in sorted(big)[-3:][::-1]))
    for d in sorted(set(denials)):
        print("  denied:", d[:120])
    for t in tests:
        print("  tests attempt %s -> rc %s" % (t.get("attempt"), t.get("tests_rc")))
    print("--- last actions")
    for r in recent[-n:]:
        print(r)
    if cwd:
        print("--- git (%s)" % cwd)
        for cmd in (["git", "log", "--oneline", "-6"], ["git", "status", "--short"]):
            print(subprocess.run(cmd, cwd=cwd, capture_output=True, text=True).stdout.rstrip()[:1500])


if __name__ == "__main__":
    main()
