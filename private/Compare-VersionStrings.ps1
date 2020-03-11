function Compare-VersionStrings {
    <#
        .SYNOPSIS
        This function parses some of Lenovos conventions for expressing
        version requirements and does the comparison. Returns 0, -1 or -2.
    #>

    [CmdletBinding()]
    [OutputType('System.SByte')]
    Param (
        [ValidateNotNullOrEmpty()]
        [string]$LenovoString,
        [ValidateNotNullOrEmpty()]
        [string]$SystemString
    )

    Write-Host "LENOVO-STRING: $LenovoString" -ForegroundColor Magenta
    Write-Host "SYSTEM-STRING: $SystemString" -ForegroundColor Magenta

    [bool]$LenovoStringIsVersion = [Version]::TryParse( $LenovoString, [ref]$null )
    [bool]$SystemStringIsVersion = [Version]::TryParse( $SystemString, [ref]$null )

    if (-not $SystemStringIsVersion) {
        Write-Verbose "Got unsupported version format from OS: '$SystemString'"
        return -2
    }

    if ($LenovoStringIsVersion) {
        # Easiest case, both inputs are just version numbers
        if ([Version]::new($LenovoString) -eq [Version]::new($SystemString)) {
            return 0 # SUCCESS, Versions match
        } else {
            return -1
        }
    } else {
        # Lenovo string contains additional directive (^-symbol likely)
        if (-not ($LenovoString -match '^\^?[\d\.]+$' -xor $LenovoString -match '^[\d\.]+\^?$')) {
            # Unknown character in version string or ^ at both the first and last positions
            Write-Verbose "Got unsupported version format from Lenovo: '$LenovoString'"
            return -2
        }

        [Version]$LenovoVersion = $LenovoString -replace '\^'
        [Version]$SystemVersion = $SystemString
        
        switch -Wildcard ($LenovoString) {
            "^*" {
                Write-Verbose "SystemVersion: '$SystemVersion'"
                Write-Verbose "Up to and including '$LenovoVersion'"
                # Means up to and including
                if ($SystemVersion -le $LenovoVersion) {
                    Write-Verbose "returning 0!"
                    return 0
                } else {
                    Write-Verbose "returning -1!"
                    return -1
                }
            }
            "*^" {
                # Means must be equal or higher than
                if ($SystemVersion -ge $LenovoVersion) {
                    return 0
                } else {
                    return -1
                }
            }
            default {
                Write-Verbose "Got unsupported version format from Lenovo: '$LenovoString'"
                return -2
            }
        }
    }
}