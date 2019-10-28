function Invoke-PackageCommand {
    Param (
        [ValidateNotNullOrEmpty()]
        [string]$Path,
        [ValidateNotNullOrEmpty()]
        [Parameter( Mandatory = $true )]
        [string]$Command
    )

    # Some commands Lenovo specifies include an unescaped & sign so we have to escape it
    $Command = $Command -replace '&', '^&'

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
    $process.StartInfo.Arguments        = "/D /C $Command 2>&1 1>`"$LogFilePath`""
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