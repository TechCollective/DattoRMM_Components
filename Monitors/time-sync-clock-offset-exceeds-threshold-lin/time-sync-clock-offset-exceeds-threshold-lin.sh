#!/bin/bash

# Global variables
NTP_SERVER="pool.ntp.org"
TIME_THRESHOLD=60 # seconds
SCRIPT_NAME="Check_Time_Sync"

# Function to get current time from NTP server
get_ntp_time() {
    local ntp_time
    ntp_time=$(ntpdate -q "$NTP_SERVER" | awk '/offset/ {print $10}')
    if [[ -z "$ntp_time" ]]; then
        printf "<-Start Result->\n"
        printf "STATUS=Error: Unable to retrieve time from NTP server.\n"
        printf "<-End Result->\n"
        return 1
    fi
    echo "$ntp_time"
}

# Function to compare NTP time with local system time
compare_times() {
    local ntp_offset
    ntp_offset=$(get_ntp_time)
    if [[ -z "$ntp_offset" ]]; then
        printf "<-Start Result->\n"
        printf "STATUS=Error: Failed to get NTP offset.\n"
        printf "<-End Result->\n"
        return 1
    fi

    local offset_seconds
    offset_seconds=$(awk -v offset="$ntp_offset" 'BEGIN {print (offset < 0 ? -offset : offset) * 60}')
    
    if (( $(echo "$offset_seconds > $TIME_THRESHOLD" | bc -l) )); then
        printf "<-Start Result->\n"
        printf "STATUS=Warning: Time discrepancy detected. Offset is %s seconds.\n" "$offset_seconds"
        printf "<-End Result->\n"
        return 1
    fi
    
    printf "<-Start Result->\n"
    printf "STATUS=Success: Local system time is within acceptable range.\n"
    printf "<-End Result->\n"
}

# Main function
main() {
    if ! compare_times; then
        return 1
    fi
    return 0
}

# Execute main function
main
