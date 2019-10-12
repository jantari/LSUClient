#Requires -Version 5.0

# StrictMode 2.0 is possible but makes the creation of the LenovoPackage objects a lot uglier with no real benefit
Set-StrictMode -Version 1.0

enum Severity {
    Critical    = 1
    Recommended = 2
    Optional    = 3
}

enum DependencyParserState {
    DO_HAVE     = 0
    DO_NOT_HAVE = 1
}

# Check for old Windows versions in a manner that is compatible with PowerShell 2.0 all the way to to 7.0
$WINDOWSVERSION = (New-Object -TypeName 'System.Management.ManagementObjectSearcher' -ArgumentList "SELECT Version FROM Win32_OperatingSystem").Get() | Select-Object -ExpandProperty Version
if ($WINDOWSVERSION -notmatch "^10\.") {
    throw "This module requires Windows 10."
}

$CachedHardwareTable = @{
    '_OS'                        = 'WIN' + (Get-CimInstance Win32_OperatingSystem).Version -replace "\..*"
    '_CPUAddressWidth'           = [wmisearcher]::new('SELECT AddressWidth FROM Win32_Processor').Get().AddressWidth
    '_Bios'                      = (Get-CimInstance -ClassName Win32_BIOS).SMBIOSBIOSVersion
    '_PnPID'                     = @(Get-PnpDevice)
    '_EmbeddedControllerVersion' = [Regex]::Match((Get-CimInstance -ClassName Win32_BIOS).SMBIOSBIOSVersion, "(?<=\()[\d\.]+").Value
}

[int]$XMLTreeDepth = 0

class LenovoPackage {
    [string]$ID
    [string]$Category
    [string]$Title
    [version]$Version
    [string]$Vendor
    [Severity]$Severity
    [int]$RebootType
    [Uri]$URL
    [PackageExtractInfo]$Extracter
    [PackageInstallInfo]$Installer
    [bool]$IsApplicable
}

class PackageExtractInfo {
    [string]$Command
    [string]$FileName
    [int64]$FileSize
    [string]$FileSHA

    PackageExtractInfo ([System.Xml.XmlElement]$PackageXML) {
        $this.Command  = $PackageXML.ExtractCommand
        $this.FileName = $PackageXML.Files.Installer.File.Name
        $this.FileSize = $PackageXML.Files.Installer.File.Size
        $this.FileSHA  = $PackageXML.Files.Installer.File.CRC
    }
}

class PackageInstallInfo {
    [bool]$Unattended
    [ValidateNotNullOrEmpty()]
    [string]$InstallType
    [int64[]]$SuccessCodes
    [string]$InfFile
    [string]$Command
    
    PackageInstallInfo ([System.Xml.XmlElement]$PackageXML, [string]$Category) {
        $this.InstallType    = $PackageXML.Install.type
        $this.SuccessCodes   = $PackageXML.Install.rc -split ','
        $this.InfFile        = $PackageXML.Install.INFCmd.INFfile
        $this.Command        = $PackageXML.Install.Cmdline.'#text'
        if (($PackageXML.Reboot.type -in 0, 3) -or
            ($Category -eq 'BIOS UEFI') -or
            ($PackageXML.Install.type -eq 'INF'))
        {
            $this.Unattended = $true
        } else {
            $this.Unattended = $false
        }
    }
}

class BiosUpdateInfo {
    [ValidateNotNullOrEmpty()]
    [bool]$WasRun
    [int64]$Timestamp
    [ValidateNotNullOrEmpty()]
    [int64]$ExitCode
    [string]$LogMessage
    [ValidateNotNullOrEmpty()]
    [string]$ActionNeeded
}

function Test-RunningAsAdmin {
    $Identity = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    return [bool]$Identity.IsInRole( [Security.Principal.WindowsBuiltInRole]::Administrator )
}

