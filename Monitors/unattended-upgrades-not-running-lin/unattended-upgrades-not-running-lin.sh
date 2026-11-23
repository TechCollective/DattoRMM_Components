#!/usr/bin/env bash
# Datto RMM “unattended updates” monitor, Debian family only. On any other
# system it reports OK and checks nothing: there is no unattended-upgrades to check.
#
#   0 OK | 1 WARNING | 2 CRITICAL | 3 UNKNOWN
#
# ───────────────────────────────────────────────────────────────────────
set -euo pipefail

# ───── constants & helpers ────────────────────────────────────────────
OK=0; 
WARN=1; 
CRIT=2; 
UNK=3

_out() {
  local status="$1" detail="${3:-}"   # $2, the one-line summary, is not printed
  echo "<-Start Result->"; echo "Status=${status}"; echo "<-End Result->"
  # if, not &&: with no detail a false && would return 1 and set -e would exit 1 on OK
  if [[ -n $detail ]]; then echo "<-Start Diagnostic->"; echo "$detail"; echo "<-End Diagnostic->"; fi
  emitted=1
}

# set -e (or a signal) can end the script before any _out; this guarantees the
# one result block anyway, and never as OK.
emitted=0
on_exit() {
  local code=$?
  if [[ $emitted -eq 0 ]]; then
    # On a signal $? is 0 and bash exits with the signal's code (143 for TERM)
    # whatever this trap says.
    local why="shell exit ${code}"
    [[ $code -ne 0 ]] || why="stopped by a signal"
    echo "<-Start Result->"
    echo "Status=UNKNOWN: check failed before it could decide (${why}); see the component's raw job output for the error"
    echo "<-End Result->"
    exit $UNK
  fi
  exit "$code"
}
trap on_exit EXIT

need_cmd() { command -v "$1" &>/dev/null || { _out "UNKNOWN" "UNKNOWN: $1 not found." ; exit $UNK; }; }

# ───── distro detection ───────────────────────────────────────────────
OS_FAMILY=other; PRETTY="unknown"
if [[ -r /etc/os-release ]]; then
  . /etc/os-release
  PRETTY=${PRETTY_NAME:-${NAME:-unknown}}
  case "${ID_LIKE:-}${ID:-}" in
    *debian*|*ubuntu*|*linuxmint*) OS_FAMILY=debian ;;
  esac
fi

# ───── Debian / Ubuntu check ──────────────────────────────────────────
check_debian() {
  need_cmd unattended-upgrade
  local log_dir="/var/log/unattended-upgrades"
  local log_file="${log_dir}/unattended-upgrades.log"
  [[ -r $log_file ]] || { _out "CRITICAL" "CRITICAL: cannot read $log_file" ; exit $CRIT; }

  # 1. Grab the newest timestamp line from the **end** of the current log.
  local last_line
  last_line=$(tac "$log_file" \
              | grep -m1 -E '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}') || true

  # 2. If the current log was empty (e.g. just rotated), fall back to the
  #    newest rotated file (logrotate's lowest number, .1.gz) and take its
  #    last timestamp line.
  if [[ -z $last_line ]]; then
    local newest_rotated
    newest_rotated=$(ls -1v "${log_file}".*.gz 2>/dev/null | head -n1) || true
    if [[ -n $newest_rotated ]]; then
      last_line=$(zgrep -h -E '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}' \
                         "$newest_rotated" | tail -n1) || true
    fi
  fi

  # 3. If we still have nothing, fall back to the log file’s m-time.
  local last_run
  if [[ -n $last_line ]]; then
    local last_date=${last_line%%,*}
    last_run=$(date -d "$last_date" +%s 2>/dev/null || echo 0)
  else
    last_run=$(stat -c %Y "$log_file" 2>/dev/null || echo 0)
  fi

  # 4. Compare age against thresholds.
  local warn_sec=93600   # 26 h
  local crit_sec=187200  # 52 h
  local now; now=$(date +%s)
  local diff=$(( now - last_run ))
  local msg; msg="- unattended-upgrades last ran at $(date -d "@$last_run" '+%F %T') (age ${diff}s)."

  if   (( diff >= crit_sec )); then _out "CRITICAL" "CRITICAL: last run ${diff}s ago" "$msg" ; exit $CRIT
  elif (( diff >= warn_sec )); then _out "WARNING"  "WARNING: last run ${diff}s ago" "$msg" ; exit $WARN
  else                              _out "OK"       "OK: last run ${diff}s ago"      ; exit $OK
  fi
}


# ───── dispatcher ─────────────────────────────────────────────────────
case $OS_FAMILY in
  debian)  check_debian  ;;
  *)       _out "OK: not a Debian-based system ($PRETTY); nothing to check" ; exit $OK ;;
esac
