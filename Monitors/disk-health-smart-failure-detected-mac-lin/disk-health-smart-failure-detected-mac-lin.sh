#!/bin/bash
:<<'WINDOWS_STUB'
@echo off
goto WindowsScript
WINDOWS_STUB
# ============================================================================
#  Disk Health (SMART) Monitor [Mac][Lin]
#  Datto RMM custom monitor component.  Exit 0 = healthy, exit 1 = alert.
#
#  Replaces the Datto Labs "Unified Disk SMART Monitor" (build 25/seagull),
#  which alerted on every healthy ATA drive.  See the IT Glue document
#  "Datto RMM - Disk Health (SMART) Monitor" for why.
#
#  Input variables (all optional; defaults shown):
#    reallocMax        0      max reallocated sectors            (attr 5)
#    pendingMax        0      max pending / uncorrectable        (attr 197, 198)
#    crcMax            10     max interface CRC errors           (attr 199)
#    tempMax           55     max drive temperature in C         (attr 194, 190)
#    nvmeWearMax       90     max NVMe "Percentage Used"
#    nvmeSpareMin      10     min NVMe "Available Spare" percent
#    failOnPastTrip    false  alert on attributes that tripped In_the_past
#    failOnUnreadable  false  alert when a disk's SMART data cannot be read
#    smartctlTimeout   20     seconds allowed per smartctl call
#
#  "I could not tell" policy: a missing smartmontools, or a host where no
#  disk at all could be read, exits 1 -- an unmonitored disk is not a
#  healthy disk.  Individual unreadable disks (USB bridges that come and go)
#  are reported in the status line but do not alert unless failOnUnreadable
#  is set.
# ============================================================================

# ---------------------------------------------------------------- settings --
num() { case "$1" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac; }
istrue() {
    case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
        true|yes|y|1) return 0 ;; *) return 1 ;;
    esac
}

REALLOC_MAX=$(num "$reallocMax" 0)
PENDING_MAX=$(num "$pendingMax" 0)
CRC_MAX=$(num "$crcMax" 10)
TEMP_MAX=$(num "$tempMax" 55)
NVME_WEAR_MAX=$(num "$nvmeWearMax" 90)
NVME_SPARE_MIN=$(num "$nvmeSpareMin" 10)
TMO=$(num "$smartctlTimeout" 20)

# ----------------------------------------------------------------- output --
emit() {
    # STATUS must be a single line with no space after the '='
    printf '<-Start Result->\n'
    printf 'STATUS=%s\n' "$(printf '%s' "$1" | tr '\n\r' '  ')"
    printf '<-End Result->\n'
}
emit_diag() {
    [ -n "$1" ] || return 0
    printf '<-Start Diagnostic->\n%s\n<-End Diagnostic->\n' "$1"
}
bail() { emit "Check could not run: $1"; exit 1; }

FAILS=""        # one phrase per failing disk
UNREADABLE=""   # device names we could not read
NOTES=""        # non-fatal observations
DIAG=""         # diagnostic payload, failing disks only
TOTAL=0
OK_COUNT=0
MAX_TEMP=""

add_fail()  { FAILS="${FAILS}${FAILS:+; }$1"; }
add_note()  { NOTES="${NOTES}${NOTES:+; }$1"; }
add_unread(){ UNREADABLE="${UNREADABLE}${UNREADABLE:+ }$1"; }
add_diag()  { DIAG="${DIAG}${DIAG:+
}$1"; }
note_temp() {
    [ -n "$1" ] || return 0
    if [ -z "$MAX_TEMP" ] || [ "$1" -gt "$MAX_TEMP" ] 2>/dev/null; then MAX_TEMP="$1"; fi
}

# ============================================================== macOS path ==
if [ "$(uname -s)" = "Darwin" ]; then
    DISKS=$(diskutil list physical 2>/dev/null | awk '/^\/dev\/disk/{print $1}')
    [ -n "$DISKS" ] && DISKS=$(printf '%s\n' "$DISKS" | sort -u)
    [ -n "$DISKS" ] || bail "no physical disks reported by diskutil"

    for DEV in $DISKS; do
        TOTAL=$((TOTAL + 1))
        INFO=$(diskutil info "$DEV" 2>&1)
        # exact value, not a substring: "Not Supported" must not match "Supported"
        ST=$(printf '%s\n' "$INFO" | awk -F': *' '/SMART Status/{print $2; exit}' \
             | sed 's/[[:space:]]*$//')
        case "$ST" in
            Verified)
                OK_COUNT=$((OK_COUNT + 1)) ;;
            "Not Supported"|"")
                add_note "$DEV reports no SMART support"
                OK_COUNT=$((OK_COUNT + 1)) ;;
            *)
                add_fail "$DEV SMART status is '$ST'"
                add_diag "$(printf '===== %s =====\n%s' "$DEV" "$INFO")" ;;
        esac
    done

