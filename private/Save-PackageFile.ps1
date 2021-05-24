function Save-PackageFile {
    <#
        .DESCRIPTION
        Returns the full filesystem path to a file.
        If the path to the file is a HTTP/S URL the file is downloaded first.
    #>
    [CmdletBinding()]
    [OutputType('System.String')]
    Param (
        [Parameter( Mandatory = $true, ValueFromPipeline = $true )]
        [string[]]$SourceFile,
        [Parameter( Mandatory = $true )]
        [string]$DestinationDirectory,
        [Uri]$Proxy,
        [pscredential]$ProxyCredential,
        [switch]$ProxyUseDefaultCredentials
    )

    begin {
        if (-not (Test-Path -Path $DestinationDirectory)) {
            $null = New-Item -Path $DestinationDirectory -Force -ItemType Directory
        }
    }

    process {
        foreach ($FileToGet in $SourceFile) {
            [System.Uri]$Uri = $null
            if ([System.Uri]::IsWellFormedUriString($FileToGet, [System.UriKind]::Absolute)) {
                if ([System.Uri]::TryCreate($FileToGet, [System.UriKind]::Absolute, [ref]$Uri)) {
                    if ($Uri.Scheme -in 'http', 'https') {
                        # Valid URL - Downloading file via HTTP
                        $webClient = New-WebClient -Proxy $Proxy -ProxyCredential $ProxyCredential -ProxyUseDefaultCredentials $ProxyUseDefaultCredentials

                        [string]$DownloadDest = Join-Path -Path $DestinationDirectory -ChildPath $Uri.Segments[-1]
                        Write-Verbose "Downloading '${Uri}' to '${DownloadDest}'"
                        $webClient.DownloadFile($Uri, $DownloadDest)

                        $DownloadDest
                        continue
                    }
                }
            }

            $File = Get-Item -LiteralPath $FileToGet -ErrorAction SilentlyContinue
            if ($?) {
                Write-Debug "Found '$($File.Name)' by its absolute path"
                $File.FullName
                continue
            } else {
                [string]$Path = Join-Path -Path $DestinationDirectory -ChildPath $FileToGet
                $File = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
                if ($?) {
                    Write-Debug "Found '$($File.Name)' by its relative path"
                    $File.FullName
                    continue
                }
            }

            Write-Error "The file ${FileToGet} could not be accessed or found"
            $null
        }
    }
}
