function Save-PackageFile {
    <#
        .DESCRIPTION
        Returns the full filesystem path to a file.
        If the path to the file is a HTTP/S URL the file is downloaded first.
    #>
    [CmdletBinding()]
    [OutputType('System.String')]
    Param (
        [Parameter( Mandatory = $true )]
        [string]$SourceFile,
        [Parameter( Mandatory = $true )]
        [string]$Directory,
        [Uri]$Proxy,
        [pscredential]$ProxyCredential,
        [switch]$ProxyUseDefaultCredentials
    )

    if (-not (Test-Path -Path $Directory)) {
        $null = New-Item -Path $Directory -Force -ItemType Directory
    }

    [System.Uri]$Uri = $null
    if ([System.Uri]::IsWellFormedUriString($SourceFile, [System.UriKind]::Absolute)) {
        if ([System.Uri]::TryCreate($SourceFile, [System.UriKind]::Absolute, [ref]$Uri)) {
            if ($Uri.Scheme -in 'http', 'https') {
                # Valid URL - Downloading file via HTTP
                $webClient = New-WebClient -Proxy $Proxy -ProxyCredential $ProxyCredential -ProxyUseDefaultCredentials $ProxyUseDefaultCredentials

                [string]$DownloadDest = Join-Path -Path $Directory -ChildPath $Uri.Segments[-1]
                Write-Verbose "Downloading '${Uri}' to '${DownloadDest}'"
                $webClient.DownloadFile($Uri, $DownloadDest)

                return $DownloadDest
            }
        }
    }

    $File = Get-Item -LiteralPath $SourceFile -ErrorAction SilentlyContinue
    if ($?) {
        return $File.FullName
    } else {
        [string]$Path = Join-Path -Path $Directory -ChildPath $SourceFile
        if ($?) {
            $File = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
            if ($?) {
                return $File.FullName
            }
        }
    }

    Write-Error "The file ${SourceFile} could not be accessed or found"
    $null
}
