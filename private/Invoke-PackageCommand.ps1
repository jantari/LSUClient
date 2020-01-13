function Invoke-PackageCommand {
    [CmdletBinding()]
    Param (
        [ValidateNotNullOrEmpty()]
        [string]$Path,
        [ValidateNotNullOrEmpty()]
        [Parameter( Mandatory = $true )]
        [string]$Command
    )

    $Command        = Resolve-CmdVariable -String $Command -ExtraVariables @{'PACKAGEPATH' = "$Path\"}
    $Command        = $Command -replace '(?<!\^)&', '^&'
    $ExeAndArgs     = Split-ExecutableAndArguments -Command $Command -WorkingDirectory $Path
    $output         = [String]::Empty
    $processStarted = $false

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
    $process.StartInfo.FileName         = $env:ComSpec
    $process.StartInfo.Arguments        = '/D /C ""{0}" {1} 2>&1 1>"{2}""' -f $ExeAndArgs.Executable, $ExeAndArgs.Arguments, $LogFilePath

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
    }

    if ([System.IO.File]::Exists($LogFilePath)) {
        $output = Get-Content -LiteralPath $LogFilePath -Raw
        if ($output) {
            $output = $output.Trim()
        }
        Remove-Item -LiteralPath $LogFilePath
    }

    $return = [PSCustomObject]@{
        'Output'   = $output
        'ExitCode' = $process.ExitCode
    }

    return $return
}