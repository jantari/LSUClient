function Install-BiosUpdate {
    [CmdletBinding()]
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

        $installProcess = Invoke-PackageCommand -Path $PackageDirectory -Command 'winuptp.exe -s'
        if ($installProcess) {
            return [BiosUpdateInfo]@{
                'FilePath'         = $installProcess.FilePath
                'Arguments'        = $installProcess.Arguments
                'WorkingDirectory' = $installProcess.WorkingDirectory
                'Timestamp'        = [datetime]::Now.ToFileTime()
                'ExitCode'         = $installProcess.ExitCode
                'StandardOutput'   = $installProcess.StandardOutput
                'StandardError'    = $installProcess.StandardError
                'LogMessage'       = if ($Log = Get-Content -LiteralPath "$PackageDirectory\winuptp.log" -ErrorAction SilentlyContinue) { $Log } else { [String]::Empty }
                'Runtime'          = $installProcess.Runtime
                'ActionNeeded'     = 'REBOOT'
            }
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
            $installProcess = Invoke-PackageCommand -Path $PackageDirectory -Command 'Flash.cmd /ign /sccm /quiet'
            # Handle the case where $installProcess is NULL because the process never started
            if ($installProcess) {
                return [BiosUpdateInfo]@{
                    'FilePath'         = $installProcess.FilePath
                    'Arguments'        = $installProcess.Arguments
                    'WorkingDirectory' = $installProcess.WorkingDirectory
                    'Timestamp'        = [datetime]::Now.ToFileTime()
                    'ExitCode'         = $installProcess.ExitCode
                    'StandardOutput'   = $installProcess.StandardOutput
                    'StandardError'    = $installProcess.StandardError
                    'LogMessage'       = ''
                    'Runtime'          = $installProcess.Runtime
                    'ActionNeeded'     = 'SHUTDOWN'
                }
            }
        } else {
            Write-Warning "This BIOS-Update uses an older version of wflash2.exe that cannot be installed without forcing a reboot - skipping!"
        }
    }
}
