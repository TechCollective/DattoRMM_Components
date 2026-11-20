#!/bin/sh
# Harness self-test fixture: prints the result blocks fixtureBlocks asks for.
result() { printf '<-Start Result->\nSTATUS=%s\n<-End Result->\n' "$1"; }
case "$fixtureBlocks" in
    one)      result ok ;;
    diag)     printf '<-Start Diagnostic->\nnote\n<-End Diagnostic->\n'; result ok ;;
    zero)     echo 'no result block' ;;
    two)      result first; result second ;;
    unclosed) printf '<-Start Result->\nSTATUS=unclosed\n' ;;
esac
exit 0
