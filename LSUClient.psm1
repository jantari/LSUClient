#Requires -Version 5.0

Set-StrictMode -Version 1.0

enum Severity {
    Critical    = 1
    Recommended = 2
    Optional    = 3
}

# Source for this information is: https://download.lenovo.com/cdrt/docs/DG-SystemUpdateSuite.pdf page 57
enum PackageType {
    Reserved    = 0
    Application = 1
    Driver      = 2
    BIOS        = 3
    Firmware    = 4
}

enum DependencyParserState {
    DO_HAVE     = 0
    DO_NOT_HAVE = 1
}

# Check for old Windows versions in a manner that is compatible with PowerShell 2.0 all the way up to 7.1
$WindowsVersion = (New-Object -TypeName 'System.Management.ManagementObjectSearcher' -ArgumentList "SELECT Version FROM Win32_OperatingSystem").Get() | Select-Object -ExpandProperty Version
if ($WindowsVersion -notlike "10.*") {
    throw "This module requires Windows 10 or 11."
}

$script:CachedHardwareTable = @{}

[int]$script:XMLTreeDepth = 0

# Internal
class PackageFilePointer {
    [ValidateNotNullOrEmpty()]
    [string] $Name
    [ValidateNotNullOrEmpty()]
    [string] $Container
    [ValidateNotNullOrEmpty()]
    [string] $AbsoluteLocation
    [ValidateNotNullOrEmpty()]
    [string] $LocationType
    [ValidateNotNullOrEmpty()]
    [string] $Kind
    [string] $Checksum
    [Int64] $Size

    # Constructor with file name
    PackageFilePointer (
        [string] $Name,
        [string] $AbsoluteLocation,
        [string] $LocationType,
        [string] $Kind,
        [string] $Checksum,
        [Int64] $Size
    ) {
        $this.AbsoluteLocation = $AbsoluteLocation
        $this.Name = $Name -replace '^.*[\\/]'
        $this.Container = $AbsoluteLocation -replace '[^\\/]*$'
        $this.LocationType = $LocationType
        $this.Kind = $Kind
        $this.Checksum = $Checksum
        $this.Size = $Size
    }

    # Constructor without explicit file name
    PackageFilePointer (
        [string] $AbsoluteLocation,
        [string] $LocationType,
        [string] $Kind,
        [string] $Checksum,
        [Int64] $Size
    ) {
        $this.AbsoluteLocation = $AbsoluteLocation
        $this.Name = $AbsoluteLocation -replace '^.*[\\/]'
        $this.Container = $AbsoluteLocation -replace '[^\\/]*$'
        $this.LocationType = $LocationType
        $this.Kind = $Kind
        $this.Checksum = $Checksum
        $this.Size = $Size
    }
}

# Internal
class PackageXmlPointer : PackageFilePointer {
    [string] $Category

    # Constructor with file name
    PackageXmlPointer (
        [string] $Name,
        [string] $AbsoluteLocation,
        [string] $LocationType,
        [string] $Kind,
        [string] $Checksum,
        [Int64] $Size,
        [string] $Category
    ) : base (
        $Name,
        $AbsoluteLocation,
        $LocationType,
        $Kind,
        $Checksum,
        $Size
    ) {
        $this.Category = $Category
    }

    # Constructor without explicit file name
    PackageXmlPointer (
        [string] $AbsoluteLocation,
        [string] $LocationType,
        [string] $Kind,
        [string] $Checksum,
        [Int64] $Size,
        [string] $Category
    ) : base (
        $AbsoluteLocation,
        $LocationType,
        $Kind,
        $Checksum,
        $Size
    ) {
        $this.Category = $Category
    }
}

# Public
class LenovoPackage {
    [string] $ID
    hidden [string] $Name
    [string] $Title
    [Nullable[PackageType]] $Type
    [string] $Category
    [version] $Version
    [Severity] $Severity
    [DateTime] $ReleaseDate
    [int] $RebootType
    [string] $Vendor
    [Int64] $Size
    [string] $URL
    hidden [System.Collections.Generic.List[PackageFilePointer]] $Files
    [PackageExtractInfo] $Extracter
    [PackageInstallInfo] $Installer
    [Nullable[bool]] $IsApplicable
    [Nullable[bool]] $IsInstalled
}

# Public
class PackageExtractInfo {
    [string] $Command
    [string] $FileName
    [int64] $FileSize
    [string] $FileSHA

    PackageExtractInfo ([System.Xml.XmlElement]$PackageXML) {
        $this.Command  = $PackageXML.ExtractCommand
        $this.FileName = $PackageXML.Files.Installer.File.Name # Unused, kept for backwards compatibility
        $this.FileSize = $PackageXML.Files.Installer.File.Size # Unused, kept for backwards compatibility
        $this.FileSHA  = $PackageXML.Files.Installer.File.CRC  # Unused, kept for backwards compatibility
    }
}

# Public
class PackageInstallInfo {
    [bool] $Unattended
    [ValidateNotNullOrEmpty()]
    [string] $InstallType
    [int64[]] $SuccessCodes
    [string] $InfFile
    [string] $Command

    PackageInstallInfo ([System.Xml.XmlElement]$PackageXML) {
        $this.InstallType    = $PackageXML.Install.type
        $this.SuccessCodes   = $PackageXML.Install.rc -split ','
        $this.InfFile        = $PackageXML.Install.INFCmd.INFfile
        $this.Command        = $PackageXML.Install.Cmdline.'#text'
        if (($PackageXML.Reboot.type -in 0, 3) -or
            ($PackageXML.Install.Cmdline.'#text' -match 'winuptp\.exe|Flash\.cmd') -or
            ($PackageXML.Install.type -eq 'INF'))
        {
            $this.Unattended = $true
        } else {
            $this.Unattended = $false
        }
    }
}

# Internal
class BiosUpdateInfo {
    [ValidateNotNullOrEmpty()]
    [bool] $WasRun
    [int64] $Timestamp
    [ValidateNotNullOrEmpty()]
    [int64] $ExitCode
    [string] $LogMessage
    [ValidateNotNullOrEmpty()]
    [string] $ActionNeeded
}

# Internal
class ProcessReturnInformation {
    [ValidateNotNullOrEmpty()]
    [string] $FilePath
    [string] $Arguments
    [string] $WorkingDirectory
    [string[]] $StandardOutput
    [string[]] $StandardError
    [Int64] $ExitCode
    [TimeSpan] $Runtime
}

# Import all private functions
foreach ($function in (Get-ChildItem "$PSScriptRoot\private" -File -ErrorAction Ignore)) {
    . $function.FullName
}

# Import all public functions
foreach ($function in (Get-ChildItem "$PSScriptRoot\public" -File -ErrorAction Ignore)) {
    . $function.FullName
}
