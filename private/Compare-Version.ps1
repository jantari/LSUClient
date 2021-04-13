function Compare-Version {
    <#
        .DESCRIPTION
        Compares two version numbers, each passed as an array of numbers (split on the dots).
        Returns 1 when the ReferenceVersion was higher, 2 for the DifferenceVersion or 0 for equal.
    #>

    [OutputType('System.Int32')]
    Param (
        [ValidateNotNullOrEmpty()]
        [UInt32[]]$ReferenceVersion,
        [ValidateNotNullOrEmpty()]
        [UInt32[]]$DifferenceVersion
    )

    $longerVersion = if ($ReferenceVersion.Count -gt $DifferenceVersion.Count) {
        $ReferenceVersion.Count
    } else {
        $DifferenceVersion.Count
    }

    for ($i = 0; $i -lt $longerVersion; $i++) {
        $FirstNumber = if ($i -lt $ReferenceVersion.Count) {
            $ReferenceVersion[$i]
        } else {
            0
        }

        $SecondNumber = if ($i -lt $DifferenceVersion.Count) {
            $DifferenceVersion[$i]
        } else {
            0
        }

        if ($FirstNumber -gt $SecondNumber) {
            return 1
        } elseif ($FirstNumber -lt $SecondNumber) {
            return 2
        }
    }

    # Equal
    return 0
}
