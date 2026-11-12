# Local LLM Orchestration

Split AI coding work between a cloud model and a local one: **Claude plans and reviews, a local model implements.**

Cloud models are good at judgment but expensive per token. Implementation work (reading code, writing it, iterating against tests) uses most of the tokens and needs less judgment. This project moves that part to a local model ([Qwen](https://ollama.com/library) on [Ollama](https://ollama.com)), run headlessly through [Claude Code](https://docs.claude.com/en/docs/claude-code), while the cloud session only writes the brief and reviews the diff.

It's packaged as a Claude Code **skill**, plus a runner, a context guard and an unattended **nightly scheduler**.

## How it works

```
 Cloud Claude (orchestrator)                       Local model (Qwen 27B via Ollama)
 ───────────────────────────                       ─────────────────────────────────
 1. Route: is this local-model work?
 2. Research cheaply, write a precise brief  ──►   3. Implement against the brief,
    (files you may change, known facts,               commit after each working piece
    worked examples, "done when" checklist)           ├─ read guard blocks whole-file reads
                                                      └─ tests run; on failure, retry locally
                                              ◄──  4. Escalate only if still failing (exit 3)
 5. Review the diff, not the repo
 6. Write notes for the next round
```

- **Route the work.** Boilerplate, specified features, tests and mechanical refactors go local. Architecture, non-obvious debugging, security-sensitive code and review stay in the cloud. The full table is in [`SKILL.md`](skill/local-model-orchestration/SKILL.md).
- **Tiered escalation.** After the local model finishes, `TEST_CMD` runs. On failure the local model gets the output and retries in the same session, up to `TRIES` times. Only then does the run hand back to Claude.
- **Small, checkable rounds.** A brief covers one or two pieces of work taking 2-5 hours, and carries the facts already known so the model writes code instead of re-researching. See the [brief template](skill/local-model-orchestration/references/brief-template.md).

## What's in here

| Path | What it does |
|---|---|
| [`skill/local-model-orchestration/SKILL.md`](skill/local-model-orchestration/SKILL.md) | The playbook Claude follows: routing, patterns, how to run and review a round, known pitfalls |
| [`skill/.../scripts/run_local.sh`](skill/local-model-orchestration/scripts/run_local.sh) | Headless runner: preflight checks (Ollama up, model loads, context >= 100K), Claude Code pointed at Ollama with a restricted tool list, test-gated retries, exit codes for escalation |
| [`skill/.../scripts/guard_read.py`](skill/local-model-orchestration/scripts/guard_read.py) | PreToolUse hook that refuses whole-file reads of large files and tells the model to Grep and read a range instead |
| [`skill/.../scripts/check_local.py`](skill/local-model-orchestration/scripts/check_local.py) | Summarizes a run log without reading it whole: result, tool-call pace, context size, retries, denials, git state, and warnings when a run is bloating or stalling |
| [`skill/.../references/brief-template.md`](skill/local-model-orchestration/references/brief-template.md) | Template for a round's brief |
| [`nightly/nightly.sh`](nightly/nightly.sh) | Unattended runner: works through a queue of briefs from midnight, only starting rounds that should finish by morning |
| [`nightly/com.example.local-llm-nightly.plist`](nightly/com.example.local-llm-nightly.plist) | launchd job to start it at 00:00 |
| [`examples/ROUND_RULES.md`](examples/ROUND_RULES.md) | Shared rules every brief points to |

## Quick start

Requirements: macOS, [Ollama](https://ollama.com), [Claude Code](https://docs.claude.com/en/docs/claude-code), Python 3. Developed on an M-series Mac with 36GB of memory.

```bash
ollama pull qwen3.8:27b
# Set the context slider in Ollama Settings to 128K (Claude Code's auto-compact needs at least ~100K).

# Install the skill
cp -R skill/local-model-orchestration ~/.claude/skills/

# Run one round on a brief in your repo
TEST_CMD="python3 -m unittest discover tests" TRIES=2 \
  ~/.claude/skills/local-model-orchestration/scripts/run_local.sh ~/Dev/my-project TASK1.md

# Check on it (the runner prints the log path first)
python3 ~/.claude/skills/local-model-orchestration/scripts/check_local.py <log.jsonl>
```

Inside a Claude Code session, the skill triggers on requests like "have Qwen do it" or "run a round". Claude then writes the brief, launches the run and reviews the result.

**Nightly runs:** copy `nightly/` somewhere, fill in `nightly.conf` (from `nightly.conf.example`) and `queue.txt`, put the briefs next to it, and install the plist. Create a file named `STOP` in that folder to pause; delete it to resume. Each night it:
- skips the night if a round is still running, the Mac is on battery or Ollama's context is too low
- halts the queue if the previous round has no success result, the tests fail or tracked files are uncommitted
- never pushes

## Results so far

Used to build a personal Python/JavaScript data dashboard, with the local model doing the implementation:

- ~15 multi-hour rounds, ~100 commits, and a test suite of 255 tests written by the local model
- Unattended overnight rounds, with the cloud session used only for briefs and review
- Verification rounds also run locally: the model re-checked its own earlier numbers against the source and corrected an overstated result

## Lessons learned

- **Overnight runs that did nothing.** Two nights produced no code. Ollama's log showed a request cancelled every ~15 minutes, and `pmset -g log` showed why: the Mac was in maintenance sleep, waking briefly every 15 minutes, and Claude Code gave up on and resent each long step. Fix: wrap the run in `caffeinate -i -s` and require AC power.
- **Context bloat.** The model read 20-30K-character notes files whole at the start of every round, because a project instruction file told it to, and that file is read before the brief. Asking it not to wasn't enough. What worked was three layers: a hook that enforces the rule, small per-round notes files behind a short index, and instructions that agree with each other.
- **Research doesn't belong in the round.** A round that starts with "find out how X works" can burn hours before writing code. The orchestrator does the research cheaply and puts the facts in the brief.
- **Don't let the model guess interfaces.** A round segfaulted on guessed native-library bindings. Putting the exact signatures in the brief fixed it.
- **Scheduler edge cases.** A round started after the morning cutoff because the time-left check didn't treat "past the end hour" as zero time left. It's handled now.

## License

MIT
