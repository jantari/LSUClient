function Split-ExecutableAndArguments {
    <#
        .SYNOPSIS
        This function seperates the exeutable path from its command line arguments

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
            return [PSCustomObject]@{
                "Executable" = [System.IO.Path]::GetFullPath($testPath)
                "Arguments"  = "$($pathParts | Select-Object -Skip ($i + 1))"
            }
        }

        $testPathRelative = Join-Path -Path $WorkingDirectory -ChildPath $testPath

        if ( [System.IO.File]::Exists($testPathRelative) ) {
            return [PSCustomObject]@{
                "Executable" = [System.IO.Path]::GetFullPath($testPathRelative)
                "Arguments"  = "$($pathParts | Select-Object -Skip ($i + 1))"
            }
        }
    }
}
