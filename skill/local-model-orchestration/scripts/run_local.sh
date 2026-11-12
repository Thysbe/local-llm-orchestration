#!/bin/bash
# Run a local Ollama model headlessly through Claude Code on a brief, with tiered escalation.
# usage: run_local.sh <repo-dir> <brief.md (relative to repo)>
# env:   MODEL (qwen3.8:27b)  TRIES (2)  TEST_CMD ("")  EXTRA_TOOLS ("a;b")  LOG_DIR (~/.local/state/local-model-runs)
#        READ_DENY ("data/big.json;output/**": never readable)  READ_MAX_BYTES (15000)  READ_MAX_LINES (400)
# exit:  0 done | 1 usage | 2 preflight failed | 3 escalate to Claude (tests still failing)
set -u
REPO=${1:?usage: run_local.sh <repo> <brief.md>}; BRIEF=${2:?usage: run_local.sh <repo> <brief.md>}
MODEL=${MODEL:-qwen3.8:27b}; TRIES=${TRIES:-2}; TEST_CMD=${TEST_CMD:-}
LOG_DIR=${LOG_DIR:-$HOME/.local/state/local-model-runs}; mkdir -p "$LOG_DIR"
cd "$REPO" || exit 1
[ -f "$BRIEF" ] || { echo "brief not found: $REPO/$BRIEF"; exit 1; }
LOG="$LOG_DIR/$(basename "$PWD")-$(basename "$BRIEF" .md)-$(date +%Y%m%d-%H%M%S).jsonl"
echo "LOG $LOG"

# Preflight: Ollama up, model loads, context >= 100K (Claude Code's auto-compact can't go lower).
curl -sf localhost:11434/api/version >/dev/null || { echo "PREFLIGHT: Ollama is not running (open -a Ollama)"; exit 2; }
curl -sf localhost:11434/api/generate -d "{\"model\":\"$MODEL\",\"prompt\":\"hi\",\"stream\":false,\"options\":{\"num_predict\":1}}" >/dev/null \
  || { echo "PREFLIGHT: model $MODEL failed to load (ollama list)"; exit 2; }
CTX=$(curl -sf localhost:11434/api/ps | python3 -I -c 'import json,sys; m=sys.argv[1]; print(next((x.get("context_length",0) for x in json.load(sys.stdin)["models"] if x["name"]==m),0))' "$MODEL")
if [ "${CTX:-0}" -lt 100000 ]; then
  echo "PREFLIGHT: $MODEL loaded with context $CTX (< 100000). Set the Ollama Settings context slider, or"
  echo "  launchctl setenv OLLAMA_CONTEXT_LENGTH 131072 and restart Ollama (see SKILL.md)."; exit 2
fi

TOOLS=(Read Write Edit Glob Grep "Bash(python3:*)" "Bash(jq:*)" "Bash(git:*)" "Bash(mkdir:*)" "Bash(ls:*)" "Bash(head:*)" "Bash(wc:*)")
if [ -n "${EXTRA_TOOLS:-}" ]; then IFS=';' read -ra X <<<"$EXTRA_TOOLS"; TOOLS+=("${X[@]}"); fi
DENY=(WebFetch WebSearch)
if [ -n "${READ_DENY:-}" ]; then IFS=';' read -ra X <<<"$READ_DENY"; for g in "${X[@]}"; do DENY+=("Read(./$g)"); done; fi
# Read guard: a hook that refuses whole-file reads of big files (see guard_read.py).
GUARD="$(cd "$(dirname "$0")" && pwd)/guard_read.py"
SETTINGS="{\"hooks\":{\"PreToolUse\":[{\"matcher\":\"Read\",\"hooks\":[{\"type\":\"command\",\"command\":\"python3 -I '$GUARD'\"}]}]}}"
export READ_MAX_BYTES=${READ_MAX_BYTES:-15000} READ_MAX_LINES=${READ_MAX_LINES:-400}

local_claude() {  # $1 = prompt, rest = extra claude args
  local prompt=$1; shift
  ANTHROPIC_BASE_URL=http://localhost:11434 ANTHROPIC_AUTH_TOKEN=ollama ANTHROPIC_API_KEY="" \
  ANTHROPIC_DEFAULT_HAIKU_MODEL=$MODEL ANTHROPIC_DEFAULT_SONNET_MODEL=$MODEL ANTHROPIC_DEFAULT_OPUS_MODEL=$MODEL \
  CLAUDE_CODE_SUBAGENT_MODEL=$MODEL CLAUDE_CODE_MAX_CONTEXT_TOKENS=131072 \
  caffeinate -i -s claude -p "$prompt" "$@" --model "$MODEL" --permission-mode acceptEdits \
    --allowedTools "${TOOLS[@]}" --disallowedTools "${DENY[@]}" --settings "$SETTINGS" \
    --output-format stream-json --verbose >> "$LOG" 2>&1
}

local_claude "Read CLAUDE.md (if it exists) and $BRIEF, then complete $BRIEF. Commit after each piece works."

attempt=1
while [ -n "$TEST_CMD" ]; do
  OUT=$(bash -c "$TEST_CMD" 2>&1); RC=$?
  printf '{"type":"orchestrator","attempt":%d,"tests_rc":%d}\n' "$attempt" "$RC" >> "$LOG"
  [ "$RC" -eq 0 ] && break
  if [ "$attempt" -ge "$TRIES" ]; then
    echo "ESCALATE: '$TEST_CMD' still failing after $attempt local attempt(s). Last output:"
    echo "$OUT" | tail -40; exit 3
  fi
  SID=$(python3 -I -c 'import json,sys
s=""
for l in open(sys.argv[1]):
    try: e=json.loads(l)
    except Exception: continue
    if e.get("type")=="system" and e.get("subtype")=="init": s=e.get("session_id","")
print(s)' "$LOG")
  local_claude "The test command \`$TEST_CMD\` fails. Fix the code so it passes; do not delete or weaken tests. Commit when it passes. Last output:
$(echo "$OUT" | tail -60)" ${SID:+--resume "$SID"}
  attempt=$((attempt+1))
done
echo "DONE ($attempt attempt(s)). LOG $LOG"