# ============================================================== Linux path ==
else
    command -v smartctl >/dev/null 2>&1 || bail "smartmontools is not installed"

    if command -v timeout >/dev/null 2>&1; then RUN="timeout $TMO"; else RUN=""; fi

    # smartctl's own scan reports the -d type a device needs (sat, nvme, megaraid).
    # A major-number allowlist would silently skip virtio, xen and dm disks.
    SCAN=$($RUN smartctl --scan-open 2>/dev/null | sed 's/#.*//' | sed 's/[[:space:]]*$//' \
           | grep '^/dev/')
    [ -n "$SCAN" ] && SCAN=$(printf '%s\n' "$SCAN" | awk '!seen[$1]++')
    if [ -z "$SCAN" ]; then
        SCAN=$(lsblk -dpno NAME,TYPE 2>/dev/null | awk '$2=="disk"{print $1}')
    fi
    [ -n "$SCAN" ] || bail "no disks found to check"

    add_disk_fail() { DISK_FAIL="${DISK_FAIL}${DISK_FAIL:+, }$1"; }

    # read on fd 3 so nothing inside the loop can swallow the disk list
    while IFS= read -r LINE <&3; do
        [ -n "$LINE" ] || continue
        TOTAL=$((TOTAL + 1))
        DEV=$(printf '%s' "$LINE" | awk '{print $1}')
        DTYPE=$(printf '%s' "$LINE" | awk '{$1=""; print}')   # e.g. " -d sat"

        # One call per healthy disk. The old component made four.
        OUT=$($RUN smartctl -H -A $DTYPE "$DEV" 2>&1)
        RC=$?

        # smartctl exit bits: 1 cmdline, 2 open failed, 4 cmd failed,
        # 8 DISK FAILING, 16 prefail attr below threshold NOW,
        # 32 attr below threshold in the past, 64 error log, 128 selftest log
        if [ "$RC" -eq 124 ] || [ $((RC & 3)) -ne 0 ]; then
            add_unread "$DEV"
            continue
        fi

        DISK_FAIL=""
        TEMPC=""

        # ---- overall self-assessment (ATA / SCSI wording both covered) ----
        HEALTH=$(printf '%s\n' "$OUT" \
                 | sed -n -e 's/.*self-assessment test result: *//p' \
                          -e 's/.*SMART Health Status: *//p' \
                          -e 's/.*SMART overall-health.*: *//p' | head -1 \
                 | sed 's/[[:space:]]*$//')
        case "$HEALTH" in
            PASSED|OK|"")
                # bit 3 is the machine-readable form of the same verdict;
                # only report it when the text did not already say so
                [ $((RC & 8)) -ne 0 ] && add_disk_fail "smartctl reports the disk is failing"
                ;;
            *)  add_disk_fail "overall health $HEALTH" ;;
        esac

        if printf '%s\n' "$OUT" | grep -q 'Percentage Used'; then
            # ------------------------------- NVMe ------------------------------
            # exact key match: "Available Spare" must not pick up
            # "Available Spare Threshold"
            nv() { printf '%s\n' "$OUT" | awk -F': *' -v k="$1" \
                   '$1==k {gsub(/[^0-9]/,"",$2); print $2+0; exit}'; }
            CW=$(nv 'Critical Warning')
            USED=$(nv 'Percentage Used')
            SPARE=$(nv 'Available Spare')
            MEDERR=$(nv 'Media and Data Integrity Errors')
            TEMPC=$(nv 'Temperature')

            [ -n "$CW" ] && [ "$CW" -ne 0 ] 2>/dev/null && \
                add_disk_fail "NVMe critical warning flag is set"
            [ -n "$USED" ] && [ "$USED" -gt "$NVME_WEAR_MAX" ] 2>/dev/null && \
                add_disk_fail "${USED}% life used (max ${NVME_WEAR_MAX}%)"
            [ -n "$SPARE" ] && [ "$SPARE" -lt "$NVME_SPARE_MIN" ] 2>/dev/null && \
                add_disk_fail "${SPARE}% spare remaining (min ${NVME_SPARE_MIN}%)"
            [ -n "$MEDERR" ] && [ "$MEDERR" -gt 0 ] 2>/dev/null && \
                add_disk_fail "$MEDERR media/data integrity errors"
            note_temp "$TEMPC"

        elif printf '%s\n' "$OUT" | grep -q 'Vendor Specific SMART Attributes'; then
            # -------------------------------- ATA ------------------------------
            # THE fix: judge the WHEN_FAILED column, not the TYPE column.
            # "Pre-fail" in TYPE is a class label present on every healthy drive.
            WF_NOW=$(printf '%s\n' "$OUT" \
                     | awk '$1 ~ /^[0-9]+$/ && NF>=10 && $9=="FAILING_NOW" {printf "%s ", $2}')
            WF_PAST=$(printf '%s\n' "$OUT" \
                      | awk '$1 ~ /^[0-9]+$/ && NF>=10 && $9=="In_the_past" {printf "%s ", $2}')

            raw() { printf '%s\n' "$OUT" | awk -v id="$1" \
                    '$1 ~ /^[0-9]+$/ && $1==id && NF>=10 {print $10+0; exit}'; }
            REALLOC=$(raw 5)
            PENDING=$(raw 197)
            OFFUNC=$(raw 198)
            CRC=$(raw 199)
            TEMPC=$(raw 194); [ -n "$TEMPC" ] || TEMPC=$(raw 190)

            [ -n "$WF_NOW" ] && add_disk_fail "attributes failing now: $(echo $WF_NOW)"
            [ $((RC & 16)) -ne 0 ] && [ -z "$WF_NOW" ] && \
                add_disk_fail "a pre-fail attribute is below threshold"
            if [ -n "$WF_PAST" ] || [ $((RC & 32)) -ne 0 ]; then
                if istrue "$failOnPastTrip"; then
                    add_disk_fail "attributes tripped in the past: $(echo $WF_PAST)"
                else
                    add_note "$DEV had a threshold trip in the past ($(echo $WF_PAST))"
                fi
            fi
            [ -n "$REALLOC" ] && [ "$REALLOC" -gt "$REALLOC_MAX" ] 2>/dev/null && \
                add_disk_fail "$REALLOC reallocated sectors (max $REALLOC_MAX)"
            [ -n "$PENDING" ] && [ "$PENDING" -gt "$PENDING_MAX" ] 2>/dev/null && \
                add_disk_fail "$PENDING pending sectors (max $PENDING_MAX)"
            [ -n "$OFFUNC" ] && [ "$OFFUNC" -gt "$PENDING_MAX" ] 2>/dev/null && \
                add_disk_fail "$OFFUNC offline-uncorrectable sectors (max $PENDING_MAX)"
            [ -n "$CRC" ] && [ "$CRC" -gt "$CRC_MAX" ] 2>/dev/null && \
                add_disk_fail "$CRC interface CRC errors (max $CRC_MAX) - check the cable"
            note_temp "$TEMPC"

        else
            # ------------------------------- SCSI ------------------------------
            DEFECTS=$(printf '%s\n' "$OUT" \
                      | awk -F': *' '/grown defect list/{gsub(/[^0-9]/,"",$2); print $2+0; exit}')
            [ -n "$DEFECTS" ] && [ "$DEFECTS" -gt "$REALLOC_MAX" ] 2>/dev/null && \
                add_disk_fail "$DEFECTS entries in the grown defect list"
            TEMPC=$(printf '%s\n' "$OUT" \
                    | awk -F': *' '/Current Drive Temperature/{gsub(/[^0-9]/,"",$2); print $2+0; exit}')
            note_temp "$TEMPC"
        fi

        # temperature applies to every family
        [ -n "$TEMPC" ] && [ "$TEMPC" -gt "$TEMP_MAX" ] 2>/dev/null && \
            add_disk_fail "${TEMPC}C (max ${TEMP_MAX}C)"

        if [ -n "$DISK_FAIL" ]; then
            add_fail "$DEV: $DISK_FAIL"
            # accumulate per disk -- the old component overwrote this each pass
            EXTRA=$($RUN smartctl -l error -l selftest $DTYPE "$DEV" 2>&1 | head -40)
            add_diag "$(printf '===== %s =====\n%s\n\n--- error / self-test log ---\n%s' \
                        "$DEV" "$OUT" "$EXTRA")"
        else
            OK_COUNT=$((OK_COUNT + 1))
        fi
    done 3<<EOF
