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

# Check for old Windows versions
$WINDOWSVERSION = Get-WmiObject -Class Win32_OperatingSystem | Select-Object -ExpandProperty Version
if ($WINDOWSVERSION -notmatch "^10\.") {
    throw "This module requires Windows 10."
}

$DependencyHardwareTable = @{
    '_OS'                = 'WIN' + (Get-CimInstance Win32_OperatingSystem).Version -replace "\..*"
    '_CPUAddressWidth'   = [wmisearcher]::new('SELECT AddressWidth FROM Win32_Processor').Get().AddressWidth
    '_Bios'              = (Get-CimInstance -ClassName Win32_BIOS).SMBIOSBIOSVersion
    '_PnPID'             = (Get-PnpDevice).DeviceID
    '_ExternalDetection' = $NULL
    #'_EmbeddedControllerVersion' = [Regex]::Match((Get-CimInstance -ClassName Win32_BIOS).SMBIOSBIOSVersion, "(?<=\()[\d\.]+")
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
        if (($PackageXML.Reboot.type -eq 3) -or
            ($Category -eq 'BIOS UEFI' -and $PackageXML.Install.Cmdline.'#text' -like "*winuptp.exe*") -or
            ($PackageXML.Install.type -eq 'INF'))
        {
            $this.Unattended = $true
        } else {
            $this.Unattended = $false
        }
    }
}

class BiosUpdateInfo {
    [bool]$WasRun
    [int64]$Timestamp
    [int64]$ExitCode
    [string]$LogMessage
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

    $process                                  = [System.Diagnostics.Process]::new()
    $process.StartInfo.WindowStyle            = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $process.StartInfo.FileName               = 'cmd.exe'
    $process.StartInfo.UseShellExecute        = $false
    $process.StartInfo.Arguments              = "/D /C $Command"
    $process.StartInfo.WorkingDirectory       = $Path
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError  = $true
    $process.StartInfo.EnvironmentVariables.Add("PACKAGEPATH", "$Path")
    $null = $process.Start()
    $process.WaitForExit()

    return [PSCustomObject]@{
        'STDOUT'   = $process.StandardOutput.ReadToEnd()
        'STDERR'   = $process.StandardError.ReadToEnd()
        'ExitCode' = $process.ExitCode
    }
}

function Test-MachineSatisfiesDependency {
    Param (
        [string]$DependencyKey,
        [string]$DependencyValue
    )

    # Return values:
    # 0  SUCCESS, Dependency is met
    # -1 FAILRE, Dependency is not met
    # -2 Unknown dependency kind - status uncertain

    if ($DependencyKey -notin $DependencyHardwareTable.Keys) {
        return -2;
    }

    foreach ($Value in $DependencyHardwareTable["$DependencyKey"]) {
        if ($Value -like "$DependencyValue*") {
            return 0
        }
    }

    return -1;
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
        switch -Regex ($XMLTREE.SchemaInfo.Name) {
            '^_' {
                $ITEM = $XMLTREE.SchemaInfo.Name
            }
            'Not' {
                $ParserState = $ParserState -bxor 1
                if ($DebugLogFile) {
                    Add-Content -LiteralPath $DebugLogFile -Value "Switched state to: $ParserState"
                }
            }
        }
        
        $Results = if ($XMLTREE.HasChildNodes -and $XMLTREE.ChildNodes) {
            if ($DebugLogFile) {
                Add-Content -LiteralPath $DebugLogFile -Value "$('- ' * $XMLTreeDepth)$($XMLTREE.SchemaInfo.Name) has more children --> $($XMLTREE.ChildNodes)"
            }
            $subtreeresults = if ($XMLTREE.SchemaInfo.Name -eq '_ExternalDetection') {
                if ($DebugLogFile) {
                    Add-Content -LiteralPath $DebugLogFile -Value "External command is RAW: $($XMLTREE.'#text')"
                }
                $externalDetection = Invoke-PackageCommand -Path $env:Temp -Command $XMLTREE.'#text'
                if ($externalDetection.ExitCode -in ($XMLTREE.rc -split ',')) {
                    $true
                } else {
                    $false
                }
            } else {
                Resolve-XMLDependencies -XMLIN $XMLTREE.ChildNodes -FailUnsupportedDependencies:$FailUnsupportedDependencies -DebugLogFile:$DebugLogFile
            }
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
        } else {
            switch (Test-MachineSatisfiesDependency -DependencyKey $ITEM -DependencyValue $XMLTREE.innerText) {
                0 {
                    $true
                }
                -1 {
                    $false
                }
                -2 {
                    Write-Verbose "Unsupported dependency encountered: $ITEM`r`n"
                    if ($FailUnsupportedDependencies) { $false } else { $true }
                }
            }
            if ($DebugLogFile) {
                Add-Content -LiteralPath $DebugLogFile -Value "$('- ' * $XMLTreeDepth)$ITEM  :  $($XMLTREE.innerText)"
            }
        }
        if ($DebugLogFile) {
            Add-Content -LiteralPath $DebugLogFile -Value "Returning $($Results -bxor $ParserState) from node $($XMLTREE.SchemaInfo.Name)"
        }

        $Results -bxor $ParserState
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

    [array]$BIOSUpdateFiles = Get-ChildItem -LiteralPath $PackageDirectory -File
    $BitLockerOSDrive = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction SilentlyContinue | Where-Object { $_.ProtectionStatus -eq 'On' }
    if ($BitLockerOSDrive) {
        $BitLockerOSDrive | Suspend-BitLocker
        Write-Verbose "Operating System drive is BitLocker-encrypted, suspending protection for BIOS update. BitLocker will automatically resume after a power cycle.`r`n"
    }

    if ($BIOSUpdateFiles.Name -contains 'winuptp.exe' ) {
        # ThinkPad BIOS Update
        if (Test-Path -LiteralPath "$PackageDirectory\winuptp.log" -PathType Leaf) {
            Remove-Item -LiteralPath "$PackageDirectory\winuptp.log" -Force
        }

        $installProcess = Invoke-PackageCommand -Path $PackageDirectory -Command 'winuptp.exe -s'
        return [BiosUpdateInfo]@{
            'Timestamp'    = [datetime]::Now.ToFileTime()
            'ExitCode'     = $installProcess.ExitCode
            'LogMessage'   = if ($Log = Get-Content -LiteralPath "$PackageDirectory\winuptp.log" -Raw) { $Log.Trim() } else { [String]::Empty }
            'WasRun'       = $true
            'ActionNeeded' = 'REBOOT'
        }
    } elseif ($BIOSUpdateFiles.Name -contains 'Flash.cmd' ) {
        # ThinkCentre or ThinkStation BIOS Update
        $installProcess = Invoke-PackageCommand -Path $PackageDirectory -Command 'Flash.cmd /ign /sccm /quiet'
        return [BiosUpdateInfo]@{
            'Timestamp'    = [datetime]::Now.ToFileTime()
            'ExitCode'     = $installProcess.ExitCode
            'LogMessage'   = $installProcess.STDOUT
            'WasRun'       = $true
            'ActionNeeded' = 'SHUTDOWN'
        }
    }
}

