function Invoke-PackageCommand {
    Param (
        [ValidateNotNullOrEmpty()]
        [string]$Path,
        [ValidateNotNullOrEmpty()]
        [Parameter( Mandatory = $true )]
        [string]$Command
    )

    # PSSA doesn't like Write-Host but we definitely don't want this to be returned by the function
    [Console]::WriteLine("Raw Package-Command is '$Command'")

    $Command = Resolve-CmdVariable -StringToEcho $Command -ExtraVariables @{'PACKAGEPATH' = "$Path"}

    # In some cases (n1cgf02w for the T460s) Lenovo does not escape the & symbol in a command,
    # but other times (n1olk08w for the X1 Tablet 2nd Gen) they do! This means I cannot double-quote
    # the CLI arguments, but instead have to manually escape unescaped ampersands.
    $Command = $Command -replace '(?<!\^)&', '^&'

    [Console]::WriteLine("Command with vars resolved is '$Command'")

    $ExeAndArgs = Split-ExecutableAndArguments -Command $Command -WorkingDirectory $Path
    $ExeAndArgs | Format-List | Out-Host

    # Get a random non-existant file name to capture cmd output to
    do {
        [string]$LogFilePath = Join-Path -Path $Path -ChildPath ( [System.IO.Path]::GetRandomFileName() )
    } until ( -not [System.IO.File]::Exists($LogFilePath) )

    $process                            = [System.Diagnostics.Process]::new()
    $process.StartInfo.WindowStyle      = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $process.StartInfo.UseShellExecute  = $true
    $process.StartInfo.WorkingDirectory = $Path
    $process.StartInfo.FileName         = 'cmd.exe'
    $process.StartInfo.Arguments        = '/D /C ""{0}" {1} 2>&1 1>"{2}""' -f $ExeAndArgs.Executable, $ExeAndArgs.Arguments, $LogFilePath

    $return = $null
    $output = [String]::Empty
    [bool]$processStarted = $false

    try {
        $processStarted = $process.Start()
    }
    catch [System.Management.Automation.MethodInvocationException] {
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

    $return | Format-List | Out-Host

    return $return
}