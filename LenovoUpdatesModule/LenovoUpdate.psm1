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
    throw "This script requires Windows 10."
}

$DependencyHardwareTable = @{
    '_OS'                = 'WIN' + (Get-CimInstance Win32_OperatingSystem).Version -replace "\..*"
    '_CPUAddressWidth'   = [wmisearcher]::new('SELECT AddressWidth FROM Win32_Processor').Get().AddressWidth
    '_Bios'              = (Get-CimInstance -ClassName Win32_BIOS).SMBIOSBIOSVersion
    '_PnPID'             = (Get-PnpDevice).DeviceID
    '_ExternalDetection' = $NULL
    #'_EmbeddedControllerVersion' = [Regex]::Match((Get-CimInstance -ClassName Win32_BIOS).SMBIOSBIOSVersion, "(?<=\()[\d\.]+")
}

[DependencyParserState]$ParserState = 0
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
    [string]$InstallCommand
    
    PackageInstallInfo ([System.Xml.XmlElement]$PackageXML, [string]$Category) {
        $this.InstallType    = $PackageXML.Install.type
        $this.SuccessCodes   = $PackageXML.Install.rc -split ','
        $this.InfFile        = $PackageXML.Install.INFCmd.INFfile
        $this.InstallCommand = $PackageXML.Install.Cmdline.'#text'
        if (($PackageXML.Reboot.type -eq 3) -or
            ($Category -eq 'BIOS UEFI' -and $PackageXML.ExtractCommand -like "*winuptp.exe*") -or
            ($PackageXML.Install.type -eq 'INF'))
        {
            $this.Unattended = $true
        } else {
            $this.Unattended = $false
        }
    }
}

function Show-DownloadProgress {
    Param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        $Transfers
    )
	
    [char]$ESC  = 0x1b
    [int]$j = $Transfers.Count
	$cursorYpos = $host.UI.RawUI.CursorPosition.Y
	[console]::CursorVisible = $false
	[console]::Write("[ {0}   ]  Downloading packages ...`r[ " -f (' ' * ($j.ToString().Length * 2 + 3)))
	while ($Transfers.IsCompleted -contains $false) {
        $i = $Transfers.Where{ $_.IsCompleted }.Count
		[console]::Write("`r[ {0,2} / $j /" -f $i)
        Start-Sleep -Milliseconds 75
        [console]::Write("`r[ {0,2} / $j $ESC(0q$ESC(B" -f $i)
        Start-Sleep -Milliseconds 75
        [console]::Write("`r[ {0,2} / $j \" -f $i)
        Start-Sleep -Milliseconds 65
        [console]::Write("`r[ {0,2} / $j |" -f $i)
        Start-Sleep -Milliseconds 65
	}
	[console]::SetCursorPosition(1, $cursorYpos)
	if ($Transfers.Status -contains "Faulted" -or $Transfers.Status -contains "Canceled") {
        Write-Host "$ESC[91m    X    $ESC[0m] Downloaded $($Transfers.Where{ $_.Status -notin 'Faulted', 'Canceled'}.Count) / $($Transfers.Count) packages"
	} else {
		Write-Host "$ESC[92m    $([char]8730)    $ESC[0m] Downloaded all packages    "
	}
	[console]::CursorVisible = $true
}

function Test-MachineSatisfiesDependency {
    Param (
        [string]$DependencyKey,
        [string]$DependencyValue,
        [DependencyParserState]$State
    )

    # Return values:
    # 0  SUCCESS, Dependency is met
    # -1 FAILRE, Dependency is not met
    # -2 Unknown dependency kind - status uncertain

    if ($DependencyKey -notin $DependencyHardwareTable.Keys) {
        Write-Warning "Unsupported dependency '$DependencyKey' encountered!"
        return -2;
    }

    $RESULT = foreach ($Value in $DependencyHardwareTable["$DependencyKey"]) {
        # The first part of this expression returns a boolean if we have a dependency match,
        # the bxor inverts the boolean if we were supposed to NOT have a match
        ($Value -like "$DependencyValue*") -bxor $State
        # TODO: Implement an alternative REGEX matching algorithm
    }
    
    if ($RESULT -contains $true) {
        # Dependency is met
        return 0;
    } else {
        # Machine does not satisfy this dependency
        return -1;
    }
}

