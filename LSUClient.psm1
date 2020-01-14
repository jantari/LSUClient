#Requires -Version 5.0

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

$script:CachedHardwareTable = @{
    '_OS'                        = 'WIN' + (Get-CimInstance Win32_OperatingSystem).Version -replace "\..*"
    '_CPUAddressWidth'           = [wmisearcher]::new('SELECT AddressWidth FROM Win32_Processor').Get().AddressWidth
    '_Bios'                      = (Get-CimInstance -ClassName Win32_BIOS).SMBIOSBIOSVersion
    '_PnPID'                     = @(Get-PnpDevice)
    '_EmbeddedControllerVersion' = [Regex]::Match((Get-CimInstance -ClassName Win32_BIOS).SMBIOSBIOSVersion, "(?<=\()[\d\.]+").Value
}

[int]$script:XMLTreeDepth = 0

class LenovoPackage {
    [string]$ID
    [string]$Title
    [string]$Category
    [version]$Version
    [Severity]$Severity
    [int]$RebootType
    [string]$Vendor
    [Uri]$URL
    [PackageExtractInfo]$Extracter
    [PackageInstallInfo]$Installer
    [bool]$IsApplicable
    [bool]$IsInstalled
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

# Import all private functions
foreach ($function in (Get-ChildItem "$PSScriptRoot\private" -File -ErrorAction Ignore)) {
    . $function.FullName
}

# Import all public functions
foreach ($function in (Get-ChildItem "$PSScriptRoot\public" -File -ErrorAction Ignore)) {
    . $function.FullName
}
