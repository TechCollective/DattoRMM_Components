#!/usr/bin/env bash
# Waits for a pull request's checks to finish, then prints one line per
# check that did not pass and a count of each outcome.
#
#   tools/wait-ci.sh <pr number or branch> [minutes, default 45]
#
# Exit: 0 all passed, 1 something failed, 124 still running at the deadline.
# Always ends: a bare `gh pr checks --watch` can outlive its PR and hang a
# shell, so the watch runs under a hard timeout.
set -uo pipefail
pr="${1:?usage: tools/wait-ci.sh <pr number or branch> [minutes]}"
minutes="${2:-45}"

sleep 15  # new runs take a moment to register after a push
timeout "${minutes}m" gh pr checks "$pr" --watch --interval 60 >/dev/null 2>&1
rc=$?

checks=$(gh pr checks "$pr" --json name,bucket,link -q '.[] | [.bucket, .name, .link] | @tsv')
echo "$checks" | awk -F'\t' '$1 != "pass" && $1 != "skipping" { print $1 ": " $2 "  " $3 }'
echo "$checks" | cut -f1 | sort | uniq -c | tr '\n' ' '; echo

if [ $rc -eq 124 ]; then echo "Still running after ${minutes} minutes."; exit 124; fi
echo "$checks" | cut -f1 | grep -qvE '^(pass|skipping)$' && exit 1
exit 0
