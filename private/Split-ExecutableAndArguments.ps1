function Split-ExecutableAndArguments {
    <#
        .SYNOPSIS
        This function seperates the exeutable path from its command line arguments

        Returns nothing if unsuccessful
    #>

    Param (
        [ValidateNotNullOrEmpty()]
        [string]$Command
    )

    $pathParts = $Command -split ' '

    for ($i = $pathParts.Count - 1; $i -ge 0; $i--) {
        $testPath = [String]::Join(' ', $pathParts[0..$i])

        if ( [System.IO.File]::Exists($testPath) ) {
            return [PSCustomObject]@{
                "EXECUTABLE" = "$testPath"
                "ARGUMENTS"  = "$($pathParts | Select-Object -Skip ($i + 1))"
            }
        }
    }
}