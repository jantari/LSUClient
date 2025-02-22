function Get-PackagesInRepository {
    <#

    #>
    [CmdletBinding()]
    [OutputType('PackageXmlPointer')]
    Param (
        [Parameter( Mandatory = $true )]
        [string]$Repository,
        [Parameter( Mandatory = $true )]
        [string]$RepositoryType,
        [Parameter( Mandatory = $true )]
        [string]$Model
    )

    $UTF8ByteOrderMark = [System.Text.Encoding]::UTF8.GetString(@(195, 175, 194, 187, 194, 191))

    Write-Verbose "Looking for packages in repository '${Repository}' (Type: ${RepositoryType})"

    if ($RepositoryType -eq 'HTTP') {
        $ModelXmlPath    = $Repository.TrimEnd('/', '\') + "/${Model}_Win$($CachedHardwareTable._OS).xml"
        $DatabaseXmlPath = $Repository.TrimEnd('/', '\') + '/database.xml'
    } elseif ($RepositoryType -eq 'FILE') {
        $ModelXmlPath    = Join-Path -Path $Repository -ChildPath "${Model}_Win$($CachedHardwareTable._OS).xml"
        $DatabaseXmlPath = Join-Path -Path $Repository -ChildPath "database.xml"
    }

    # Used as pipeline OutVariables
    $ModelXmlPathInfo    = $null
    $DatabaseXmlPathInfo = $null

    if ((Get-PackagePathInfo -Path $ModelXmlPath -TestURLReachable -OutVariable ModelXmlPathInfo).Reachable) {
        Write-Verbose "Getting packages from the model xml file ${ModelXmlPath}"
        if ($RepositoryType -eq 'HTTP') {
            # Model XML method for web based repositories
            $webClient = New-WebClient -Proxy $Proxy -ProxyCredential $ProxyCredential -ProxyUseDefaultCredentials:$ProxyUseDefaultCredentials

            try {
                $COMPUTERXML = $webClient.DownloadString($ModelXmlPath)
            }
            catch {
                if ($_.Exception.innerException.Response.StatusCode -eq [System.Net.HttpStatusCode]::NotFound) {
                    throw "No information was found on this model of computer (invalid model number or not supported by Lenovo?)"
                } else {
                    throw "An error occured when contacting ${Repository}:`r`n$($_.Exception.Message)"
                }
            }

            # Downloading with Net.WebClient seems to remove the BOM automatically, this only seems to be neccessary when downloading with IWR. Still I'm leaving it in to be safe
            [xml]$PARSEDXML = $COMPUTERXML -replace "^$UTF8ByteOrderMark"
        } elseif ($RepositoryType -eq 'FILE') {
            # Model XML method for file based repositories
            $COMPUTERXML = Get-Content -LiteralPath $ModelXmlPath -Raw

            # Strings with a BOM cannot be cast to an XmlElement, so we make sure to remove it if present
            [xml]$PARSEDXML = $COMPUTERXML -replace "^$UTF8ByteOrderMark"
        }

        foreach ($Package in $PARSEDXML.packages.package) {
            $PathInfo = Get-PackagePathInfo -Path $Package.location -BasePath $Repository
            if ($PathInfo.Valid) {
                [PackageXmlPointer]::new(
                    $PathInfo.AbsoluteLocation,
                    $PathInfo.Type,
                    'XmlDefinition',
                    $Package.checksum.'#text',
                    0,
                    $Package.category,
                    'Active' # Model-XML files do not store a status for packages, so I've decided to default them all to 'Active' for usability
                )
            } else {
                Write-Error "The package definition at $($Package.location) could not be found or accessed"
            }
        }
    } elseif ((Get-PackagePathInfo -Path $DatabaseXmlPath -TestURLReachable -OutVariable DatabaseXmlPathInfo).Reachable) {
        Write-Debug "Getting packages from the database xml file ${DatabaseXmlPath}"
        if ($RepositoryType -eq 'HTTP') {
            $webClient = New-WebClient -Proxy $Proxy -ProxyCredential $ProxyCredential -ProxyUseDefaultCredentials:$ProxyUseDefaultCredentials

            try {
                $XmlString = $webClient.DownloadString($DatabaseXmlPath)
            }
            catch {
                if ($_.Exception.innerException.Response.StatusCode -eq [System.Net.HttpStatusCode]::NotFound) {
                    throw "No information was found on this model of computer (invalid model number or not supported by Lenovo?)"
                } else {
                    throw "An error occured when contacting ${Repository}:`r`n$($_.Exception.Message)"
                }
            }

            # Downloading with Net.WebClient seems to remove the BOM automatically, this only seems to be neccessary when downloading with IWR. Still I'm leaving it in to be safe
            [xml]$PARSEDXML = $XmlString -replace "^$UTF8ByteOrderMark"
        } elseif ($RepositoryType -eq 'FILE') {
            $XmlString = Get-Content -LiteralPath $DatabaseXmlPath -Raw

            # Strings with a BOM cannot be cast to an XmlElement, so we make sure to remove it if present
            [xml]$PARSEDXML = $XmlString -replace "^$UTF8ByteOrderMark"
        }

        :NextPackage foreach ($Package in $PARSEDXML.Database.package) {
            foreach ($CompatibleSystem in $Package.SystemCompatibility.System) {
                if ($CompatibleSystem.mtm -eq $Model -and $CompatibleSystem.os -eq "Windows $($CachedHardwareTable._OS)") {
                    # Updates in a database.xml repository have a 'Status' that can be set to 'Active', 'Hidden' and a few others.
                    # Get-LSUpdate should not show updates that have been hidden, so we skip them. See issue #113.
                    if ($Package.Status -ne 'Hidden') {
                        $PathInfo = Get-PackagePathInfo -Path $Package.LocalPath -BasePath $Repository
                        if ($PathInfo.Valid) {
                            [PackageXmlPointer]::new(
                                $PathInfo.AbsoluteLocation,
                                $PathInfo.Type,
                                'XmlDefinition',
                                $Package.checksum.'#text',
                                0,
                                $Package.category,
                                $Package.Status
                            )
                        } else {
                            Write-Error "The package definition at $($Package.LocalPath) could not be found or accessed"
                        }
                    } else {
                        Write-Verbose "Discovered package $($Package.LocalPath) is hidden and will be ignored"
                    }
                    continue NextPackage
                }
            }
            Write-Debug "Discovered package $($Package.LocalPath) is not applicable to the computer model and OS"
        }
    } else {
        Write-Warning "The repository '${Repository}' did not contain either a '${Model}_Win$($CachedHardwareTable._OS).xml' or 'database.xml' file to get packages from"
        Write-Warning "Could not get ${Model}_Win$($CachedHardwareTable._OS).xml: $($ModelXmlPathInfo.ErrorMessage)"
        Write-Warning "Could not get database.xml: $($DatabaseXmlPathInfo.ErrorMessage)"
    }
}
