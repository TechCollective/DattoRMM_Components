#!/usr/bin/env bash
# Harness self-test fixture: a command step that hangs the hard way. Its child
# runs in a process group of its own (set -m) and ignores TERM, while the
# script itself dies on TERM at once. So the step has ended before the KILL
# that alone stops the child, and the harness must send it anyway.
set -m
( trap '' TERM; exec sleep 300 ) &
echo "$!" >/tmp/tc-harness-selftest-hang.pid
wait