function Set-BIOSUpdateRegistryFlag {
    Param (
        [Int64]$Timestamp = [datetime]::Now.ToFileTime(),
        [ValidateSet('REBOOT', 'SHUTDOWN')]
        [string]$ActionNeeded,
        [ValidateNotNullOrEmpty()]
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

    $COMPUTERINFO = Get-CimInstance -ClassName CIM_ComputerSystem | Select-Object Manufacturer, Model

    if (-not $Model) {
        $MODELRGX = [regex]::Match($COMPUTERINFO.Model, '^\w{4}')
        if ($MODELRGX.Success -ne $true) {
            throw "Could not parse Lenovo Model number. Full string otained was: '$($COMPUTERINFO.Model)', aborting."
        }
        $Model = $MODELRGX.Value
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
        $packageXMLOrig  = $webClient.DownloadString($packageURL.location)
        [xml]$packageXML = $packageXMLOrig -replace "^$UTF8ByteOrderMark"
        
        if ($packageXML.Package.Files.External) {
            foreach ($externalFile in $packageXML.Package.Files.External.ChildNodes) {
                $webClient.DownloadFile(($packageURL.location -replace "[^/]*$") + $externalFile.Name, (Join-Path -Path $env:Temp -ChildPath $externalFile.Name))
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
        $null = Invoke-PackageCommand -Path $Path -Command $Package.Extracter.Command
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

        .PARAMETER StoreBIOSUpdateInfoInRegistry
        If a BIOS update is successfully installed, write information about it to 'HKLM\Software\LSUClient\BIOSUpdate'.
        This is useful in automated deployment scenarios, especially the 'ActionNeeded' key which will tell you whether a shutdown or reboot is required to apply the BIOS update.
    #>

	[CmdletBinding()]
    Param (
        [Parameter( Position = 0, ValueFromPipeline = $true, Mandatory = $true )]
        [pscustomobject]$Package,
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
        [System.IO.DirectoryInfo]$Path = "$env:TEMP\LSUPackages",
        [switch]$StoreBIOSUpdateInfoInRegistry
    )
    
    process {
        foreach ($PackageToProcess in $Package) {
            $PackageDirectory = Join-Path -Path $Path -ChildPath $PackageToProcess.id
            if (-not (Test-Path -LiteralPath (Join-Path -Path $PackageDirectory -ChildPath $PackageToProcess.Extracter.FileName) -PathType Leaf)) {
                Write-Verbose "Package '$($PackageToProcess.id)' was not yet downloaded or deleted, downloading ..."
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
                            Write-Warning "The following information is available:`r`n$($BIOSUpdateExit.LogMessage)`r`n"
                        }
                    } else {
                        # BIOS Update successful
                        Write-Host "BIOS UPDATE SUCCESS: An immediate full $($BIOSUpdateExit.ActionNeeded) is strongly recommended to allow the BIOS update to complete!`r`n"
                        if ($StoreBIOSUpdateInfoInRegistry) {
                            Set-BIOSUpdateRegistryFlag -Timestamp $BIOSUpdateExit.Timestamp -ActionNeeded $BIOSUpdateExit.ActionNeeded -PackageHash (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path -Path $Path -ChildPath $Package.Extracter.FileName)).Hash
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
