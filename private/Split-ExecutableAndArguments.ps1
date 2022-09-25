function Split-ExecutableAndArguments {
    <#
        .SYNOPSIS
        This function seperates the exeutable path from its command line arguments
        and returns the absolute path to the executable (resolves relative) as well
        as the arguments separately.

        Returns NULL if unsuccessful
    #>

    Param (
        [ValidateNotNullOrEmpty()]
        [string]$Command,
        [Parameter( Mandatory = $true )]
        [string]$WorkingDirectory
    )

    $pathParts = $Command -split ' '

    # If necessary, also try removing parts from the start of the string
    # This loop will rarely run more than 1 iteration, but commands can
    # start with "START /WAIT ..." for example, see issue #57
    for ($start = 0; $start -lt $pathParts.Count; $start++) {
        # Repeatedly remove parts of the string from the end and test
        for ($end = $pathParts.Count - 1; $end -ge $start; $end--) {
            $testPath = [String]::Join(' ', $pathParts[$start..$end])

            # We have to trim quotes because they mess up GetFullPath() and Join-Path
            $testPath = $testPath.Trim('"')

            if ( [System.IO.File]::Exists($testPath) ) {
                return @(
                    [System.IO.Path]::GetFullPath($testPath),
                    "$($pathParts | Select-Object -Skip ($end + 1))"
                )
            }

            $testPathRelative = Join-Path -Path $WorkingDirectory -ChildPath $testPath

            if ( [System.IO.File]::Exists($testPathRelative) ) {
                return @(
                    [System.IO.Path]::GetFullPath($testPathRelative),
                    "$($pathParts | Select-Object -Skip ($end + 1))"
                )
            }
        }
    }
}
