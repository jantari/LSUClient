#Requires -Version 5.0

<#
    .SYNOPSIS
    Downloads and installs driver packages and updates for Lenovo computers

    .PARAMETER DownloadPath
    Directory in which the downloaded packages will be saved

    .PARAMETER Filter
    Select packages by their "Severity"-rating

    .PARAMETER Proxy
    A URL to an HTTP/HTTPS proxy (e.g. 'http://myproxy:3128') - this is passed directly to Invoke-WebRequest

    .PARAMETER Unattended
    Only installs packages with reboot type 3 as those support 100% silent and unattended, non-interactive installation.
    Use this parameter when running via Invoke-Command, PsExec or deployment solutions.
#>

[CmdletBinding()]
Param (
    [string]$DownloadPath = "$env:TEMP\LenovoDrivers",
    [ValidateSet('Critical', 'Recommended', 'Optional')]
    [string[]]$Filter = @('Critical', 'Recommended', 'Optional'),
    [string]$Proxy,
    [switch]$Unattended = -not [System.Environment]::UserInteractive
)

# StrictMode 2.0 is possible but makes the creation of the LenovoPackage objects a lot uglier with no real benefit
Set-StrictMode -Version 1.0

enum Severity {
    Critical    = 1
    Recommended = 2
    Optional    = 3
}

enum PkgInstallType {
    INF
    CMD
}

class LenovoPackage {
    [string]$ID
    [string]$Title
    [version]$Version
    [string]$Vendor
    [Severity]$Severity
    [int]$RebootType
    [string]$OriginURL
    [PackageExtractInfo]$Extracter
    [PackageInstallInfo]$Installer
    [string[]]$ForDevices
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
    [PkgInstallType]$InstallType
    [int64[]]$SuccessCodes
    [string]$InfFile
    [string]$InstallCommand

    PackageInstallInfo ([System.Xml.XmlElement]$PackageXML) {
        $this.InstallType    = $PackageXML.Install.type
        $this.SuccessCodes   = $PackageXML.Install.rc -split ','
        $this.InfFile        = $PackageXML.Install.INFCmd.INFfile
        $this.InstallCommand = $PackageXML.Install.Cmdline.'#text'
    }
}

function Download-LenovoPackage {
    Param (
        [Parameter( Mandatory = $true )]
        [LenovoPackage]$Package,
        [Parameter( Mandatory = $true )]
        [string]$Destination
    )

    if (-not (Test-Path -Path $Destination -PathType Container)) {
        Write-Verbose "Destination directory did not exist, created it:`r`n$Destination`r`n"
        $null = New-Item -Path $Destination -Force -ItemType Directory
    }

    $PackageDownload = $Package.OriginURL -replace "[^/]*$"
    $PackageDownload = [String]::Concat($PackageDownload, $Package.Extracter.FileName)
    $DownloadPath    = Join-Path -Path $Destination -ChildPath $Package.Extracter.FileName

    if (Test-Path -Path $DownloadPath -PathType Leaf) {
        if ((Get-FileHash -Path $DownloadPath -Algorithm SHA256).Hash -eq $Package.Extracter.FileSHA) {
            Write-Host "This package was already downloaded, skipping redownload.`r`n"
            return;
        }
    }

    try {
        if ($Proxy) {
            Invoke-WebRequest -Uri $PackageDownload -OutFile $DownloadPath -UseBasicParsing -ErrorAction Stop -Proxy $Proxy
        } else {
            Invoke-WebRequest -Uri $PackageDownload -OutFile $DownloadPath -UseBasicParsing -ErrorAction Stop
        }
        Write-Host "Download successful.`r`n"
    }
    catch {
        Write-Error "Could not download the package '$($Package.id)' from '$PackageDownload':"
        Write-Error $_.Exception.Message
        Write-Error ($_.Exception.Response | Format-List * | Out-String)
    }
}

