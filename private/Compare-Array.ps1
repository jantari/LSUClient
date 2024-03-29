﻿function Compare-Array {
    <#
        .SYNOPSIS
        This function compares the objects in two arrays/enumerables and returns true on success.
        It doesn't care whether one element is a System.Array and the other a List,
        only the elements within the collection are compared.

        .PARAMETER containsonly
        This is NOT an equals check! Because it returns true regardless of the count of elements,
        e.g. 'a', 'b', 'b' -containsonly 'b', 'a', 'a' is TRUE even though the arrays are not equal!

        .PARAMETER in
        Checks whether all elements of ArrayOne are in ArrayTwo. Does not care about extra elements
        in ArrayTwo, if any.

        .NOTES
        This can also be achieved with Compare-Object, but that function
        is slower and returns unnecessarily complex objects.

        Return values: True or False
    #>

    [OutputType('System.Boolean')]
    Param (
        [Parameter(Mandatory = $true, Position = 0)]
        [array]$ArrayOne,
        [Parameter(Position = 1, ParameterSetName="CONTAINSONLY")]
        [switch]$containsonly,
        [Parameter(Position = 1, ParameterSetName="IN")]
        [switch]$in,
        [Parameter(Mandatory = $true, Position = 2)]
        [array]$ArrayTwo
    )

    foreach ($ElementOfOne in $ArrayOne) {
        if ($ElementOfOne -notin $ArrayTwo) {
            return $false
        }
    }

    if ($containsonly) {
        foreach ($ElementOfTwo in $ArrayTwo) {
            if ($ElementOfTwo -notin $ArrayOne) {
                return $false
            }
        }
    }

    return $true
}
