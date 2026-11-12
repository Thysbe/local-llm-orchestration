# Rules for every round

Every brief points here. The local model reads this once, then the brief. Adapt the test and build commands to your project.

## How to work

- The brief says what to build and when you're done. How to build it is up to you.
- **Do only this round's brief.** If you spot other work, write it in your round's notes file as an open item and move on. Stop when the brief's "Done when" list is met.
- **Commit after each piece that works**, with tests passing (`python3 -m unittest discover tests`).
- **If you're stuck** on one thing for more than a few attempts: commit what works, write the open question in your round's notes file, and move on.
- Where the source data or code disagrees with a brief, the source wins. Write down what the brief got wrong.
- Don't rewrite working parts that the brief doesn't mention.

## Keep your context small (important)

Each step re-reads your whole conversation, so long tool outputs make every later step slower.
- Never print more than ~60 lines from one command. Pipe through `head`, use `jq` with `[:5]` or `length`, and use Grep with `head_limit`.
- Read source files with an `offset`/`limit` line range. Never read large data files, generated output, or saved tool-result files whole.
- Read only the `notes/` files the brief names. A guard refuses any read of a file over 15K without a line range (at most 400 lines). Grep first, then read the range.
- **Change only the files the brief lists** under "Files you may change". If something else needs changing, write it in your notes file as an open item.
- Use literal shell commands without shell variables (they are blocked in headless mode).
- Throwaway scripts go in the repo root as `_q*.py` (gitignored). Don't commit them.

## Checks before you finish

- The test suite passes and the build runs.
- If you changed front-end JavaScript: run `node --check` on it **and** run the changed functions against real data with `node`. Syntax checks miss runtime bugs.
- Write `notes/taskN.md` for your round, dated, with what the brief's "Done when" asks for and anything the next round should know. Add one line for it to the top of the `NOTES.md` index.