function Expand-LenovoPackage {
    Param (
        [Parameter( Mandatory = $true )]
        [LenovoPackage]$Package,
        [Parameter( Mandatory = $true )]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
        [string]$Destination
    )

    $ExtractCMD  = $Package.Extracter.Command -replace "%PACKAGEPATH%", ('"{0}"' -f $Destination)
    $ExtractARGS = $ExtractCMD -replace "^$($Package.Extracter.FileName)"

    if (Get-ChildItem -Path $Destination -File) {
        Start-Process -FilePath $Package.Extracter.FileName -Verb RunAs -WorkingDirectory $Destination -Wait -ArgumentList $ExtractARGS
    } else {
        Write-Warning "This package was not downloaded or deleted (empty folder), skipping extraction ...`r`n"
    }
}

function Install-LenovoPackage {
    Param (
        [Parameter( Mandatory = $true )]
        [LenovoPackage]$Package,
        [Parameter( Mandatory = $true )]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
        [string]$Path
    )

    if (Get-ChildItem -LiteralPath $Path -File) {
        switch ($Package.Installer.InstallType) {
            'CMD' {
                $InstallCMD = $Package.Installer.InstallCommand -replace "%PACKAGEPATH%", $Path
                # Correct typo from Lenovo ... yes really...
                $InstallCMD = $InstallCMD -replace '-overwirte', '-overwrite'
        
                $installProcess = Start-Process -FilePath cmd.exe -Wait -Verb RunAs -WorkingDirectory $Path -PassThru -ArgumentList '/c', "$InstallCMD"
                if ($installProcess.ExitCode -notin $Package.Installer.SuccessCodes) {
                    Write-Warning "Installation of package '$($Package.id) - $($Package.Title)' FAILED with return code $($installProcess.ExitCode)!`r`n"
                }
            }
            'INF' {
                $installProcess = Start-Process -FilePath pnputil.exe -Wait -Verb RunAs -WorkingDirectory $Path -PassThru -ArgumentList "/add-driver $($Package.Installer.InfFile) /install"
                if ($installProcess.ExitCode -notin $Package.Installer.SuccessCodes -and $installProcess.ExitCode -notin 0, 3010) {
                    Write-Warning "Installation of package '$($Package.id) - $($Package.Title)' FAILED with return code $($installProcess.ExitCode)!`r`n"
                }
            }
            default {
                Write-Warning "Unsupported Package installer method, skipping installation ...`r`n"
            }
        }
    } else {
        Write-Warning "This package was not downloaded or deleted (empty folder), skipping installation ..`r`n."
    }
}

# Check for old Windows versions
$WINDOWSVERSION = Get-WmiObject -Class Win32_OperatingSystem | Select-Object -ExpandProperty Version
if ($WINDOWSVERSION -notmatch "^10\.") {
    throw "This script requires Windows 10."
}

$COMPUTERINFO = Get-CimInstance -ClassName CIM_ComputerSystem | Select-Object Manufacturer, Model

if ($COMPUTERINFO.Manufacturer -ne 'LENOVO') {
    throw "Not a Lenovo computer. Aborting."
}

$MODELNO = [regex]::Match($COMPUTERINFO.Model, '^\w{4}')
if ($MODELNO.Success -ne $true) {
    throw "Could not parse Lenovo Model Number. Full string was: '$($COMPUTERINFO.Model)' - Aborting."
}

Write-Host "Lenovo Model is: $($MODELNO.Value)`r`n"

if ($Proxy) {
    $COMPUTERXML = Invoke-WebRequest -Uri ("https://download.lenovo.com/catalog/{0}_Win10.xml" -f $MODELNO.Value) -UseBasicParsing -Proxy $Proxy -ErrorAction Stop
} else {
    $COMPUTERXML = Invoke-WebRequest -Uri ("https://download.lenovo.com/catalog/{0}_Win10.xml" -f $MODELNO.Value) -UseBasicParsing -ErrorAction Stop
}

$UTF8ByteOrderMark = [System.Text.Encoding]::UTF8.GetString(@(195, 175, 194, 187, 194, 191))

[xml]$PARSEDXML = $COMPUTERXML.Content -replace "^$UTF8ByteOrderMark"

Write-Host "A total of $($PARSEDXML.packages.count) driver packages are available for this computer model:`r`n"

