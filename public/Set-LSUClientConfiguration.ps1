function Set-LSUClientConfiguration {
    <#
        .DESCRIPTION
        Sets the currently active configuration
    #>
    [CmdletBinding(DefaultParameterSetName = 'Whole')]
    Param (
        [Parameter(Mandatory = $true, ParameterSetName = 'Whole', ValueFromPipeline = $true, Position = 0)]
        [LSUClientConfiguration]$InputObject,
        [Parameter(ParameterSetName = 'Individual')]
        [Uri]$Proxy,
        [Parameter(ParameterSetName = 'Individual')]
        [PSCredential]$ProxyCredential,
        [Parameter(ParameterSetName = 'Individual')]
        [bool]$ProxyUseDefaultCredential,
        [Parameter(ParameterSetName = 'Individual')]
        [TimeSpan]$MaxExternalDetectionRuntime,
        [Parameter(ParameterSetName = 'Individual')]
        [TimeSpan]$MaxExtractRuntime,
        [Parameter(ParameterSetName = 'Individual')]
        [TimeSpan]$MaxInstallerRuntime
    )

    begin {
        if ($PSBoundParameters['Debug'] -and $DebugPreference -eq 'Inquire') {
            Write-Verbose "Adjusting the DebugPreference to 'Continue'."
            $DebugPreference = 'Continue'
        }
    }

    process {
        if ($InputObject) {
            # Assign a new / decoupled instance of the configuration passed in
            # so that changing values on the object doesn't immediately apply
            $script:LSUClientConfiguration = [LSUClientConfiguration]::new($InputObject)
        } else {
            # For every parameter that was set/passed, update the configuration
            # This allows to 'unset' options (for example Proxy) by intentionally
            # passing an empty string or null.
            foreach ($kv in $PSBoundParameters.GetEnumerator()) {
                # Ignore / skip parameters that aren't configuration options,
                # such as the common -Verbose, -Debug, -ErrorAction etc. etc.
                if ([LSUClientConfiguration].GetProperty($kv.Key)) {
                    Write-Debug "Setting option '$($kv.Key)' to: $($kv.Value)"
                    $script:LSUClientConfiguration."$($kv.Key)" = $kv.Value
                }
            }
        }
    }
}
