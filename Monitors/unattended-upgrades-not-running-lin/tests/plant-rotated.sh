# shellcheck shell=bash
# Just after logrotate: the current log is empty and the last run, two hours
# ago, is only in the newest rotated file, .1.gz. .2.gz is a month older.
set -eu
log=/var/log/unattended-upgrades/unattended-upgrades.log
rm -f "$log".*.gz
printf '%s,000 INFO Starting unattended upgrades script\n' "$(date -d '2 hours ago' '+%F %T')" | gzip > "$log.1.gz"
printf '%s,000 INFO Starting unattended upgrades script\n' "$(date -d '32 days ago' '+%F %T')" | gzip > "$log.2.gz"
: > "$log"