function Resolve-XMLDependencies {
    Param (
        [Parameter ( Mandatory = $true )]
        [ValidateNotNullOrEmpty()]
        $XMLIN,
        [switch]$TreatUnknownAsFailed
    )
    
    $XMLTreeDepth++
    
    foreach ($XMLTREE in $XMLIN) {
        switch -Regex ($XMLTREE.Name) {
            '^_' {
                $ITEM = $XMLTREE.Name
            }
            'Not' {
                $ParserState = $ParserState -bxor 1
            }
        }
        
        $Results = if ($XMLTREE.HasChildNodes -and $XMLTREE.ChildNodes) {
            Write-Verbose ("{0}$($XMLTREE.Name) --> $($XMLTREE.ChildNodes)" -f ('- ' * $XMLTreeDepth))
            $subtreeresults = if ($XMLTREE.Name -eq '_ExternalDetection') {
                $executable = Split-Path $XMLTREE.'#text' -Leaf
                $externalDetection = Start-Process -FilePath cmd.exe -WorkingDirectory "$env:Temp" -ArgumentList '/C', "$executable >nul" -PassThru -Wait -NoNewWindow
                if ($externalDetection.ExitCode -in ($XMLTREE.rc -split ',')) {
                    $true
                } else {
                    $false
                }
            } else {
                Resolve-XMLDependencies -XMLIN $XMLTREE.ChildNodes
            }
            Write-Verbose ("{0}Cleared $($XMLTREE.Name) with results: $subtreeresults" -f ('- ' * $XMLTreeDepth))
            switch ($XMLTREE.Name) {
                'And' {
                    Write-Verbose ("{0}Tree was AND: Results: $subtreeresults" -f ('- ' * $XMLTreeDepth))
                    if ($subtreeresults -contains $false) { $false } else { $true  }
                }
                default {
                    Write-Verbose ("{0}Tree was OR: Results: $subtreeresults" -f ('- ' * $XMLTreeDepth))
                    if ($subtreeresults -contains $true ) { $true  } else { $false }
                }
            }
        } else {
            switch (Test-MachineSatisfiesDependency -DependencyKey $ITEM -DependencyValue $XMLTREE.innerText -State $ParserState) {
                0 {
                    $true
                }
                -1 {
                    $false
                }
                -2 {
                    if ($TreatUnknownAsFailed) { $false } else { $true }
                }
            }
            Write-Verbose ("{0}$ITEM  :  $($XMLTREE.innerText)" -f ('- ' * $XMLTreeDepth))
        }
        $Results
    }

    $XMLTreeDepth--
}

function Get-LenovoUpdate {
    <#
        .SYNOPSIS
        Fetches available driver packages and updates for Lenovo computers
        
        .PARAMETER Model
        Specify an alternative Lenovo Computer Model to retrieve update packages for.
        You may want to use this together with '-All' so that packages are not filtered against your local machines hardware.

        .PARAMETER Proxy
        A URL to a web proxy (e.g. 'http://myproxy:3128')

        .PARAMETER All
        Return all updates, regardless of whether they are applicable to this specific machine or whether they are already installed.
        E.g. this will retrieve LTE-Modem drivers even for machines that do not have the optional LTE-Modem installed. Installation of such drivers will likely still fail.
    #>

    [CmdletBinding()]
    Param (
        [ValidatePattern('^\w{4}$')]
        [string]$Model,
        [string]$Proxy,
        [switch]$All
    )

    $COMPUTERINFO = Get-CimInstance -ClassName CIM_ComputerSystem | Select-Object Manufacturer, Model

    if (-not $Model) {
        $MODELRGX = [regex]::Match($COMPUTERINFO.Model, '^\w{4}')
        if ($MODELRGX.Success -ne $true) {
            throw "Could not parse Lenovo Model number. Full string otained was: '$($COMPUTERINFO.Model)', aborting."
        }
        $Model = $MODELRGX.Value
    }
    
    Write-Verbose "Lenovo Model is: $Model)"

    $webClient = [System.Net.WebClient]::new()
    if ($Proxy) {
        $webClient.Proxy = [System.Net.WebProxy]::new($Proxy)
    }
    
    try {
        $COMPUTERXML = $webClient.DownloadString(("https://download.lenovo.com/catalog/{0}_Win10.xml" -f $Model))
    }
    catch {
        if ($_.Exception.innerException.Response.StatusCode -eq [System.Net.HttpStatusCode]::NotFound) {
            throw "No information was found on this model of computer (not supported by Lenovo?)"
        } else {
            throw "An error occured when contacting download.lenovo.com:`r`n$($_.Exception.Message)"
        }
    }

    $UTF8ByteOrderMark = [System.Text.Encoding]::UTF8.GetString(@(195, 175, 194, 187, 194, 191))

    # Downloading with Net.WebClient seems to remove the BOM automatically, this only seems to be neccessary when downloading with IWR. Still I'm leaving it in to be safe
    [xml]$PARSEDXML = $COMPUTERXML -replace "^$UTF8ByteOrderMark"

    Write-Verbose "A total of $($PARSEDXML.packages.count) driver packages are available for this computer model."

    [LenovoPackage[]]$packagesCollection = foreach ($packageURL in $PARSEDXML.packages.package) {
        $packageXMLOrig = $webClient.DownloadString($packageURL.location)

        [xml]$packageXML = $packageXMLOrig -replace "^$UTF8ByteOrderMark"
        
        if ($packageXML.Package.Files.External) {
            foreach ($externalFile in $packageXML.Package.Files.External.ChildNodes) {
                $webClient.DownloadFile(($packageURL.location -replace "[^/]*$") + $externalFile.Name, (Join-Path -Path $env:Temp -ChildPath $externalFile.Name))
            }
        }

        Write-Verbose "Parsing dependencies for package: $($packageXML.Package.id)"
        [LenovoPackage]@{
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
            'IsApplicable' = Resolve-XMLDependencies -XML $packageXML.Package.Dependencies
        }
    }
    
    $webClient.Dispose()

    if ($All) {
        return $packagesCollection
    } else {
        return $packagesCollection.Where{ $_.IsApplicable }
    }
}

