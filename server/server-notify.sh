#!/usr/bin/env bash
# server-notify EVENT MESSAGE...: optional notification hook used by server-update, server-cleanup, server-disk-guard
# and health. Sends to the first channel configured in /etc/server-init.d/notify.env (Telegram, Slack, mail);
# does nothing when none is configured. Never fails the caller. Secrets are never printed or logged: curl reads
# its URL and data from stdin (-K -), so they are not in argv either. Events update and cleanup also refresh the
# health summary cache. Installed as /usr/local/sbin/server-notify by server/install-tools.sh.
set -uo pipefail
ENV_FILE=${SERVER_NOTIFY_ENV:-/etc/server-init.d/notify.env}
event=${1:-}; shift || true
msg="[$(uname -n)] $*"
msg=${msg:0:1000}
verbose=0; [[ $event == test ]] && verbose=1

log() { logger -t server-notify -- "$*" 2>/dev/null || true; (( verbose )) && echo "server-notify: $*"; return 0; }
case $event in update|cleanup) systemctl start --no-block server-health-brief.service >/dev/null 2>&1 || true ;; esac
if [[ ! -f $ENV_FILE ]]; then log "no $ENV_FILE, notification skipped"; exit 0; fi
if [[ $(stat -c '%a %u' "$ENV_FILE") != "600 0" ]]; then log "$ENV_FILE must be owned by root with mode 0600, notification skipped"; exit 0; fi
TELEGRAM_BOT_TOKEN="" TELEGRAM_CHAT_ID="" SLACK_WEBHOOK_URL="" MAIL_TO=""
# shellcheck source=/dev/null
. "$ENV_FILE"

cq() { local s=$1; s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\n'/\\n}; printf '%s' "$s"; }   # curl config quoting
jq_() { local s=$1; s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\n'/\\n}; printf '%s' "$s"; }  # JSON string body
sent=0
if [[ -n $TELEGRAM_BOT_TOKEN && -n $TELEGRAM_CHAT_ID ]]; then
  printf 'url = "https://api.telegram.org/bot%s/sendMessage"\ndata-urlencode = "chat_id=%s"\ndata-urlencode = "text=%s"\n' \
    "$(cq "$TELEGRAM_BOT_TOKEN")" "$(cq "$TELEGRAM_CHAT_ID")" "$(cq "$msg")" | curl -sS --fail --max-time 10 -o /dev/null -K - >/dev/null 2>&1
  rc=$?; sent=1
  if (( rc == 0 )); then log "telegram: sent ($event)"; else log "telegram: FAILED (curl exit $rc)"; fi
fi
if [[ -n $SLACK_WEBHOOK_URL ]]; then
  printf 'url = "%s"\nheader = "Content-Type: application/json"\ndata = "%s"\n' \
    "$(cq "$SLACK_WEBHOOK_URL")" "$(cq "{\"text\":\"$(jq_ "$msg")\"}")" | curl -sS --fail --max-time 10 -o /dev/null -K - >/dev/null 2>&1
  rc=$?; sent=1
  if (( rc == 0 )); then log "slack: sent ($event)"; else log "slack: FAILED (curl exit $rc)"; fi
fi
if [[ -n $MAIL_TO ]]; then
  if command -v mail >/dev/null 2>&1; then
    sent=1; if printf '%s\n' "$msg" | mail -s "[$(uname -n)] server $event" "$MAIL_TO" >/dev/null 2>&1; then log "mail: sent ($event)"; else log "mail: FAILED"; fi
  elif command -v sendmail >/dev/null 2>&1; then
    sent=1; if printf 'To: %s\nSubject: [%s] server %s\n\n%s\n' "$MAIL_TO" "$(uname -n)" "$event" "$msg" | sendmail -t >/dev/null 2>&1; then log "mail: sent ($event)"; else log "mail: FAILED"; fi
  else log "MAIL_TO set but no mail or sendmail command"; fi
fi
(( sent )) || log "no channel configured in $ENV_FILE"
exit 0
