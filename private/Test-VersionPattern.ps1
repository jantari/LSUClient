function Test-VersionPattern {
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

    [bool]$LenovoStringIsParsable = $LenovoString -match "^[\d\.]+$"
    [bool]$SystemStringIsParsable = $SystemString -match "^[\d\.]+$"

    if (-not $SystemStringIsParsable) {
        Write-Verbose "Got unsupported version format from OS: '$SystemString'"
        return -2
    }

    if ($LenovoStringIsParsable) {
        # Easiest case, both inputs are just version numbers
        if ((Compare-Version -ReferenceVersion $SystemString.Split('.') -DifferenceVersion $LenovoString.Split('.')) -eq 0) {
            return 0 # SUCCESS, Versions match
        } else {
            return -1
        }
    } else {
        # Lenovo string contains additional directive (^-symbol likely)
        # It also sometimes contains spaces, like in package r07iw22w_8260
        $LenovoStringSanitized = $LenovoString -replace '^\^|\s|\^$'
        if ($LenovoStringSanitized -notmatch "^[\d\.]+$") {
            # Unknown character in version string, cannot continue
            Write-Verbose "Got unsupported version format from Lenovo: '$LenovoString'"
            return -2
        }

        switch -Wildcard ($LenovoString) {
            "^*^" {
                Write-Verbose "Got unsupported version format from Lenovo: '$LenovoString'"
                return -2
            }
            "^*" {
                # Means up to and including
                if ((Compare-Version -ReferenceVersion $SystemString.Split('.') -DifferenceVersion $LenovoStringSanitized.Split('.')) -in 0,2) {
                    return 0
                } else {
                    return -1
                }
            }
            "*^" {
                # Means must be equal or higher than
                if ((Compare-Version -ReferenceVersion $SystemString.Split('.') -DifferenceVersion $LenovoStringSanitized.Split('.')) -in 0,1) {
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
