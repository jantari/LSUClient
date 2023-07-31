function Install-LSUpdate {
    <#
        .SYNOPSIS
        Installs a Lenovo update package. Downloads it if not previously downloaded.

        .DESCRIPTION
        Installs a Lenovo update package. Downloads it if not previously downloaded.

        .PARAMETER Package
        The Lenovo package object to install

        .PARAMETER Path
        If you previously downloaded the Lenovo package to a custom directory, specify its path here so that the package can be found

        .PARAMETER SaveBIOSUpdateInfoToRegistry
        If a BIOS update is successfully installed, write information about it to 'HKLM\Software\LSUClient\BIOSUpdate'.
        This is useful in automated deployment scenarios, especially the 'ActionNeeded' key which will tell you whether a shutdown or reboot is required to apply the BIOS update.
        The created registry values will not be deleted by this module, only overwritten on the next installed BIOS Update.

        .PARAMETER Proxy
        Specifies the URL of a proxy server to use for the connection to the update repository.
        Used if a package still needs to be downloaded before it can be installed.

        .PARAMETER ProxyCredential
        Specifies a user account that has permission to use the proxy server that is specified by the -Proxy
        parameter.

        .PARAMETER ProxyUseDefaultCredentials
        Indicates that the cmdlet uses the credentials of the current user to access the proxy server that is
        specified by the -Proxy parameter.
    #>

    [CmdletBinding()]
    [OutputType('PackageInstallResult')]
    Param (
        [Parameter( Position = 0, ValueFromPipeline = $true, Mandatory = $true )]
        [PSCustomObject]$Package,
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
        [System.IO.DirectoryInfo]$Path = "$env:TEMP\LSUPackages",
        [switch]$SaveBIOSUpdateInfoToRegistry,
        [Uri]$Proxy = $script:LSUClientConfiguration.Proxy,
        [PSCredential]$ProxyCredential = $script:LSUClientConfiguration.ProxyCredential,
        [switch]$ProxyUseDefaultCredentials = $script:LSUClientConfiguration.ProxyUseDefaultCredentials
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

            # As a precaution, do not apply runtime limits and kill in-progress installers for packages that are likely firmware updaters
            if ($script:LSUClientConfiguration.MaxInstallerRuntime -gt [TimeSpan]::Zero -and (
                $PackageToProcess.Installer.Command -like '*winuptp.exe*' -or
                $PackageToProcess.Installer.Command -like '*Flash.cmd*' -or
                $PackageToProcess.Type -in 'BIOS', 'Firmware' -or
                $PackageToProcess.Category -like "*BIOS*" -or
                $PackageToProcess.Category -like "*UEFI*" -or
                $PackageToProcess.Category -like "*Firmware*" -or
                $PackageToProcess.Title -like "*BIOS*" -or
                $PackageToProcess.Title -like "*UEFI*" -or
                $PackageToProcess.Title -like "*Firmware*" -or
                $PackageToProcess.RebootType -eq 5)
            ) {
                Write-Verbose "MaxInstallerRuntime of $($script:LSUClientConfiguration.MaxInstallerRuntime) will not be enforced for this package because it appears to be a BIOS or firmware update"
                $MaxInstallerRuntime = [TimeSpan]::Zero
            } else {
                $MaxInstallerRuntime = $script:LSUClientConfiguration.MaxInstallerRuntime
            }

            switch ($PackageToProcess.Installer.InstallType) {
                'CMD' {
                    # Special-case ThinkPad and ThinkCentre (winuptp.exe and Flash.cmd/wflash2.exe)
                    # BIOS updates because we can install them silently and unattended with custom arguments
                    # Other BIOS updates are not classified as unattended and will be treated like any other package.
                    if ($PackageToProcess.Installer.Command -match 'winuptp\.exe|Flash\.cmd') {
                        # We are dealing with a known kind of BIOS Update
                        $installProcess = Install-BiosUpdate -PackageDirectory $PackageDirectory
                    } else {
                        # Correct typo from Lenovo ... yes really...
                        $InstallCMD = $PackageToProcess.Installer.Command -replace '-overwirte', '-overwrite'
                        $installProcess = Invoke-PackageCommand -Path $PackageDirectory -Command $InstallCMD -RuntimeLimit $MaxInstallerRuntime
                    }

                    $Success = $installProcess.Err -eq [ExternalProcessError]::NONE -and $(
                        if ($installProcess.Info -is [BiosUpdateInfo] -and $null -ne $installProcess.Info.SuccessOverrideValue) {
                            $installProcess.Info.SuccessOverrideValue
                        } else {
                            $installProcess.Info.ExitCode -in $PackageToProcess.Installer.SuccessCodes
                        }
                    )

                    $FailureReason = if ($installProcess.Err) {
                        "$($installProcess.Err)"
                    } elseif ($installProcess.Info.ExitCode -in $PackageToProcess.Installer.CancelCodes) {
                        'CANCELLED_BY_USER'
                    } elseif (-not $Success) {
                        'INSTALLER_EXITCODE'
                    } else {
                        ''
                    }

                    $PendingAction = if (-not $Success) {
                        'NONE'
                    } elseif ($installProcess.Info -is [BiosUpdateInfo]) {
                        if ($installProcess.Info.ActionNeeded -eq 'SHUTDOWN') {
                            'SHUTDOWN'
                        } elseif ($installProcess.Info.ActionNeeded -eq 'REBOOT') {
                            'REBOOT_MANDATORY'
                        }
                    } elseif ($PackageToProcess.RebootType -eq 0) {
                        'NONE'
                    } elseif ($PackageToProcess.RebootType -eq 1) {
                        # RebootType 1 updates should force a reboot on their own, interrupting LSUClient anyway,
                        # but this can lead to race conditions (how fast does the reboot happen, killing LSUClient before this point?)
                        # or maybe the reboot doesn't happen for some reason so we still communicate that it's needed. See issue #94.
                        'REBOOT_MANDATORY'
                    } elseif ($PackageToProcess.RebootType -eq 3) {
                        'REBOOT_SUGGESTED'
                    } elseif ($PackageToProcess.RebootType -eq 4) {
                        'SHUTDOWN'
                    } elseif ($PackageToProcess.RebootType -eq 5) {
                        'REBOOT_MANDATORY'
                    }

                    [PackageInstallResult]@{
                        ID             = $PackageToProcess.ID
                        Title          = $PackageToProcess.Title
                        Type           = $PackageToProcess.Type
                        Success        = $Success
                        FailureReason  = $FailureReason
                        PendingAction  = $PendingAction
                        ExitCode       = $installProcess.Info.ExitCode
                        StandardOutput = $installProcess.Info.StandardOutput
                        StandardError  = $installProcess.Info.StandardError
                        LogOutput      = if ($installProcess.Info -is [BiosUpdateInfo]) { $installProcess.Info.LogMessage } else { '' }
                        Runtime        = if ($installProcess.Info) { $installProcess.Info.Runtime } else { [TimeSpan]::Zero }
                    }

                    # Extra handling for BIOS updates
                    if ($installProcess.Info -is [BiosUpdateInfo]) {
                        if ($Success) {
                            # BIOS Update successful
                            Write-Information -MessageData "BIOS UPDATE SUCCESS: An immediate full $($installProcess.Info.ActionNeeded) is strongly recommended to allow the BIOS update to complete!" -InformationAction Continue
                            if ($SaveBIOSUpdateInfoToRegistry) {
                                Set-BIOSUpdateRegistryFlag -Timestamp $installProcess.Info.Timestamp -ActionNeeded $installProcess.Info.ActionNeeded -PackageHash $Extracter.Checksum
                            }
                        }
                    }
                }
                'INF' {
                    $InfSuccessCodes = @(0, 3010) + $PackageToProcess.Installer.SuccessCodes
                    $InfInstallParams = @{
                        'Path'         = $PackageDirectory
                        'Executable'   = "${env:SystemRoot}\system32\pnputil.exe"
                        'Arguments'    = "/add-driver $($PackageToProcess.Installer.InfFile) /install"
                        'RuntimeLimit' = $MaxInstallerRuntime
                    }
                    $installProcess = Invoke-PackageCommand @InfInstallParams

                    $Success = $installProcess.Err -eq [ExternalProcessError]::NONE -and $installProcess.Info.ExitCode -in $InfSuccessCodes

                    [PackageInstallResult]@{
                        ID             = $PackageToProcess.ID
                        Title          = $PackageToProcess.Title
                        Type           = $PackageToProcess.Type
                        Success        = $Success
                        FailureReason  = if ($installProcess.Err) { "$($installProcess.Err)" } elseif (-not $Success) { 'INSTALLER_EXITCODE' } else { '' }
                        PendingAction  = if ($Success -and $installProcess.Info.ExitCode -eq 3010) { 'REBOOT_SUGGESTED' } else { 'NONE' }
                        ExitCode       = $installProcess.Info.ExitCode
                        StandardOutput = $installProcess.Info.StandardOutput
                        StandardError  = $installProcess.Info.StandardError
                        LogOutput      = ''
                        Runtime        = if ($installProcess.Info) { $installProcess.Info.Runtime } else { [TimeSpan]::Zero }
                    }
                }
                default {
                    Write-Warning "Unsupported package installtype '$_', skipping installation!"
                }
            }
        }
    }
}
