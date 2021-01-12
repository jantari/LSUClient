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
        [string]$Command
    )

    # Lenovo sometimes forgets to put a directory separator betweeen %PACKAGEPATH% and the executable so make sure it's there
    # If we end up with two backslashes, Split-ExecutableAndArguments removes the duplicate from the executable path, but
    # we could still end up with a double-backslash after %PACKAGEPATH% somewhere in the arguments for now.
    $Command        = Resolve-CmdVariable -String $Command -ExtraVariables @{'PACKAGEPATH' = "$Path\"}
    $output         = [String]::Empty
    $processStarted = $false
    $ExeAndArgs     = Split-ExecutableAndArguments -Command $Command -WorkingDirectory $Path
    # Split-ExecutableAndArguments returns NULL if no executable could be found
    if (-not $ExeAndArgs) {
        Write-Warning "The command or file '$Command' could not be found from '$Path' and was not run"
        return $null
    }

    $ExeAndArgs.Arguments = Assert-CmdAmpersandEscaped -String $ExeAndArgs.Arguments

    # Get a random non-existant file name to capture cmd output to
    do {
        [string]$LogFilePath = Join-Path -Path $Path -ChildPath ( [System.IO.Path]::GetRandomFileName() )
    } until ( -not [System.IO.File]::Exists($LogFilePath) )

    # We cannot simply use CreateProcess API and redirect the output handles
    # because that causes packages like u3aud03w_w10 (Conexant USB Audio) to hang indefinitely
    $process                            = [System.Diagnostics.Process]::new()
    $process.StartInfo.WindowStyle      = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $process.StartInfo.UseShellExecute  = $true
    $process.StartInfo.WorkingDirectory = $Path
    $process.StartInfo.FileName         = "${env:SystemRoot}\system32\cmd.exe"
    # We can't have a space after the executable arguments because it'd be passed
    # through with the executable arguments and that causes GitHub#15
    # We do need a space between the quoted executable path and the arguments though or else
    # the arguments are interpreted as part of the file name in some cases (GitHub#19)
    # AND we cannot put the redirection operator(s) at the end or else arguments that are just
    # the number "1" or "2" get misinterpreted as part of the shell redirection operation e.g.
    # 'command.exe 1' gets turned into 'command.exe 1>logfile.txt' and we'd run 'command.exe' without arguments
    $process.StartInfo.Arguments        = '/D /C ">"{2}" 2>&1 "{0}" {1}"' -f $ExeAndArgs.Executable, $ExeAndArgs.Arguments, $LogFilePath

    try {
        $processStarted = $process.Start()
    }
    catch {
        Write-Warning $_
    }

    if ($processStarted) {
        $process.WaitForExit()
    } else {
        Write-Warning "A process failed to start."
        return $null
    }

    if ([System.IO.File]::Exists($LogFilePath)) {
        $output = Get-Content -LiteralPath $LogFilePath -Raw
        if ($output) {
            $output = $output.Trim()
        }
        Remove-Item -LiteralPath $LogFilePath
    }

    Write-Debug "Process '$($ExeAndArgs.Executable)' finished with ExitCode $($process.ExitCode)"

    $return = [PSCustomObject]@{
        'Output'   = $output
        'ExitCode' = $process.ExitCode
    }

    return $return
}
