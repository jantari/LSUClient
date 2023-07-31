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

$script:LSUClientConfiguration = [LSUClientConfiguration]::new()

[int]$script:XMLTreeDepth = 0

# Public
class LSUClientConfiguration {
    [Uri] $Proxy
    [PSCredential] $ProxyCredential
    [bool] $ProxyUseDefaultCredential
    [TimeSpan] $MaxExternalDetectionRuntime
    [TimeSpan] $MaxExtractRuntime
    [TimeSpan] $MaxInstallerRuntime

    # Default constructor setting default values
    LSUClientConfiguration () {
        $this.MaxExternalDetectionRuntime = [TimeSpan]::FromMinutes(10)
        $this.MaxExtractRuntime = [TimeSpan]::FromMinutes(20)
        $this.MaxInstallerRuntime = [TimeSpan]::Zero # No timeout
    }

    # Clone-constructor from another instance of the class
    LSUClientConfiguration ([LSUClientConfiguration]$from) {
        $this.Proxy = $from.Proxy
        $this.ProxyCredential = $from.ProxyCredential
        $this.ProxyUseDefaultCredential = $from.ProxyUseDefaultCredential
        $this.MaxExternalDetectionRuntime = $from.MaxExternalDetectionRuntime
        $this.MaxExtractRuntime = $from.MaxExtractRuntime
        $this.MaxInstallerRuntime = $from.MaxInstallerRuntime
    }
}

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

# Private
class PackageDependenciesInfo {
    [string] $Version
    [System.Xml.XmlElement] $Dependencies
    [string] $LocalPackageRoot
    [Nullable[bool]] $IsInstalled
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
    hidden [PackageExtractInfo] $Extracter # Unused, kept for backwards compatibility
    [PackageInstallInfo] $Installer
    [Nullable[bool]] $IsApplicable
    [Nullable[bool]] $IsInstalled
}

