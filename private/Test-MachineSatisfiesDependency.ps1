function Test-MachineSatisfiesDependency {
    [CmdletBinding()]
    [OutputType('System.Int32')]
    Param (
        [ValidateNotNullOrEmpty()]
        [System.Xml.XmlElement]$Dependency,
        [Parameter( Mandatory = $true )]
        [string]$PackagePath,
        [int]$DebugIndent = 0,
        [switch]$FailInboxDrivers
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
            [array]$SupportedDriverNodes = 'HardwareID', 'Version', 'Date', 'File'
            [array]$DriverChildNodes = $Dependency.ChildNodes.SchemaInfo.Name
            if (-not (Compare-Array $DriverChildNodes -in $SupportedDriverNodes)) {
                Write-Debug "$('- ' * $DebugIndent)_Driver node contained unknown element - skipping checks"
                return -2
            }

            if ($DriverChildNodes -contains 'HardwareID') {
                $DevicesMatched = [System.Collections.Generic.List[object]]::new()

                :NextDevice foreach ($DeviceInMachine in $CachedHardwareTable['_PnPID']) {
                    [bool]$DeviceHwIdWildcardMatched = $false

                    foreach ($HardwareInMachine in $DeviceInMachine.HardwareID) {
                        # A _Driver node can have multiple 'HardwareID' child nodes, e.g. https://download.lenovo.com/pccbbs/mobiles/r1kwq15w_2_.xml
                        foreach ($HardwareID in $Dependency.HardwareID.'#cdata-section') {
                            # Matching with wildcards may have been a mistake, some HardwareIDs just contain a * (star).
                            # Try exact equal matches first and fall back to wildcard only when needed. I want to see how often that happens.
                            if ($HardwareInMachine -eq "$HardwareID") {
                                Write-Debug "$('- ' * $DebugIndent)Matched device '$HardwareInMachine' with required '$HardwareID' (EXACT)"
                                $DevicesMatched.Add($DeviceInMachine)
                                continue NextDevice
                            }
                            # Lenovo HardwareIDs can contain wildcards (*) so we have to compare with "-like"
                            if ($HardwareInMachine -like "*$HardwareID*") {
                                Write-Debug "$('- ' * $DebugIndent)Matched device '$HardwareInMachine' with required '$HardwareID' (WILDCARD)"
                                $DeviceHwIdWildcardMatched = $true
                            }
                        }
                    }

                    # To preserve the old behavior whilst fully testing the new, do add devices that were only matched via wildcards
                    if ($DeviceHwIdWildcardMatched) {
                        Write-Debug "$('- ' * $DebugIndent)Adding device - HardwareIDs matched only when using wildcards"
                        $DevicesMatched.Add($DeviceInMachine)
                    }
                }

                if ($DevicesMatched.Count -ge 1) {
                    if ($DevicesMatched.Count -gt 1) {
                        Write-Debug "$('- ' * $DebugIndent)$($DevicesMatched.Count) devices with matching HardwareId"
                    }

                    $TestResults = [System.Collections.Generic.List[bool]]::new()
                    foreach ($Device in $DevicesMatched) {
                        Write-Debug "$('- ' * $DebugIndent)Testing $($Device.DeviceId)"
                        # First, check if there is a driver installed for the device at all before proceeding (issue#24)
                        if ($Device.Problem -eq 'CM_PROB_FAILED_INSTALL') {
                            [string]$HexDeviceProblemStatus = '0x{0:X8}' -f (Get-PnpDeviceProperty -InputObject $Device -KeyName 'DEVPKEY_Device_ProblemStatus').Data
                            Write-Debug "$('- ' * $DebugIndent)Device '$($Device.InstanceId)' does not have any driver (ProblemStatus: $HexDeviceProblemStatus)"
                            return -1
                        }

                        if ($FailInboxDrivers) {
                            # This approach of identifying 'inbox' drivers seems to produce the most matching SeverityOverride results.
                            # Some alternatives tested were DEVPKEY_Device_GenericDriverInstalled and Get-AuthenticodeSignature .IsOSBinary property.
                            [bool]$DriverIsInbox = (
                                (Get-PnpDeviceProperty -InputObject $Device -KeyName 'DEVPKEY_Device_DriverProvider').Data -eq 'Microsoft' -and
                                (Get-PnpDeviceProperty -InputObject $Device -KeyName 'DEVPKEY_Device_DriverInfPath').Data -notmatch '^oem\d+\.inf$'
                            )
                            if ($DriverIsInbox) {
                                Write-Debug "$('- ' * $DebugIndent)Failed because device is using an inbox driver"
                                return -1
                            }
                        }

                        $icmParams = @{
                            'InputObject' = $Device
                            'MethodName'  = 'GetDeviceProperties'
                            'Arguments'   = @{'devicePropertyKeys' = @('DEVPKEY_Device_DriverVersion')}
                            'Verbose'     = $false
                            'ErrorAction' = 'SilentlyContinue'
                        }

                        $DriverVersionObject = Invoke-CimMethod @icmParams | Select-Object -ExpandProperty deviceProperties
                        if (-not $DriverVersionObject) {
                            # Fall back to the much slower Get-PnpDeviceProperty cmdlet in cases where GetDeviceProperties fails (e.g. disconnected "phantom" devices)
                            $DriverVersionObject = Get-PnpDeviceProperty -InputObject $Device -KeyName 'DEVPKEY_Device_DriverVersion'
                        }
                        $DriverVersion = $DriverVersionObject.Data

                        $icmParams = @{
                            'InputObject' = $Device
                            'MethodName'  = 'GetDeviceProperties'
                            'Arguments'   = @{'devicePropertyKeys' = @('DEVPKEY_Device_DriverDate')}
                            'Verbose'     = $false
                            'ErrorAction' = 'SilentlyContinue'
                        }

                        $DriverDateObject = Invoke-CimMethod @icmParams | Select-Object -ExpandProperty deviceProperties
                        if (-not $DriverDateObject) {
                            # Fall back to the much slower Get-PnpDeviceProperty cmdlet in cases where GetDeviceProperties fails (e.g. disconnected "phantom" devices)
                            $DriverDateObject = Get-PnpDeviceProperty -InputObject $Device -KeyName 'DEVPKEY_Device_DriverDate'
                        }
                        $DriverDate = $DriverDateObject.Data

                        # Documentation for this: https://docs.microsoft.com/en-us/windows-hardware/drivers/install/identifier-score--windows-vista-and-later-
                        # To be clear, this is a 'pretty good / best effort' approach, but it can detect false positives or miss generic drivers.
                        # AFAIK it is not possible to detect with 100% certainty that a driver is generic/inbox and even if - it's not always a problem.
                        # So this information should only be used for informaing the user or as an aid in making non-critical decisions,
                        # do not rely on this detection/boolean to be accurate!
                        [UInt32]$DriverRank = (Get-PnpDeviceProperty -InputObject $Device -KeyName 'DEVPKEY_Device_DriverRank').Data
                        [byte]$DriverMatchTypeScore = $DriverRank -shr 12 -band 0xF
                        Write-Debug "Device '$($Device.Name)' DriverRank is 0x$('{0:X8}' -f $DriverRank)"
                        if ($DriverMatchTypeScore -ge 2) {
                            Write-Verbose "Device '$($Device.Name)' may currently be using a generic or inbox driver"
                        }

                        if ($DriverChildNodes -contains 'Date') {
                            Write-Debug "$('- ' * $DebugIndent)Trying to match driver based on Date"
                            $LenovoDate = [DateTime]::new(0)
                            [bool]$LenovoDateIsValid = [DateTime]::TryParseExact(
                                $Dependency.Date,
                                'yyyy-MM-dd',
                                [CultureInfo]::InvariantCulture,
                                [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal,
                                [ref]$LenovoDate
                            )
                            if ($LenovoDateIsValid) {
                                if ($DriverDate) {
                                    # WMI and therefore CIM stores datetime values in a DMTF string format.
                                    # When these are converted to DateTime objects, they are always converted to the local timezone, aka an offset
                                    # is "artificially" added. For driver dates, this can lead to GitHub#33 where the offset is enough to change the date,
                                    # which leads to false driver results. We have to remove the offset by converting the DateTime of Kind 'Local' back to UTC.
                                    # See GitHub#33 and https://docs.microsoft.com/en-us/dotnet/api/system.management.managementdatetimeconverter.todatetime?view=netframework-4.8#remarks
                                    $DriverDate = $DriverDate.ToUniversalTime().Date
                                    Write-Debug "$('- ' * $DebugIndent)[Got: $DriverDate, Expected: $LenovoDate]"
                                    if ($DriverDate -ge $LenovoDate) {
                                        Write-Debug "$('- ' * $DebugIndent)Passed DriverDate test"
                                        $TestResults.Add($true)
                                    } else {
                                        Write-Debug "$('- ' * $DebugIndent)Failed DriverDate test"
                                        $TestResults.Add($false)
                                    }
                                } else {
                                    Write-Verbose "Device '$($Device.InstanceId)' does not report its driver date"
                                }
                            } else {
                                Write-Verbose "Got unsupported date format from Lenovo: '$($Dependency.Date)' (expected yyyy-MM-dd)"
                            }
                        }

                        if ($DriverChildNodes -contains 'Version') {
                            Write-Debug "$('- ' * $DebugIndent)Trying to match driver based on Version"
                            # Not all drivers tell us their versions via the OS API. I think later I can try to parse the INIs as an alternative, but it would get tricky
                            if ($DriverVersion) {
                                Write-Debug "$('- ' * $DebugIndent)[Got: $DriverVersion, Expected: $($Dependency.Version)]"
                                if ((Test-VersionPattern -LenovoString $Dependency.Version -SystemString $DriverVersion) -eq 0) {
                                    Write-Debug "$('- ' * $DebugIndent)Passed DriverVersion test"
                                    $TestResults.Add($true)
                                } else {
                                    Write-Debug "$('- ' * $DebugIndent)Failed DriverVersion test"
                                    $TestResults.Add($false)
                                }
                            } else {
                                Write-Verbose "Device '$($Device.InstanceId)' does not report its driver version"
                            }
                        }
                    }

                    # If all HardwareID-tests were successful, return SUCCESS
                    if (-not ($TestResults -contains $false)) {
                        return 0 #SUCCESS
                    }

                    # If one or more HardwareID-tests were completed but failed (e.g. Date) continue in case there are further tests like FileVersion
                } else {
                    Write-Debug "$('- ' * $DebugIndent)No installed device matched the driver check"
                }
            }

            if (Compare-Array @('File', 'Version') -in $DriverChildNodes) {
                # This may not be 100% yet as Lenovo sometimes uses some non-system environment variables in their file paths
                [string]$Path = Resolve-CmdVariable -String $Dependency.File -ExtraVariables @{'WINDOWS' = $env:SystemRoot}
                if (Test-Path -LiteralPath $Path -PathType Leaf) {
                    $filProductVersion = (Get-Item -LiteralPath $Path).VersionInfo.ProductVersion
                    $FileVersionCompare = Test-VersionPattern -LenovoString $Dependency.Version -SystemString $filProductVersion
                    if ($FileVersionCompare -eq -2) {
                        Write-Debug "$('- ' * $DebugIndent)Got unsupported with ProductVersion, trying comparison with FileVersion"
                        $filFileVersion = (Get-Item -LiteralPath $Path).VersionInfo.FileVersion
                        return (Test-VersionPattern -LenovoString $Dependency.Version -SystemString $filFileVersion)
                    } else {
                        return $FileVersionCompare
                    }
                } else {
                    Write-Debug "$('- ' * $DebugIndent)The file '$Path' was not found."
                    return -1
                }
            }

            # If we have not hit a success condition before the end, return with failure
            return -1
        }
        '_EmbeddedControllerVersion' {
            if ($CachedHardwareTable['_EmbeddedControllerVersion']) {
                if ($CachedHardwareTable['_EmbeddedControllerVersion'] -eq '255.255') {
                    Write-Warning "This computers EC firmware is not upgradable but is being used to evaluate a package"
                }
                return (Test-VersionPattern -LenovoString $Dependency.Version -SystemString $CachedHardwareTable['_EmbeddedControllerVersion'])
            }
            return -1
        }
        '_ExternalDetection' {
            $externalDetection = Invoke-PackageCommand -Command $Dependency.'#text' -Path $PackagePath -RuntimeLimit $script:LSUClientConfiguration.MaxExternalDetectionRuntime
            if ($externalDetection.Err) {
                Write-Debug "$('- ' * $DebugIndent)[ External process did not run properly: $($externalDetection.Err) ]"
                return -1
            } else {
                Write-Debug "$('- ' * $DebugIndent)[ Got ExitCode: $($externalDetection.Info.ExitCode), Expected: $($Dependency.rc) ]"
                if ($externalDetection.Info.ExitCode -in ($Dependency.rc -split ',')) {
                    return 0
                } else {
                    return -1
                }
            }
        }
        '_FileExists' {
            # This may not be 100% yet as Lenovo sometimes uses some non-system environment variables in their file paths
            [string]$Path = Resolve-CmdVariable -String $Dependency.'#text' -ExtraVariables @{'WINDOWS' = $env:SystemRoot}
            if (Test-Path -LiteralPath $Path -PathType Leaf) {
                return 0
            } else {
                return -1
            }
        }
        '_FileVersion' {
            # This may not be 100% yet as Lenovo sometimes uses some non-system environment variables in their file paths
            [string]$Path = Resolve-CmdVariable -String $Dependency.File -ExtraVariables @{'WINDOWS' = $env:SystemRoot}
            if (Test-Path -LiteralPath $Path -PathType Leaf) {
                $filProductVersion = (Get-Item -LiteralPath $Path).VersionInfo.ProductVersion
                $FileVersionCompare = Test-VersionPattern -LenovoString $Dependency.Version -SystemString $filProductVersion
                if ($FileVersionCompare -eq -2) {
                    Write-Debug "$('- ' * $DebugIndent)Got unsupported with ProductVersion, trying comparison with FileVersion"
                    $filFileVersion = (Get-Item -LiteralPath $Path).VersionInfo.FileVersion
                    return (Test-VersionPattern -LenovoString $Dependency.Version -SystemString $filFileVersion)
                } else {
                    return $FileVersionCompare
                }
            } else {
                Write-Debug "$('- ' * $DebugIndent)The file '$Path' was not found."
                return -1
            }
        }
        '_Firmware' {
            # https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/query-version-and-status-ps1-script?view=windows-11
            # Dependency.Version can also have a hex2dec attribute (True/False) that is currently not checked, but depending on whether
            # it exists PowerShell deserializes the XML differently (.Version can be string or XmlElement). Using SelectNode is consistent.
            $LenovoVersion = $Dependency.SelectSingleNode('Version').'#text'
            foreach ($PnpDevice in $CachedHardwareTable['_PnPID']) {
                foreach ($entry in $Dependency.HardwareIDs) {
                    # Only exact HardwareID matches will be found (no wildcards)
                    if ($entry.'#cdata-section' -in $PnpDevice.HardwareID) {
                        [string]$PnpDeviceFirmwareRev = $PnpDevice.HardwareID[0].Substring($PnpDevice.HardwareID[0].IndexOf('&REV_') + 5)
                        Write-Debug "$('- ' * $DebugIndent)[ Got: ${PnpDeviceFirmwareRev}, Expected: ${LenovoVersion} ]"
                        if ($LenovoVersion.Contains('^')) {
                            if ($PnpDeviceFirmwareRev -eq $LenovoVersion.Trim('^')) {
                                return 0 # Exact match - success
                            } else {
                                # I am not sure how to best support comparisons for hexadecimal numbers
                                return -2 # Caret in Version and no exact match - we don't know
                            }
                        } else {
                            if ($PnpDeviceFirmwareRev -eq $LenovoVersion) {
                                return 0 # Exact match - success
                            } else {
                                return -1 # No caret and no match - fail
                            }
                        }
                    }
                }
            }
            return -1 # HardwareID not in system - fail
        }
        '_OS' {
            foreach ($entry in $Dependency.OS) {
                if ("$entry" -like "WIN$($CachedHardwareTable['_OS'])*") {
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

                return (Test-VersionPattern -LenovoString $DependencyVersion -SystemString $regVersion)
            } else {
                return -1
            }
        }
        '_WindowsBuildVersion' {
            # A _WindowsBuildVersion test can specify multiple Build Versions, see issue #42
            [array]$TestResults = foreach ($DependencyVersion in $Dependency.Version) {
                Write-Debug "$('- ' * $DebugIndent)[ Got: $($CachedHardwareTable['_WindowsBuildVersion']), Expected: $DependencyVersion ]"
                Test-VersionPattern -LenovoString $DependencyVersion -SystemString $CachedHardwareTable['_WindowsBuildVersion']
            }

            # If we had a clear success match, return success overall.
            # If we had no clear successes, but an unsupported case, return
            # -2 for unsupported so the calling function can evaluate that.
            # Otherwise return -1 to indicate failure (no matches).
            if ($TestResults -contains 0) {
                return 0
            } elseif ($TestResults -contains -2) {
                return -2
            } else {
                return -1
            }
        }
        default {
            Write-Verbose "Unsupported dependency encountered: $_"
            return -2
        }
    }

    return -2
}