function Save-LenovoUpdate {
    Param (
        [Parameter( Position = 0, ValueFromPipeline = $true, Mandatory = $true )]
        [pscustomobject]$Package,
        [Uri]$Proxy,
        [switch]$ShowProgress,
        [switch]$Force,
        [System.IO.DirectoryInfo]$Path = "$env:TEMP\LenovoDrivers"
    )
    
    begin {
        $transfers = [System.Collections.Generic.List[System.Threading.Tasks.Task]]::new()
        if ($Proxy) {
            $proxyObject = [System.Net.WebProxy]::new($Proxy)
        }
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
                $webClient = [System.Net.WebClient]::new()
                if ($Proxy) {
                    $webClient.Proxy = $proxyObject
                }
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

function Expand-LenovoUpdate {
    Param (
        [Parameter( Mandatory = $true )]
        [LenovoPackage]$Package,
        [Parameter( Mandatory = $true )]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
        [string]$Path
    )

    $ExtractCMD  = $Package.Extracter.Command -replace "%PACKAGEPATH%", ('"{0}"' -f $Path)
    $ExtractARGS = $ExtractCMD -replace "^$($Package.Extracter.FileName)"

    if (Get-ChildItem -Path $Path -File) {
        Start-Process -FilePath $Package.Extracter.FileName -Verb RunAs -WorkingDirectory $Path -Wait -ArgumentList $ExtractARGS
    } else {
        Write-Warning "This package was not downloaded or deleted (empty folder), skipping extraction ...`r`n"
    }
}

function Install-LenovoUpdate {
    Param (
        [Parameter( Position = 0, ValueFromPipeline = $true, Mandatory = $true )]
        [pscustomobject]$Package,
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
        [System.IO.DirectoryInfo]$Path = "$env:TEMP\LenovoDrivers"
    )
    
    process {
        foreach ($PackageToProcess in $Package) {
            $PackageDirectory = Join-Path -Path $Path -ChildPath $PackageToProcess.id
            if (-not (Test-Path -LiteralPath (Join-Path -Path $PackageDirectory -ChildPath $PackageToProcess.Extracter.FileName) -PathType Leaf)) {
                Write-Verbose "Package '$($PackageToProcess.id)' was not yet downloaded or deleted, downloading ..."
                Save-LenovoUpdate -Package $PackageToProcess -Path $Path
            }

            Expand-LenovoUpdate -Package $PackageToProcess -Path $PackageDirectory

            if ($PackageToProcess.Category -eq 'BIOS UEFI' -and $UnattendedBIOS) {
                # We are dealing with a BIOS Update
                if (Test-Path -LiteralPath "$PackageDirectory\winuptp.exe") {
                    if (Test-Path -LiteralPath "$PackageDirectory\winuptp.log" -PathType Leaf) {
                        Remove-Item -LiteralPath "$PackageDirectory\winuptp.log" -Force
                    }
                
                    $installProcess = Start-Process -FilePath "$PackageDirectory\winuptp.exe" -Wait -Verb RunAs -WorkingDirectory $PackageDirectory -PassThru -ArgumentList "-s"
                    if ($installProcess.ExitCode -notin $PackageToProcess.Installer.SuccessCodes) {
                        $LenovoBIOSUpdateLog = (Get-Content -LiteralPath "$PackageDirectory\winuptp.log" -Raw).Trim()
                        Write-Warning "Unattended BIOS/UEFI Update FAILED with return code $($installProcess.ExitCode)!`r`nThe following log was created:`r`n$LenovoBIOSUpdateLog`r`n"
                    } else {
                        Write-Host 'An immediate full power cycle / reboot is strongly recommended to allow the BIOS Update to complete!'
                    }
                } else {
                    Write-Warning "Either this is not a BIOS Update or it's an unsupported installer for one, skipping installation ...`r`n"
                }
            } else {
                switch ($PackageToProcess.Installer.InstallType) {
                    'CMD' {
                        $InstallCMD = $PackageToProcess.Installer.InstallCommand -replace "%PACKAGEPATH%", $PackageDirectory
                        # Correct typo from Lenovo ... yes really...
                        $InstallCMD = $InstallCMD -replace '-overwirte', '-overwrite'
                
                        $installProcess = Start-Process -FilePath cmd.exe -Wait -Verb RunAs -WorkingDirectory $PackageDirectory -PassThru -ArgumentList '/c', "$InstallCMD"
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
                        Write-Warning "Unsupported Package installer method, skipping installation ...`r`n"
                    }
                }
            }
        }
    }
}
