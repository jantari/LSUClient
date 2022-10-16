function Get-LSUClientConfiguration {
    <#
        .DESCRIPTION
        Returns the currently active configuration options
    #>
    [CmdletBinding()]
    Param ()

    # Return a new / decoupled instance of the current configuration
    # so that changing values on the object doesn't immediately apply
    return [LSUClientConfiguration]::new($script:LSUClientConfiguration)
}
