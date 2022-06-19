function Install-BiosUpdate {
    [CmdletBinding()]
    [OutputType('ExternalProcessResult')]
    Param (
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
        [System.IO.DirectoryInfo]$PackageDirectory
    )

    $BitLockerOSDrive = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction SilentlyContinue | Where-Object { $_.ProtectionStatus -eq 'On' }
    if ($BitLockerOSDrive) {
        Write-Verbose "Operating System drive is BitLocker-encrypted, suspending protection for BIOS update. BitLocker will automatically resume after the next bootup.`r`n"
        $null = $BitLockerOSDrive | Suspend-BitLocker
    }

    if (Test-Path -LiteralPath "$PackageDirectory\winuptp.exe" -PathType Leaf) {
        Write-Verbose "This is a ThinkPad-style BIOS update`r`n"
        if (Test-Path -LiteralPath "$PackageDirectory\winuptp.log" -PathType Leaf) {
            Remove-Item -LiteralPath "$PackageDirectory\winuptp.log" -Force
        }

        $installProcess = Invoke-PackageCommand -Path $PackageDirectory -Executable "$PackageDirectory\winuptp.exe" -Arguments '-s'
        if ($installProcess.Err) {
            return $installProcess
        } else {
            # Collect and trim content of winuptp.log file if it exists
            [array]$LogMessage = if ($Log = Get-Content -LiteralPath "$PackageDirectory\winuptp.log" -ErrorAction SilentlyContinue) {
                $NonEmptyPredicate = [Predicate[string]] { -not [string]::IsNullOrWhiteSpace($args[0]) }

                $LogFirstNonEmpty = [array]::FindIndex([string[]]$Log, $NonEmptyPredicate)
                if ($LogFirstNonEmpty -ne -1) {
                    $LogLastNonEmpty = [array]::FindLastIndex([string[]]$Log, $NonEmptyPredicate)
                    $Log[$LogFirstNonEmpty..$LogLastNonEmpty]
                }
            }

            return [ExternalProcessResult]::new(
                $installProcess.Err,
                [BiosUpdateInfo]@{
                    'FilePath'             = $installProcess.Info.FilePath
                    'Arguments'            = $installProcess.Info.Arguments
                    'WorkingDirectory'     = $installProcess.Info.WorkingDirectory
                    'Timestamp'            = [datetime]::Now.ToFileTime()
                    'ExitCode'             = $installProcess.Info.ExitCode
                    'StandardOutput'       = $installProcess.Info.StandardOutput
                    'StandardError'        = $installProcess.Info.StandardError
                    'LogMessage'           = $LogMessage
                    'Runtime'              = $installProcess.Info.Runtime
                    'ActionNeeded'         = 'REBOOT'
                    'SuccessOverrideValue' = $installProcess.Info.ExitCode -in @(0, 1) # winuptp return codes: https://thinkdeploy.blogspot.com/2017/09/return-codes-for-winuptp.html
                }
            )
        }
    } elseif ((Test-Path -LiteralPath "$PackageDirectory\Flash.cmd" -PathType Leaf) -and (Test-Path -LiteralPath "$PackageDirectory\wflash2.exe" -PathType Leaf)) {
        Write-Verbose "This is a ThinkCentre-style BIOS update`r`n"
        # Get a random non-existant directory name to copy wflash2 to as a safe testbed
        do {
            [string]$wflashTestPath = Join-Path -Path "$PackageDirectory" -ChildPath ( [System.IO.Path]::GetRandomFileName() )
        } until ( -not [System.IO.Directory]::Exists($wflashTestPath) )
        $null = New-Item -Path "$wflashTestPath" -ItemType Directory
        Copy-Item -LiteralPath "$PackageDirectory\wflash2.exe" -Destination "$wflashTestPath"
        [bool]$SCCMParameterIsSupported = Test-Wflash2ForSCCMParameter -PathToWFLASH2EXE "$wflashTestPath\wflash2.exe"
        Remove-Item -LiteralPath "$wflashTestPath" -Recurse -Force
        if ($SCCMParameterIsSupported) {
            $installProcess = Invoke-PackageCommand -Path $PackageDirectory -Executable "$PackageDirectory\Flash.cmd" -Arguments '/ign /sccm /quiet'
            # Handle the case where $installProcess indicates an error because the process never started
            if ($installProcess.Err) {
                return $installProcess
            } else {
                return [ExternalProcessResult]::new(
                    $installProcess.Err,
                    [BiosUpdateInfo]@{
                        'FilePath'             = $installProcess.Info.FilePath
                        'Arguments'            = $installProcess.Info.Arguments
                        'WorkingDirectory'     = $installProcess.Info.WorkingDirectory
                        'Timestamp'            = [datetime]::Now.ToFileTime()
                        'ExitCode'             = $installProcess.Info.ExitCode
                        'StandardOutput'       = $installProcess.Info.StandardOutput
                        'StandardError'        = $installProcess.Info.StandardError
                        'LogMessage'           = ''
                        'Runtime'              = $installProcess.Info.Runtime
                        'ActionNeeded'         = 'SHUTDOWN'
                        'SuccessOverrideValue' = $null
                    }
                )
            }
        } else {
            Write-Warning "This BIOS-Update uses an older version of wflash2.exe that cannot be installed without forcing a reboot - skipping!"
            return [ExternalProcessResult]::new(
                [ExternalProcessError]::OPERATION_NOT_SUPPORTED,
                $null
            )
        }
    }
}
