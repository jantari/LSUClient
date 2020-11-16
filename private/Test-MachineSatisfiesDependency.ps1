function Test-MachineSatisfiesDependency {
    [CmdletBinding()]
    Param (
        [ValidateNotNullOrEmpty()]
        [System.Xml.XmlElement]$Dependency,
        [int]$DebugIndent = 0
    )

    #  0 SUCCESS, Dependency is met
    # -1 FAILRE, Dependency is not met
    # -2 Unknown dependency kind - status uncertain

    switch ($Dependency.SchemaInfo.Name) {
        '_Bios' {
            Write-Debug "$('- ' * $DebugIndent)[ Got: $($CachedHardwareTable['_Bios']) ]"
            foreach ($entry in $Dependency.Level) {
                if ($CachedHardwareTable['_Bios'] -like "$entry*") {
                    return 0
                }
            }
            return -1
        }
        '_CPUAddressWidth' {
            Write-Debug "$('- ' * $DebugIndent)[ Got: $($CachedHardwareTable['_CPUAddressWidth']), Expected: $($dependency.AddressWidth) ]"
            if ($CachedHardwareTable['_CPUAddressWidth'] -like "$($Dependency.AddressWidth)*") {
                return 0
            } else {
                return -1
            }
        }
        '_Driver' {
            if ( @($Dependency.ChildNodes.SchemaInfo.Name) -notmatch "^(HardwareID|Version|Date)$") {
                # If there's any unknown node inside _Driver, return unsupported (-2) right away
                Write-Debug "$('- ' * $DebugIndent)_Driver node contained unknown element - skipping checks"
                return -2
            }

            [bool]$HardwareFound = $false

            foreach ($HardwareInMachine in $CachedHardwareTable['_PnPID'].HardwareID) {
                foreach ($HardwareID in $Dependency.HardwareID.'#cdata-section') {
                    # Lenovo HardwareIDs can contain wildcards (*) so we have to compare with "-like"
                    if ($HardwareInMachine -like "*$HardwareID*") {
                        Write-Debug "$('- ' * $DebugIndent)Matched device '$HardwareInMachine' with required '$HardwareID'"
                        $HardwareFound   = $true
                        $HardwareIDFound = $HardwareInMachine
                    }
                }
            }

            if ($HardwareFound) {
                $Device = $CachedHardwareTable['_PnPID'].Where{ $_.HardwareID -eq "$HardwareIDFound" }

                # First, check if there is a driver installed for the device at all before proceeding (issue#24)
                if ($Device.Problem -eq 'CM_PROB_FAILED_INSTALL') {
                    [string]$HexDeviceProblemStatus = '0x{0:X8}' -f ($Device | Get-PnpDeviceProperty -KeyName 'DEVPKEY_Device_ProblemStatus').Data
                    Write-Debug "$('- ' * $DebugIndent)Device '$HardwareIDFound' does not have any driver (ProblemStatus: $HexDeviceProblemStatus)"
                    return -1
                }

                if (@($Dependency.ChildNodes.SchemaInfo.Name) -contains 'Date') {
                    Write-Debug "$('- ' * $DebugIndent)Trying to match driver based on Date"
                    $LenovoDate = [DateTime]::new(0)
                    if ( [DateTime]::TryParseExact($Dependency.Date, 'yyyy-MM-dd', [CultureInfo]::InvariantCulture, 'None', [ref]$LenovoDate) ) {
                        $DriverDate = ($Device | Get-PnpDeviceProperty -KeyName 'DEVPKEY_Device_DriverDate').Data.Date
                        if ($DriverDate -eq $LenovoDate) {
                            return 0 # SUCCESS
                        }
                    } else {
                        Write-Verbose "Got unsupported date format from Lenovo: '$($Dependency.Date)' (expected yyyy-MM-dd)"
                    }
                }

                if (@($Dependency.ChildNodes.SchemaInfo.Name) -contains 'Version') {
                    Write-Debug "$('- ' * $DebugIndent)Trying to match driver based on Version"
                    $DriverVersion = ($Device | Get-PnpDeviceProperty -KeyName 'DEVPKEY_Device_DriverVersion').Data
                    # Not all drivers tell us their versions via the OS API. I think later I can try to parse the INIs as an alternative, but it would get tricky
                    if ($DriverVersion) {
                        Write-Debug "$('- ' * $DebugIndent)Testing installed driver version: $DriverVersion against required $($Dependency.Version)"
                        return (Compare-VersionStrings -LenovoString $Dependency.Version -SystemString $DriverVersion)
                    } else {
                        Write-Verbose "Device '$HardwareIDFound' does not report its driver version. Returning unsupported (-2)"
                        return -2
                    }
                }
            }

            if (-not $HardwareFound) {
                Write-Debug "$('- ' * $DebugIndent)No installed device matched the driver check"
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
            Write-Debug "$('- ' * $DebugIndent)[ Got ExitCode: $($externalDetection.ExitCode), Expected: $($Dependency.rc) ]"
            if ($externalDetection -and $externalDetection.ExitCode -in ($Dependency.rc -split ',')) {
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

                [string]$DependencyVersion = if ($Dependency.KeyValue) {
                    $Dependency.KeyValue
                } elseif ($Dependency.Version) {
                    $Dependency.Version
                } else {
                    Write-Verbose "Could not get LenovoString from _RegistryKeyValue dependency node"
                    return -2
                }

                return (Compare-VersionStrings -LenovoString $DependencyVersion -SystemString $regVersion)
            } else {
                return -1
            }

        }
        default {
            Write-Verbose "Unsupported dependency encountered: $_`r`n"
            return -2
        }
    }

    return -2
}
