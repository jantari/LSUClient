function Set-BIOSUpdateRegistryFlag {
    Param (
        [Int64]$Timestamp = [datetime]::Now.ToFileTime(),
        [ValidateSet('REBOOT', 'SHUTDOWN')]
        [string]$ActionNeeded,
        [string]$PackageHash
    )

    try {
        $HKLM = [Microsoft.Win32.Registry]::LocalMachine
        $key  = $HKLM.CreateSubKey('SOFTWARE\LSUClient\BIOSUpdate')
        $key.SetValue('Timestamp',    $Timestamp,      'QWord' )
        $key.SetValue('ActionNeeded', "$ActionNeeded", 'String')
        $key.SetValue('PackageHash',  "$PackageHash",  'String')
    }
    catch {
        Write-Warning "The registry values containing information about the pending BIOS update could not be written!"
    }
}
