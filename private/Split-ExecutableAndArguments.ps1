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

    # Only search the Machine-Scope PATH
    # Package commands would not rely on a user-specific PATH setup so skip it to avoid false matches
    [string[]]$MachinePathDirectories = [System.Environment]::GetEnvironmentVariable("Path", "Machine").Split(';') | Where-Object { $_ }
    [string[]]$MachinePathExtensions  = [System.Environment]::GetEnvironmentVariable("PATHEXT", "Machine").Split(';') | Where-Object { $_ }

    # Workaround for #57
    if ($Command.StartsWith('START /WAIT')) {
        $Command = $Command.Substring(11).TrimStart()
    }
    $pathParts = $Command -split ' '

    # Repeatedly remove parts of the string from the end and test
    for ($end = $pathParts.Count - 1; $end -ge 0; $end--) {
        $testPath = [String]::Join(' ', $pathParts[0..$end])

        # We have to trim quotes because they mess up GetFullPath() and Join-Path
        $testPath = $testPath.Trim('"')

        if ( [System.IO.File]::Exists($testPath) ) {
            return @(
                [System.IO.Path]::GetFullPath($testPath),
                "$($pathParts | Select-Object -Skip ($end + 1))"
            )
        }

        # In PowerShell 7.3 and 7.4 Join-Path throws an exception (not a PowerShell error, a .NET exception)
        # when it tries to combine certain invalid paths (e.g. Join-Path -Path 'C:\' -ChildPath 'C:\ /x:').
        # These exceptions are not influenced by ErrorAction, so we need a try-catch. We still set ErrorAction
        # to Stop because whenever Join-Path doesn't succeed for any reason, we can always skip and continue
        # in the loop because there won't be a new path to test in testPathRelative. See issue #96.
        try {
            $testPathRelative = Join-Path -Path $WorkingDirectory -ChildPath $testPath -ErrorAction Stop
        }
        catch [System.IO.IOException] {
            continue
        }

        if ( [System.IO.File]::Exists($testPathRelative) ) {
            return @(
                [System.IO.Path]::GetFullPath($testPathRelative),
                "$($pathParts | Select-Object -Skip ($end + 1))"
            )
        }
    }

    # Some commands call/rely on executables in PATH and even call
    # them without their file extension (see issue #57). To support this
    # we also have to search PATH with PATHEXT for potential file matches
    $testPath = $pathParts[0].Trim('"')

    foreach ($MachinePathDir in $MachinePathDirectories) {
        $testPathInPath = Join-Path -Path $MachinePathDir -ChildPath $testPath
        if ([System.IO.File]::Exists($testPathInPath)) {
            return @(
                [System.IO.Path]::GetFullPath($testPathInPath),
                "$($pathParts | Select-Object -Skip 1)"
            )
        }
        foreach ($FileExtension in $MachinePathExtensions) {
            $testPathInPathWithExt = $testPathInPath + $FileExtension
            if ([System.IO.File]::Exists($testPathInPathWithExt)) {
                return @(
                    [System.IO.Path]::GetFullPath($testPathInPathWithExt),
                    "$($pathParts | Select-Object -Skip 1)"
                )
            }
        }
    }
}
