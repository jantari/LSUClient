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

    for ($i = $pathParts.Count - 1; $i -ge 0; $i--) {
        $testPath = [String]::Join(' ', $pathParts[0..$i])

        # We have to trim quotes because they mess up GetFullPath() and Join-Path
        $testPath = $testPath.Trim('"')

        if ( [System.IO.File]::Exists($testPath) ) {
            return @(
                [System.IO.Path]::GetFullPath($testPath),
                "$($pathParts | Select-Object -Skip ($i + 1))"
            )
        }

        $testPathRelative = Join-Path -Path $WorkingDirectory -ChildPath $testPath

        if ( [System.IO.File]::Exists($testPathRelative) ) {
            return @(
                [System.IO.Path]::GetFullPath($testPathRelative),
                "$($pathParts | Select-Object -Skip ($i + 1))"
            )
        }
    }
}
