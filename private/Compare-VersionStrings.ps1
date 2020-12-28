function Compare-VersionStrings {
    <#
        .SYNOPSIS
        This function parses some of Lenovos conventions for expressing
        version requirements and does the comparison. Returns 0, -1 or -2.
    #>

    [CmdletBinding()]
    [OutputType('System.Int32')]
    Param (
        [ValidateNotNullOrEmpty()]
        [string]$LenovoString,
        [ValidateNotNullOrEmpty()]
        [string]$SystemString
    )

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
        # It also sometimes contains spaces, like in package r07iw22w_8260
        $LenovoStringSanitized = $LenovoString -replace '^\^|\s|\^$'
        if (-not ([Version]::TryParse( $LenovoStringSanitized, [ref]$null ))) {
            # Unknown character in version string or ^ at both the first and last positions
            Write-Verbose "Got unsupported version format from Lenovo: '$LenovoString'"
            return -2
        }

        [Version]$LenovoVersion = $LenovoStringSanitized
        [Version]$SystemVersion = $SystemString

        switch -Wildcard ($LenovoString) {
            "^*^" {
                Write-Verbose "Got unsupported version format from Lenovo: '$LenovoString'"
                return -2
            }
            "^*" {
                # Means up to and including
                if ($SystemVersion -le $LenovoVersion) {
                    return 0
                } else {
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
