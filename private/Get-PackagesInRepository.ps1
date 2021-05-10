function Get-PackagesInRepository {
    <#

    #>
    [CmdletBinding()]
    Param (
        [Parameter( Mandatory = $true )]
        [string]$Repository,
        [Parameter( Mandatory = $true )]
        [string]$RepositoryType,
        [Parameter( Mandatory = $true )]
        [string]$Model
    )

    $UTF8ByteOrderMark = [System.Text.Encoding]::UTF8.GetString(@(195, 175, 194, 187, 194, 191))

    # Model XML method
    Write-Debug "Finding packages in repository '${Repository}' (Type: ${RepositoryType})"

    if ($RepositoryType -eq 'HTTP') {
        $ModelXmlPath    = Join-Url -BaseUri $Repository -ChildUri "${Model}_Win10.xml"
        $DatabaseXmlPath = Join-Url -BaseUri $Repository -ChildUri "database.xml"
    } elseif ($RepositoryType -eq 'FILE') {
        $ModelXmlPath    = Join-Path -Path $Repository -ChildPath "${Model}_Win10.xml"
        $DatabaseXmlPath = Join-Path -Path $Repository -ChildPath "database.xml"
    }

    if ((Get-PackagePathInfo -Path $ModelXmlPath).Reachable) {
        Write-Debug "Getting packages from the model xml file ${ModelXmlPath}"
        if ($RepositoryType -eq 'HTTP') {
            # Model XML method for web based repositories
            $webClient = New-WebClient -Proxy $Proxy -ProxyCredential $ProxyCredential -ProxyUseDefaultCredentials $ProxyUseDefaultCredentials

            try {
                $COMPUTERXML = $webClient.DownloadString( (Join-Url -BaseUri $Repository -ChildUri "${Model}_Win10.xml") )
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

            foreach ($Package in $PARSEDXML.packages.package) {
                $PathInfo = Get-PackagePathInfo -Path $Package.location -BasePath $Repository
                if ($PathInfo.Reachable) {
                    Write-Debug "Found package: $($PathInfo.AbsoluteLocation)"
                    [PSCustomObject]@{
                        XMLFullPath  = $PathInfo.AbsoluteLocation
                        XMLFile      = $Package.location -replace '^.*[\\/]'
                        Directory    = $PathInfo.AbsoluteLocation -replace '[^\\/]*$'
                        Category     = $Package.category
                        LocationType = $PathInfo.Type
                    }
                } else {
                    Write-Error "The package definition at $($Package.location) could not be found or accessed"
                }
            }
        } elseif ($RepositoryType -eq 'FILE') {
            # Model XML method for file based repositories
            if (Test-Path -Path (Join-Path -Path $Repository -ChildPath "${Model}_Win10.xml") -PathType Leaf) {
                $COMPUTERXML = Get-Content (Join-Path -Path $Repository -ChildPath "${Model}_Win10.xml") -Raw

                # Strings with a BOM cannot be cast to an XmlElement, so we make sure to remove it if present
                [xml]$PARSEDXML = $COMPUTERXML -replace "^$UTF8ByteOrderMark"

                foreach ($Package in $PARSEDXML.packages.package) {
                    $PathInfo = Get-PackagePathInfo -Path $Package.location -BasePath $Repository
                    if ($PathInfo.Reachable) {
                        Write-Debug "Found packag: $($PathInfo.AbsoluteLocation)"
                        [PSCustomObject]@{
                            XMLFullPath  = $PathInfo.AbsoluteLocation
                            XMLFile      = $Package.location -replace '^.*[\\/]'
                            Directory    = $PathInfo.AbsoluteLocation -replace '[^\\/]*$'
                            Category     = $Package.category
                            LocationType = $PathInfo.Type
                        }
                    } else {
                        Write-Error "The package definition at $($Package.location) could not be found or accessed"
                    }
                }
            }
        }
    } elseif ((Get-PackagePathInfo -Path $DatabaseXmlPath).Reachable) {
        # database.xml method
        # NOT IMPLEMENTED
    } else {
        # "Simply searching for subfolders with XMLs inside them"-method
        # This should be a fallback method only - it only works for filesystem
        # repositories and it cannot recover the categories of the packages.
        if ($RepositoryType -eq 'FILE') {
            Get-ChildItem -LiteralPath $Repository -Directory |
                ForEach-Object {
                    Get-ChildItem -LiteralPath $_.FullName -File -Filter "$($_.Name)*.xml"
                } |
                ForEach-Object {
                    Write-Debug "Found package by traversing directories: $($_.Name)"
                    [PSCustomObject]@{
                        XMLFullPath  = $_.FullName
                        XMLFile      = $_.Name
                        Directory    = $_.DirectoryName
                        Category     = ""
                        LocationType = 'FILE'
                    }
                }
        }
    }
}
