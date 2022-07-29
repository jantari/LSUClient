function Invoke-PackageCommand {
    <#
        .SYNOPSIS
        Tries to run a command and returns an object containing an error
        code and optionally information about the process that was run.

        .PARAMETER Path

        .PARAMETER Command
        File path to the excutable and its arguments in one string.
        The string can contain environment variables as well.

        .PARAMETER Executable
        File path to the executable to run. The path to the executable is currently not
        resolved to an absolute path but run as-is. Variables are not expanded either.
        Because of this the caller should already pass an absolute, verbatim path toArguments this parameter.

        .PARAMETER Arguments
        The optional command line arguments to run the executable with, as a single string.
    #>

    [CmdletBinding()]
    [OutputType('ExternalProcessResult')]
    Param (
        [ValidateNotNullOrEmpty()]
        [string]$Path,
        [ValidateNotNullOrEmpty()]
        [Parameter( Mandatory = $true, ParameterSetName = 'CommandString' )]
        [string]$Command,
        [Parameter( Mandatory = $true, ParameterSetName = 'ExeAndArgs' )]
        [string]$Executable,
        [Parameter( ParameterSetName = 'ExeAndArgs' )]
        [string]$Arguments = '',
        [switch]$FallbackToShellExecute
    )

    # Remove any trailing backslashes from the Path.
    # This isn't necessary, because Split-ExecutableAndArguments can handle and trims
    # extra backslashes, but this will make the path look more sane in errors and warnings.
    $Path = $Path.TrimEnd('\')

    if ($PSCmdlet.ParameterSetName -eq 'CommandString') {
        # Lenovo sometimes forgets to put a directory separator betweeen %PACKAGEPATH% and the executable so make sure it's there
        # If we end up with two backslashes, Split-ExecutableAndArguments removes the duplicate from the executable path, but
        # we could still end up with a double-backslash after %PACKAGEPATH% somewhere in the arguments for now.
        [string]$ExpandedCommandString = Resolve-CmdVariable -String $Command -ExtraVariables @{'PACKAGEPATH' = "${Path}\"; 'WINDOWS' = $env:SystemRoot}
        $Executable, $Arguments = Split-ExecutableAndArguments -Command $ExpandedCommandString -WorkingDirectory $Path
        # Split-ExecutableAndArguments returns NULL if no executable could be found
        if (-not $Executable) {
            Write-Warning "The command or file '$Command' could not be found from '$Path' and was not run"
            return [ExternalProcessResult]::new(
                [ExternalProcessError]::FILE_NOT_FOUND,
                $null
            )
        }
        $Arguments = Remove-CmdEscapeCharacter -String $Arguments
    }

    Write-Debug "Starting external process:`r`n  File: ${Executable}`r`n  Arguments: ${Arguments}`r`n  WorkingDirectory: ${Path}"

    $Runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateOutOfProcessRunspace($null)
    $Runspace.Open()

    $Powershell = [PowerShell]::Create().AddScript{
        [CmdletBinding()]
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
            # In case we get ERROR_ACCESS_DENIED (5) e.g. when the file could not be accessed by the running user
            } elseif ($null -ne $_.Exception.InnerException -and $_.Exception.InnerException.NativeErrorCode -eq 5) {
                $HandledError = 5
            } else {
                Write-Error $_
                $HandledError = 2 # Any other Process.Start exception
            }
        }

        if ($ProcessStarted) {
            $process.ID

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
        'Executable'             = $Executable
        'Arguments'              = $Arguments
        'FallbackToShellExecute' = $FallbackToShellExecute
    })

    $Powershell.Runspace = $Runspace
    $RunspaceStandardInput = [System.Management.Automation.PSDataCollection[PSObject]]::new()
    $RunspaceStandardInput.Complete()
    $RunspaceStandardOut = [System.Management.Automation.PSDataCollection[PSObject]]::new()
    $RunspaceTimer = [System.Diagnostics.Stopwatch]::new()
    $RunspaceTimer.Start()
    $PSAsyncRunspace = $Powershell.BeginInvoke($RunspaceStandardInput, $RunspaceStandardOut)

    $ProcessKilledTimeout = $false
    [Int32]$LastPrinted = 0
    while ($PSAsyncRunspace.IsCompleted -eq $false) {
        # Only start looking into processes if they have been running for x time,
        # many are really short lived and don't need to be tested for 'hanging'
        if ($RunspaceTimer.Elapsed.TotalMinutes -gt 2) { # Set to low time of 2 minutes intentionally during testing
            # Print message once every minute
            if ($RunspaceTimer.Elapsed.Minutes - $LastPrinted -gt 0) {
                Write-Debug "Process '$Executable' has been running for $($RunspaceTimer.Elapsed)"
                $LastPrinted = $RunspaceTimer.Elapsed.Minutes
                if ($RunspaceStandardOut.Count -ge 1) {
                    $ProcessID = $RunspaceStandardOut[0]
                    $Process   = Get-Process -Id $ProcessID

                    $ProcessDiagnostics = Debug-LongRunningProcess -Process $Process
                    $ProcessDiagnostics | ConvertTo-Json -Depth 10 | Out-Host

                    if ($ProcessDiagnostics.AllThreadsWaiting -and $ProcessDiagnostics.InteractableWindows.Count -gt 0) {
                        Write-Debug "CONCLUSION: The process looks blocked."
                    } else {
                        Write-Debug "CONCLUSION: The process looks normal."
                    }
                    Write-Debug ""

                    # Stop processes after 10 minutes
                    if ($RunspaceTimer.Elapsed.TotalMinutes -gt 10) {
                        # Try graceful stop with WM_CLOSE
                        foreach ($ProcessID2 in $ProcessDiagnostics.AllProcesses) {
                            $Process2 = Get-Process -Id $ProcessID2
                            Write-Debug "Going to close Process $ProcessID2 ('$($Process2.ProcessName)') ..."

                            [Bool]$cmwSent = $false
                            try {
                                $cmwSent = $Process2.CloseMainWindow()
                            }
                            catch [InvalidOperationException] {
                                Write-Debug "CloseMainWindow() threw InvalidOperationException: The process has already closed"
                            }

                            if ($cmwSent) {
                                Write-Debug "CloseMainWindow() returned True: WM_CLOSE message successfully sent"
                            } else {
                                Write-Debug "CloseMainWindow() returned False: No MainWindow or its message loop is blocked, would have to kill this process"
                            }
                        }

                        # Allow up to 10 seconds for the process to gracefully close, then kill process tree
                        if (-not $Process.WaitForExit(10000)) {
                            Write-Debug "Killing processes due to timeout ..."
                            Get-Process -Id $ProcessDiagnostics.AllProcesses -ErrorAction Ignore | ForEach-Object {
                                try {
                                    $_.Kill()
                                }
                                catch [InvalidOperationException] { <# Process has exited in the meantime, which is fine #> }
                            }
                        }

                        $ProcessKilledTimeout = $true
                    }
                }

                Write-Debug ""
            }
        }

        Start-Sleep -Milliseconds 200
    }

    $RunspaceTimer.Stop()

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

                $ProcessReturnInformation = [ProcessReturnInformation]@{
                    'FilePath'         = $Executable
                    'Arguments'        = $Arguments
                    'WorkingDirectory' = $Path
                    'StandardOutput'   = $StdOutTrimmed
                    'StandardError'    = $StdErrTrimmed
                    'OpenWindows'      = @()
                    'ExitCode'         = $RunspaceStandardOut[-1].ExitCode
                    'Runtime'          = $RunspaceStandardOut[-1].Runtime
                }

                if ($ProcessKilledTimeout) {
                    $ProcessReturnInformation.OpenWindows = @($ProcessDiagnostics.InteractableWindows | Select-Object -Property WindowTitle, WindowText)
                    return [ExternalProcessResult]::new(
                        [ExternalProcessError]::PROCESS_KILLED_TIMEOUT,
                        $ProcessReturnInformation
                    )
                } else {
                    return [ExternalProcessResult]::new(
                        [ExternalProcessError]::NONE,
                        $ProcessReturnInformation
                    )
                }
            }
            # Error cases that are handled explicitly inside the runspace
            1 {
                Write-Warning "No new process was created or a handle to it could not be obtained."
                Write-Warning "Executable was: '${Executable}' - this should *probably* not have happened"
                return [ExternalProcessResult]::new(
                    [ExternalProcessError]::PROCESS_NONE_CREATED,
                    $null
                )
            }
            2 {
                return [ExternalProcessResult]::new(
                    [ExternalProcessError]::UNKNOWN,
                    $null
                )
            }
            5 {
                return [ExternalProcessResult]::new(
                    [ExternalProcessError]::ACCESS_DENIED,
                    $null
                )
            }
            740 {
                if (-not $FallbackToShellExecute) {
                    Write-Warning "This process requires elevated privileges - falling back to ShellExecute, consider running PowerShell as Administrator"
                    Write-Warning "Process output cannot be captured when running with ShellExecute!"
                    return (Invoke-PackageCommand -Path:$Path -Executable:$Executable -Arguments:$Arguments -FallbackToShellExecute)
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
                    return (Invoke-PackageCommand -Path:$Path -Executable:$Executable -Arguments:$Arguments -FallbackToShellExecute)
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
