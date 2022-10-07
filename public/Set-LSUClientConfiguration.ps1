function Set-LSUClientConfiguration {
    <#
        .DESCRIPTION
        Sets the currently active configuration
    #>
    [CmdletBinding(DefaultParameterSetName = 'Whole')]
    Param (
        [Parameter(Mandatory = $true, ParameterSetName = 'Whole', ValueFromPipeline = $true, Position = 0)]
        [LSUClientConfiguration]$InputObject
        <#
            Further parameters are added dynamically!
        #>
    )

    DynamicParam {
        $ParamDictionary = [System.Management.Automation.RuntimeDefinedParameterDictionary]::new()

        # Add a dynamic parameter to the cmdlet for every property of the LSUClientConfiguration class
        # This ensures the cmdlet will always be up-to-date in providing a parameter to set each property
        $Position = 0
        foreach ($Property in [LSUClientConfiguration].GetProperties()) {
            $AttributeCollection = [System.Collections.ObjectModel.Collection[System.Attribute]]::new()
            $ParamAttribute = [System.Management.Automation.ParameterAttribute]::new()
            $ParamAttribute.Position = $Position
            $ParamAttribute.ParameterSetName = 'Individual'
            $AttributeCollection.Add($ParamAttribute)

            $DynamicParam = [System.Management.Automation.RuntimeDefinedParameter]::new($Property.Name, $Property.PropertyType, $AttributeCollection)

            $paramDictionary.Add($Property.Name, $DynamicParam)
            $Position++
        }

        return $ParamDictionary
    }

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
