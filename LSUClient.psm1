﻿#Requires -Version 5.0

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
    [Nullable[bool]]$IsApplicable
    [Nullable[bool]]$IsInstalled
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

class ProcessReturnInformation {
    [ValidateNotNullOrEmpty()]
    [string] $FilePath
    [string] $Arguments
    [string[]] $StandardOutput
    [string[]] $StandardError
    [Nullable[int64]] $ExitCode
    [TimeSpan] $RunTime
    hidden [bool] $ProcessStarted
}

# Import all private functions
foreach ($function in (Get-ChildItem "$PSScriptRoot\private" -File -ErrorAction Ignore)) {
    . $function.FullName
}

# Import all public functions
foreach ($function in (Get-ChildItem "$PSScriptRoot\public" -File -ErrorAction Ignore)) {
    . $function.FullName
}
