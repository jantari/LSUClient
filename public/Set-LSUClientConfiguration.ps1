function Set-LSUClientConfiguration {
    <#
        .DESCRIPTION
        Sets the currently active configuration
    #>
    [CmdletBinding(DefaultParameterSetName = 'Individual')]
    Param (
        [Parameter(Mandatory = $true, ParameterSetName = 'Whole', Position = 0)]
        [LSUClientConfiguration]$InputObject,
        [Parameter(ParameterSetName = 'Individual')]
        [TimeSpan]$MaxExternalDetectionRuntime,
        [Parameter(ParameterSetName = 'Individual')]
        [TimeSpan]$MaxExtractRuntime,
        [Parameter(ParameterSetName = 'Individual')]
        [TimeSpan]$MaxInstallerRuntime
    )

    if ($InputObject) {
        # Assign a new / decoupled instance of the configuration passed in
        # so that changing values on the object doesn't immediately apply
        $script:LSUClientConfiguration = [LSUClientConfiguration]::new($InputObject)
    } else {
        if ($MaxExternalDetectionRuntime) {
            $script:LSUClientConfiguration.MaxExternalDetectionRuntime = $MaxExternalDetectionRuntime
        }
        if ($MaxExtractRuntime) {
            $script:LSUClientConfiguration.MaxExtractRuntime = $MaxExtractRuntime
        }
        if ($MaxInstallerRuntime) {
            $script:LSUClientConfiguration.MaxInstallerRuntime = $MaxInstallerRuntime
        }
    }
}
