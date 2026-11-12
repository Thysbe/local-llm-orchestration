---
name: local-model-orchestration
description: This skill should be used when work should be split between cloud Claude (planning, review, hard debugging) and a local Ollama model such as Qwen (bulk implementation) to save API costs. Triggers include "have Qwen do it", "use the local model", "orchestrate Qwen", "run a round", "save tokens/API costs", "Claude plans, local executes", or resuming or checking a headless local-model run.
version: 1.0.0
---

# Local model orchestration (Claude plans and reviews, local model implements)

Cloud Claude is the **orchestrator**. Its work is small in tokens but needs judgment: choosing what to do, writing a precise brief, launching the local model, and reviewing the diff. The **local model** (default `qwen3.8:27b` via Ollama) does the token-heavy part, such as reading code, writing it and iterating against tests. It runs headless through Claude Code, pointed at Ollama.

The goal is fewer cloud tokens. Don't do heavy implementation in the cloud session that the local model could do.

## 1. Route the work

| Give to the local model | Keep in Claude |
|---|---|
| Boilerplate, scaffolding, DTOs, mappers, CRUD | Architecture and design decisions |
| Implementing a precise spec or step-by-step plan | Debugging where the cause isn't obvious |
| Unit tests for well-understood functions | Changes that need reasoning across many files |
| Mechanical refactors (rename, extract, apply a stated pattern) | Security-sensitive code, concurrency, anything subtle |
| Docstrings, comments, commit messages, format conversions | Reviewing what the local model produced |
| First-pass file summaries, log or stack-trace triage | A task the local model has already failed 1–2 times |

Middle-difficulty work that doesn't suit local can go to a cheaper Claude tier, for example an Agent with `model: "haiku"`, instead of the top model.

## 2. Patterns (use them together)

1. **Claude plans, local executes.** Claude writes a short, precise brief (see `references/brief-template.md`). The output is small, so it's cheap. A weak executor drifts, so keep each step small and checkable, and make it commit after each piece.
2. **Tiered escalation.** The local model attempts the task, then `TEST_CMD` runs. On failure the local model gets the failing output and retries, up to `TRIES` times in the same session. Only then does the run escalate to Claude (exit code 3). `scripts/run_local.sh` does this loop. It needs an automatic pass/fail signal (tests, build, linter).
3. **Pre-filter context.** When Claude does need to look at something, use grep, `jq`, `git diff --stat` and line-range reads, never whole large files. Give the local model the same rule in the brief: it otherwise reads whole files and fills its context.
4. **Claude reviews the diff, not the repo.** Start with `git log --oneline` and `git diff --stat <base>..HEAD`, then read only the hunks that matter. Spot-check numbers against the source data.

## 3. Keep the local model's scope small

A local model reads whole files whenever it can, and asking it not to in the brief isn't enough. On 2026-11-05 Qwen read a 27K NOTES.md and a 20K MECHANICS.md at the start of every round because the project's CLAUDE.md said "read NOTES.md at the start", and CLAUDE.md is read before the brief. Use all three layers:

1. **Enforce it (built in).** `run_local.sh` installs `scripts/guard_read.py` as a PreToolUse hook. It refuses any Read of a file over `READ_MAX_BYTES` (15000) without a `limit` of at most `READ_MAX_LINES` (400), and tells the model to Grep and read a range instead, so it corrects itself. For files that must never be opened, set `READ_DENY="data/big.json;output/**"`, which become `Read(./…)` deny rules. A project with its own launcher script should pass the same `--settings` hook JSON (copy it from `run_local.sh`).
2. **Keep handoff docs small.** Don't let one notes file grow. Use a short index (`NOTES.md`, one line per round) plus one file per round (`notes/task8c.md`), and split reference docs by topic (`docs/auth.md`). Each file should be 2–5K, so even a whole read is cheap.
3. **Make the instructions agree.** Check that the project's CLAUDE.md doesn't say "read X at the start" for any big file. CLAUDE.md should say "read only the notes files your brief names". Each brief lists the exact notes files to read and the files it may change, and its "Already known" section carries the facts, so the model has little reason to go looking.

**Scope of changes.** The brief's "Files you may change" list is the round's boundary. At review, compare `git diff --stat <base>..HEAD` against it, and question any file outside it.

## 4. Run a round

**Preflight (once per boot).** The local model's context must be at least about 100K, because Claude Code's auto-compact can't work below that.
- Check it with `curl -s localhost:11434/api/ps`, which shows `context_length` for loaded models. `run_local.sh` checks this and refuses to start if it's too low.
- To fix it on macOS, the permanent option is the context slider in Ollama Settings. For this boot only, run `launchctl setenv OLLAMA_CONTEXT_LENGTH 131072; launchctl setenv OLLAMA_KEEP_ALIVE 30m` and then restart Ollama.
- Restarting Ollama: `osascript -e 'quit app "Ollama"'` fails with "User canceled" because of a confirmation dialog. Use `pkill -TERM -x Ollama; pkill -TERM -f 'ollama serve'`, then `open -a Ollama`.
- Claude Code doesn't know local model names. Set `CLAUDE_CODE_MAX_CONTEXT_TOKENS=131072`, which the script does, or Claude Code assumes 200K.

