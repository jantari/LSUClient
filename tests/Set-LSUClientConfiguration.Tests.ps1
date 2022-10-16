BeforeDiscovery {
    # Import the module before discovery so that
    # we can use InScopeModule and/or functions
    # from the module in ForEach blocks.
    Import-Module "$PSScriptRoot/../LSUClient.psd1"
}

Describe 'Set-LSUClientConfiguration' {
    It 'Has a parameter to accept a config object' {
        InModuleScope LSUClient {
            $LSUClientConfiguration = [LSUClientConfiguration]::new()
            Get-Command 'Set-LSUClientConfiguration' | Should -HaveParameter -ParameterName 'InputObject' -Type $LSUClientConfiguration.GetType()
        }
    }
    It 'Has parameter to set <Name>' -ForEach @(
        InModuleScope LSUClient {
            [LSUClientConfiguration].GetProperties() | ForEach-Object {
                @{'Name' = $_.Name; 'Type' = $_.PropertyType }
            }
        }
    ) {
        Get-Command 'Set-LSUClientConfiguration' | Should -HaveParameter -ParameterName $Name -Type $Type
    }
    It "Doesn't tie live configuration to InputObject" {
        $DefaultLSUClientConfiguration = Get-LSUClientConfiguration
        $ConfigClassPropertyNames =  (Get-LSUClientConfiguration).PSObject.Properties.Name

        $ChangedLSUClientConfiguration = Get-LSUClientConfiguration

        Set-LSUClientConfiguration -InputObject $ChangedLSUClientConfiguration

        # Updating these values should not affect the 'live' configuration in LSUClient
        # The config should only be updated when explicitly set with Set-LSUClientConfiguration.
        # However, copy-by-reference types can lead to accidental coupling.
        $ChangedLSUClientConfiguration.Proxy = 'http://localhost:3128'
        $ChangedLSUClientConfiguration.MaxExternalDetectionRuntime = [TimeSpan]::FromDays(33)
        $ChangedLSUClientConfiguration.MaxExtractRuntime = [TimeSpan]::FromDays(33)
        $ChangedLSUClientConfiguration.MaxInstallerRuntime = [TimeSpan]::FromDays(33)

        Get-LSUClientConfiguration |
            Compare-Object -ReferenceObject $DefaultLSUClientConfiguration -Property $ConfigClassPropertyNames -IncludeEqual |
            Select-Object -ExpandProperty SideIndicator |
            Should -Be '=='
    }
}
