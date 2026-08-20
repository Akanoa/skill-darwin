#!/usr/bin/env bash
# A real darwin run, driven by real agents, rendered live in herdr.
#
#   scripts/demo.sh [workdir] [--yes]
#
# Builds a small throwaway repo, then runs the full loop: an implementer agent
# in its own herdr workspace, mechanical verification, a reviewer agent in a
# second workspace, and a judgment. Open herdr while it runs - each role is a
# workspace you can attach to, and darwin reports its state to the UI.
#
# This spawns real agent CLIs and spends real tokens.
set -euo pipefail
export PATH="$PATH:$HOME/.local/bin"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DARWIN="python3 $HERE/darwin.py"
WORK="${1:-$HOME/darwin-demo}"
[ "${1:-}" = "--yes" ] && WORK="$HOME/darwin-demo"
YES=0; for a in "$@"; do [ "$a" = "--yes" ] && YES=1; done

IMPL_MODEL="${DARWIN_DEMO_IMPL_MODEL:-sonnet}"
REVIEW_MODEL="${DARWIN_DEMO_REVIEW_MODEL:-opus}"

hr()   { printf '\n\033[1m── %s \033[0m%s\n' "$1" "$(printf '─%.0s' $(seq 1 $((60 - ${#1}))))"; }
note() { printf '   \033[2m%s\033[0m\n' "$1"; }

if [ "$YES" != "1" ]; then
  printf 'This runs real agents (implementer=%s, reviewer=%s) in %s and spends tokens.\n' \
    "$IMPL_MODEL" "$REVIEW_MODEL" "$WORK"
  read -r -p 'Continue? [y/N] ' answer
  [ "$answer" = "y" ] || exit 1
fi

hr "building the demo repository"
rm -rf "$WORK"; mkdir -p "$WORK/src" "$WORK/tests"; cd "$WORK"
git init -q .; git config user.email demo@darwin; git config user.name darwin-demo
printf '__pycache__/\n*.pyc\n' > .gitignore
touch src/__init__.py tests/__init__.py
cat > src/duration.py <<'EOF'
UNITS = {"s": 1, "m": 60}


def parse_duration(text):
    """Parse a duration like '90s' or '5m' into a whole number of seconds."""
    unit = text[-1]
    return int(text[:-1]) * UNITS[unit]
EOF
cat > tests/test_duration.py <<'EOF'
import unittest
from src.duration import parse_duration


class TestParseDuration(unittest.TestCase):
    def test_seconds(self):
        self.assertEqual(parse_duration("90s"), 90)

    def test_minutes(self):
        self.assertEqual(parse_duration("5m"), 300)
EOF
cat > darwin.config.json <<EOF
{
  "spawn": "herdr-agent",
  "max_rounds": 2,
  "test": {
    "command": "python3 -m unittest discover -q -s . -p \"test_*.py\"",
    "single_command": "python3 -m unittest -q {selector}"
  },
  "mutation": { "min_mutants": 4, "reviewer_min_mutants": 3 },
  "agents": {
    "implementer": { "provider": "claude", "model": "$IMPL_MODEL", "timeout_sec": 1800 },
    "reviewer":    { "provider": "claude", "model": "$REVIEW_MODEL", "timeout_sec": 1800 }
  }
}
EOF
git add -A; git commit -qm "duration parser: seconds and minutes"
note "$WORK  (python, unittest, no dependencies)"

cat > TASK.md <<'EOF'
Extend `parse_duration` in src/duration.py:

- support hours, e.g. "2h" -> 7200
- raise ValueError for an unknown unit, e.g. "5x"
- raise ValueError for an empty string
- raise ValueError for a missing number, e.g. "s"
- raise ValueError for a negative duration, e.g. "-5m"

Keep the return value a whole number of seconds. Do not add dependencies.
EOF

hr "opening the run"
$DARWIN init --task-file TASK.md
RUN=$(cat .darwin/current)

# give the run its own herdr workspace: the orchestrator itself lives outside
# herdr, so without this the loop has no presence in the UI
$DARWIN ui || true

watch_role() {   # $1 = role, $2 = round
  local role="$1" round="$2" pid pane
  $DARWIN spawn --role "$role" --round "$round" > ".darwin/spawn-$role.json" 2>&1 &
  pid=$!
  pane=$(python3 -c "import json;print(json.load(open('.darwin/runs/$RUN/run.json'))['roles']['$role'].get('pane_id',''))")
  note "watching pane $pane - attach with: herdr agent attach darwin-$role"
  while kill -0 "$pid" 2>/dev/null; do
    sleep 20
    herdr agent list 2>/dev/null | python3 -c "
import json,sys
try: agents = json.load(sys.stdin)['result']['agents']
except Exception: sys.exit()
for a in agents:
    print('   %-22s %-8s %s' % (a.get('name') or a.get('label'),
                                a.get('agent_status') or '?',
                                (a.get('terminal_title_stripped') or a.get('message') or '')[:60]))
" || true
  done
  wait "$pid" || true
  cat ".darwin/spawn-$role.json"
}

hr "implementer (claude/$IMPL_MODEL) - red, green, mutate, report"
$DARWIN worktree add --role implementer
watch_role implementer 1

hr "orchestrator replays every mutant itself"
$DARWIN verify --role implementer --round 1 --verifier orchestrator

hr "reviewer (claude/$REVIEW_MODEL) - replay, grade, attack"
$DARWIN worktree add --role reviewer
watch_role reviewer 1

hr "judgment"
$DARWIN judge --round 1

hr "herdr state"
herdr workspace list 2>/dev/null | python3 -c "
import json,sys
for w in json.load(sys.stdin)['result'].get('workspaces', []):
    print('   %-4s %-22s panes=%s status=%s' % (w['workspace_id'], w.get('label'), w.get('pane_count'), w.get('agent_status')))
" || true

hr "what to look at"
note "evidence:   $WORK/.darwin/runs/$RUN/"
note "report:     .../rounds/r1/implementer/MUTATION-REPORT.json"
note "replay:     .../rounds/r1/implementer/verify.orchestrator.json"
note "review:     .../rounds/r1/reviewer/REVIEW.json"
note "teardown:   $DARWIN --cwd $WORK clean --delete-branches"
