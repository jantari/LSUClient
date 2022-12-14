function Test-VersionPattern {
    <#
        .SYNOPSIS
        This function parses some of Lenovos conventions for expressing
        version requirements and does the comparison. Returns 0, -1 or -2.

        .PARAMETER LenovoStringFormat
        Force the LenovoString input to be interpreted as decimal or hexadecimal.
        The default setting, Auto, assumes decimal first but falls back to hexadecimal
        if the number isn't valid in decimal.

        .PARAMETER SystemStringFormat
        Force the SystemString input to be interpreted as decimal or hexadecimal.
        The default setting, Auto, assumes decimal first but falls back to hexadecimal
        if the number isn't valid in decimal.
    #>

    [CmdletBinding()]
    [OutputType('System.Int32')]
    Param (
        [ValidateNotNullOrEmpty()]
        [string]$LenovoString,
        [ValidateSet('Auto', 'Dec', 'Hex')]
        [string]$LenovoStringFormat = 'Auto',
        [ValidateNotNullOrEmpty()]
        [string]$SystemString,
        [ValidateSet('Auto', 'Dec', 'Hex')]
        [string]$SystemStringFormat = 'Auto'
    )

    [string]$SystemStringDec = ''
    [string]$GreaterOrEqual  = ''
    [string]$LessOrEqual     = ''
    [string]$ExactlyEqual    = ''

    # Lenovo version can sometimes contains spaces, like in package r07iw22w_8260
    $LenovoStringSanitized = $LenovoString.Replace(' ', '')

    [bool]$LenovoStringIsParsableDec = $LenovoStringSanitized -match "^[\d\.]*\^?[\d\.]*$"
    [bool]$LenovoStringIsParsableHex = $LenovoStringSanitized -match '^[\da-f]*\^?[\da-f]*$'

    if ($LenovoStringIsParsableDec -and $LenovoStringFormat -ne 'Hex') {
        # Lenovo string can contain the additional directive ^-symbol
        if ($LenovoStringSanitized.Contains('^')) {
            $GreaterOrEqual, $LessOrEqual = $LenovoStringSanitized.Split('^')
        } else {
            $ExactlyEqual = $LenovoStringSanitized
        }
    } elseif ($LenovoStringIsParsableHex -and $LenovoStringFormat -ne 'Dec') {
        if ($LenovoStringSanitized.Contains('^')) {
            try {
                $GreaterOrEqual, $LessOrEqual = $LenovoStringSanitized.Split('^') | ForEach-Object {
                     if ($_) { [Convert]::ToUInt32($_, 16) } else { '' }
                }
            }
            catch {
                Write-Verbose "Got unsupported hex version format from Lenovo: '$LenovoString' ($_)"
                return -2
            }
        } else {
            $ExactlyEqual = [Convert]::ToUInt32($LenovoStringSanitized, 16)
        }
    } else {
        # Unknown character in version string, cannot continue
        Write-Verbose "Got unsupported version format from Lenovo: '$LenovoString'"
        return -2
    }

    [bool]$SystemStringIsParsableDec = $SystemString -match "^[\d\.]+$"
    [bool]$SystemStringIsParsableHex = $SystemString -match '^[\da-f]+$'

    if ($SystemStringIsParsableDec -and $SystemStringFormat -ne 'Hex') {
        $SystemStringDec = $SystemString
    } elseif ($SystemStringIsParsableHex -and $SystemStringFormat -ne 'Dec') {
        $SystemStringDec = [Convert]::ToUInt32($SystemString, 16)
    } else {
        Write-Verbose "Got unsupported version format from OS: '$SystemString'"
        return -2
    }

    # Exact match test
    if ($ExactlyEqual) {
        if ((Compare-Version -ReferenceVersion $SystemStringDec.Split('.') -DifferenceVersion $ExactlyEqual.Split('.')) -ne 0) {
            return -1
        }
    }
    # Greater than, Less than, or within range (if both combined) tests
    if ($LessOrEqual) {
        # System version must be less or equal
        if ((Compare-Version -ReferenceVersion $SystemStringDec.Split('.') -DifferenceVersion $LessOrEqual.Split('.')) -notin 0,2) {
            return -1
        }
    }
    if ($GreaterOrEqual) {
        # System version must be equal or higher than
        if ((Compare-Version -ReferenceVersion $SystemStringDec.Split('.') -DifferenceVersion $GreaterOrEqual.Split('.')) -notin 0,1) {
            return -1
        }
    }

    return 0 # SUCCESS, SystemVersion meets version pattern criteria
}
