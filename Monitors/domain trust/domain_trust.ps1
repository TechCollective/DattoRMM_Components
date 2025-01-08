# Monitor Script to test domain trust using both nltest and Test-ComputerSecureChannel

function check_domain {
    param ($computerSystem)
    If (-not ($computerSystem.PartOfDomain)) {
        Write-Host '<-Start Result->'
        Write-Host "STATUS=Computer is not joined to a domain."
        Write-Host '<-End Result->'
        return $false
    }
    return $true
}

function test_nltest {
    param ($domain)
    Try {
        nltest /sc_verify:$domain
        $exitCode = $LASTEXITCODE
        If ($exitCode -eq 0) {
            Write-Host "INFO=nltest succeeded. Exit code: $exitCode"
            return $true
        } Else {
            Write-Host "INFO=nltest failed. Exit code: $exitCode"
            return $false
        }
    } Catch {
        Write-Host "INFO=nltest encountered an error: $($_.Exception.Message)"
        return $false
    }
}

function test_secure_channel {
    Try {
        If (Test-ComputerSecureChannel -ErrorAction SilentlyContinue) {
            return $true
        } Else {
            Write-Host "INFO=Test-ComputerSecureChannel reported a broken secure channel"
            return $false
        }
    } Catch {
        Write-Host "INFO=Test-ComputerSecureChannel encountered an error: $($_.Exception.Message)"
        return $false
    }
}

function evaluate_results {
    param ($nltestPassed, $secureChannelPassed, $domain)
    If ($nltestPassed -and $secureChannelPassed) {
        Write-Host '<-Start Result->'
        Write-Host "STATUS=Secure channel is functioning correctly. Both nltest and Test-ComputerSecureChannel passed for domain $domain."
        Write-Host '<-End Result->'
        return
    } Else {
        Write-Host '<-Start Result->'
        Write-Host "STATUS=Secure channel verification failed for domain $domain."
        Write-Host "DETAILS=nltest result: $($nltestPassed), Test-ComputerSecureChannel result: $($secureChannelPassed)"
        Write-Host '<-End Result->'
        return
    }
}

function main {
    $computerSystem = Get-WmiObject -Class Win32_ComputerSystem

    # Check if the computer is joined to a domain
    If (-not (check_domain -computerSystem $computerSystem)) {
        return
    }

    # Test nltest and secure channel
    $nltestPassed = test_nltest -domain $computerSystem.Domain
    $secureChannelPassed = test_secure_channel

    # Evaluate the results
    evaluate_results -nltestPassed $nltestPassed -secureChannelPassed $secureChannelPassed -domain $computerSystem.Domain
}

main
