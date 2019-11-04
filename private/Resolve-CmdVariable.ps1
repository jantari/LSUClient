function Resolve-CmdVariable {
    Param (
        [ValidateNotNullOrEmpty()]
        [Parameter( Mandatory = $true )]
        [string]$StringToEcho,
        [Hashtable]$ExtraVariables
    )

    $process                                  = [System.Diagnostics.Process]::new()
    $process.StartInfo.WindowStyle            = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $process.StartInfo.FileName               = 'cmd.exe'
    $process.StartInfo.UseShellExecute        = $false
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.Arguments              = "/D /C echo `"$StringToEcho`" 2> nul"
    if ($extraVariables) {
        foreach ($extraVariable in $ExtraVariables.GetEnumerator()) {
            $process.StartInfo.Environment[$extraVariable.Key] = $extraVariable.Value
        }
    }
    $null = $process.Start()
    $process.WaitForExit()

    $out = $process.StandardOutput.ReadToEnd().Trim() -replace '^"' -replace '"$'

    return $out
}