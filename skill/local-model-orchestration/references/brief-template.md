# Task N: <short title>

Read CLAUDE.md first. Then read only these notes files: <notes/taskX.md, docs/Y.md>. Don't open other notes files. <One line on which source wins on conflicts, e.g. "Where the code disagrees with this brief, the code wins.">

## How to work

- You decide how to implement this. The goals and the "Done when" list are what matter.
- **Commit after each piece that works**, with tests passing (`<test command>`).
- **Read only what you need.** Use Grep, then Read with a line range. Never read <big files/dirs> whole.
- **Keep your context small.** Every step gets slower as the conversation grows. Never print more than ~60 lines from one command (pipe through `head`, use `jq` with `[:5]` or `length`, use Grep's `head_limit`). Read files with an `offset`/`limit` range, including the notes files: Grep them for the heading you need. Never Read saved tool-result files whole.
- Use literal shell commands without shell variables. Commands with variables are blocked.
- **If you're stuck** on one thing for more than a few attempts, or it needs information you don't have: commit what works, write the open question in `notes/taskN.md` under a dated heading, and move on.
- Write what future rounds should know (findings, gotchas, decisions) in `notes/taskN.md`, and add one line for it to the `NOTES.md` index.
- Don't rewrite working parts that this brief doesn't mention.

## Files you may change

- <file 1, file 2, tests/test_x.py, notes/taskN.md (new)>. Anything else: write it in your notes file as an open item instead.

## Already known (don't re-research)

- <Facts from earlier rounds or the orchestrator's own checks, with file:line citations, so the model starts writing code instead of re-reading the source.>

## 1. <First piece> (do first)

- What to change, and where: name the files and functions.
- The exact formula, rule or behaviour, with one worked example and its expected number or output.
- Tests to add: the specific cases.
- **Commit** before starting part 2.

## 2. <Next piece>

...

## Done when

- [ ] <Checkable outcome 1, e.g. "test X passes", "dashboard shows column Y">
- [ ] <Checkable outcome 2>
- [ ] Tests pass. `notes/taskN.md` exists and the `NOTES.md` index has a line for it.
