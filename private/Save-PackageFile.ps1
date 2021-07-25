function Save-PackageFile {
    <#
        .DESCRIPTION
        Takes a PackageFilePointer object and ensures the file referenced by it is saved
        locally in the path specified by $Directory. If the SourceFile is a HTTP(S) URL it is
        downloaded, if it is a filesystem file it is copied to the destination.

        Saving directories recursively with this function is not supported.
    #>
    [CmdletBinding()]
    [OutputType('System.String')]
    Param (
        [Parameter( Mandatory = $true )]
        [PackageFilePointer]$SourceFile,
        [Parameter( Mandatory = $true )]
        [string]$Directory,
        [Uri]$Proxy,
        [pscredential]$ProxyCredential,
        [switch]$ProxyUseDefaultCredentials
    )

    if ($SourceFile.Container -eq $Directory) {
        # File is already in the destination location
        return $SourceFile.AbsoluteLocation
    }

    if (-not (Test-Path -Path $Directory)) {
        $null = New-Item -Path $Directory -Force -ItemType Directory
    }

    if ($SourceFile.LocationType -eq 'HTTP') {
        # Valid URL - Downloading file via HTTP
        $webClient = New-WebClient -Proxy $Proxy -ProxyCredential $ProxyCredential -ProxyUseDefaultCredentials $ProxyUseDefaultCredentials

        [string]$DownloadDest = Join-Path -Path $Directory -ChildPath $SourceFile.Name
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
