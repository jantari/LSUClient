function Resolve-CmdVariable {
    [OutputType('System.String')]
    Param (
        [ValidateNotNullOrEmpty()]
        [Parameter( Mandatory = $true )]
        [string]$String,
        [Hashtable]$ExtraVariables
    )

    foreach ($Variable in $ExtraVariables.GetEnumerator()) {
        [System.Environment]::SetEnvironmentVariable($Variable.Key, $Variable.Value, 'Process')
    }

    [string]$ResolvedVars = [System.Environment]::ExpandEnvironmentVariables($String)

    foreach ($Variable in $ExtraVariables.GetEnumerator()) {
        [System.Environment]::SetEnvironmentVariable($Variable.Key, '', 'Process')
    }

    return $ResolvedVars
}