#!/usr/bin/env bash
# Weekly audit run by security-audit.timer: lynis, OpenSCAP (evaluation only), aide --check and rkhunter, whichever is installed.
# Reports go to /var/log/security-audit/<tool>-<timestamp>.log; the newest KEEP runs of each tool are kept.
# Nothing is remediated. A tool that fails or finds problems never stops the others.
set -uo pipefail

DIR=/var/log/security-audit
KEEP="${KEEP:-8}"
AIDE_CONF=/etc/security-tools/aide.conf
OSCAP_PROFILE="${OSCAP_PROFILE:-xccdf_org.ssgproject.content_profile_standard}"
OSCAP_DATASTREAM="${OSCAP_DATASTREAM:-}"
TS=$(date +%Y%m%d-%H%M%S)

install -d -m 0750 "$DIR"

# prune NAME: delete all but the newest KEEP logs of NAME and the files sharing their timestamp
prune() {
  local old f
  while IFS= read -r old; do
    [[ -n "$old" ]] || continue
    for f in "${old%.log}".*; do rm -f -- "$f"; done
  done < <(ls -1t "$DIR/$1"-*.log 2>/dev/null | tail -n +"$((KEEP + 1))")
}

# run_one NAME COMMAND...: output to the log file, exit code to the journal
run_one() {
  local name="$1" rc=0
  shift
  "$@" > "$DIR/${name}-${TS}.log" 2>&1 || rc=$?
  echo "${name}: exit ${rc}, log ${DIR}/${name}-${TS}.log"
  prune "$name"
}

if command -v lynis >/dev/null 2>&1; then
  run_one lynis lynis audit system --cronjob
fi

if command -v oscap >/dev/null 2>&1; then
  if [[ -z "$OSCAP_DATASTREAM" ]]; then
    OSCAP_DATASTREAM=$(compgen -G '/usr/share/xml/scap/ssg/content/ssg-*-ds.xml' | head -1 || true)
  fi
  if [[ -n "$OSCAP_DATASTREAM" ]]; then
    run_one oscap oscap xccdf eval --profile "$OSCAP_PROFILE" --results "$DIR/oscap-${TS}.xml" --report "$DIR/oscap-${TS}.html" "$OSCAP_DATASTREAM"
  fi
fi

if command -v aide >/dev/null 2>&1 && [[ -s /var/lib/security-tools/aide/aide.db.gz && -f "$AIDE_CONF" ]]; then
  run_one aide aide --config "$AIDE_CONF" --check
fi

if command -v rkhunter >/dev/null 2>&1; then
  run_one rkhunter rkhunter --check --sk --rwo
fi
exit 0
