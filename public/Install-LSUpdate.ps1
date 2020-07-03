function Install-LSUpdate {
    <#
        .SYNOPSIS
        Installs a Lenovo update package. Downloads it if not previously downloaded.

        .PARAMETER Package
        The Lenovo package object to install

        .PARAMETER Path
        If you previously downloaded the Lenovo package to a custom directory, specify its path here so that the package can be found

        .PARAMETER SaveBIOSUpdateInfoToRegistry
        If a BIOS update is successfully installed, write information about it to 'HKLM\Software\LSUClient\BIOSUpdate'.
        This is useful in automated deployment scenarios, especially the 'ActionNeeded' key which will tell you whether a shutdown or reboot is required to apply the BIOS update.
        The created registry values will not be deleted by this module, only overwritten on the next installed BIOS Update.
    #>

	[CmdletBinding()]
    Param (
        [Parameter( Position = 0, ValueFromPipeline = $true, Mandatory = $true )]
        [pscustomobject]$Package,
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
        [System.IO.DirectoryInfo]$Path = "$env:TEMP\LSUPackages",
        [switch]$SaveBIOSUpdateInfoToRegistry
    )
    
    process {
        foreach ($PackageToProcess in $Package) {
            $PackageDirectory = Join-Path -Path $Path -ChildPath $PackageToProcess.id
            if (-not (Test-Path -LiteralPath (Join-Path -Path $PackageDirectory -ChildPath $PackageToProcess.Extracter.FileName) -PathType Leaf)) {
                Write-Verbose "Package '$($PackageToProcess.id)' was not yet downloaded or deleted, downloading ...`r`n"
                Save-LSUpdate -Package $PackageToProcess -Path $Path
            }

            Expand-LSUpdate -Package $PackageToProcess -Path $PackageDirectory
            
            Write-Verbose "Installing package $($PackageToProcess.ID) ...`r`n"

            if ($PackageToProcess.Category -eq 'BIOS UEFI') {
                # We are dealing with a BIOS Update
                [BiosUpdateInfo]$BIOSUpdateExit = Install-BiosUpdate -PackageDirectory $PackageDirectory
                if ($BIOSUpdateExit) {
                    if ($BIOSUpdateExit.ExitCode -notin $PackageToProcess.Installer.SuccessCodes) {
                        Write-Warning "Unattended BIOS/UEFI update FAILED with return code $($BIOSUpdateExit.ExitCode)!`r`n"
                        if ($BIOSUpdateExit.LogMessage) {
                            Write-Warning "The following information was collected:`r`n$($BIOSUpdateExit.LogMessage)`r`n"
                        }
                    } else {
                        # BIOS Update successful
                        Write-Output "BIOS UPDATE SUCCESS: An immediate full $($BIOSUpdateExit.ActionNeeded) is strongly recommended to allow the BIOS update to complete!`r`n"
                        if ($SaveBIOSUpdateInfoToRegistry) {
                            Set-BIOSUpdateRegistryFlag -Timestamp $BIOSUpdateExit.Timestamp -ActionNeeded $BIOSUpdateExit.ActionNeeded -PackageHash (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path -Path $PackageDirectory -ChildPath $Package.Extracter.FileName)).Hash
                        }
                    }
                } else {
                    Write-Warning "Either this is not a BIOS Update or it's an unsupported installer for one, skipping installation!`r`n"
                }
            } else {
                switch ($PackageToProcess.Installer.InstallType) {
                    'CMD' {
                        # Correct typo from Lenovo ... yes really...
                        $InstallCMD     = $PackageToProcess.Installer.Command -replace '-overwirte', '-overwrite'
                        $installProcess = Invoke-PackageCommand -Path $PackageDirectory -Command $InstallCMD
                        if (-not $installProcess) {
                            Write-Warning "Installation of package '$($PackageToProcess.id) - $($PackageToProcess.Title)' FAILED"
                        } elseif ($installProcess.ExitCode -notin $PackageToProcess.Installer.SuccessCodes) {
                            Write-Warning "Installation of package '$($PackageToProcess.id) - $($PackageToProcess.Title)' FAILED with:`r`n$($installProcess | Format-List | Out-String)"
                        }
                    }
                    'INF' {
                        $installProcess = Start-Process -FilePath pnputil.exe -Wait -Verb RunAs -WorkingDirectory $PackageDirectory -PassThru -ArgumentList "/add-driver $($PackageToProcess.Installer.InfFile) /install"
                        # pnputil is a documented Microsoft tool and Exit code 0 means SUCCESS while 3010 means SUCCESS but reboot required,
                        # however Lenovo does not always include 3010 as an OK return code - that's why we manually check against it here
                        if ($installProcess.ExitCode -notin $PackageToProcess.Installer.SuccessCodes -and $installProcess.ExitCode -notin 0, 3010) {
                            Write-Warning "Installation of package '$($PackageToProcess.id) - $($PackageToProcess.Title)' FAILED with:`r`n$($installProcess | Format-List | Out-String)"
                        }
                    }
                    default {
                        Write-Warning "Unsupported package installtype '$_', skipping installation ...`r`n"
                    }
                }
            }
        }
    }
}