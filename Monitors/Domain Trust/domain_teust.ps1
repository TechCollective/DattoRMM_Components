# Monitor Script to check the status of the computer's secure channel with the domain

# Run the Test-ComputerSecureChannel cmdlet
If (Test-ComputerSecureChannel -ErrorAction SilentlyContinue) {
    # Output the result in the required format for Datto RMM
    Write-Host '<-Start Result->'
    Write-Host "STATUS=Secure channel with the domain is functioning correctly"
    Write-Host '<-End Result->'
    # Exit with code 0 to indicate success
    Exit 0
} else {
    # Output the result in the required format for Datto RMM
    Write-Host '<-Start Result->'
    Write-Host "STATUS=Secure channel with the domain is broken"
    Write-Host '<-End Result->'
    # Exit with code 1 to indicate failure
    Exit 1
}