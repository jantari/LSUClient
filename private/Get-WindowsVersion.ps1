function Get-WindowsVersion {
    <#
        .DESCRIPTION
        Tries a few different methods to get the exact current Windows version
        because some of them can be inaccurate/outdated (particularly for Insider Builds).
    #>

    [OutputType('System.Version')]

    $Versions = [System.Collections.Generic.Dictionary[string, Version]]::new()

    $CmdOutput = & "${env:SystemRoot}\System32\cmd.exe" /D /C VER
    $CmdOutputRegex = [regex]::match($CmdOutput, '[\d\.]+')
    if ($CmdOutputRegex.Success) {
        [version]$cmdVersion = $CmdOutputRegex.Value
        $Versions.Add('cmd', $cmdVersion)
    }

    $registryData = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name CurrentMajorVersionNumber, CurrentMinorVersionNumber, CurrentBuildNumber, UBR -ErrorAction SilentlyContinue
    if ($?) {
        $registryVersion = [Version]::new(
            $registryData.CurrentMajorVersionNumber,
            $registryData.CurrentMinorVersionNumber,
            $registryData.CurrentBuildNumber,
            $registryData.UBR
        )
        $Versions.Add('registry', $registryVersion)
    }

    $fileData = Get-Item -LiteralPath "${env:SystemRoot}\System32\ntoskrnl.exe" -ErrorAction SilentlyContinue
    $fileVersion = [Version]::new()
    if ($fileData -and [Version]::TryParse($fileData.VersionInfo.ProductVersion, [ref]$fileVersion)) {
        $Versions.Add('file', $fileVersion)
    }

    [Version]$EnvVersion = [Environment]::OSVersion.Version
    $Versions.Add('env', $EnvVersion)

    [Version]$WmiData = (Get-CimInstance -ClassName CIM_OperatingSystem -Property Version -Verbose:$false).Version
    $WmiVersion = [Version]::new()
    if ([Version]::TryParse($WmiData, [ref]$WmiVersion)) {
        $Versions.Add('wmi', $WmiVersion)
    }

    $HighestFound = $Versions.GetEnumerator() | Sort-Object -Property Value | Select-Object -Last 1

    return $HighestFound.Value
}
