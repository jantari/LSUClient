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

    [CmdletBinding()]
    Param (
        [ValidatePattern('^\w{4}$')]
        [string]$Model,
        [Uri]$Proxy,
        [pscredential]$ProxyCredential,
        [switch]$ProxyUseDefaultCredentials,
        [switch]$All,
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

        $SMBiosInformation = Get-CimInstance -ClassName Win32_BIOS -Verbose:$false
        $script:CachedHardwareTable = @{
            '_OS'                        = 'WIN' + (Get-CimInstance Win32_OperatingSystem).Version -replace "\..*"
            '_CPUAddressWidth'           = [wmisearcher]::new('SELECT AddressWidth FROM Win32_Processor').Get().AddressWidth
            '_Bios'                      = $SMBiosInformation.SMBIOSBIOSVersion
            '_PnPID'                     = @(Get-PnpDevice)
            '_EmbeddedControllerVersion' = @($SMBiosInformation.EmbeddedControllerMajorVersion, $SMBiosInformation.EmbeddedControllerMinorVersion) -join '.'
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
    }

    process {
        foreach ($packageURL in $PARSEDXML.packages.package) {
            # This is in place to prevent packages like 'k2txe01us17' that have invalid XML from stopping the entire function with an error
            try {
                $rawPackageXML   = $webClient.DownloadString($packageURL.location)
                [xml]$packageXML = $rawPackageXML -replace "^$UTF8ByteOrderMark"
            }
            catch {
                if ($_.FullyQualifiedErrorId -eq 'InvalidCastToXmlDocument') {
                    Write-Warning "Could not parse package '$($packageURL.location)' (invalid XML)"
                } else {
                    Write-Warning "Could not retrieve or parse package '$($packageURL.location)':`r`n$($_.Exception.Message)"
                }
                continue
            }

            $DownloadedExternalFiles = [System.Collections.Generic.List[System.IO.FileInfo]]::new()

            # Downloading files needed by external detection tests in package
            if (-not ($NoTestApplicable -and $NoTestInstalled) -and $packageXML.Package.Files.External) {
                # Packages like https://download.lenovo.com/pccbbs/mobiles/r0qch05w_2_.xml show we have to download the XML itself too
                [string]$DownloadDest = Join-Path -Path $env:Temp -ChildPath ($packageURL.location -replace "^.*/")
                $webClient.DownloadFile($packageURL.location, $DownloadDest)
                $DownloadedExternalFiles.Add( [System.IO.FileInfo]::new($DownloadDest) )
                foreach ($externalFile in $packageXML.Package.Files.External.ChildNodes) {
                    [string]$DownloadDest = Join-Path -Path $env:Temp -ChildPath $externalFile.Name
                    [string]$DownloadSrc = ($packageURL.location -replace "[^/]*$") + $externalFile.Name
                    try {
                        $webClient.DownloadFile($DownloadSrc, $DownloadDest)
                    }
                    catch {
                        Write-Error "Download of '$DownloadSrc' failed, dependency resolution for package '$($packageXML.Package.id)' will be impaired:`r`n$($_.Exception)"
                    }
                    $DownloadedExternalFiles.Add( [System.IO.FileInfo]::new($DownloadDest) )
                }
            }

            # The explicit $null is to avoid powershell/powershell#13651
            [Nullable[bool]]$PackageIsInstalled = if ($NoTestInstalled) {
                $null
            } else {
                if ($packageXML.Package.DetectInstall) {
                    Write-Verbose "Detecting install status of package: $($packageXML.Package.id) ($($packageXML.Package.Title.Desc.'#text'))"
                    Resolve-XMLDependencies -XMLIN $packageXML.Package.DetectInstall -TreatUnsupportedAsPassed:$PassUnsupportedInstallTests
                } else {
                    Write-Verbose "Package $($packageURL.location) doesn't have a DetectInstall section"
                    0
                }
            }

            # The explicit $null is to avoid powershell/powershell#13651
            [Nullable[bool]]$PackageIsApplicable = if ($NoTestApplicable) {
                $null
            } else {
                Write-Verbose "Parsing dependencies for package: $($packageXML.Package.id) ($($packageXML.Package.Title.Desc.'#text'))"
                Resolve-XMLDependencies -XMLIN $packageXML.Package.Dependencies -TreatUnsupportedAsPassed:(-not $FailUnsupportedDependencies)
            }

            $packageObject = [LenovoPackage]@{
                'ID'           = $packageXML.Package.id
                'Title'        = $packageXML.Package.Title.Desc.'#text'
                'Category'     = $packageURL.category
                'Version'      = if ([Version]::TryParse($packageXML.Package.version, [ref]$null)) { $packageXML.Package.version } else { '0.0.0.0' }
                'Severity'     = $packageXML.Package.Severity.type
                'ReleaseDate'  = [DateTime]::ParseExact($packageXML.Package.ReleaseDate, 'yyyy-MM-dd', [CultureInfo]::InvariantCulture, 'None')
                'RebootType'   = $packageXML.Package.Reboot.type
                'Vendor'       = $packageXML.Package.Vendor
                'URL'          = $packageURL.location
                'Extracter'    = $packageXML.Package
                'Installer'    = [PackageInstallInfo]::new($packageXML.Package, $packageURL.category)
                'IsApplicable' = $PackageIsApplicable
                'IsInstalled'  = $PackageIsInstalled
            }

            if ($All -or ($packageObject.IsApplicable -and $packageObject.IsInstalled -eq $false)) {
                $packageObject
            }

            foreach ($tempFile in $DownloadedExternalFiles) {
                if ($tempFile.Exists) {
                    $tempFile.Delete()
                }
            }
        }
    }

    end {
        $webClient.Dispose()
    }
}
