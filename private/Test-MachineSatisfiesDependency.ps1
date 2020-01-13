function Test-MachineSatisfiesDependency {
    Param (
        [ValidateNotNullOrEmpty()]
        [System.Xml.XmlElement]$Dependency,
        [string]$DebugLogFile
    )

    #  0 SUCCESS, Dependency is met
    # -1 FAILRE, Dependency is not met
    # -2 Unknown dependency kind - status uncertain

    switch ($Dependency.SchemaInfo.Name) {
        '_Bios' {
            foreach ($entry in $Dependency.Level) {
                if ($CachedHardwareTable['_Bios'] -like "$entry*") {
                    return 0
                }
            }
            return -1
        }
        '_CPUAddressWidth' {
            if ($CachedHardwareTable['_CPUAddressWidth'] -like "$($Dependency.AddressWidth)*") {
                return 0
            } else {
                return -1
            }
        }
        '_Driver' {
            if ( @($Dependency.ChildNodes.SchemaInfo.Name) -notmatch "^(HardwareID|Version|Date)$") {
                # If there's any unknown node inside _Driver, return unsupported (-2) right away
                return -2
            }

            [bool]$HardwareFound = $false

            foreach ($HardwareInMachine in $CachedHardwareTable['_PnPID'].HardwareID) {
                foreach ($HardwareID in $Dependency.HardwareID.'#cdata-section') {
                    # Lenovo HardwareIDs can contain wildcards (*) so we have to compare with "-like"
                    if ($HardwareInMachine -like "*$HardwareID*") {
                        $HardwareFound   = $true
                        $HardwareIDFound = $HardwareInMachine
                    }
                }
            }

            if ($HardwareFound) {
                if (@($Dependency.ChildNodes.SchemaInfo.Name) -contains 'Date') {
                    $LenovoDate = [DateTime]::new(0)
                    if ( [DateTime]::TryParseExact($Dependency.Date, 'yyyy-MM-dd', [CultureInfo]::InvariantCulture, 'None', [ref]$LenovoDate) ) {
                        $DriverDate = ($CachedHardwareTable['_PnPID'].Where{ $_.HardwareID -eq "$HardwareIDFound" } | Get-PnpDeviceProperty -KeyName 'DEVPKEY_Device_DriverDate').Data.Date
                        if ($DriverDate -eq $LenovoDate) {
                            return 0 # SUCCESS
                        }
                    } else {
                        Write-Verbose "Got unsupported date format from Lenovo: '$($Dependency.Date)' (expected yyyy-MM-dd)"
                    }
                }
    
                if (@($Dependency.ChildNodes.SchemaInfo.Name) -contains 'Version') {
                    $DriverVersion = ($CachedHardwareTable['_PnPID'].Where{ $_.HardwareID -eq "$HardwareIDFound" } | Get-PnpDeviceProperty -KeyName 'DEVPKEY_Device_DriverVersion').Data
                    # Not all drivers tell us their versions via the OS API. I think later I can try to parse the INIs as an alternative, but it would get tricky
                    if ($DriverVersion) {
                        return (Compare-VersionStrings -LenovoString $Dependency.Version -SystemString $DriverVersion)
                    } else {
                        Write-Verbose "HardwareID '$HardwareID' does not report its driver version. Returning unsupported -2"
                        return -2
                    }
                }
            } else {
                Write-Verbose "Hardware IDs specified by _Driver not present in system."
            }

            return -1
        }
        '_EmbeddedControllerVersion' {
            if ($CachedHardwareTable['_EmbeddedControllerVersion']) {
                return (Compare-VersionStrings -LenovoString $Dependency.Version -SystemString $CachedHardwareTable['_EmbeddedControllerVersion'])
            }
            return -1
        }
        '_ExternalDetection' {
            $externalDetection = Invoke-PackageCommand -Command $Dependency.'#text' -Path $env:TEMP
            if ($externalDetection.ExitCode -in ($Dependency.rc -split ',')) {
                return 0
            } else {
                return -1
            }
        }
        '_FileExists' {
            # This may not be 100% yet as Lenovo sometimes uses some non-system environment variables in their file paths
            [string]$Path = Resolve-CmdVariable -String $Dependency -ExtraVariables @{'WINDOWS' = $env:SystemRoot}
            return (Test-Path -LiteralPath $Path -PathType Leaf)
        }
        '_FileVersion' {
            # This may not be 100% yet as Lenovo sometimes uses some non-system environment variables in their file paths
            [string]$Path = Resolve-CmdVariable -String $Dependency.File -ExtraVariables @{'WINDOWS' = $env:SystemRoot}
            if (Test-Path -LiteralPath $Path -PathType Leaf) {
                $filVersion = (Get-Item -LiteralPath $Path).VersionInfo.FileVersion
                return (Compare-VersionStrings -LenovoString $Dependency.Version -SystemString $filVersion)
            } else {
                return -1
            }
        }
        '_OS' {
            foreach ($entry in $Dependency.OS) {
                if ("$entry" -like "${CachedHardwareTable['_OS']}*") {
                    return 0
                }
            }
            return -1
        }
        '_OSLang' {
            if ($Dependency.Lang -eq [CultureInfo]::CurrentUICulture.ThreeLetterWindowsLanguageName) {
                return 0
            } else {
                return -1
            }
        }
        '_PnPID' {
            foreach ($HardwareID in $CachedHardwareTable['_PnPID'].HardwareID) {
                if ($HardwareID -like "*$($Dependency.'#cdata-section')*") {
                    return 0
                }
            }
            return -1
        }
        '_RegistryKey' {
            if ($Dependency.Key) {
                if (Test-Path -LiteralPath ('Microsoft.PowerShell.Core\Registry::{0}' -f $Dependency.Key) -PathType Container) {
                    return 0
                }
            }
            return -1
        }
        '_RegistryKeyValue' {
            if ($Dependency.type -ne 'REG_SZ') {
                return -2
            }

            if (Test-Path -LiteralPath ('Microsoft.PowerShell.Core\Registry::{0}' -f $Dependency.Key) -PathType Container) {
                try {
                    $regVersion = Get-ItemPropertyValue -LiteralPath ('Microsoft.PowerShell.Core\Registry::{0}' -f $Dependency.Key) -Name $Dependency.KeyName -ErrorAction Stop
                }
                catch {
                    return -1
                }
                return (Compare-VersionStrings -LenovoString $Dependency.Version -SystemString $regVersion)
            }

        }
        default {
            Write-Verbose "Unsupported dependency encountered: $_`r`n"
            return -2
        }
    }

    return -2
}