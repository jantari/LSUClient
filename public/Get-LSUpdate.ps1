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
        Return all packages, regardless of whether they are applicable to this specific machine or whether they are already installed.
        E.g. this will return LTE-Modem drivers even on machines that do not have the optional LTE-Modem installed, or 32-bit drivers on a 64-bit OS.
        Attempting to install such drivers will likely fail.

        .PARAMETER ScratchDirectory
        The path to a directory where temporary files are downloaded to for use during the search for packages. Defaults to $env:TEMP.

        .PARAMETER CustomRepository
        The path to a custom update package repository. This has to be a filesystem path, local or UNC. A package repository can be created with Save-LSUpdate.

        .PARAMETER NoTestApplicable
        Do not check whether packages are applicable to the computer. The IsApplicable property of the package objects will be set to $null.
        This switch is only available together with -All.

        .PARAMETER NoTestInstalled
        Do not check whether packages are already installed on the computer. The IsInstalled property of the package objects will be set to $null.
        This switch is only available together with -All.

        .PARAMETER FailUnsupportedDependencies
        Lenovo specifies different tests to determine whether each package is applicable to a machine or not.
        This module makes a best effort to parse, understand and check these.
        However, new kinds of tests may be added by Lenovo at any point and some currently in use are not supported yet either.
        By default, any unknown applicability test will be treated as passed which could result in packages that are not actually applicable being detected as applicable.
        This switch will make all applicability tests we can't really check fail instead, which could lead to an applicable package being detected as not applicable instead.

        .PARAMETER PassUnsupportedInstallTests
        Lenovo specifies different tests to determine whether each package is already installed or not.
        This module makes a best effort to parse, understand and check these.
        However, new kinds of tests may be added by Lenovo at any point and some currently in use are not supported yet either.
        By default, any unknown install tests will be treated as failed which could result in a package that is actually installed being detected as missing.
        This switch will make all tests we can't really check pass instead, which could lead to a missing update being detected as installed instead.
    #>

    [CmdletBinding(DefaultParameterSetName = 'HttpRepository')]
    Param (
        [ValidatePattern('^\w{4}$')]
        [string]$Model,
        [Uri]$Proxy,
        [pscredential]$ProxyCredential,
        [switch]$ProxyUseDefaultCredentials,
        [switch]$All,
        [System.IO.DirectoryInfo]$ScratchDirectory = $env:TEMP,
        #[Parameter( ParameterSetName = 'FilesystemRepository' )]
        #[System.IO.DirectoryInfo]$CustomRepository,
        [string]$Repository = 'https://download.lenovo.com/catalog',
        [switch]$NoTestApplicable,
        [switch]$NoTestInstalled,
        [switch]$FailUnsupportedDependencies,
        [switch]$PassUnsupportedInstallTests
    )

    begin {
        if ($PSBoundParameters['Debug'] -and $DebugPreference -eq 'Inquire') {
            Write-Verbose "Adjusting the DebugPreference to 'Continue'."
            $DebugPreference = 'Continue'
        }

        if ($NoTestApplicable -or $NoTestInstalled -and -not $All) {
            throw "You can only use -NoTestApplicable or -NoTestInstalled together with -All"
        }

        if (-not (Test-RunningAsAdmin)) {
            Write-Warning "Unfortunately, this command produces most accurate results when run as an Administrator`r`nbecause some of the commands Lenovo uses to detect your computers hardware have to run as admin :("
        }

        if (-not $Model) {
            $MODELREGEX = [regex]::Match((Get-CimInstance -ClassName CIM_ComputerSystem -ErrorAction SilentlyContinue -Verbose:$false).Model, '^\w{4}')
            if ($MODELREGEX.Success -ne $true) {
                throw "Could not parse computer model number. This may not be a Lenovo computer, or an unsupported model."
            }
            $Model = $MODELREGEX.Value
        }

        Write-Verbose "Lenovo Model is: $Model"

        $RepositoryInfo = Get-PackagePathInfo -Path $Repository
        if (-not $RepositoryInfo.Valid) {
            throw "Repository '${Repository}' could not be accessed or refers to an invalid location"
        }

        $SMBiosInformation = Get-CimInstance -ClassName Win32_BIOS -Verbose:$false
        $script:CachedHardwareTable = @{
            '_OS'                        = 'WIN' + (Get-CimInstance Win32_OperatingSystem).Version -replace "\..*"
            '_CPUAddressWidth'           = [wmisearcher]::new('SELECT AddressWidth FROM Win32_Processor').Get().AddressWidth
            '_Bios'                      = $SMBiosInformation.SMBIOSBIOSVersion
            '_PnPID'                     = @(Get-PnpDevice)
            '_EmbeddedControllerVersion' = @($SMBiosInformation.EmbeddedControllerMajorVersion, $SMBiosInformation.EmbeddedControllerMinorVersion) -join '.'
        }

        # Create a random subdirectory inside ScratchDirectory and use that instead, so we can safely delete it later without taking user data with us
        do {
            $ScratchSubDirectory = Join-Path -Path $ScratchDirectory -ChildPath ( [System.IO.Path]::GetRandomFileName() )
        } until (-not (Test-Path -Path $ScratchSubDirectory))
        # Using the FullName path returned by New-Item ensures we have an absolute path even if the ScratchDirectory passed by the user was relative.
        # This is important because $PWD and System.Environment.CurrentDirectory can differ in PowerShell, so not all path-related APIs/Cmdlets treat relative
        # paths as relative to the same base-directory which would cause errors later, particularly during path resolution in Split-ExecutableAndArguments
        try {
            # throw is needed to really stop and exit the whole script/cmdlet on an error, ErrorAction Stop would only terminate the current pipeline/statement
            $ScratchSubDirectory = New-Item -Path $ScratchSubDirectory -Force -ItemType Directory -ErrorAction Stop | Select-Object -ExpandProperty FullName
        }
        catch {
            throw $_
        }

        Write-Debug "Created temporary scratch directory: $ScratchSubDirectory"

        [array]$PackageXMLs = Get-PackagesInRepository -Repository $Repository -RepositoryType $RepositoryInfo.Type -Model $Model

        Write-Verbose "A total of $($PackageXMLs.Count) driver packages are available for this computer model."
    }

    process {
        foreach ($Package in $PackageXMLs) {
            $Package | Format-List | Out-Host
            if ($Package.LocationType -eq 'FILE') {
                $LocalPackageRoot = $Package.Directory
            } elseif ($Package.LocationType -eq 'HTTP') {
                $LocalPackageRoot = Join-Path -Path $ScratchSubDirectory -ChildPath '__current_package'
            }
            [string]$localFile = Get-PackageFile -SourceFile $Package.XMLFullPath -DestinationDirectory $LocalPackageRoot
            $rawPackageXML = Get-Content -LiteralPath $localFile -Raw

            try {
                [xml]$packageXML = $rawPackageXML -replace "^$UTF8ByteOrderMark"
            }
            catch {
                if ($_.FullyQualifiedErrorId -eq 'InvalidCastToXmlDocument') {
                    Write-Warning "Could not parse package '$($Package.XMLFile)' (invalid XML)"
                } else {
                    Write-Warning "Could not parse package '$($Package.XMLFile)':`r`n$($_.Exception.Message)"
                }
                continue
            }

            if ($Package.LocationType -eq 'HTTP') {
                # Rename package root directory to package id
                $LocalPackageRoot = Rename-Item -LiteralPath $LocalPackageRoot -NewName $packageXML.Package.Id -PassThru | Select-Object -ExpandProperty FullName
            }

            [array]$packageFiles = $packageXML.Package.Files.SelectNodes('descendant-or-self::File') | Foreach-Object {
                [PSCustomObject]@{
                    'Kind' = $_.ParentNode.SchemaInfo.Name
                    'Name' = $_.Name
                    'CRC'  = $_.CRC
                    'Size' = $_.Size
                }
            }

             # Download files needed by external detection tests in package
            foreach ($externalFile in $packageFiles.Where{ $_.Kind -eq 'External'}) {
                $GetFile = $Package.Directory + '/' + $externalFile.Name
                $DownloadedExternalFile = Get-PackageFile -SourceFile $GetFile -DestinationDirectory $LocalPackageRoot
                Write-Verbose "DOWNLOADED EXTERNAL FILE: ${DownloadedExternalFile}"
            }

            # The explicit $null is to avoid powershell/powershell#13651
            [Nullable[bool]]$PackageIsInstalled = if ($NoTestInstalled) {
                $null
            } else {
                if ($packageXML.Package.DetectInstall) {
                    Write-Verbose "Detecting install status of package: $($packageXML.Package.id) ($($packageXML.Package.Title.Desc.'#text'))"
                    Resolve-XMLDependencies -XMLIN $packageXML.Package.DetectInstall -TreatUnsupportedAsPassed:$PassUnsupportedInstallTests -PackagePath $LocalPackageRoot
                } else {
                    Write-Verbose "Package $($packageXML.Package.id) doesn't have a DetectInstall section"
                    0
                }
            }

            # The explicit $null is to avoid powershell/powershell#13651
            [Nullable[bool]]$PackageIsApplicable = if ($NoTestApplicable) {
                $null
            } else {
                Write-Verbose "Parsing dependencies for package: $($packageXML.Package.id) ($($packageXML.Package.Title.Desc.'#text'))"
                Resolve-XMLDependencies -XMLIN $packageXML.Package.Dependencies -TreatUnsupportedAsPassed:(-not $FailUnsupportedDependencies) -PackagePath $LocalPackageRoot
            }

            # Calculate package size
            [Int64]$PackageSize = 0
            $packageFiles | Where-Object { $_.Kind -ne 'External'} | Foreach-Object {
                [Int64]$Number = 0
                $null = [Int64]::TryParse($_.Size, [ref]$Number)
                $PackageSize += $Number
            }

            $packageObject = [LenovoPackage]@{
                'ID'           = $packageXML.Package.id
                'Name'         = $packageXML.Package.name
                'Title'        = $packageXML.Package.Title.Desc.'#text'
                'Category'     = $Package.Category
                'Version'      = if ([Version]::TryParse($packageXML.Package.version, [ref]$null)) { $packageXML.Package.version } else { '0.0.0.0' }
                'Severity'     = $packageXML.Package.Severity.type
                'ReleaseDate'  = [DateTime]::ParseExact($packageXML.Package.ReleaseDate, 'yyyy-MM-dd', [CultureInfo]::InvariantCulture, 'None')
                'RebootType'   = $packageXML.Package.Reboot.type
                'Vendor'       = $packageXML.Package.Vendor
                'Size'         = $PackageSize
                'URL'          = $Package.XMLFullPath
                'Files'        = $packageFiles
                'Extracter'    = $packageXML.Package
                'Installer'    = [PackageInstallInfo]::new($packageXML.Package, $Package.Category)
                'IsApplicable' = $PackageIsApplicable
                'IsInstalled'  = $PackageIsInstalled
            }

            if ($All -or ($packageObject.IsApplicable -and $packageObject.IsInstalled -eq $false)) {
                $packageObject
            }
        }
    }

    end {
        Write-Debug "Removing temporary scratch directory ${ScratchSubDirectory}"
        Remove-Item -LiteralPath $ScratchSubDirectory -Recurse -Force -Confirm:$false
    }
}
