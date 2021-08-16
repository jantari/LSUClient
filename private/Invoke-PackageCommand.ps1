function Invoke-PackageCommand {
    <#
        .SYNOPSIS
        Tries to run a command, returns its ExitCode and Output if successful, otherwise returns NULL
    #>

    [CmdletBinding()]
    Param (
        [ValidateNotNullOrEmpty()]
        [string]$Path,
        [ValidateNotNullOrEmpty()]
        [Parameter( Mandatory = $true )]
        [string]$Command,
        [switch]$FallbackToShellExecute
    )

    # Remove any trailing backslashes from the Path.
    # This isn't necessary, because Split-ExecutableAndArguments can handle and trims
    # extra backslashes, but this will make the path look more sane in errors and warnings.
    $Path = $Path.TrimEnd('\')

    # Lenovo sometimes forgets to put a directory separator betweeen %PACKAGEPATH% and the executable so make sure it's there
    # If we end up with two backslashes, Split-ExecutableAndArguments removes the duplicate from the executable path, but
    # we could still end up with a double-backslash after %PACKAGEPATH% somewhere in the arguments for now.
    [string]$Command       = Resolve-CmdVariable -String $Command -ExtraVariables @{'PACKAGEPATH' = "${Path}\"}
    [string[]]$StdOutLines = @()
    [string[]]$StdErrLines = @()
    $ExeAndArgs            = Split-ExecutableAndArguments -Command $Command -WorkingDirectory $Path
    # Split-ExecutableAndArguments returns NULL if no executable could be found
    if (-not $ExeAndArgs) {
        Write-Warning "The command or file '$Command' could not be found from '$Path' and was not run"
        return $null
    }

    $ExeAndArgs.Arguments = Remove-CmdEscapeCharacter -String $ExeAndArgs.Arguments

    Write-Debug "Starting external process:`r`n  File: $($ExeAndArgs.Executable)`r`n  Arguments: $($ExeAndArgs.Arguments)`r`n  WorkingDirectory: $Path"
    $RunspaceOutput = Start-ProcessInRunspace -Executable $ExeAndArgs.Executable -Arguments $ExeAndArgs.Arguments -WorkingDirectory $Path -FallbackToShellExecut:$FallbackToShellExecute
    $RunspaceOutput | Format-List | Out-Host

    if ($RunspaceOutput.StdOutStream.Count -ne 1) {
        Write-Warning "Unexpected results: More than 1 object returned: $($RunspaceOutput.StdOutStream)"
        return $null
    }

    # Print any unhandled / unexpected errors as warnings
    if ($RunspaceOutput.StdErrStream.Count -gt 0) {
        foreach ($ErrorRecord in $RunspaceOutput.StdErrStream) {
            Write-Warning $ErrorRecord
        }
    }

    switch ($RunspaceOutput.StdOutStream[0].HandledError) {
        # Success case
        0 {
            $RunspaceOutput.StdOutStream[0] | Format-List | Out-Host
            return $RunspaceOutput.StdOutStream[0]
        }
        # Error cases that are handled explicitly
        1 {
            Write-Warning "No new process was created or a handle to it could not be obtained."
            Write-Warning "Executable was: '$($ExeAndArgs.Executable)' - this should *probably* not have happened"
            return $null
        }
        740 {
            if (-not $FallbackToShellExecute) {
                Write-Warning "This process requires elevated privileges - falling back to ShellExecute, consider running PowerShell as Administrator"
                Write-Warning "Process output cannot be captured when running with ShellExecute!"
                return (Invoke-PackageCommand -Path:$Path -Command:$Command -FallbackToShellExecute)
            }
        }
        193 {
            if (-not $FallbackToShellExecute) {
                Write-Warning "The file to be run is not an executable - falling back to ShellExecute"
                return (Invoke-PackageCommand -Path:$Path -Command:$Command -FallbackToShellExecute)
            }
        }
    }

    return $returnInfo
}