function Show-DownloadProgress {
    Param (
        [Parameter( Mandatory=$true )]
        [ValidateNotNullOrEmpty()]
        [array]$Transfers
    )

    [char]$ESC               = 0x1b
    [int]$TotalTransfers     = $Transfers.Count
    [int]$InitialCursorYPos  = $host.UI.RawUI.CursorPosition.Y
    [console]::CursorVisible = $false
    [int]$TransferCountChars = $TotalTransfers.ToString().Length
    [console]::Write("[ {0}   ]  Downloading packages ...`r[ " -f (' ' * ($TransferCountChars * 2 + 3)))
    while ($Transfers.IsCompleted -contains $false) {
        $i = $Transfers.Where{ $_.IsCompleted }.Count
        [console]::Write("`r[ {0,$TransferCountChars} / $TotalTransfers /" -f $i)
        Start-Sleep -Milliseconds 75
        [console]::Write("`r[ {0,$TransferCountChars} / $TotalTransfers $ESC(0q$ESC(B" -f $i)
        Start-Sleep -Milliseconds 75
        [console]::Write("`r[ {0,$TransferCountChars} / $TotalTransfers \" -f $i)
        Start-Sleep -Milliseconds 65
        [console]::Write("`r[ {0,$TransferCountChars} / $TotalTransfers |" -f $i)
        Start-Sleep -Milliseconds 65
    }
    [console]::SetCursorPosition(1, $InitialCursorYPos)
    if ($Transfers.Status -contains "Faulted" -or $Transfers.Status -contains "Canceled") {
        Write-Host "$ESC[91m    !    $ESC[0m] Downloaded $($Transfers.Where{ $_.Status -notin 'Faulted', 'Canceled'}.Count) / $($Transfers.Count) packages"
    } else {
        Write-Host "$ESC[92m    $([char]8730)    $ESC[0m] Downloaded all packages    "
    }
    [console]::CursorVisible = $true
}

function New-WebClient {
    Param (
        [Uri]$Proxy,
        [pscredential]$ProxyCredential,
        [switch]$ProxyUseDefaultCredentials
    )

    $webClient = [System.Net.WebClient]::new()

    if ($Proxy) {
        $webProxy = [System.Net.WebProxy]::new($Proxy)
        $webProxy.BypassProxyOnLocal = $false
        if ($ProxyCredential) {
            $webProxy.Credentials = $ProxyCredential.GetNetworkCredential()
        } elseif ($ProxyUseDefaultCredentials) {
            # If both ProxyCredential and ProxyUseDefaultCredentials are passed,
            # UseDefaultCredentials will overwrite the supplied credentials.
            # This behaviour, comment and code are replicated from Invoke-WebRequest
            $webproxy.UseDefaultCredentials = $true
        }
        $webClient.Proxy = $webProxy
    }

    return $webClient
}

function Compare-VersionStrings {
    <#
        .SYNOPSIS
        This function parses some of Lenovos conventions for expressing
        version requirements and does the comparison. Returns 0, -1 or -2.
    #>

    Param (
        [ValidateNotNullOrEmpty()]
        [string]$LenovoString,
        [ValidateNotNullOrEmpty()]
        [string]$SystemString
    )

    [bool]$LenovoStringIsVersion = [Version]::TryParse( $LenovoString, [ref]$null )
    [bool]$SystemStringIsVersion = [Version]::TryParse( $SystemString, [ref]$null )

    if (-not $SystemStringIsVersion) {
        Write-Verbose "Got unsupported version format from OS: '$SystemString'"
        return -2
    }

    if ($LenovoStringIsVersion) {
        # Easiest case, both inputs are just version numbers
        if ([Version]::new($LenovoString) -eq [Version]::new($SystemString)) {
            return 0 # SUCCESS, Versions match
        } else {
            return -1
        }
    } else {
        # Lenovo string contains additional directive (^-symbol likely)
        if (-not ($LenovoString -match '^\^?[\d\.]+$' -xor $LenovoString -match '^[\d\.]+\^?$')) {
            # Unknown character in version string or ^ at both the first and last positions
            Write-Verbose "Got unsupported version format from Lenovo: '$LenovoString'"
            return -2
        }

        [Version]$LenovoVersion = $LenovoString -replace '\^'
        [Version]$SystemVersion = $SystemString
        
        switch -Wildcard ($LenovoString) {
            "^*" {
                # Means up to and including
                if ($SystemVersion -le $LenovoVersion) {
                    return 0
                } else {
                    return -1
                }
            }
            "*^" {
                # Means must be equal or higher than
                if ($SystemVersion -ge $LenovoVersion) {
                    return 0
                } else {
                    return -1
                }
            }
            default {
                Write-Verbose "Got unsupported version format from Lenovo: '$LenovoString'"
                return -2
            }
        }
    }
}

function Invoke-PackageCommand {
    Param (
        [ValidateNotNullOrEmpty()]
        [string]$Path,
        [ValidateNotNullOrEmpty()]
        [Parameter( Mandatory = $true )]
        [string]$Command
    )

    # Some commands Lenovo specifies include an unescaped & sign so we have to escape it
    $Command = $Command -replace '&', '^&'

    # Get a random non-existant file name to capture cmd output to
    do {
        [string]$LogFilePath = Join-Path -Path $Path -ChildPath ( [System.IO.Path]::GetRandomFileName() )
    } until ( -not [System.IO.File]::Exists($LogFilePath) )

    # Environment variables are carried over to child processes and we cannot set this in the StartInfo of the new process because ShellExecute is true
    # ShellExecute is true because there are installers that indefinitely hang otherwise (Conexant Audio)
    [System.Environment]::SetEnvironmentVariable("PACKAGEPATH", "$Path", "Process")

    $process                            = [System.Diagnostics.Process]::new()
    $process.StartInfo.WindowStyle      = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $process.StartInfo.FileName         = 'cmd.exe'
    $process.StartInfo.UseShellExecute  = $true
    $process.StartInfo.Arguments        = "/D /C $Command 2>&1 1>`"$LogFilePath`""
    $process.StartInfo.WorkingDirectory = $Path
    $null = $process.Start()
    $process.WaitForExit()

    [System.Environment]::SetEnvironmentVariable("PACKAGEPATH", [String]::Empty, "Process")

    if ([System.IO.File]::Exists($LogFilePath)) {
        $output = Get-Content -LiteralPath "$LogFilePath" -Raw
        Remove-Item -LiteralPath "$LogFilePath"
    }
    
    return [PSCustomObject]@{
        'Output'   = $output
        'ExitCode' = $process.ExitCode
    }
}

function Test-MachineSatisfiesDependency {
    Param (
        [ValidateNotNullOrEmpty()]
        [System.Xml.XmlElement]$Dependency
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

            foreach ($HardwareID in $Dependency.HardwareID.'#cdata-section') {
                if ($CachedHardwareTable['_PnPID'].HardwareID -notcontains "$HardwareID") {
                    continue
                }

                if (@($Dependency.ChildNodes.SchemaInfo.Name) -contains 'Date') {
                    $LenovoDate = [DateTime]::new(0)
                    if ( [DateTime]::TryParseExact($Dependency.Date, 'yyyy-MM-dd', [CultureInfo]::InvariantCulture, 'None', [ref]$LenovoDate) ) {
                        $DriverDate = ($CachedHardwareTable['_PnPID'].Where{ $_.HardwareID -eq "$HardwareID" } | Get-PnpDeviceProperty -KeyName 'DEVPKEY_Device_DriverDate').Data.Date
                        if ($DriverDate -eq $LenovoDate) {
                            return 0 # SUCCESS
                        }
                    } else {
                        Write-Verbose "Got unsupported date format from Lenovo: '$($Dependency.Date)' (expected yyyy-MM-dd)"
                    }
                }

                if (@($Dependency.ChildNodes.SchemaInfo.Name) -contains 'Version') {
                    $DriverVersion = ($CachedHardwareTable['_PnPID'].Where{ $_.HardwareID -eq "$HardwareID" } | Get-PnpDeviceProperty -KeyName 'DEVPKEY_Device_DriverVersion').Data
                    # Not all drivers tell us their versions via the OS API. I think later I can try to parse the INIs as an alternative, but it would get tricky
                    if ($DriverVersion) {
                        return (Compare-VersionStrings -LenovoString $Dependency.Version -SystemString $DriverVersion)
                    } else {
                        return -2
                    }
                }
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
            return (Invoke-PackageCommand -Command "IF EXIST `"$Dependency`" ( exit 0 ) else ( exit -1 )" -Path $env:TEMP)
        }
        '_OS' {
            foreach ($entry in $Dependency.OS) {
                if ($CachedHardwareTable['_OS'] -like "$entry*") {
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
                if ($HardwareID -like "$($Dependency.'#cdata-section')*") {
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
        default {
            Write-Verbose "Unsupported dependency encountered: $_`r`n"
            return -2
        }
    }
}

function Resolve-XMLDependencies {
    Param (
        [string]$PackageID,
        [Parameter ( Mandatory = $true )]
        [ValidateNotNullOrEmpty()]
        $XMLIN,
        [switch]$FailUnsupportedDependencies,
        [string]$DebugLogFile
    )
    
    $XMLTreeDepth++
    [DependencyParserState]$ParserState = 0
    
    foreach ($XMLTREE in $XMLIN) {
        if ($DebugLogFile) {
            Add-Content -LiteralPath $DebugLogFile -Value "$('- ' * $XMLTreeDepth )|> Node: $($XMLTREE.SchemaInfo.Name)"
        }

        if ($XMLTREE.SchemaInfo.Name -eq 'Not') {
            $ParserState = $ParserState -bxor 1
            if ($DebugLogFile) {
                Add-Content -LiteralPath $DebugLogFile -Value "$('- ' * $XMLTreeDepth)Switched state to: $ParserState"
            }
        }
        
        $Result = if ($XMLTREE.SchemaInfo.Name -like "_*") {
            switch (Test-MachineSatisfiesDependency -Dependency $XMLTREE) {
                0 {
                    $true
                }
                -1 {
                    $false
                }
                -2 {
                    if ($DebugLogFile) {
                        Add-Content -LiteralPath $DebugLogFile -Value "$('- ' * $XMLTreeDepth)Something unsupported encountered in: $($XMLTREE.SchemaInfo.Name)"
                    }
                    if ($FailUnsupportedDependencies) { $false } else { $true }
                }
            }
        } else {
            $SubtreeResults = Resolve-XMLDependencies -XMLIN $XMLTREE.ChildNodes -FailUnsupportedDependencies:$FailUnsupportedDependencies -DebugLogFile $DebugLogFile
            switch ($XMLTREE.SchemaInfo.Name) {
                'And' {
                    if ($DebugLogFile) {
                        Add-Content -LiteralPath $DebugLogFile -Value "$('- ' * $XMLTreeDepth)Tree was AND: Results: $subtreeresults"
                    }
                    if ($subtreeresults -contains $false) { $false } else { $true  }
                }
                default {
                    if ($DebugLogFile) {
                        Add-Content -LiteralPath $DebugLogFile -Value "$('- ' * $XMLTreeDepth)Tree was OR: Results: $subtreeresults"
                    }
                    if ($subtreeresults -contains $true ) { $true  } else { $false }
                }
            }
        }

        if ($DebugLogFile) {
            Add-Content -LiteralPath $DebugLogFile -Value "$('- ' * $XMLTreeDepth)< Returning $($Result -bxor $ParserState) from node $($XMLTREE.SchemaInfo.Name)"
        }

        $Result -bxor $ParserState
        $ParserState = 0 # DO_HAVE
    }

    $XMLTreeDepth--
}

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

    if (Test-Path -LiteralPath "$PackageDirectory\wintpup.exe" -PathType Leaf) {
        Write-Verbose "This is a ThinkPad-style BIOS update`r`n"
        if (Test-Path -LiteralPath "$PackageDirectory\winuptp.log" -PathType Leaf) {
            Remove-Item -LiteralPath "$PackageDirectory\winuptp.log" -Force
        }

        $installProcess = Invoke-PackageCommand -Path $PackageDirectory -Command 'winuptp.exe -s'
        return [BiosUpdateInfo]@{
            'WasRun'       = $true
            'Timestamp'    = [datetime]::Now.ToFileTime()
            'ExitCode'     = $installProcess.ExitCode
            'LogMessage'   = if ($Log = Get-Content -LiteralPath "$PackageDirectory\winuptp.log" -Raw -ErrorAction SilentlyContinue) { $Log.Trim() } else { [String]::Empty }
            'ActionNeeded' = 'REBOOT'
        }
    } elseif (Test-Path -LiteralPath "$PackageDirectory\Flash.cmd" -PathType Leaf) {
        Write-Verbose "This is a ThinkCentre-style BIOS update`r`n"
        $installProcess = Invoke-PackageCommand -Path $PackageDirectory -Command 'Flash.cmd /ign /sccm /quiet'
        return [BiosUpdateInfo]@{
            'WasRun'       = $true
            'Timestamp'    = [datetime]::Now.ToFileTime()
            'ExitCode'     = $installProcess.ExitCode
            'LogMessage'   = $installProcess.Output
            'ActionNeeded' = 'SHUTDOWN'
        }
    }
}

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

function Get-LSUpdate {
    <#
        .SYNOPSIS
        Fetches available driver packages and updates for Lenovo computers
        
        .PARAMETER Model
        Specify an alternative Lenovo Computer Model to retrieve update packages for.
        You may want to use this together with '-All' so that packages are not filtered against your local machines configuration.

        .PARAMETER Proxy
        Specifies a proxy server for the connection to Lenovo. Enter the URI of a network proxy server.

        .PARAMETER ProxyCredential
        Specifies a user account that has permission to use the proxy server that is specified by the -Proxy
        parameter.

        .PARAMETER ProxyUseDefaultCredentials
        Indicates that the cmdlet uses the credentials of the current user to access the proxy server that is
        specified by the -Proxy parameter.

        .PARAMETER All
        Return all updates, regardless of whether they are applicable to this specific machine or whether they are already installed.
        E.g. this will retrieve LTE-Modem drivers even for machines that do not have the optional LTE-Modem installed. Installation of such drivers will likely still fail.
        
        .PARAMETER FailUnsupportedDependencies
        Lenovo has different kinds of dependencies they specify for each package. This script makes a best effort to parse, understand and check these.
        However, new kinds of dependencies may be added at any point and some currently in use are not supported yet either. By default, any unknown
        dependency will be treated as met/OK. This switch will fail all dependencies we can't actually check. Typically, an update installation
        will simply fail if there really was a dependency missing.
    #>

    [CmdletBinding()]
    Param (
        [ValidatePattern('^\w{4}$')]
        [string]$Model,
        [Uri]$Proxy,
        [pscredential]$ProxyCredential,
        [switch]$ProxyUseDefaultCredentials,
        [switch]$All,
        [switch]$FailUnsupportedDependencies,
        [ValidateScript({ try { [System.IO.File]::Create("$_").Dispose(); $true} catch { $false } })]
        [string]$DebugLogFile
    )

    if (-not (Test-RunningAsAdmin)) {
        Write-Warning "Unfortunately, this command produces most accurate results when run as an Administrator`r`nbecause some of the commands Lenovo uses to detect your computers hardware have to run as admin :("
    }

    if (-not $Model) {
        $MODELREGEX = [regex]::Match((Get-CimInstance -ClassName CIM_ComputerSystem -ErrorAction SilentlyContinue).Model, '^\w{4}')
        if ($MODELREGEX.Success -ne $true) {
            throw "Could not parse computer model number. This may not be a Lenovo computer, or an unsupported model."
        }
        $Model = $MODELREGEX.Value
    }
    
    Write-Verbose "Lenovo Model is: $Model`r`n"
    if ($DebugLogFile) {
        Add-Content -LiteralPath $DebugLogFile -Value "Lenovo Model is: $Model"
    }

    $webClient = New-WebClient -Proxy $Proxy -ProxyCredential $ProxyCredential -ProxyUseDefaultCredentials $ProxyUseDefaultCredentials
    
    try {
        $COMPUTERXML = $webClient.DownloadString("https://download.lenovo.com/catalog/${Model}_Win10.xml")
    }
    catch {
        if ($_.Exception.innerException.Response.StatusCode -eq [System.Net.HttpStatusCode]::NotFound) {
            throw "No information was found on this model of computer (invalid model number or not supported by Lenovo?)"
        } else {
            throw "An error occured when contacting download.lenovo.com:`r`n$($_.Exception.Message)"
        }
    }

    $UTF8ByteOrderMark = [System.Text.Encoding]::UTF8.GetString(@(195, 175, 194, 187, 194, 191))

    # Downloading with Net.WebClient seems to remove the BOM automatically, this only seems to be neccessary when downloading with IWR. Still I'm leaving it in to be safe
    [xml]$PARSEDXML = $COMPUTERXML -replace "^$UTF8ByteOrderMark"

    Write-Verbose "A total of $($PARSEDXML.packages.count) driver packages are available for this computer model."

    foreach ($packageURL in $PARSEDXML.packages.package) {
        $rawPackageXML           = $webClient.DownloadString($packageURL.location)
        [xml]$packageXML         = $rawPackageXML -replace "^$UTF8ByteOrderMark"
        $DownloadedExternalFiles = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
        
        # Downloading files needed by external detection in package dependencies
        if ($packageXML.Package.Files.External) {
            # Packages like https://download.lenovo.com/pccbbs/mobiles/r0qch05w_2_.xml show we have to download the XML itself too
            $DownloadDest = Join-Path -Path $env:Temp -ChildPath ($packageURL.location -replace "^.*/")
            $webClient.DownloadFile($packageURL.location, $DownloadDest)
            $DownloadedExternalFiles.Add( [System.IO.FileInfo]::new($DownloadDest) )
            foreach ($externalFile in $packageXML.Package.Files.External.ChildNodes) {
                [string]$DownloadDest = Join-Path -Path $env:Temp -ChildPath $externalFile.Name
                $webClient.DownloadFile(($packageURL.location -replace "[^/]*$") + $externalFile.Name, $DownloadDest)
                $DownloadedExternalFiles.Add( [System.IO.FileInfo]::new($DownloadDest) )
            }
        }

        if ($DebugLogFile) {
            Add-Content -LiteralPath $DebugLogFile -Value "Parsing dependencies for package: $($packageXML.Package.id)`r`n"
        }
        
        $packageObject = [LenovoPackage]@{
            'ID'           = $packageXML.Package.id
            'Category'     = $packageURL.category
            'Title'        = $packageXML.Package.Title.Desc.'#text'
            'Version'      = if ([Version]::TryParse($packageXML.Package.version, [ref]$null)) { $packageXML.Package.version } else { '0.0.0.0' }
            'Vendor'       = $packageXML.Package.Vendor
            'Severity'     = $packageXML.Package.Severity.type
            'RebootType'   = $packageXML.Package.Reboot.type
            'URL'          = $packageURL.location
            'Extracter'    = $packageXML.Package
            'Installer'    = [PackageInstallInfo]::new($packageXML.Package, $packageURL.category)
            'IsApplicable' = Resolve-XMLDependencies -PackageID $packageXML.Package.id -XML $packageXML.Package.Dependencies -FailUnsupportedDependencies:$FailUnsupportedDependencies -DebugLogFile $DebugLogFile
        }

        if ($All -or $packageObject.IsApplicable) {
            $packageObject
        }

        foreach ($tempFile in $DownloadedExternalFiles) {
            if ($tempFile.Exists) {
                $tempFile.Delete()
            }
        }
    }
    
    $webClient.Dispose()
}

function Save-LSUpdate {
    <#
        .SYNOPSIS
        Downloads a Lenovo update package to disk

        .PARAMETER Package
        The Lenovo package or packages to download

        .PARAMETER Proxy
        Specifies a proxy server for the connection to Lenovo. Enter the URI of a network proxy server.

        .PARAMETER ProxyCredential
        Specifies a user account that has permission to use the proxy server that is specified by the -Proxy
        parameter.

        .PARAMETER ProxyUseDefaultCredentials
        Indicates that the cmdlet uses the credentials of the current user to access the proxy server that is
        specified by the -Proxy parameter.

        .PARAMETER ShowProgress
        Shows a progress animation during the downloading process, recommended for interactive use
        as downloads can be quite large and without any progress output the script may appear stuck

        .PARAMETER Force
        Redownload and overwrite packages even if they have already been downloaded previously

        .PARAMETER Path
        The target directory to which to download the packages to. In this directory,
        a subfolder will be created for each downloaded package.
    #>

	[CmdletBinding()]
    Param (
        [Parameter( Position = 0, ValueFromPipeline = $true, Mandatory = $true )]
        [pscustomobject]$Package,
        [Uri]$Proxy,
        [pscredential]$ProxyCredential,
        [switch]$ProxyUseDefaultCredentials,
        [switch]$ShowProgress,
        [switch]$Force,
        [System.IO.DirectoryInfo]$Path = "$env:TEMP\LSUPackages"
    )
    
    begin {
        $transfers = [System.Collections.Generic.List[System.Threading.Tasks.Task]]::new()
    }
    
    process {
        foreach ($PackageToGet in $Package) {
            $DownloadDirectory = Join-Path -Path $Path -ChildPath $PackageToGet.id

            if (-not (Test-Path -Path $DownloadDirectory -PathType Container)) {
                Write-Verbose "Destination directory did not exist, created it: '$DownloadDirectory'`r`n"
                $null = New-Item -Path $DownloadDirectory -Force -ItemType Directory
            }

            $PackageDownload = $PackageToGet.URL -replace "[^/]*$"
            $PackageDownload = [String]::Concat($PackageDownload, $PackageToGet.Extracter.FileName)
            $DownloadPath    = Join-Path -Path $DownloadDirectory -ChildPath $PackageToGet.Extracter.FileName

            if ($Force -or -not (Test-Path -Path $DownloadPath -PathType Leaf) -or (
               (Get-FileHash -Path $DownloadPath -Algorithm SHA256).Hash -ne $PackageToGet.Extracter.FileSHA)) {
                # Checking if this package was already downloaded, if yes skipping redownload
                $webClient = New-WebClient -Proxy $Proxy -ProxyCredential $ProxyCredential -ProxyUseDefaultCredentials $ProxyUseDefaultCredentials
                $transfers.Add( $webClient.DownloadFileTaskAsync($PackageDownload, $DownloadPath) )
            }
        }
    }
    
    end {
        if ($ShowProgress -and $transfers) {
            Show-DownloadProgress -Transfers $transfers
        } else {
            while ($transfers.IsCompleted -contains $false) {
                Start-Sleep -Milliseconds 500
            }
        }

        if ($transfers.Status -contains "Faulted" -or $transfers.Status -contains "Canceled") {
            $errorString = "Not all packages could be downloaded, the following errors were encountered:"
            foreach ($transfer in $transfers.Where{ $_.Status -in "Faulted", "Canceled"}) {
                $errorString += "`r`n$($transfer.AsyncState.AbsoluteUri) : $($transfer.Exception.InnerExceptions.Message)"
            }
            Write-Error $errorString
        }
        
        foreach ($webClient in $transfers) {
            $webClient.Dispose()
        }
    }
}

function Expand-LSUpdate {
    Param (
        [Parameter( Position = 0, ValueFromPipeline = $true, Mandatory = $true )]
        [pscustomobject]$Package,
        [Parameter( Mandatory = $true )]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
        [string]$Path
    )

    if (Get-ChildItem -Path $Path -File) {
        $extractionProcess = Invoke-PackageCommand -Path $Path -Command $Package.Extracter.Command
        if ($extractionProcess.ExitCode -ne 0) {
            Write-Warning "Extraction of package $($PackageToProcess.ID) may have failed!`r`n"
        }
    } else {
        Write-Warning "This package was not downloaded or deleted (empty folder), skipping extraction ...`r`n"
    }
}

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
                if ($BIOSUpdateExit.WasRun -eq $true) {
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
                        if ($installProcess.ExitCode -notin $PackageToProcess.Installer.SuccessCodes) {
                            Write-Warning "Installation of package '$($PackageToProcess.id) - $($PackageToProcess.Title)' FAILED with return code $($installProcess.ExitCode)!`r`n"
                        }
                    }
                    'INF' {
                        $installProcess = Start-Process -FilePath pnputil.exe -Wait -Verb RunAs -WorkingDirectory $PackageDirectory -PassThru -ArgumentList "/add-driver $($PackageToProcess.Installer.InfFile) /install"
                        # pnputil is a documented Microsoft tool and Exit code 0 means SUCCESS while 3010 means SUCCESS but reboot required,
                        # however Lenovo does not always include 3010 as an OK return code - that's why we manually check against it here
                        if ($installProcess.ExitCode -notin $PackageToProcess.Installer.SuccessCodes -and $installProcess.ExitCode -notin 0, 3010) {
                            Write-Warning "Installation of package '$($PackageToProcess.id) - $($PackageToProcess.Title)' FAILED with return code $($installProcess.ExitCode)!`r`n"
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
