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

# Check for old Windows versions in a manner that is compatible with PowerShell 2.0 all the way up to 7.1
$WindowsVersion = (New-Object -TypeName 'System.Management.ManagementObjectSearcher' -ArgumentList "SELECT Version FROM Win32_OperatingSystem").Get() | Select-Object -ExpandProperty Version
if ($WindowsVersion -notlike "10.*") {
    throw "This module requires Windows 10."
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
    [string] $Kind
    [string] $Checksum
    [Int64] $Size

    # Constructor from Filename and Container
    # TODO: This currently bugs out when you pass an absolute path to the Name argument
    PackageFilePointer (
        [string] $Name,
        [string] $Container,
        [string] $Kind,
        [string] $Checksum,
        [Int64] $Size
    ) {
        $this.Name = $Name
        $this.Container = $Container
        $this.AbsoluteLocation = (Get-PackagePathInfo -Path $Name -BasePath $Container).AbsoluteLocation
        $this.Kind = $Kind
        $this.Checksum = $Checksum
        $this.Size = $Size
    }

    # Constructor from absolute path
    PackageFilePointer (
        [string] $AbsoluteLocation,
        [string] $Kind,
        [string] $Checksum,
        [Int64] $Size
    ) {
        $this.Name = $AbsoluteLocation -replace '^.*[\\/]'
        $this.Container = $AbsoluteLocation -replace '[^\\/]*$'
        $this.AbsoluteLocation = $AbsoluteLocation
        $this.Kind = $Kind
        $this.Checksum = $Checksum
        $this.Size = $Size
    }
}

# Internal
class PackageXmlPointer : PackageFilePointer {
    [string] $Category
    [ValidateNotNullOrEmpty()]
    [string] $LocationType

    # Constructor from Filename and Container
    # TODO: This currently bugs out when you pass an absolute path to the Name argument
    PackageXmlPointer (
        [string] $Name,
        [string] $Container,
        [string] $Kind,
        [string] $Checksum,
        [Int64] $Size,
        [string] $Category,
        [string] $LocationType
    ) : base (
        $Name,
        $Container,
        $Kind,
        $Checksum,
        $Size
    ) {
        $this.Category = $Category
        $this.LocationType = $LocationType
    }

    # Constructor from absolute path
    PackageXmlPointer (
        [string] $AbsoluteLocation,
        [string] $Kind,
        [string] $Checksum,
        [Int64] $Size,
        [string] $Category,
        [string] $LocationType
    ) : base (
        $AbsoluteLocation,
        $Kind,
        $Checksum,
        $Size
    ) {
        $this.Category = $Category
        $this.LocationType = $LocationType
    }
}

# Public
class LenovoPackage {
    [string] $ID
    hidden [string] $Name
    [string] $Title
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
        $this.FileName = $PackageXML.Files.Installer.File.Name
        $this.FileSize = $PackageXML.Files.Installer.File.Size
        $this.FileSHA  = $PackageXML.Files.Installer.File.CRC
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
