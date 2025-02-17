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
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseDeclaredVarsMoreThanAssignments',
        'ProcessKilledTimeout',
        Justification = 'https://github.com/PowerShell/PSScriptAnalyzer/issues/1163'
    )]
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
        [switch]$FallbackToShellExecute,
        [TimeSpan]$RuntimeLimit = [TimeSpan]::Zero
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

    # Get the PID and handle of our out-of-process runspace ...
    $Powershell = [PowerShell]::Create().AddScript{ $PID }
    $Powershell.Runspace = $Runspace
    $RunspacePID = $Powershell.Invoke() | Select-Object -First 1
    $hRunspaceProcess = (Get-Process -Id $RunspacePID).Handle

    # ... so we can add the runspace process to a job object.
    # Job objects are the only reliable way in Windows to track
    # a process tree (process and ALL descendant processes)
    # which we want to know in case we have to debug and kill
    # the process(es) due to hitting the configured RuntimeLimit
    $hJob = [LSUClient.JobAPI]::CreateJobObject([System.IntPtr]::Zero, $null)
    [bool]$aptjoSuccess = [LSUClient.JobAPI]::AssignProcessToJobObject($hJob, $hRunspaceProcess)
    Write-Debug "Added runspace process $RunspacePID to job: $aptjoSuccess"

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

        $process = [System.Diagnostics.Process]::new()
        # WindowStyle used to be set to 'Hidden', but it turns out that does nothing unless used with ShellExecute.
        # It had just appeared to work because most processes run properly hidden and silent on their own, but the
        # 'Hidden' setting did prevent navigating the Installers of non-unattended packages if they were invoked with
        # UseShellExecute due to one of the fallback cases below.
        # To keep behavior consistent whether using ShellExeute or not, WindowStyle is now always set to 'Normal'.
        # https://docs.microsoft.com/en-us/dotnet/api/system.diagnostics.processwindowstyle?view=netframework-4.6.1
        $process.StartInfo.WindowStyle            = [System.Diagnostics.ProcessWindowStyle]::Normal
        $process.StartInfo.UseShellExecute        = $false
        $process.StartInfo.WorkingDirectory       = $WorkingDirectory
        $process.StartInfo.FileName               = $Executable
        $process.StartInfo.Arguments              = $Arguments
        $process.StartInfo.RedirectStandardInput  = $true
        $process.StartInfo.RedirectStandardOutput = $true
        $process.StartInfo.RedirectStandardError  = $true

        if ($FallbackToShellExecute) {
            $process.StartInfo.UseShellExecute        = $true
            $process.StartInfo.RedirectStandardInput  = $false
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
            if (-not $FallbackToShellExecute) {
                # When redirecting StandardOutput or StandardError you have to start reading the streams asynchronously, or else it can cause
                # programs that output a lot (like package u3aud03w_w10 - Conexant USB Audio) to fill a stream and deadlock/hang indefinitely.
                # See issue #25 and https://stackoverflow.com/questions/11531068/powershell-capturing-standard-out-and-error-with-process-object
                $StdOutAsync = $process.StandardOutput.ReadToEndAsync()
                $StdErrAsync = $process.StandardError.ReadToEndAsync()
                # https://github.com/jantari/LSUClient/issues/103
                $process.StandardInput.Close()
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

    [bool]$ProcessKilledTimeout = $false
    [TimeSpan]$LastPrinted = [TimeSpan]::FromMinutes(4)
    while ($PSAsyncRunspace.IsCompleted -eq $false) {
        # To either print the warning about long-running processes or to kill them
        # we have to gather all process IDs from the job object we created first
        if (($RunspaceTimer.Elapsed - $LastPrinted -ge [TimeSpan]::FromMinutes(1)) -or
            ($RuntimeLimit -gt [TimeSpan]::Zero -and $RunspaceTimer.Elapsed -gt $RuntimeLimit)) {

            [int]$ListPtrSize = [System.Runtime.InteropServices.Marshal]::SizeOf([LSUClient.JobAPI+JOBOBJECT_BASIC_PROCESS_ID_LIST]::new());
            [System.IntPtr]$JobListPtr = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($ListPtrSize)

            # QueryInformationJobObject does not write any data out to lpJobObjectInformation (no NumberOfAssignedProcesses) under WOW (PowerShell x86) if it fails:
            # https://social.msdn.microsoft.com/Forums/office/en-US/41a7b8c9-6b5e-4c91-b92d-31310522d0cd/wow64-issue-with-queryinformationjobobject-and-jobobjectbasicprocessidlist-including-windows-10?forum=windowssdk
            # This means we just have to continually increase the buffer until it's large enough for QueryInformationJobObject to succeed.
            [int]$GuessNumberOfAssignedProcesses = 0

            # Retry ERROR_MORE_DATA in a loop because it *could* run into a race condition where a new process is spawned
            # exactly in between allocating the memory we think we need and the next call to QueryInformationJobObject
            do {
                [System.UInt32]$qijoReturnLength = 0
                [bool]$qijoSuccess = [LSUClient.JobAPI]::QueryInformationJobObject($hJob, 3, $JobListPtr, $ListPtrSize, [ref] $qijoReturnLength)
                $Win32Error = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()

                $JobList = [System.Runtime.InteropServices.Marshal]::PtrToStructure($JobListPtr, [Type][LSUClient.JobAPI+JOBOBJECT_BASIC_PROCESS_ID_LIST])

                Write-Debug "QueryInformationJobObject: returned $qijoSuccess, last error: $Win32Error, bytes written: $qijoReturnLength"

                if (-not $qijoSuccess -and $Win32Error -eq 234) {
                    if ($qijoReturnLength -eq 0) {
                        # Because AllocHGlobal doesn't zero the memory it allocates, the struct will be filled with random data
                        # if QueryInformationJobObject did not overwrite it so we cannot use NumberOfAssignedProcesses and have to guess
                        $GuessNumberOfAssignedProcesses += 2
                        [int]$ListPtrSize = [System.Runtime.InteropServices.Marshal]::SizeOf($JobList) + $GuessNumberOfAssignedProcesses * [System.IntPtr]::Size
                    } else {
                        [int]$ListPtrSize = [System.Runtime.InteropServices.Marshal]::SizeOf($JobList) + ($JobList.NumberOfAssignedProcesses - 1) * [System.IntPtr]::Size
                    }
                    [System.IntPtr]$JobListPtr = [System.Runtime.InteropServices.Marshal]::ReAllocHGlobal($JobListPtr, $ListPtrSize)
                    $RetryMoreData = $true
                } else {
                    $RetryMoreData = $false
                }
            } while ($RetryMoreData)

            [System.IntPtr[]]$ProcessIdList = [System.IntPtr[]]::new($JobList.NumberOfProcessIdsInList)
            # It's possible the processes and runspace have exited by this point
            if ($JobList.NumberOfProcessIdsInList -gt 0) {
                # Get the first process ID directly from the marshaled struct
                $ProcessIdList[0] = $JobList.ProcessIdList
                $PIDListPointer = [System.IntPtr]::Add($JobListPtr, [System.Runtime.InteropServices.Marshal]::SizeOf([LSUClient.JobAPI+JOBOBJECT_BASIC_PROCESS_ID_LIST]::new()))
                # Copy the others (variable length) from unmanaged memory manually
                [System.Runtime.InteropServices.Marshal]::Copy($PIDListPointer, $ProcessIdList, 1, $JobList.NumberOfProcessIdsInList - 1)
            }

            [System.Runtime.InteropServices.Marshal]::FreeHGlobal($JobListPtr)

            # Filter out our PowerShell runspace process
            $ProcessIdList = $ProcessIdList -ne $RunspacePID
            Write-Debug "Process IDs in job (without runspace): $ProcessIdList"

            # Print message once every minute after an initial 5 minutes of silence
            if ($RunspaceTimer.Elapsed - $LastPrinted -ge [TimeSpan]::FromMinutes(1)) {
                Write-Debug "(Current session ID: $( [System.Diagnostics.Process]::GetCurrentProcess().SessionId ), Environment.UserInteractive: $( [System.Environment]::UserInteractive ))"
                Write-Warning "Process '$Executable' has been running for $($RunspaceTimer.Elapsed)"

                # Get-Process -Id errors when passed an empty array so test it first
                if ($ProcessIdList) {
                    # Getting and piping all processes at once with ErrorAction Ignore silently skips over any process that has already exited
                    Get-Process -Id $ProcessIdList -ErrorAction Ignore | ForEach-Object {
                        Write-Warning "$($_.Id): '$($_.ProcessName)' started at $($_.StartTime.TimeOfDay)"

                        $ProcessDiagnostics = Debug-LongRunningProcess -Process $_
                        if ($ProcessDiagnostics.InteractableWindows) {
                            Write-Warning "Process has windows open, this can help troubleshoot if it is stuck:"
                            foreach ($OpenWindow in $ProcessDiagnostics.InteractableWindows) {
                                Write-Warning "- Title: -------------------------------------------"
                                Write-Warning $OpenWindow.WindowTitle
                                Write-Warning "- Content: -----------------------------------------"
                                $OpenWindow.WindowText | Write-Warning
                                Write-Warning "----------------------------------------------------"
                            }
                        }
                    }
                }
                $LastPrinted = $RunspaceTimer.Elapsed
            }

            # Stop processes after exceeding runtime limit
            if ($RuntimeLimit -gt [TimeSpan]::Zero -and $RunspaceTimer.Elapsed -gt $RuntimeLimit) {
                Write-Warning "Process has exceeded the configured runtime limit of $RunTimeLimit"

                if ($ProcessIdList) {
                    Get-Process -Id $ProcessIdList -ErrorAction Ignore | ForEach-Object {
                        # It's possible for a process (object) to linger and be "get-able"
                        # for a short while after it has already exited. Kill() won't throw
                        # on these processes, but they didn't technically get "killed" by us
                        if (-not $_.HasExited) {
                            Write-Warning "Killing process $($_.Id) '$($_.ProcessName)' due to exceeding time limit ..."
                            try {
                                $_.Kill()
                                # Only set ProcessKilledTimeout if Kill() ran and succeeded
                                $ProcessKilledTimeout = $true
                            }
                            catch [InvalidOperationException] { <# Process has exited in the meantime, which is fine #> }
                        }
                    }
                }
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
    if (-not [LSUClient.JobAPI]::CloseHandle($hJob)) {
        Write-Debug "CloseHandle failed for hJob handle"
    }

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

                $ReturnErr = if ($ProcessKilledTimeout) {
                    [ExternalProcessError]::PROCESS_KILLED_TIMELIMIT
                } else {
                    [ExternalProcessError]::NONE
                }

                return [ExternalProcessResult]::new(
                    $ReturnErr,
                    [ProcessReturnInformation]@{
                        'FilePath'         = $Executable
                        'Arguments'        = $Arguments
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
                    return (Invoke-PackageCommand -Path:$Path -Executable:$Executable -Arguments:$Arguments -FallbackToShellExecute -RuntimeLimit $RuntimeLimit)
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
                    return (Invoke-PackageCommand -Path:$Path -Executable:$Executable -Arguments:$Arguments -FallbackToShellExecute -RuntimeLimit $RuntimeLimit)
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

    Write-Warning "An unexpected error occurred when trying to run the external process."
    return [ExternalProcessResult]::new(
        [ExternalProcessError]::UNKNOWN,
        $null
    )
}