# Public
# Unused, kept for backwards compatibility with
# scripts in case anyone uses these properties.
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
    [string[]] $FailureCodes # FailureCodes are hex values, so need to be strings
    [int64[]] $CancelCodes
    [string] $InfFile
    [string] $ExtractCommand
    [string] $Command

    PackageInstallInfo ([System.Xml.XmlElement]$PackageXML) {
        $this.InstallType    = $PackageXML.Install.GetAttribute('type')
        $this.SuccessCodes   = $PackageXML.Install.GetAttribute('rc').Split(',').Where({ $_ }) # Avoids issue #87
        $this.FailureCodes   = $PackageXML.Install.GetAttribute('rcfailure').Split(',')
        $this.CancelCodes    = $PackageXML.Install.GetAttribute('rccancel').Split(',').Where({ $_ }) # Avoids issue #87
        $this.InfFile        = $PackageXML.Install.INFCmd.INFfile
        $this.ExtractCommand = $PackageXML.ExtractCommand
        $this.Command        = $PackageXML.Install.Cmdline.'#text'
        <# 
            This PDF contains the definition of Reboot Types 0-4
            - https://download.lenovo.com/pccbbs/mobiles_pdf/tvsu5_mst_en.pdf
            This page introduces Reboot Type 5, delayed reboot
            - https://thinkdeploy.blogspot.com/2019/06/what-are-reboot-delayed-updates.html

            All known Reboot Types
            0 - No reboot
            1 - Forces a reboot
            2 - Reserved
            3 - Requires reboot
            4 - Power off
            5 - Reboot Delayed (Multiple updates can be applied and one reboot can work for all of them)
        #>
        if (($PackageXML.Reboot.type -in 0, 3, 5) -or
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

# Internal
class BiosUpdateInfo : ProcessReturnInformation {
    [int64] $Timestamp
    [string[]] $LogMessage
    [ValidateSet('REBOOT', 'SHUTDOWN')]
    [string] $ActionNeeded
    [Nullable[bool]] $SuccessOverrideValue
}

# Enum internal, but members exposed as strings
# through PackageInstallResult.FailureReason
enum ExternalProcessError {
    NONE = 0 # No error aka Success
    UNKNOWN = 1
    OPERATION_NOT_SUPPORTED
    RUNSPACE_DIED_UNEXPECTEDLY
    CANCELLED_BY_USER
    ACCESS_DENIED
    FILE_NOT_FOUND
    FILE_NOT_EXECUTABLE
    PROCESS_NONE_CREATED
    PROCESS_REQUIRES_ELEVATION
    PROCESS_KILLED_TIMELIMIT
}

# Public
enum PackagePendingAction {
    NONE = 0
    REBOOT_SUGGESTED = 1
    REBOOT_MANDATORY = 2
    # 3 reserved for SHUTDOWN_SUGGESTED even though unlikely
    SHUTDOWN = 4
}

# Internal
class ExternalProcessResult {
    [ExternalProcessError] $Err
    [ProcessReturnInformation] $Info

    ExternalProcessResult (
        [ExternalProcessError] $Err,
        [ProcessReturnInformation] $Info
    ) {
        $this.Err  = $Err
        $this.Info = $Info
    }
}

# Public
class PackageInstallResult {
    [string] $ID
    [string] $Title
    [Nullable[PackageType]] $Type
    [bool] $Success
    [string] $FailureReason
    [PackagePendingAction] $PendingAction
    [Nullable[Int64]] $ExitCode
    [string[]] $StandardOutput
    [string[]] $StandardError
    [string[]] $LogOutput
    [TimeSpan] $Runtime
}

# Internal
class MachineCharacteristics {
    [string]${_OS}
    [Int32]${_WindowsBuildVersion}
    [UInt16]${_CPUAddressWidth}
    [string]${_Bios}
    [Object[]]${_PnPID}
    [string]${_EmbeddedControllerVersion}

    MachineCharacteristics (
        [bool]$IncludePhantomDevices,
        [hashtable]$Overrides
    ) {
        [Version]$WindowsVersion = Get-WindowsVersion
        $SMBiosInformation = Get-CimInstance -ClassName Win32_BIOS -Verbose:$false

        if ($Overrides.ContainsKey('_OS')) {
            $this._OS = $Overrides['_OS']
        } else {
            $this._OS = if ($WindowsVersion -ge [Version]::new(10, 0, 22000, 0)) { '11' } else { '10' }
        }

        if ($Overrides.ContainsKey('_WindowsBuildVersion')) {
            $this._WindowsBuildVersion = $Overrides['_WindowsBuildVersion']
        } else {
            $this._WindowsBuildVersion = $WindowsVersion.Build
        }

        if ($Overrides.ContainsKey('_CPUAddressWidth')) {
            $this._CPUAddressWidth = $Overrides['_CPUAddressWidth']
        } else {
            $this._CPUAddressWidth = [System.Management.ManagementObjectSearcher]::new('SELECT AddressWidth FROM Win32_Processor').Get().AddressWidth
        }

        if ($Overrides.ContainsKey('_Bios')) {
            $this._Bios = $Overrides['_Bios']
        } else {
            $this._Bios = $SMBiosInformation.SMBIOSBIOSVersion
        }

        if ($Overrides.ContainsKey('_PnPID')) {
            $this._PnPID = $Overrides['_PnPID']
        } else {
            $this._PnPID = if ($IncludePhantomDevices) { Get-PnpDevice } else { Get-PnpDevice -PresentOnly }
        }

        if ($Overrides.ContainsKey('_EmbeddedControllerVersion')) {
            $this._EmbeddedControllerVersion = $Overrides['_EmbeddedControllerVersion']
        } else {
            $this._EmbeddedControllerVersion = @($SMBiosInformation.EmbeddedControllerMajorVersion, $SMBiosInformation.EmbeddedControllerMinorVersion) -join '.'
        }
    }
}

if (-not ('LSUClient.ImportTest' -as [Type])) {
    Add-Type -LiteralPath "$PSScriptRoot\LSUClient.Types.cs" -Debug:$false
}

# Import all private functions
foreach ($function in (Get-ChildItem "$PSScriptRoot\private" -File -ErrorAction Ignore)) {
    . $function.FullName
}

# Import all public functions
foreach ($function in (Get-ChildItem "$PSScriptRoot\public" -File -ErrorAction Ignore)) {
    . $function.FullName
}