[LenovoPackage[]]$packagesCollection = foreach ($packageURL in $PARSEDXML.packages.package.location) {
    if ($Proxy) {
        $packageXMLOrig = Invoke-WebRequest -Uri $packageURL -UseBasicParsing -ErrorAction Stop -Proxy $Proxy
    } else {
        $packageXMLOrig = Invoke-WebRequest -Uri $packageURL -UseBasicParsing -ErrorAction Stop
    }

    [xml]$packageXML = $packageXMLOrig.Content -replace "^$UTF8ByteOrderMark"

    [LenovoPackage]@{
        'ID'          = $packageXML.Package.id
        'Title'       = $packageXML.Package.Title.Desc.'#text'
        'Version'     = if ([Version]::TryParse($packageXML.Package.version, [ref]$null)) { $packageXML.Package.version } else { '0.0.0.0' }
        'Vendor'      = $packageXML.Package.Vendor
        'Severity'    = $packageXML.Package.Severity.type
        'RebootType'  = $packageXML.Package.Reboot.type
        'OriginURL'   = $packageURL
        'Extracter'   = $packageXML.Package
        'Installer'   = $packageXML.Package
        'ForDevices'  = $packageXML.Package.Dependencies.GetElementsByTagName('_PnPID').'#cdata-section'
    }
}

$packagesCollection | Format-List -Property id, Title, Severity, RebootType

# Filtering out unneeded or unwanted drivers from the comprehensive list of all possibly applicable ones
$packagesCollection = $packagesCollection.Where{ $_.Severity -in $Filter }

if ($Unattended) {
    Write-Host "Skipping the following packages because of Reboot-Types that are incompatible with unattended mode:`r`n"
    $packagesCollection = $packagesCollection.Where{ $_.RebootType -eq 3 }
    $packagesCollection | Format-Table -Property id, Title, RebootType
}

[array]$devices = Get-PnpDevice

Write-Host "$($devices.Count) devices in this computer.`r`n"

$neededDriverPkgs = [System.Collections.Generic.List[LenovoPackage]]::new()
# For every available driver package ...
:NEXTPACKAGE foreach ($package in $packagesCollection) {
    # Go through the Hardware-IDs it's applicable to ...
    foreach ($compatiblePnPDevice in $package.ForDevices) {
        # Go through the Hardware-IDs present in the computer ...
        foreach ($presentPnPDevice in $devices) {
            if ($presentPnPDevice.DeviceID -like "*$compatiblePnPDevice*") {
                # Match found available driver <--> installed hardware
                Write-Host "Found Hardware match on DeviceID: $($compatiblePnPDevice), will be installing '$($package.Title)'`r`n"
                $currentDrvVer  = (Get-PnpDeviceProperty -InputObject $presentPnPDevice -KeyName 'DEVPKEY_Device_DriverVersion').Data
                $currentDrvRank = "0x{0:X8}" -f (Get-PnpDeviceProperty -InputObject $presentPnPDevice -KeyName 'DEVPKEY_Device_DriverRank').Data
                Write-Host "Current driver version is: $currentDrvVer with DriverRank: $currentDrvRank"
                $neededDriverPkgs.Add($package)
                # Skip to the next driver package to avoid multiple matching
                continue NEXTPACKAGE;
            }
        }
    }
}

Write-Host "$($neededDriverPkgs.count) driver packages eligible for installation:"

$neededDriverPkgs | Format-Table id, Title, version, Severity, RebootType | Out-Host

foreach ($driver in $neededDriverPkgs) {
    Write-Host "Downloading $($driver.id) - $($driver.Title) ...`r`n"
    Download-LenovoPackage -Package $driver -Destination (Join-Path -Path $DownloadPath -ChildPath $driver.id)
}

foreach ($driver in $neededDriverPkgs) {
    Write-Host "Extracting $($driver.id) - $($driver.Title) ...`r`n"
    Expand-LenovoPackage -Package $driver -Destination (Join-Path -Path $DownloadPath -ChildPath $driver.id)

    Write-Host "Installing $($driver.id) - $($driver.Title) ...`r`n"
    Install-LenovoPackage -Package $driver -Path (Join-Path -Path $DownloadPath -ChildPath $driver.id)
}

Get-PnpDevice -Status ERROR | Format-Table FriendlyName, DeviceID, Problem, @{'n' = 'ProblemCode'; 'e' = { $_.Problem.value__ }}

Write-Host "`r`nDONE!"