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

    # Lenovo sometimes forgets to put a directory separator betweeen %PACKAGEPATH% and the executable so make sure it's there
    # If we end up with two backslashes, Split-ExecutableAndArguments removes the duplicate from the executable path, but
    # we could still end up with a double-backslash after %PACKAGEPATH% somewhere in the arguments for now.
    [string]$Command       = Resolve-CmdVariable -String $Command -ExtraVariables @{'PACKAGEPATH' = "${Path}\"}
    [bool]$processStarted  = $false
    [string[]]$StdOutLines = @()
    [string[]]$StdErrLines = @()
    $ExeAndArgs            = Split-ExecutableAndArguments -Command $Command -WorkingDirectory $Path
    # Split-ExecutableAndArguments returns NULL if no executable could be found
    if (-not $ExeAndArgs) {
        Write-Warning "The command or file '$Command' could not be found from '$Path' and was not run"
        return $null
    }

    $ExeAndArgs.Arguments = Assert-CmdAmpersandEscaped -String $ExeAndArgs.Arguments

    $process                                  = [System.Diagnostics.Process]::new()
    $process.StartInfo.WindowStyle            = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $process.StartInfo.UseShellExecute        = $false
    $process.StartInfo.WorkingDirectory       = $Path
    $process.StartInfo.FileName               = $ExeAndArgs.Executable
    $process.StartInfo.Arguments              = $ExeAndArgs.Arguments
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError  = $true

    if ($FallbackToShellExecute) {
        Write-Warning "Running with ShellExecute - any process output cannot be captured!"
        $process.StartInfo.UseShellExecute        = $true
        $process.StartInfo.RedirectStandardOutput = $false
        $process.StartInfo.RedirectStandardError  = $false
    }

    try {
        $processStarted = $process.Start()
    }
    catch {
        if ($null -ne $_.Exception.InnerException -and $_.Exception.InnerException.NativeErrorCode -eq 740) {
            Write-Warning "This process requires elevated privileges - falling back to ShellExecute"
            if (-not $FallbackToShellExecute) {
                return (Invoke-PackageCommand -Path:$Path -Command:$Command -FallbackToShellExecute)
            }
        } else {
            Write-Warning $_
        }
    }

    if ($processStarted) {
        if (-not $FallbackToShellExecute) {
            # When redirecting StandardOutput or StandardError you have to start reading the streams asynchronously, or else it can cause
            # programs that output a lot (like package u3aud03w_w10 - Conexant USB Audio) to fill a stream and deadlock/hang indefinitely.
            # See issue #25 and https://stackoverflow.com/questions/11531068/powershell-capturing-standard-out-and-error-with-process-object
            $stdoutAsync = $process.StandardOutput.ReadToEndAsync()
            $stderrAsync = $process.StandardError.ReadToEndAsync()
        }

        $process.WaitForExit()

        if (-not $FallbackToShellExecute) {
            $STDOUTinOneString = $stdoutAsync.GetAwaiter().GetResult()
            $STDERRinOneString = $stderrAsync.GetAwaiter().GetResult()

            [string[]]$StdOutLines = $STDOUTinOneString.Split(
                [string[]]("`r`n", "`r", "`n"),
                [StringSplitOptions]::None
            )

            [string[]]$StdErrLines = $STDERRinOneString.Split(
                [string[]]("`r`n", "`r", "`n"),
                [StringSplitOptions]::None
            )
        }
    }

    $returnInfo = [ProcessReturnInformation]@{
        "FilePath"       = $ExeAndArgs.Executable
        "StandardOutput" = $StdOutLines
        "StandardError"  = $StdErrLines
        "ExitCode"       = $process.ExitCode
        "ProcessStarted" = $processStarted
        "RunTime"        = $process.ExitTime - $process.StartTime
    }

    $returnInfo | Format-List | Out-Host

    return $returnInfo
}
