#!/bin/bash
# Put fake smartctl and diskutil first on the root PATH (/usr/local/sbin), so
# the monitor reads one disk whose health the test chooses. The runComponent
# variable tcTestHealth reaches the shims through the monitor's environment:
# "passed" (the default), "failed", "hang" (sleep 600, for the kill test), or
# "hang-list" (diskutil list sleeps 600 instead).
# Linux reads smartctl; macOS reads diskutil and never calls smartctl.
set -e
mkdir -p /usr/local/sbin

cat > /usr/local/sbin/smartctl <<'EOF'
#!/bin/sh
# Test shim: one ATA disk, /dev/sda, healthy or failing per $tcTestHealth.
case " $* " in
    *" --scan-open "*)
        echo "/dev/sda -d sat # /dev/sda [SAT], ATA device"; exit 0 ;;
    *" -l "*)
        echo "SMART Error Log Version: 1"
        echo "No Errors Logged"; exit 0 ;;
esac
[ "$tcTestHealth" = hang ] && exec sleep 600
if [ "$tcTestHealth" = failed ]; then
    health=FAILED!; when=FAILING_NOW; realloc=812; rc=24
else
    health=PASSED; when=-; realloc=0; rc=0
fi
cat <<OUT
smartctl 7.4 (test shim)
=== START OF READ SMART DATA SECTION ===
SMART overall-health self-assessment test result: $health

SMART Attributes Data Structure revision number: 16
Vendor Specific SMART Attributes with Thresholds:
ID# ATTRIBUTE_NAME          FLAG     VALUE WORST THRESH TYPE      UPDATED  WHEN_FAILED RAW_VALUE
  5 Reallocated_Sector_Ct   0x0033   100   100   010    Pre-fail  Always       $when       $realloc
194 Temperature_Celsius     0x0022   064   050   000    Old_age   Always       -       36
197 Current_Pending_Sector  0x0012   100   100   000    Old_age   Always       -       0
199 UDMA_CRC_Error_Count    0x003e   200   200   000    Old_age   Always       -       0
OUT
exit $rc
EOF

cat > /usr/local/sbin/diskutil <<'EOF'
#!/bin/sh
# Test shim: one physical disk, /dev/disk0, Verified or Failing per $tcTestHealth.
case "$1" in
    list)
        [ "$tcTestHealth" = hang-list ] && exec sleep 600
        printf '/dev/disk0 (internal, physical):\n   #:  TYPE NAME  SIZE  IDENTIFIER\n' ;;
    info)
        [ "$tcTestHealth" = hang ] && exec sleep 600
        st=Verified; [ "$tcTestHealth" = failed ] && st=Failing
        printf '   Device Identifier:         disk0\n   SMART Status:              %s\n' "$st" ;;
    *) echo "diskutil test shim: unexpected arguments: $*" >&2; exit 1 ;;
esac
EOF

chmod 755 /usr/local/sbin/smartctl /usr/local/sbin/diskutil
echo "shims installed: $(command -v smartctl), $(command -v diskutil)"
