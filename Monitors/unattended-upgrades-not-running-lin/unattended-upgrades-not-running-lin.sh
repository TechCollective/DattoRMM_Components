#!/usr/bin/env bash
# Datto RMM mixed-distro “unattended updates” monitor
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
  local status="$1" short="$2" detail="${3:-}"
  echo "<-Start Result->"; echo "Status=${status}"; echo "<-End Result->"
  [[ -n $detail ]] && { echo "<-Start Diagnostic->"; echo "$detail"; echo "<-End Diagnostic->"; }
}

need_cmd() { command -v "$1" &>/dev/null || { _out "UNKNOWN" "UNKNOWN: $1 not found." ; exit $UNK; }; }

# ───── distro detection ───────────────────────────────────────────────
OS_FAMILY=other; PRETTY="unknown"
if [[ -r /etc/os-release ]]; then
  . /etc/os-release
  PRETTY=${PRETTY_NAME:-$NAME}
  case "${ID_LIKE:-}$ID" in
    *debian*|*ubuntu*|*linuxmint*) OS_FAMILY=debian ;;
    *rhel*|*centos*|*fedora*|*rocky*|*almalinux*|*ol*) OS_FAMILY=rhel ;;
  esac
fi

# ───── RHEL / CentOS / Rocky / Alma check ─────────────────────────────
check_rhel() {
  # 1. Select package, unit and mgr based on what’s installed
  local mgr pkg unit
  if command -v dnf &>/dev/null; then
    mgr="dnf"; pkg="dnf-automatic";       unit="dnf-automatic-install.timer"
  else
    mgr="yum"; pkg="yum-cron";            unit="yum-cron.service"
  fi

  # 2. Build a reusable diagnostic header
  local diag_header="OS        : $PRETTY_NAME
PkgMgr    : $mgr
AutoPkg   : $pkg
Unit/Timer: $unit"

  # 3-A  package present?
  if ! rpm -q "$pkg" &>/dev/null; then
    _out "CRITICAL" "CRITICAL: $pkg not installed" \
        "$diag_header\nProblem   : package missing."
    exit $CRIT
  fi

  # 3-B  unit enabled?
  if ! systemctl is-enabled --quiet "$unit"; then
    _out "WARNING" "WARNING: $unit is disabled" \
        "$diag_header\nProblem   : timer/service disabled."
    exit $WARN
  fi

  # 3-C  unit active?
  if ! systemctl is-active --quiet "$unit"; then
    _out "WARNING" "WARNING: $unit is inactive" \
        "$diag_header\nProblem   : timer/service not running."
    exit $WARN
  fi

  # 4. Everything good
  _out "OK" "OK: auto-updates healthy" "$diag_header"
  exit $OK
}


# ───── Debian / Ubuntu check ──────────────────────────────────────────
check_debian() {
  need_cmd unattended-upgrade
  local log_dir="/var/log/unattended-upgrades"
  local log_file="${log_dir}/unattended-upgrades.log"
  [[ -r $log_file ]] || { _out "CRITICAL" "CRITICAL: cannot read $log_file" ; exit $CRIT; }

  # 1. Grab the newest timestamp line from the **end** of the current log.
  local last_line
  last_line=$(tac "$log_file" \
              | grep -m1 -E '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}')
  
  # 2. If the current log was empty (e.g. just rotated), fall back to the
  #    newest rotated file (highest number) and take its last timestamp line.
  if [[ -z $last_line ]]; then
    local newest_rotated
    newest_rotated=$(ls -1v "${log_file}".*.gz 2>/dev/null | tail -n1) || true
    if [[ -n $newest_rotated ]]; then
      last_line=$(zgrep -h -E '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}' \
                         "$newest_rotated" | tail -n1)
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
  local now=$(date +%s)
  local diff=$(( now - last_run ))
  local msg="- unattended-upgrades last ran at $(date -d "@$last_run" '+%F %T') (age ${diff}s)."

  if   (( diff >= crit_sec )); then _out "CRITICAL" "CRITICAL: last run ${diff}s ago" "$msg" ; exit $CRIT
  elif (( diff >= warn_sec )); then _out "WARNING"  "WARNING: last run ${diff}s ago" "$msg" ; exit $WARN
  else                              _out "OK"       "OK: last run ${diff}s ago"      ; exit $OK
  fi
}



# ───── dispatcher ─────────────────────────────────────────────────────
case $OS_FAMILY in
  rhel)    check_rhel    ;;
  debian)  check_debian  ;;
  *)       _out "UNKNOWN" "UNKNOWN: unsupported distro ($PRETTY)" ; exit $UNK ;;
esac
