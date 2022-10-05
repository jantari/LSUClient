function Test-Wflash2ForSCCMParameter {
    <#
        .DESCRIPTION
        This function tests for wflash2.exe versions that do not support the /sccm (suppress reboot) argument
        because when you supply wflash2.exe an unknown argument it displays some usage help and then waits for
        something to be written to its CONIN$ console input buffer. Redirecting the StdIn handle of wflash2.exe
        and writing to that does not suffice to break this deadlock - real console keyboard input has to be made,
        so this is the only solution I've found that can accomplish this even in a non-interactive session.

        .NOTES
        While this approach may look like a crazy hack, it's actually the only working way
        I've found to send STDIN to wflash2.exe so that it exits when printing the usage help.
        Redirecting STDIN through StartInfo.RedirectStandardInput does nothing, and the SendInput
        API is simpler but only works in interactive sessions.
    #>

    [CmdletBinding()]
    [OutputType('System.Boolean')]
    Param (
        [ValidateNotNullOrEmpty()]
        [ValidateScript({ [System.IO.File]::Exists($_) })]
        [string]$PathToWFLASH2EXE
    )

    [bool]$SupportsSCCMSwitch = $false

    $process                                  = [System.Diagnostics.Process]::new()
    $process.StartInfo.FileName               = "$PathToWFLASH2EXE"
    $process.StartInfo.UseShellExecute        = $false
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError  = $true
    $process.StartInfo.Arguments              = "/quiet /sccm"
    $process.StartInfo.WorkingDirectory       = "$env:USERPROFILE"

    try {
        $null = $process.Start()
    }
    catch {
        Write-Warning "Could not test this ThinkCentre BIOS-Update for the /sccm (suppress reboot) parameter: The process did not start: $_"
        return $SupportsSCCMSwitch
    }

    do {
        Start-Sleep -Seconds 1
        [LSUClient.WinAPI+ReturnValues]$APICALL = [LSUClient.WinAPI]::WriteCharToConin()
        if ($APICALL.WCIReturnValue   -ne $true -or
            $APICALL.WCIEventsWritten -ne 1 -or
            $APICALL.LastWin32Error   -ne 0) {
                Write-Warning "Could not test this ThinkCentre BIOS-Update for the /sccm (suppress reboot) parameter: A problem occured when calling the native API 'WriteConsoleInput': $($APICALL.LastWin32Error)"
                $process.Kill()
        }
    } until ($process.HasExited)

    [string]$STDOUT = $process.StandardOutput.ReadToEnd()

    # If the output is the parameter help text that means an unknown
    # argument was passed aka /sccm was not recognized and is not supported.
    # If the help output cannot be detected then /sccm was a known parameter.
    if (-not [System.String]::IsNullOrEmpty($STDOUT)) {
        if (-not [regex]::Match($STDOUT, '^Usage',      'Multiline').Success -and
            -not [regex]::Match($STDOUT, '^Arguments:', 'Multiline').Success -and
            -not [regex]::Match($STDOUT, '^Examples:',  'Multiline').Success) {
                $SupportsSCCMSwitch = $true
        }
    }

    return $SupportsSCCMSwitch
}
