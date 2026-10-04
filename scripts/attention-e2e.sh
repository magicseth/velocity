#!/usr/bin/env bash
# LIVE end-to-end: a real Terminal tab asks (Codex's real dialog shape + the "[ ! ] Action
# Required" title), Velocity must REPORT it to Julia within 5 s; the tab closes, Velocity must
# RESOLVE it. Reads Velocity's own log (every report/resolve call result is logged) and, when
# ~/Projects/convexos is here, the attentionReports row itself.
#
#   bash scripts/attention-e2e.sh            # Velocity must be running and paired with Julia
#   ROW_CHECK=0 bash scripts/attention-e2e.sh  # skip the Convex row read
set -uo pipefail

NONCE="e2e-$(date +%s)-$RANDOM"
TASK="E2E test"
REPORT_WITHIN=${REPORT_WITHIN:-5}
RESOLVE_WITHIN=${RESOLVE_WITHIN:-30}   # the reporter latches 10 s before resolving
CONVEXOS=${CONVEXOS:-$HOME/Projects/convexos}
DEPLOYMENT=${CONVEX_DEPLOYMENT_E2E:-dev:hidden-kudu-77}
ROW_CHECK=${ROW_CHECK:-1}
fail() { echo "FAIL: $*"; cleanup; exit 1; }
pass() { echo "PASS: $*"; }

vlog() {  # Velocity's attention log lines since $1 (a `log show --start` timestamp)
  /usr/bin/log show --start "$1" --style compact \
    --predicate 'process == "TerminalVelocity" AND subsystem BEGINSWITH "velocity"' 2>/dev/null | grep "attention: "
}

pgrep -x TerminalVelocity >/dev/null || { echo "FAIL: Velocity isn't running"; exit 1; }

# The tab: title via OSC 0, then the dialog, then a builtin `read`; cleanup presses Return
# into it (ends the read → the shell exits) and closes the window, so Terminal never raises
# its "terminate running processes?" sheet.
DIALOG_FILE=$(mktemp -t velocity-e2e)
cat > "$DIALOG_FILE" <<EOF
Would you like to run the following command?

  \$ echo $NONCE

› 1. Yes, proceed (y)
  2. Yes, and don't ask again for this command (a)
  3. No, and tell Codex what to do differently (esc)

Press enter to confirm or esc to cancel
EOF
TAB_SCRIPT=$(mktemp -t velocity-e2e-tab)
cat > "$TAB_SCRIPT" <<TAB
clear
printf '\\033]0;[ ! ] Action Required | $TASK\\007'
cat '$DIALOG_FILE'
read -r _
exit
TAB
CMD="source '$TAB_SCRIPT'"

START=$(date '+%Y-%m-%d %H:%M:%S')
TTY=$(osascript -e "tell application \"Terminal\"
  set t to do script \"$CMD\"
  delay 0.3
  return tty of t
end tell" 2>&1) || { echo "FAIL: couldn't open a Terminal tab: $TTY"; exit 1; }
echo "opened $TTY (nonce $NONCE)"

cleanup() {
  [ -n "${TTY:-}" ] || return 0
  osascript -e "tell application \"Terminal\"
    repeat with w in windows
      repeat with tb in tabs of w
        if tty of tb is \"$TTY\" then
          set wid to id of w
          do script \"\" in tb
          repeat 20 times
            delay 0.1
            if (count of processes of tb) is 0 then exit repeat
          end repeat
          close window id wid
          return
        end if
      end repeat
    end repeat
  end tell" >/dev/null 2>&1
  TTY=""
  rm -f "$DIALOG_FILE" "$TAB_SCRIPT"
}
trap cleanup EXIT

# 1. REPORTED within REPORT_WITHIN seconds.
ID=""
for _ in $(seq 1 $((REPORT_WITHIN * 4))); do
  LINE=$(vlog "$START" | grep "report " | grep "“${TASK}" | grep "→ ok" | tail -1)
  if [ -n "$LINE" ]; then ID=$(echo "$LINE" | sed -E 's/.*attention: report ([0-9a-f]{8}).*/\1/'); break; fi
  sleep 0.25
done
if [ -z "$ID" ]; then
  echo "--- Velocity's attention log since $START:"; vlog "$START" | tail -10
  fail "Velocity didn't report the asking tab within ${REPORT_WITHIN}s"
fi
REPORTED_AT=$(date +%s)
pass "Velocity reported it (${ID}…): $(vlog "$START" | grep "report $ID" | tail -1 | sed -E 's/.*attention: //')"

# 2. The Convex row (best-effort: needs the convexos checkout + a logged-in convex CLI).
if [ "$ROW_CHECK" = 1 ] && [ -d "$CONVEXOS" ]; then
  ROWS=$(cd "$CONVEXOS" && CONVEX_DEPLOYMENT=$DEPLOYMENT npx convex data attentionReports --limit 5 --order desc 2>&1)
  if echo "$ROWS" | grep -q "$ID"; then
    ROW=$(echo "$ROWS" | grep "$ID" | head -1)
    echo "$ROW" | grep -q "awaiting_input" && pass "Convex row ${ID}… is awaiting_input" || echo "WARN: row ${ID}… found but not awaiting_input: ${ROW:0:200}"
    echo "$ROW" | grep -q "$NONCE" && pass "the row carries the dialog (nonce $NONCE)" || echo "WARN: the row's prompt doesn't show the nonce"
  else
    echo "WARN: no attentionReports row for ${ID}… in the newest 5 (CLI said: $(echo "$ROWS" | head -2 | tr '\n' ' '))"
  fi
fi

# 3. Close the tab → RESOLVED.
cleanup
CLOSED=$(date '+%Y-%m-%d %H:%M:%S')
for _ in $(seq 1 $((RESOLVE_WITHIN * 2))); do
  if vlog "$CLOSED" | grep -q "resolve ${ID} → ok"; then
    pass "Velocity resolved ${ID}… after the tab closed ($(( $(date +%s) - REPORTED_AT ))s after the report)"
    if [ "$ROW_CHECK" = 1 ] && [ -d "$CONVEXOS" ]; then
      ROW=$(cd "$CONVEXOS" && CONVEX_DEPLOYMENT=$DEPLOYMENT npx convex data attentionReports --limit 5 --order desc 2>&1 | grep "$ID" | head -1)
      [ -n "$ROW" ] && { echo "$ROW" | grep -q "awaiting_input" && echo "WARN: row still awaiting_input: ${ROW:0:200}" || pass "Convex row ${ID}… is no longer awaiting_input"; }
    fi
    echo "ALL PASS"
    exit 0
  fi
  sleep 0.5
done
echo "--- Velocity's attention log since close:"; vlog "$CLOSED" | tail -10
fail "Velocity didn't resolve ${ID}… within ${RESOLVE_WITHIN}s of the tab closing"
