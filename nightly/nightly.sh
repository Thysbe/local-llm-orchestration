#!/bin/bash
# Nightly runner: works through a queue of briefs with a local model, unattended, until END_HOUR.
# Start it from launchd at midnight (see com.example.local-llm-nightly.plist). It never pushes.
#
# Each round N runs the brief TASK<N>.md: it is copied from this folder into the repo (unless the
# repo already has it), committed, then handed to run_local.sh. A round only starts if it should
# finish by END_HOUR, estimated from the longest of the last 3 rounds (2.5h with no history).
# A round that runs long is never killed.
#
# Skips the night (tries again tomorrow): STOP file present, a round still running, on battery,
# Ollama context too low. Halts the queue (writes STOP; delete it to resume) when the previous
# round didn't finish cleanly: no success result, failing tests or uncommitted changes.
#
# Config: nightly.conf next to this script (see nightly.conf.example).
# Files next to this script:
#   queue.txt   rounds still to run, one per line (# comments allowed); the top one runs next
#   last_round  the round started last
#   STOP        present = queue halted; holds the reason
#   logs/       nightly.log, run logs, and a per-round summary

S="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
[ -f "$S/nightly.conf" ] && . "$S/nightly.conf"
REPO=${REPO:?set REPO in nightly.conf}
RUN_LOCAL=${RUN_LOCAL:?set RUN_LOCAL in nightly.conf (path to run_local.sh)}
MODEL=${MODEL:-qwen3.8:27b}
TEST_CMD=${TEST_CMD:-}
END_HOUR=${END_HOUR:-7}
export MODEL TEST_CMD LOG_DIR="$S/logs" TRIES=${TRIES:-2} EXTRA_TOOLS=${EXTRA_TOOLS:-} READ_DENY=${READ_DENY:-}
LOG="$S/logs/nightly.log"
mkdir -p "$S/logs"

log() { echo "$(date '+%Y-%m-%d %H:%M') $*" >> "$LOG"; }
notify() { osascript -e "display notification \"$1\" with title \"Local model nightly\"" >/dev/null 2>&1; }
halt() { echo "$(date '+%Y-%m-%d %H:%M') $*" > "$S/STOP"; log "STOP: $*"; notify "Queue stopped: $*"; exit 1; }
tests_pass() { [ -z "$TEST_CMD" ] || bash -c "$TEST_CMD" >/dev/null 2>&1; }
latest_log() { ls -t "$S"/logs/*-TASK"$1"-*.jsonl 2>/dev/null | head -1; }

# exit 0 if round N's latest run log ends with a successful result
ok() { local f; f=$(latest_log "$1"); [ -n "$f" ] && python3 -I -c "
import json,sys
r=None
for l in open(sys.argv[1]):
    try: e=json.loads(l)
    except Exception: continue
    if e.get('type')=='result': r=e.get('subtype')
sys.exit(0 if r=='success' else 1)" "$f"; }

# exit 0 if a round started now should finish by END_HOUR; prints the estimate either way
fits() { python3 -I -c "
import re,sys,datetime as D
end_h=int(sys.argv[2]); st={}; durs=[]
try: lines=open(sys.argv[1]).readlines()
except OSError: lines=[]
for l in lines:
    m=re.match(r'(\S+ \S+) (start|done) round (\S+)',l)
    if not m: continue
    t=D.datetime.strptime(m[1],'%Y-%m-%d %H:%M')
    if m[2]=='start': st[m[3]]=t
    elif m[3] in st: durs.append((t-st.pop(m[3])).total_seconds())
est=max(durs[-3:]) if durs else 9000
now=D.datetime.now(); end=now.replace(hour=end_h,minute=0,second=0,microsecond=0)
left=max(0,(end-now).total_seconds())  # past END_HOUR = no time left (the runner starts at 00:00)
print(f'needs ~{est/3600:.1f}h, {left/3600:.1f}h left before {end_h:02d}:00')
sys.exit(0 if est<=left else 1)" "$LOG" "$END_HOUR"; }

[ -f "$S/STOP" ] && { log "skip: STOP file present ($(cat "$S/STOP"))"; exit 0; }
pgrep -f "claude -p Read CLAUDE.md" >/dev/null && { log "skip: a round is still running"; exit 0; }
pmset -g batt | grep -q "AC Power" || { log "skip: on battery"; exit 0; }

cd "$REPO" || halt "repo missing: $REPO"
while true; do
  if [ -f "$S/last_round" ]; then
    P=$(cat "$S/last_round")
    ok "$P" || halt "round $P has no success result"
  fi
  git diff --quiet HEAD || halt "uncommitted changes to tracked files"
  tests_pass || halt "tests fail before starting"

  N=$(grep -v '^[[:space:]]*\(#\|$\)' "$S/queue.txt" 2>/dev/null | head -1)
  [ -z "$N" ] && { log "skip: queue empty"; exit 0; }
  WHY=$(fits) || { log "stop for the night: round $N $WHY"; exit 0; }

  if [ ! -f "TASK$N.md" ]; then
    [ -f "$S/TASK$N.md" ] || halt "brief TASK$N.md not found"
    cp "$S/TASK$N.md" . && git add "TASK$N.md" && git commit -qm "Add task $N brief" || halt "could not commit brief $N"
  fi

  # Make sure Ollama is up (run_local.sh checks the model and context itself).
  if ! curl -s -m 5 localhost:11434/api/version >/dev/null; then
    open -a Ollama; for _ in $(seq 30); do sleep 2; curl -s -m 2 localhost:11434/api/version >/dev/null && break; done
  fi

  python3 -I -c "
import sys;p=sys.argv[1];L=open(p).read().split('\n');L.remove(sys.argv[2]);open(p,'w').write('\n'.join(L))" "$S/queue.txt" "$N"
  echo "$N" > "$S/last_round"
  log "start round $N"
  "$RUN_LOCAL" "$REPO" "TASK$N.md" > "$S/logs/nightly-$N.txt" 2>&1
  RC=$?
  if [ "$RC" -eq 2 ]; then  # preflight failed (e.g. context too low): not the round's fault
    rm -f "$S/last_round"; echo "$N" | cat - "$S/queue.txt" > "$S/queue.tmp" && mv "$S/queue.tmp" "$S/queue.txt"
    log "skip: preflight failed for round $N (requeued); see logs/nightly-$N.txt"; notify "Skipped: preflight failed"; exit 0
  fi
  python3 -I "$(dirname "$RUN_LOCAL")/check_local.py" "$(latest_log "$N")" >> "$S/logs/nightly-$N.txt" 2>&1
  if [ "$RC" -eq 0 ] && ok "$N" && tests_pass; then
    log "done round $N; summary in logs/nightly-$N.txt"; notify "Round $N finished"
  else
    halt "round $N did not finish cleanly (exit $RC); see logs/nightly-$N.txt"
  fi
done