**Steps:**
1. Read the project's handoff notes first, such as `NOTES.md` or `CLAUDE.md`, and any memory for the project.
2. **Size the round small:** one or two parts, with research already done. A round that starts with "find out how X works" across several systems can burn hours before any code is written, so do that research yourself, cheaply with Grep, or as its own short round, and put the facts in the brief's "Already known" section. Write the brief into the repo, for example `TASK7.md`, from `references/brief-template.md`, and commit it. When resuming an interrupted round, add a dated "resume state" section to the notes file instead, saying what's done (with commit hashes), what's half done and what's next. Without it the model redoes finished work.
3. Branch first if the work is risky, or when the user wants to review before merging.
4. Launch it in the background with the Bash tool's `run_in_background`. A round takes 30 minutes to 5 hours.
   ```bash
   TEST_CMD="python3 -m unittest discover tests" TRIES=2 \
     ~/.claude/skills/local-model-orchestration/scripts/run_local.sh <repo> TASK7.md
   ```
   - Env options: `MODEL` (default `qwen3.8:27b`), `TRIES` (default 2), `TEST_CMD`, `EXTRA_TOOLS` (`;`-separated, for example `Bash(npm:*);Bash(dotnet:*)`), `READ_DENY` (`;`-separated paths/globs the model may never Read), `READ_MAX_BYTES`/`READ_MAX_LINES` (read-guard limits), `LOG_DIR` (default `~/.local/state/local-model-runs`).
   - The script prints the log path first.
   - Exit codes: 0 means done (tests pass, if given). 2 means preflight failed. 3 means escalate (still failing after `TRIES`, with the failing output printed).
5. **Monitoring.** The background task's own output stays quiet, because the model writes to the log. A "no new output" check-in is therefore not a hang. Check `scripts/check_local.py <log>`. It shows the tool-call count, the latest actions, permission denials and compactions, plus the repo's recent commits and status. Do one early check at about 30–45 minutes: there should be commits or code changes, and no WARNING line. If there's a warning, act on it (see "Context bloat and slow runs") instead of letting the run go on overnight. Otherwise make one check, end the turn, and wait for the completion notification instead of polling.
6. **Review** (pattern 4). Run the tests yourself. Read the model's notes and its final message, which is in `check_local.py` output. Fix small things directly. For anything bigger, write a follow-up brief and run again, rather than doing heavy work in the cloud.
7. Update the project's notes and memory with what the next round needs to know.

## 5. Known pitfalls

- **Context bloat and slow runs.** Seen on 2026-11-04 on a real project: two runs made ~7–9 tool calls an hour and wrote no code in 9 hours. `check_local.py` now warns about the signs:
  - **Context over ~60K tokens early.** The model read `NOTES.md`, `MECHANICS.md` and big source files whole (24–33K characters each). Ollama's prefix cache *does* work (`server.log` shows `cache hit … left=1`), so the cost isn't re-reading the prompt. Generation gets slower as context grows, and the model thinks longer.
  - **Steps cancelled after ~15 minutes.** Ollama's `~/.ollama/logs/server.log` showed `Request terminated error="context canceled"` 29 times, one every 15–17 minutes, and the run log showed `api_retry` with `error: unknown`. Claude Code had given up on a long step and resent it, throwing away the work. **Cause (confirmed 2026-11-05): the Mac was asleep.** `pmset -g log` showed it in Maintenance Sleep, waking ("DarkWake") for ~45s every ~15 min, and each cancel lined up with a wake. Tell-tale: Ollama's `took=` (monotonic clock, excludes sleep) says 16s–90s while the wall-clock gap is ~15 min. **Fix:** both run scripts now wrap `claude` in `caffeinate -i -s`. This only holds on AC power and with the lid open (or clamshell with an external display).
  - **What to do:** stop the run (`pkill -TERM -f "claude -p Read CLAUDE.md and <brief>"`). Pull its findings from the log: its long `thinking`/`text` blocks usually hold a good summary. Check them, write them into the notes as a dated "resume from here" section, then relaunch with a smaller brief.
  - **Diagnose with:** `grep -E 'canceled|took=' ~/.ollama/logs/server.log | tail`, count `api_retry` in the run log, and check `pmset -g log | grep -E ' (Sleep|DarkWake) '` for the run's time window.

- **Appended logs.** Run scripts append (`>>`), so a resumed or retried round shares one log with earlier attempts. `check_local.py` now counts only the run after the last `init` event (fixed 2026-11-09, after an old run's stats raised a false bloat warning).
- **Scratchpad is temporary.** Anything in `/private/tmp/...` (the session scratchpad) is wiped on reboot. Keep briefs, scripts and logs in the repo or in `LOG_DIR`.
- **Shell variables get blocked.** Headless permission checks refuse Bash commands that contain shell variables ("A variable in this command can't be checked before it runs"). That's harmless, because the model works around it. Tell the model in the brief to use literal commands.
- **Whole-file reads.** The local model reads whole large files, then compacts its context. The read guard (section 3) now refuses these. Also name the specific files and functions in the brief.
- **Connector warning.** Every run logs "claude.ai connectors are disabled because ANTHROPIC_API_KEY…". This is expected.
- **Unrecognized model.** Every run logs `[claude-code:unrecognized_model]`. This is also expected.
- **Tool limits.** The allowed tools are limited, with no web access and `acceptEdits`. Add project build and test commands through `EXTRA_TOOLS` if they aren't run via `python3` or `git`.
