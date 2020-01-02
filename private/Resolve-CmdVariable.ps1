function Resolve-CmdVariable {
    [OutputType('System.String')]
    Param (
        [ValidateNotNullOrEmpty()]
        [Parameter( Mandatory = $true )]
        [string]$String,
        [Hashtable]$ExtraVariables
    )
    
    if ($String.Contains('%')) {
        $String = [Regex]::Replace($String, "%([^%]+)%", {
            if ($ExtraVariables.ContainsKey($args.Groups[1].Value)) {
                $ExtraVariables.get_Item($args.Groups[1].Value)
            } elseif ($value = [Environment]::GetEnvironmentVariable($args.Groups[1].Value)) {
                $value
            } else {
                $args.Value
            }
        })
    }

    return $String
}