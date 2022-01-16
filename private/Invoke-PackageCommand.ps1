function Invoke-PackageCommand {
    <#
        .SYNOPSIS
        Tries to run a command and returns an object containing an error
        code and optionally information about the process that was run.
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
    [string]$ExpandedCommandString = Resolve-CmdVariable -String $Command -ExtraVariables @{'PACKAGEPATH' = "${Path}\"; 'WINDOWS' = $env:SystemRoot}
    $ExeAndArgs = Split-ExecutableAndArguments -Command $ExpandedCommandString -WorkingDirectory $Path
    # Split-ExecutableAndArguments returns NULL if no executable could be found
    if (-not $ExeAndArgs) {
        Write-Warning "The command or file '$Command' could not be found from '$Path' and was not run"
        return [ExternalProcessResult]::new(
            [ExternalProcessError]::FILE_NOT_FOUND,
            $null
        )
    }

    $ExeAndArgs.Arguments = Remove-CmdEscapeCharacter -String $ExeAndArgs.Arguments
    Write-Debug "Starting external process:`r`n  File: $($ExeAndArgs.Executable)`r`n  Arguments: $($ExeAndArgs.Arguments)`r`n  WorkingDirectory: $Path"

    $Runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateOutOfProcessRunspace($null)
    $Runspace.Open()

    $Powershell = [PowerShell]::Create().AddScript{
        Param (
            [ValidateNotNullOrEmpty()]
            [string]$WorkingDirectory,
            [ValidateNotNullOrEmpty()]
            [Parameter( Mandatory = $true )]
            [string]$Executable,
            [string]$Arguments,
            [switch]$FallbackToShellExecute
        )

        Set-StrictMode -Version 3.0

        # This value is used to communicate problems and errors that can be handled and or remedied/retried
        # internally to the calling function. It stays 0 when no known errors occurred.
        $HandledError = 0
        $ProcessStarted = $false
        [string[]]$StdOutLines = @()
        [string[]]$StdErrLines = @()

        $process                                  = [System.Diagnostics.Process]::new()
        $process.StartInfo.WindowStyle            = [System.Diagnostics.ProcessWindowStyle]::Hidden
        $process.StartInfo.UseShellExecute        = $false
        $process.StartInfo.WorkingDirectory       = $WorkingDirectory
        $process.StartInfo.FileName               = $Executable
        $process.StartInfo.Arguments              = $Arguments
        $process.StartInfo.RedirectStandardOutput = $true
        $process.StartInfo.RedirectStandardError  = $true

        if ($FallbackToShellExecute) {
            $process.StartInfo.UseShellExecute        = $true
            $process.StartInfo.RedirectStandardOutput = $false
            $process.StartInfo.RedirectStandardError  = $false
        }

        try {
            if (-not $process.Start()) {
                $HandledError = 1
            } else {
                $ProcessStarted = $true
            }
        }
        catch {
            # In case we get ERROR_ELEVATION_REQUIRED (740) retry with ShellExecute to elevate with UAC
            if ($null -ne $_.Exception.InnerException -and $_.Exception.InnerException.NativeErrorCode -eq 740) {
                $HandledError = 740
            # In case we get ERROR_BAD_EXE_FORMAT (193) retry with ShellExecute to open files like MSI
            } elseif ($null -ne $_.Exception.InnerException -and $_.Exception.InnerException.NativeErrorCode -eq 193) {
                $HandledError = 193
            } else {
                Write-Error $_
            }
        }

        if ($ProcessStarted) {
            if (-not $FallbackToShellExecute) {
                # When redirecting StandardOutput or StandardError you have to start reading the streams asynchronously, or else it can cause
                # programs that output a lot (like package u3aud03w_w10 - Conexant USB Audio) to fill a stream and deadlock/hang indefinitely.
                # See issue #25 and https://stackoverflow.com/questions/11531068/powershell-capturing-standard-out-and-error-with-process-object
                $StdOutAsync = $process.StandardOutput.ReadToEndAsync()
                $StdErrAsync = $process.StandardError.ReadToEndAsync()
            }

            $process.WaitForExit()

            if (-not $FallbackToShellExecute) {
                $StdOutInOneString = $StdOutAsync.GetAwaiter().GetResult()
                $StdErrInOneString = $StdErrAsync.GetAwaiter().GetResult()

                [string[]]$StdOutLines = $StdOutInOneString.Split(
                    [string[]]("`r`n", "`r", "`n"),
                    [StringSplitOptions]::None
                )

                [string[]]$StdErrLines = $StdErrInOneString.Split(
                    [string[]]("`r`n", "`r", "`n"),
                    [StringSplitOptions]::None
                )
            }
        }

        return [PSCustomObject]@{
            'StandardOutput' = $StdOutLines
            'StandardError'  = $StdErrLines
            'ExitCode'       = $process.ExitCode
            'Runtime'        = $process.ExitTime - $process.StartTime
            'HandledError'   = $HandledError
        }
    }

    [void]$Powershell.AddParameters(@{
        'WorkingDirectory'       = $Path
        'Executable'             = $ExeAndArgs.Executable
        'Arguments'              = $ExeAndArgs.Arguments
        'FallbackToShellExecute' = $FallbackToShellExecute
    })

    $Powershell.Runspace = $Runspace
    $RunspaceStandardOut = $Powershell.Invoke()

    # Print any unhandled / unexpected errors as warnings
    if ($PowerShell.Streams.Error.Count -gt 0) {
        foreach ($ErrorRecord in $PowerShell.Streams.Error.ReadAll()) {
            Write-Warning $ErrorRecord
        }
    }

    $PowerShell.Runspace.Dispose()
    $PowerShell.Dispose()

    # Test for NULL before indexing into array. RunspaceStandardOut can be null
    # when the runspace aborted abormally, for example due to an exception.
    if ($null -ne $RunspaceStandardOut -and $RunspaceStandardOut.Count -gt 0) {
        switch ($RunspaceStandardOut[-1].HandledError) {
            # Success case
            0 {
                $NonEmptyPredicate = [Predicate[string]] { -not [string]::IsNullOrWhiteSpace($args[0]) }

                $StdOutFirstNonEmpty = [array]::FindIndex([string[]]$RunspaceStandardOut[-1].StandardOutput, $NonEmptyPredicate)
                if ($StdOutFirstNonEmpty -ne -1) {
                    $StdOutLastNonEmpty = [array]::FindLastIndex([string[]]$RunspaceStandardOut[-1].StandardOutput, $NonEmptyPredicate)
                    $StdOutTrimmed = $RunspaceStandardOut[-1].StandardOutput[$StdOutFirstNonEmpty..$StdOutLastNonEmpty]
                } else {
                    $StdOutTrimmed = @()
                }

                $StdErrFirstNonEmpty = [array]::FindIndex([string[]]$RunspaceStandardOut[-1].StandardError, $NonEmptyPredicate)
                if ($StdErrFirstNonEmpty -ne -1) {
                    $StdErrLastNonEmpty = [array]::FindLastIndex([string[]]$RunspaceStandardOut[-1].StandardError, $NonEmptyPredicate)
                    $StdErrTrimmed = $RunspaceStandardOut[-1].StandardError[$StdErrFirstNonEmpty..$StdErrLastNonEmpty]
                } else {
                    $StdErrTrimmed = @()
                }

                return [ExternalProcessResult]::new(
                    [ExternalProcessError]::NONE,
                    [ProcessReturnInformation]@{
                        'FilePath'         = $ExeAndArgs.Executable
                        'Arguments'        = $ExeAndArgs.Arguments
                        'WorkingDirectory' = $Path
                        'StandardOutput'   = $StdOutTrimmed
                        'StandardError'    = $StdErrTrimmed
                        'ExitCode'         = $RunspaceStandardOut[-1].ExitCode
                        'Runtime'          = $RunspaceStandardOut[-1].Runtime
                    }
                )
            }
            # Error cases that are handled explicitly inside the runspace
            1 {
                Write-Warning "No new process was created or a handle to it could not be obtained."
                Write-Warning "Executable was: '$($ExeAndArgs.Executable)' - this should *probably* not have happened"
                return [ExternalProcessResult]::new(
                    [ExternalProcessError]::PROCESS_REUSED,
                    $null
                )
            }
            740 {
                if (-not $FallbackToShellExecute) {
                    Write-Warning "This process requires elevated privileges - falling back to ShellExecute, consider running PowerShell as Administrator"
                    Write-Warning "Process output cannot be captured when running with ShellExecute!"
                    return (Invoke-PackageCommand -Path:$Path -Command:$Command -FallbackToShellExecute)
                } else {
                    return [ExternalProcessResult]::new(
                        [ExternalProcessError]::PROCESS_REQUIRES_ELEVATION,
                        $null
                    )
                }
            }
            193 {
                if (-not $FallbackToShellExecute) {
                    Write-Warning "The file to be run is not an executable - falling back to ShellExecute"
                    return (Invoke-PackageCommand -Path:$Path -Command:$Command -FallbackToShellExecute)
                } else {
                    return [ExternalProcessResult]::new(
                        [ExternalProcessError]::FILE_NOT_EXECUTABLE,
                        $null
                    )
                }
            }
        }
    } else {
        Write-Warning "The external process runspace did not run to completion because an unexpected error occurred."
        return [ExternalProcessResult]::new(
            [ExternalProcessError]::RUNSPACE_DIED_UNEXPECTEDLY,
            $null
        )
    }

    Write-Warning "An unexpected error occurred when trying to run the extenral process."
    return [ExternalProcessResult]::new(
        [ExternalProcessError]::UNKNOWN,
        $null
    )
}