$SCAN
EOF
fi

# ============================================================== verdict ====
UNREAD_COUNT=0
[ -n "$UNREADABLE" ] && UNREAD_COUNT=$(printf '%s' "$UNREADABLE" | wc -w | tr -d ' ')

# monitoring nothing is not the same as finding nothing wrong
if [ "$TOTAL" -gt 0 ] && [ "$UNREAD_COUNT" -eq "$TOTAL" ]; then
    emit "Check could not run: SMART data unreadable on all $TOTAL disks ($UNREADABLE)"
    exit 1
fi

if [ -n "$UNREADABLE" ]; then
    if istrue "$failOnUnreadable"; then
        add_fail "SMART data unreadable on $UNREADABLE"
    else
        add_note "SMART data unreadable on $UNREADABLE"
    fi
fi

SUFFIX=""
[ -n "$MAX_TEMP" ] && SUFFIX="; max temp ${MAX_TEMP}C"
[ -n "$NOTES" ] && SUFFIX="$SUFFIX; $NOTES"

if [ -n "$FAILS" ]; then
    emit "$FAILS ($OK_COUNT of $TOTAL disks healthy)$SUFFIX"
    emit_diag "$DIAG"
    exit 1
fi

if [ "$UNREAD_COUNT" -gt 0 ]; then
    emit "$OK_COUNT of $TOTAL disks healthy$SUFFIX"
else
    emit "All $TOTAL disks healthy: SMART self-assessment passes, no failed attributes$SUFFIX"
fi
exit 0

# Windows branch. The heredoc hides it from bash entirely; cmd.exe treats the
# opening line as a label, skips it, and reaches :WindowsScript via the goto.
:<<'WINDOWS_SECTION'
:WindowsScript
echo ^<-Start Result-^>
echo STATUS^=This monitor does not support Windows. Use the Windows Disk SMART monitor.
echo ^<-End Result-^>
exit 0
WINDOWS_SECTION
