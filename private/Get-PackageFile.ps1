function Get-PackageFile {
    [CmdletBinding()]
    [OutputType('System.String')]
    Param (
        [Parameter( Mandatory = $true, ValueFromPipeline = $true )]
        [string[]]$SourceFile,
        [Parameter( Mandatory = $true )]
        [string]$DestinationDirectory
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
                $File.FullName
                continue
            } else {
                [string]$Path = Join-Path -Path $DestinationDirectory -ChildPath $FileToGet
                $File = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
                if ($?) {
                    $File.FullName
                    continue
                }
            }

            Write-Error "The file ${FileToGet} could not be accessed or found"
            $null
        }
    }
}
