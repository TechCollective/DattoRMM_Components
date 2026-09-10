#!/bin/bash

# Name: APT update availble for PACKAGE [LIN]
# Description: Will run apt -y update, then check if a package can be updated and alert if it can be.
# Category: Monitoring
# Script: Shell (Unix, macOS)
# Variables
# Name: PACKAGE
# - Type: String
# - Default value:
# - Description: Package you want to monitor

write_DRMMAlert() {
    local message="$1"
    printf '<-Start Result->\n'
    printf "Alert=%s\n" "$message"
    printf '<-End Result->\n'
}

write_Diagnostic() {
    local message="$1"
    printf '<-Start Diagnostic->\n'
    printf "%s\n" "$message"
    printf '<-End Diagnostic->\n'
}

check_package_update() {
    local package="$1"

    # Update package list
    if ! sudo apt-get update -y; then
        write_DRMMAlert "Unhealthy: Failed to update package list"
        write_Diagnostic "The package list update failed. Please check your network connection and repository configuration."
        return 1
    fi

    # Check if package has an update available
    local package_status
    package_status=$(apt list --upgradable 2>/dev/null | grep -w "$package")

    if [[ -n "$package_status" ]]; then
        write_DRMMAlert "Update available for $package"
        write_Diagnostic "There is an update available for the package $package."
        return 1
    else
        write_DRMMAlert "No updates available for $package"
        return 0
    fi
}

main() {
    if [[ -z "$PACKAGE" ]]; then
        write_DRMMAlert "Unhealthy: No package specified"
        write_Diagnostic "Please specify a package name to check for updates."
        exit 1
    fi

#    local package="$1"
    local package="$PACKAGE"
    if ! check_package_update "$package"; then
        exit 1
    fi
}

# Execute main function
main "$@"
