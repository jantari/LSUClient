function Get-LSUpdate {
    <#
        .SYNOPSIS
        Fetches available driver packages and updates for Lenovo computers

        .DESCRIPTION
        Fetches available driver packages and updates for Lenovo computers

        .PARAMETER Model
        Specify an alternative Lenovo Computer Model to retrieve update packages for.
        You may want to use this together with '-All' so that packages are not filtered against your local machines configuration.

        .PARAMETER Proxy
        Specifies the URL of a proxy server to use for the connection to the update repository.

        .PARAMETER ProxyCredential
        Specifies a user account that has permission to use the proxy server that is specified by the -Proxy
        parameter.

        .PARAMETER ProxyUseDefaultCredentials
        Indicates that the cmdlet uses the credentials of the current user to access the proxy server that is
        specified by the -Proxy parameter.

        .PARAMETER All
        Return all packages, regardless of whether they are applicable to this specific machine or whether they are already installed.
        E.g. this will return LTE-Modem drivers even on machines that do not have the optional LTE-Modem installed, or 32-bit drivers
        on a 64-bit OS. Attempting to install such inapplicable drivers will likely fail. Re-installing an already installed driver can
        sometimes be useful to fix a driver that got corrupted.

        .PARAMETER IncludePhantomDevices
        Consider currently disconnected (phantom) devices as well when evaluating relevant packages.

        .PARAMETER ScratchDirectory
        The path to a directory where temporary files are downloaded to for use during the search for packages. These files are cleaned
        up automatically. Defaults to $env:TEMP.

        .PARAMETER Repository
        The path to a package repository. This can either be an HTTP(S) URL pointing to a webserver or a filesystem path to a directory.

        .PARAMETER MachineCharacteristicsOverride
        Advanced usage: Pass a Hashtable to override information about the computer that is used to evaluate packages.

        .PARAMETER NoTestApplicable
        Do not check whether packages are applicable to the computer. The IsApplicable property of the package objects will be set to $null.
        This switch is only available together with -All.

        .PARAMETER NoTestInstalled
        Do not check whether packages are already installed on the computer. The IsInstalled property of the package objects will be set to $null.
        This switch is only available together with -All.

        .PARAMETER NoTestSeverityOverride
        Packages have a static severity classification, but may also contain a set of tests pertaining to currently installed hardware or drivers
        that, when passed, dynamically override and adjust the severity rating of a package up or down. By default, this module makes a best effort
        to parse, understand and check these. Use this parameter to skip all SeverityOverride tests instead and have all packages be returned with
        their static, default severity classification. This switch is available both with and without -All.

        .PARAMETER FailUnsupportedDependencies
        Lenovo specifies different tests with each package to determine whether it is applicable to a machine or not.
        This module makes a best effort to parse, understand and check these.
        However, new kinds of tests may be added by Lenovo at any point and some currently in use are not supported yet either.
        By default, any unknown applicability tests will be treated as passed which may result in a package that is really not applicable being classified as applicable.
        This switch will make all unsupported applicability tests fail instead, which in turn could lead to an applicable package being detected as not applicable instead.

        .PARAMETER PassUnsupportedInstallTests
        Lenovo specifies different tests with each package to determine whether it is already installed or not.
        This module makes a best effort to parse, understand and check these.
        However, new kinds of tests may be added by Lenovo at any point and some currently in use are not supported yet either.
        By default, any unknown install tests will be treated as failed which may result in a package that is already installed being classified as missing.
        This switch will make all unsupported install tests pass instead, which in turn could lead to a missing update being detected as installed instead.

        .EXAMPLE
        # Get available updates for the local computer
        PS> Get-LSUpdate 

        .EXAMPLE
        # Get all available packages for a different computer model
        PS> Get-LSUpdate -Model 20K70000GE -All
    #>

    [CmdletBinding()]
    [OutputType('LenovoPackage')]
    Param (
        [string]$Model,
        [Uri]$Proxy = $script:LSUClientConfiguration.Proxy,
        [PSCredential]$ProxyCredential = $script:LSUClientConfiguration.ProxyCredential,
        [switch]$ProxyUseDefaultCredentials = $script:LSUClientConfiguration.ProxyUseDefaultCredentials,
        [switch]$All,
        [switch]$IncludePhantomDevices,
        [System.IO.DirectoryInfo]$ScratchDirectory = $env:TEMP,
        [string]$Repository = 'https://download.lenovo.com/catalog',
        [Hashtable]$MachineCharacteristicsOverride = @{},
        [switch]$NoTestApplicable,
        [switch]$NoTestInstalled,
        [switch]$NoTestSeverityOverride,
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

        if (-not $Model) {
            $Model = (Get-CimInstance -ClassName CIM_ComputerSystem -ErrorAction SilentlyContinue -Verbose:$false).Model
        }

        $Model = $Model.Trim()

        if ($Model.Length -gt 5) {
            $Model = $Model.Substring(0, 4)
        }

        if ($Model -notmatch '^\w{4,5}$') {
            throw "Could not parse computer model number. This may not be a Lenovo computer, or an unsupported model."
        }

        Write-Verbose "Lenovo Model is: $Model"

        if (-not (Test-RunningAsAdmin)) {
            Write-Warning "Unfortunately, this command produces most accurate results when run as an Administrator`r`nbecause some of the commands Lenovo uses to detect your computers hardware have to run as admin :("
        }

        $RepositoryInfo = Get-PackagePathInfo -Path $Repository
        if (-not $RepositoryInfo.Valid) {
            throw "Repository '${Repository}' refers to an invalid location: $($RepositoryInfo.ErrorMessage)"
        }

        $UTF8ByteOrderMark = [System.Text.Encoding]::UTF8.GetString(@(195, 175, 194, 187, 194, 191))

        New-Variable -Name CachedHardwareTable -Option AllScope, ReadOnly -Value (
            $script:CachedHardwareTable = [MachineCharacteristics]::new($IncludePhantomDevices, $MachineCharacteristicsOverride)
        )

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

        Write-Verbose "Created temporary scratch directory: $ScratchSubDirectory"

        [array]$PackagePointers = Get-PackagesInRepository -Repository $Repository -RepositoryType $RepositoryInfo.Type -Model $Model
        if ($PackagePointers.Count -eq 0) {
            throw "No packages for computer model '${Model}' could be retrieved from repository '${Repository}'"
        }

        Write-Verbose "A total of $($PackagePointers.Count) driver packages are available for this computer model."

        # This variable will hold the LenovoPackage objects as they are processed in two stages
        New-Variable -Name PackageList -Option Private -Value ( [System.Collections.Generic.List[LenovoPackage]]::new() )

        # This variable will hold additional metadata that needs to be referenced from nested scopes (functions) during dependency tests
        New-Variable -Name AllPackagesDependenciesInfo -Option AllScope, ReadOnly -Value ( [System.Collections.Generic.Dictionary[string, PackageDependenciesInfo]]::new() )
    }

    process {
        # Stage 1 of 2 : Process most parts of the packages XML, only dependencies will be resolved later to support Coreq (package inter-dependency) tests
        foreach ($Package in $PackagePointers) {
            Write-Verbose "Processing package $($Package.AbsoluteLocation)"

            # Creata a random subdirectory for the packages temporary files
            do {
                $LocalPackageRoot = Join-Path -Path $ScratchSubDirectory -ChildPath ( [System.IO.Path]::GetRandomFileName() )
            } until (-not (Test-Path -Path $LocalPackageRoot))
            # Using the FullName path returned by New-Item ensures we have an absolute path even if the ScratchDirectory passed by the user was relative.
            # This is important because $PWD and System.Environment.CurrentDirectory can differ in PowerShell, so not all path-related APIs/Cmdlets treat relative
            # paths as relative to the same base-directory which would cause errors later, particularly during path resolution in Split-ExecutableAndArguments
            try {
                $LocalPackageRoot = New-Item -Path $LocalPackageRoot -Force -ItemType Directory -ErrorAction Stop | Select-Object -ExpandProperty FullName
            }
            catch {
                Write-Error "Could not create the temporary package directory '$LocalPackageRoot', continuing with the next package."
                continue
            }

            Write-Debug "Local package scratch directory: $LocalPackageRoot"

            # Packages like https://download.lenovo.com/pccbbs/mobiles/r0qch05w_2_.xml show we have to download the XML itself too
            $SpfParams = @{
                'SourceFile' = $Package
                'Directory' = $LocalPackageRoot
                'Proxy' = $Proxy
                'ProxyCredential' = $ProxyCredential
                'ProxyUseDefaultCredentials' = $ProxyUseDefaultCredentials
            }
            [string]$localFile = Save-PackageFile @SpfParams
            $rawPackageXML = Get-Content -LiteralPath $localFile -Raw -ErrorAction Ignore
            if (-not $?) {
                Write-Error "The package $($Package.Name) could not be retrieved or read and will be skipped"
                continue
            }

            try {
                [xml]$packageXML = $rawPackageXML -replace "^$UTF8ByteOrderMark"
            }
            catch {
                if ($_.FullyQualifiedErrorId -eq 'InvalidCastToXmlDocument') {
                    Write-Warning "Could not parse package '$($Package.Name)' (invalid XML)"
                } else {
                    Write-Warning "Could not parse package '$($Package.Name)':`r`n$($_.Exception.Message)"
                }
                continue
            }

            $PackageFiles = [System.Collections.Generic.List[PackageFilePointer]]::new()
            $PackageFiles.Add($Package)
            $packageXML.Package.Files.SelectNodes('descendant-or-self::File') | Foreach-Object {
                $FileInfo = Get-PackagePathInfo -Path $_.Name -BasePath $Package.Container
                if ($FileInfo.Valid) {
                    $PackageFiles.Add(
                        [PackageFilePointer]::new(
                            $_.Name,
                            $FileInfo.AbsoluteLocation,
                            $FileInfo.Type,
                            $_.ParentNode.SchemaInfo.Name,
                            $_.CRC,
                            $_.Size
                        )
                    )
                } else {
                    Write-Error "The file '$($_.Name)' referenced by package $($packageXML.Package.id) could not be found or accessed and will be ignored"
                }
            }

            # Download the files needed by external detection tests in package
            if (-not ($NoTestApplicable -and $NoTestInstalled)) {
                foreach ($externalFile in $PackageFiles.Where{ $_.Kind -eq 'External'}) {
                    $SpfParams = @{
                        'SourceFile' = $externalFile
                        'Directory' = $LocalPackageRoot
                        'Proxy' = $Proxy
                        'ProxyCredential' = $ProxyCredential
                        'ProxyUseDefaultCredentials' = $ProxyUseDefaultCredentials
                    }
                    $null = Save-PackageFile @SpfParams
                }
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

            [Severity]$PackageSeverity = $packageXML.Package.Severity.type
            if (-not $NoTestSeverityOverride -and
                $packageXML.Package.SelectSingleNode('SeverityOverride') -and # SeverityOverride element may not exist
                $packageXML.Package.SelectSingleNode('SeverityOverride').HasChildNodes -and # SeverityOverride element may exist but be empty (#63)
                ($packageXML.Package.SeverityOverride.type -ne $packageXML.Package.Severity.type)) {
                Write-Verbose "Parsing severity override for package: $($packageXML.Package.id) ($($packageXML.Package.Title.Desc.'#text'))"
                if (Resolve-XMLDependencies -XMLIN $packageXML.Package.SeverityOverride -TreatUnsupportedAsPassed:$true -PackagePath $LocalPackageRoot -FailInboxDrivers) {
                    Write-Debug "Default severity $($packageXML.Package.Severity.type) overriden with $($packageXML.Package.SeverityOverride.type)"
                    [Severity]$PackageSeverity = $packageXML.Package.SeverityOverride.type
                }
            }

            # Calculate package size
            [Int64]$PackageSize = 0
            $PackageFiles | Where-Object { $_.Kind -ne 'External'} | Foreach-Object {
                [Int64]$Number = 0
                $null = [Int64]::TryParse($_.Size, [ref]$Number)
                $PackageSize += $Number
            }

            $packageObject = [LenovoPackage]@{
                'ID'           = $packageXML.Package.id
                'Name'         = $packageXML.Package.name
                'Title'        = $packageXML.Package.Title.Desc.'#text'
                'Type'         = $packageXML.Package.PackageType.type
                'Category'     = $Package.Category
                'Version'      = if ([Version]::TryParse($packageXML.Package.version, [ref]$null)) { $packageXML.Package.version } else { '0.0.0.0' }
                'Severity'     = $PackageSeverity
                'ReleaseDate'  = [DateTime]::ParseExact($packageXML.Package.ReleaseDate, 'yyyy-MM-dd', [CultureInfo]::InvariantCulture, 'None')
                'RebootType'   = $packageXML.Package.Reboot.type
                'Status'       = $Package.Status
                'Vendor'       = $packageXML.Package.Vendor
                'Size'         = $PackageSize
                'URL'          = $Package.AbsoluteLocation
                'Files'        = $PackageFiles
                'Extracter'    = $packageXML.Package
                'Installer'    = [PackageInstallInfo]::new($packageXML.Package)
                'IsApplicable' = $null # Package applicability is determined later in stage 2
                'IsInstalled'  = $PackageIsInstalled
            }

            $PackageList.Add($packageObject)

            if ($AllPackagesDependenciesInfo.ContainsKey($packageXML.Package.name)) {
                Write-Debug "Replacing previous package dependency info for $($packageXML.Package.name)"
            }
            $AllPackagesDependenciesInfo[$packageXML.Package.name] = [PackageDependenciesInfo]@{
                'Version'          = $packageXML.Package.version
                'IsInstalled'      = $PackageIsInstalled
                'Dependencies'     = $packageXML.Package.Dependencies
                'LocalPackageRoot' = $LocalPackageRoot
            }
        }
        # Stage 2 of 2 : Process package dependencies (determines IsApplicable)
        foreach ($Package in $PackageList) {
            $CurrentPackageDependenciesInfo = $AllPackagesDependenciesInfo[$Package.Name]

            # The explicit $null is to avoid powershell/powershell#13651
            [Nullable[bool]]$PackageIsApplicable = if ($NoTestApplicable) {
                $null
            } else {
                Write-Verbose "Parsing dependencies for package: $($Package.ID) ($($Package.Title))"
                Resolve-XMLDependencies -XMLIN $CurrentPackageDependenciesInfo.Dependencies -TreatUnsupportedAsPassed:(-not $FailUnsupportedDependencies) -PackagePath $CurrentPackageDependenciesInfo.LocalPackageRoot
            }

            $Package.IsApplicable = $PackageIsApplicable

            if ($All -or ($Package.IsApplicable -and $Package.IsInstalled -eq $false)) {
                $Package
            }
        }
    }

    end {
        Write-Verbose "Cleaning up temporary scratch directory"
        Remove-Item -LiteralPath $ScratchSubDirectory -Recurse -Force -Confirm:$false
    }
}
