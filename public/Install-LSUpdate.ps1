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
        [switch]$SaveBIOSUpdateInfoToRegistry,
        [Uri]$Proxy,
        [pscredential]$ProxyCredential,
        [switch]$ProxyUseDefaultCredentials
    )

    begin {
        if ($PSBoundParameters['Debug'] -and $DebugPreference -eq 'Inquire') {
            Write-Verbose "Adjusting the DebugPreference to 'Continue'."
            $DebugPreference = 'Continue'
        }
    }

    process {
        foreach ($PackageToProcess in $Package) {
            $Extracter = $PackageToProcess.Files | Where-Object { $_.Kind -eq 'Installer' }
            $PackageDirectory = Join-Path -Path $Path -ChildPath $PackageToProcess.ID
            if (-not (Test-Path -LiteralPath $PackageDirectory -PathType Container)) {
                $null = New-Item -Path $PackageDirectory -Force -ItemType Directory
            }

            $SpfParams = @{
                'SourceFile' = $Extracter
                'Directory' = $PackageDirectory
                'Proxy' = $Proxy
                'ProxyCredential' = $ProxyCredential
                'ProxyUseDefaultCredentials' = $ProxyUseDefaultCredentials
            }
            $FullPath = Save-PackageFile @SpfParams
            if (-not $FullPath) {
                Write-Error "The installer of package '$($PackageToProcess.ID)' could not be accessed or found and will be skipped"
                continue
            }

            Expand-LSUpdate -Package $PackageToProcess -WorkingDirectory $PackageDirectory

            Write-Verbose "Installing package $($PackageToProcess.ID) ..."

            # Special-case ThinkPad and ThinkCentre (winuptp.exe and Flash.cmd/wflash2.exe)
            # BIOS updates because we can install them silently and unattended with custom arguments
            # Other BIOS updates are not classified as unattended and will be treated like any other package.
            if ($PackageToProcess.Installer.Command -match 'winuptp\.exe|Flash\.cmd') {
                # We are dealing with a known kind of BIOS Update
                [BiosUpdateInfo]$BIOSUpdateExit = Install-BiosUpdate -PackageDirectory $PackageDirectory
                if ($BIOSUpdateExit) {
                    if ($BIOSUpdateExit.ExitCode -notin $PackageToProcess.Installer.SuccessCodes) {
                        Write-Warning "Unattended BIOS/UEFI update FAILED with return code $($BIOSUpdateExit.ExitCode)!`r`n"
                        if ($BIOSUpdateExit.LogMessage) {
                            Write-Warning "The following information was collected:`r`n$($BIOSUpdateExit.LogMessage)`r`n"
                        }
                    } else {
                        # BIOS Update successful
                        Write-Output "BIOS UPDATE SUCCESS: An immediate full $($BIOSUpdateExit.ActionNeeded) is strongly recommended to allow the BIOS update to complete!"
                        if ($SaveBIOSUpdateInfoToRegistry) {
                            Set-BIOSUpdateRegistryFlag -Timestamp $BIOSUpdateExit.Timestamp -ActionNeeded $BIOSUpdateExit.ActionNeeded -PackageHash $Extracter.Checksum
                        }
                    }
                } else {
                    Write-Warning "The BIOS update could not be installed, the most likely cause is that it's an unknown, unsupported kind"
                }
            } else {
                switch ($PackageToProcess.Installer.InstallType) {
                    'CMD' {
                        # Correct typo from Lenovo ... yes really...
                        $InstallCMD     = $PackageToProcess.Installer.Command -replace '-overwirte', '-overwrite'
                        $installProcess = Invoke-PackageCommand -Path $PackageDirectory -Command $InstallCMD
                        if (-not $installProcess) {
                            Write-Warning "Installation of package '$($PackageToProcess.ID) - $($PackageToProcess.Title)' FAILED - the installation could not start"
                        } elseif ($installProcess.ExitCode -notin $PackageToProcess.Installer.SuccessCodes) {
                            if ($installProcess.StandardOutput -or $installProcess.StandardError) {
                                Write-Warning "Installation of package '$($PackageToProcess.ID) - $($PackageToProcess.Title)' FAILED with:`r`n$($installProcess | Format-List ExitCode, StandardOutput, StandardError | Out-String)"
                            } else {
                                Write-Warning "Installation of package '$($PackageToProcess.ID) - $($PackageToProcess.Title)' FAILED with ExitCode $($installProcess.ExitCode)"
                            }
                        }
                    }
                    'INF' {
                        $installProcess = Start-Process -FilePath 'pnputil.exe' -Wait -Verb RunAs -WorkingDirectory $PackageDirectory -PassThru -ArgumentList "/add-driver $($PackageToProcess.Installer.InfFile) /install"
                        if (-not $installProcess) {
                            Write-Warning "Installation of package '$($PackageToProcess.ID) - $($PackageToProcess.Title)' FAILED - the installation could not start"
                        } elseif ($installProcess.ExitCode -notin $PackageToProcess.Installer.SuccessCodes -and $installProcess.ExitCode -notin 0, 3010) {
                            # pnputil is a documented Microsoft tool and Exit code 0 means SUCCESS while 3010 means SUCCESS but reboot required,
                            # however Lenovo does not always include 3010 as an OK return code - that's why we manually check against it here
                            if ($installProcess.StandardOutput -or $installProcess.StandardError) {
                                Write-Warning "Installation of package '$($PackageToProcess.ID) - $($PackageToProcess.Title)' FAILED with:`r`n$($installProcess | Format-List ExitCode, StandardOutput, StandardError | Out-String)"
                            } else {
                                Write-Warning "Installation of package '$($PackageToProcess.ID) - $($PackageToProcess.Title)' FAILED with ExitCode $($installProcess.ExitCode)"
                            }
                        }
                    }
                    default {
                        Write-Warning "Unsupported package installtype '$_', skipping installation!"
                    }
                }
            }
        }
    }
}
