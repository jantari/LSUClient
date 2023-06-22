function Save-PackageFile {
    <#
        .DESCRIPTION
        Takes a PackageFilePointer object and ensures the file referenced by it is saved
        locally in the path specified by $Directory. If the SourceFile is a HTTP(S) URL it is
        downloaded, if it is a filesystem file it is copied to the destination.

        Saving directories recursively with this function is not supported.

        .PARAMETER SourceFile
        A PackageFilePointer object
    #>
    [CmdletBinding()]
    [OutputType('System.String')]
    Param (
        [Parameter( Mandatory = $true )]
        [PSCustomObject]$SourceFile,
        [Parameter( Mandatory = $true )]
        [string]$Directory,
        [Uri]$Proxy,
        [PSCredential]$ProxyCredential,
        [switch]$ProxyUseDefaultCredentials
    )

    if ($SourceFile.Container -eq $Directory) {
        # SourceFile is already in the destination
        return $SourceFile.AbsoluteLocation
    }

    # Test whether the file was previously downloaded to the destination (e.g. with Save-LSUpdate)
    # This check is important for backwards compatibility with scripts written for LSUClient 1.2.5
    # and earlier where Install-LSUpdate did not have proxy parameters so downloading first with
    # Save-LSUpdate was recommended - Install-LSUpdate then has to work completely "offline" and use those
    # files, or it would throw a connection error in environments where a proxy is required to download.
    [string]$DownloadDest = Join-Path -Path $Directory -ChildPath $SourceFile.Name
    if (Test-Path -LiteralPath $DownloadDest) {
        return $DownloadDest
    }

    if (-not (Test-Path -Path $Directory)) {
        $null = New-Item -Path $Directory -Force -ItemType Directory
    }

    if ($SourceFile.LocationType -eq 'HTTP') {
        # Valid URL - Downloading file via HTTP
        $webClient = New-WebClient -Proxy $Proxy -ProxyCredential $ProxyCredential -ProxyUseDefaultCredentials:$ProxyUseDefaultCredentials

        Write-Verbose "Downloading '$($SourceFile.AbsoluteLocation)' to '${DownloadDest}'"
        $webClient.DownloadFile($SourceFile.AbsoluteLocation, $DownloadDest)

        return $DownloadDest
    } elseif ($SourceFile.LocationType -eq 'FILE') {
        $CopiedItem = Copy-Item -LiteralPath $SourceFile.AbsoluteLocation -Destination $Directory -PassThru
        return $CopiedItem.FullName
    }

    Write-Error "The file $($SourceFile.AbsoluteLocation) could not be accessed or found"
    $null
}
