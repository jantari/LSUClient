function Invoke-PackageCommand {
    Param (
        [ValidateNotNullOrEmpty()]
        [string]$Path,
        [ValidateNotNullOrEmpty()]
        [Parameter( Mandatory = $true )]
        [string]$Command
    )

    # In order to support paths with spaces and to not break on symbols like & that would
    # normally be parsed by cmd we have to wrap everything in double quotes if we can
    $ExeAndArgs = Split-ExecutableAndArguments -Command $Command
    if ($ExeAndArgs) {
        [string]$CMDARGS = '""{0}" {1}"' -f $ExeAndArgs.EXECUTABLE, $ExeAndArgs.ARGUMENTS
    } else {
        # This fallback is unlikely, as it would basically mean we have an invalid path (non existant executable)
        [string]$CMDARGS = $Command
    }

    # Get a random non-existant file name to capture cmd output to
    do {
        [string]$LogFilePath = Join-Path -Path $Path -ChildPath ( [System.IO.Path]::GetRandomFileName() )
    } until ( -not [System.IO.File]::Exists($LogFilePath) )

    # Environment variables are carried over to child processes and we cannot set this in the StartInfo of the new process because ShellExecute is true
    # ShellExecute is true because there are installers that indefinitely hang otherwise (Conexant Audio)
    [System.Environment]::SetEnvironmentVariable("PACKAGEPATH", "$Path", "Process")

    $process                            = [System.Diagnostics.Process]::new()
    $process.StartInfo.WindowStyle      = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $process.StartInfo.FileName         = 'cmd.exe'
    $process.StartInfo.UseShellExecute  = $true
    $process.StartInfo.Arguments        = "/D /C $CMDARGS 2>&1 1>`"$LogFilePath`""
    $process.StartInfo.WorkingDirectory = $Path
    $null = $process.Start()
    $process.WaitForExit()

    [System.Environment]::SetEnvironmentVariable("PACKAGEPATH", [String]::Empty, "Process")

    if ([System.IO.File]::Exists($LogFilePath)) {
        $output = Get-Content -LiteralPath "$LogFilePath" -Raw
        Remove-Item -LiteralPath "$LogFilePath"
    }
    
    return [PSCustomObject]@{
        'Output'   = $output
        'ExitCode' = $process.ExitCode
    }
}