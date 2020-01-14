function Assert-CmdAmpersandEscaped {
    <#
        .NOTES
        All CMD Metacharacters are: ( ) % ! ^ " < > & |
        but since it's impossibe to escape them properly ( we don't know what's intentional and what isn't )
        only the most common problem source & (since it appears in HardwareIDs) is adressed. See issue #2.
    #>

    [OutputType('System.String')]
    Param (
        [string]$String
    )

    if (-not $String.Contains('&')) {
        return $String
    }

    [bool]$CurrentlyInQuotes = $false
    [int]$NextCharVerbatim   = 0

    $newString = for ($i = 0; $i -lt $String.Length; $i++) {
        switch ($String[$i]) {
            '"' {
                $CurrentlyInQuotes = $CurrentlyInQuotes -bxor 1
            }
            '&' {
                if (-not $CurrentlyInQuotes -and -not $NextCharVerbatim) {
                    '^'
                }
            }
            '^' {
                # Carets are returned "as is" (not further escaped) because they are most likely intentional,
                # but an escaped caret cannot further escape a following ampersand
                if (-not $CurrentlyInQuotes -and -not $NextCharVerbatim) {
                    $NextCharVerbatim = 2
                }
            }
        }

        $String[$i]
        if ($NextCharVerbatim) {
            $NextCharVerbatim--
        }
    }

    return -join $newString
}