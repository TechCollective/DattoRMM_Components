#!/bin/bash
# Name: Docker Monitor [LIN]
# Description: Monitors docker containers running on Linux
# Category: Script
# Script: Shell *Unix, macOS)

# Name: CPU
# - Type: String
# - Default value: 90:95
# - Description: WARN Level:CRITICAL Level

# Name: MEMORY
# - Type: String
# - Default value: 90:95:%
# - Description: WARN Level:CRITICAL Level:UNITS

write_DRMMAlert() {
    local message="$1"
    printf '<-Start Result->\n'
    printf "Alert=%s\n" "$message"
    printf '<-End Result->\n'
}

if ! test -f /usr/local/bin/check_docker; then
  wget -O /usr/local/bin/check_docker https://raw.githubusercontent.com/jensritter/check_docker/master/check_docker/check_docker.py
  chmod a+rx /usr/local/bin/check_docker
fi

CONTAINER = $(docker ps --filter "status=running" --format \'{{.Names}}\')


CHECK_DOCKER_OUTPUT=$(/usr/local/bin/check_docker --containers $CONTAINER --no-ok --cpu $CPU --memory $MEMORY) && {
        write_DRMMAlert "Healthy"
} || {
        write_DRMMAlert "Unhealthy"
        printf '<-Start Diagnostic->\n'
        printf "Alert=%s\n" "$CHECK_DOCKER_OUTPUT"
        printf '<-End Diagnostic->\n'
        exit 1
}
