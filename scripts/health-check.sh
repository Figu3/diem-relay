#!/bin/bash
# Daily health check for the RevenueSplitter keeper.
#
# Reads /home/figue/diem-relay/keeper.log and pings a Telegram chat
# ONLY when something is wrong:
#   - log file is missing
#   - no log entries at all
#   - last entry is older than ~36 hours (keeper skipped a daily run)
#   - last run contained ERROR or FATAL
#
# Silent on success. Designed to run under cron at ~06:00 UTC
# (07:00 CET / 08:00 CEST) so alerts land first thing in the morning.
#
# Required env (sourced from /home/figue/diem-relay/.env.alerts):
#   TELEGRAM_BOT_TOKEN - bot token (can reuse IronClaw's agent_figue bot)
#   TELEGRAM_CHAT_ID   - chat to message

set -uo pipefail

LOG=/home/figue/diem-relay/keeper.log
ENV_FILE=/home/figue/diem-relay/.env.alerts
MAX_AGE_SECONDS=$((36 * 3600)) # 36h — allow one missed run before alerting

if [[ ! -f "$ENV_FILE" ]]; then
  echo "FATAL: $ENV_FILE missing — cannot send alerts" >&2
  exit 2
fi
# shellcheck disable=SC1090
set -a && . "$ENV_FILE" && set +a
: "${TELEGRAM_BOT_TOKEN:?TELEGRAM_BOT_TOKEN missing in $ENV_FILE}"
: "${TELEGRAM_CHAT_ID:?TELEGRAM_CHAT_ID missing in $ENV_FILE}"

send_alert() {
  local msg="$1"
  curl -sS --max-time 15 "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=⚠️ DIEM keeper alert
${msg}

log: ${LOG}" \
    > /dev/null
}

# Check 1: log file exists
if [[ ! -f "$LOG" ]]; then
  send_alert "keeper.log missing on NUC — cron may never have run"
  exit 1
fi

# Check 2: any entries at all
LAST_RUN=$(grep -E "^\[[0-9]{4}-[0-9]{2}-[0-9]{2}" "$LOG" | tail -1)
if [[ -z "$LAST_RUN" ]]; then
  send_alert "no timestamped entries in keeper.log"
  exit 1
fi

# Check 3: age of last entry (> 36h means a daily run was missed)
LAST_TS_RAW=$(echo "$LAST_RUN" | grep -oE "^\[[^]]+\]" | tr -d '[]')
LAST_EPOCH=$(date -u -d "$LAST_TS_RAW" +%s 2>/dev/null || echo 0)
NOW_EPOCH=$(date -u +%s)
AGE=$((NOW_EPOCH - LAST_EPOCH))

if (( LAST_EPOCH == 0 )); then
  send_alert "could not parse last log timestamp: $LAST_TS_RAW"
  exit 1
fi

if (( AGE > MAX_AGE_SECONDS )); then
  HOURS=$((AGE / 3600))
  send_alert "last keeper run was ${HOURS}h ago (${LAST_TS_RAW}) — cron may be dead or bun/RPC broken"
  exit 1
fi

# Check 4: most recent run surfaced an error.
# Scan the entire latest run (from its 'keeper=' start line to EOF),
# not just the last 10 lines — long stack traces can push the ERROR:
# marker out of a fixed tail window and silently miss real failures.
LATEST_RUN_LINE=$(grep -nE "^\[[^]]+\] keeper=" "$LOG" | tail -1 | cut -d: -f1)
if [[ -n "$LATEST_RUN_LINE" ]]; then
  LATEST_RUN=$(tail -n +"$LATEST_RUN_LINE" "$LOG")
  if echo "$LATEST_RUN" | grep -qE "FATAL:|ERROR:"; then
    LAST_ERR=$(echo "$LATEST_RUN" | grep -E "FATAL:|ERROR:" | head -1)
    send_alert "last run surfaced an error:
${LAST_ERR}"
    exit 1
  fi
fi


# Check 5: most recent run reached "done:" — catches mid-run kills/hangs
# (SIGKILL, OOM, RPC timeout) where the last log line is not an ERROR
# and the log is fresh, but the keeper never finished its two steps.
# Only applies to the new (csDIEM-aware) keeper format whose start line
# includes 'csdiem='. Pre-csDIEM runs don't emit a 'done:' marker, so we
# skip the check for them rather than false-alerting on historical logs.
LAST_RUN_START_LINE=$(grep -nE "^\[[^]]+\] keeper=.*csdiem=" "$LOG" | tail -1 | cut -d: -f1)
if [[ -n "$LAST_RUN_START_LINE" ]]; then
  TAIL_FROM_LAST=$(tail -n +"$LAST_RUN_START_LINE" "$LOG")
  if ! echo "$TAIL_FROM_LAST" | grep -qE "^\[[^]]+\] done:"; then
    send_alert "latest keeper run started but never reached done: — process may have been killed or hung mid-execution"
    exit 1
  fi
fi

# All clear — silent
exit 0
