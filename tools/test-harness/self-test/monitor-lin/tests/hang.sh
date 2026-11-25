#!/usr/bin/env bash
# Harness self-test fixture: a command step that hangs the hard way. Its child
# runs in a process group of its own (set -m) and, like the script, ignores
# TERM, so only a KILL aimed at every process the step started stops it.
trap '' TERM
set -m
sleep 300 &
echo "$!" >/tmp/tc-harness-selftest-hang.pid
wait
