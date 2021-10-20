function Get-PackagePathInfo {
    <#
        .DESCRIPTION
        Tests for the validity, existance and type of a location/path.
        Returns whether the path locator is valid, whether it points to a HTTP or
        filesystem resource and can optionally test whether the resource is accessible.

        .PARAMETER Path
        The absolute or relative path to get.

        .PARAMETER BasePath
        In cases where the Path is relative, this BasePath will be used to resolve the absolute location of the resource.

        .PARAMETER TestURLReachable
        In case the input Path is a HTTP(S) URL test connectivity with a HEAD request.
    #>
    [CmdletBinding()]
    Param (
        [Parameter( Mandatory = $true )]
        [string]$Path,
        [string]$BasePath,
        [switch]$TestURLReachable
    )

    $PathInfo = [PSCustomObject]@{
        'Valid'            = $false
        'Reachable'        = $false
        'Type'             = 'Unknown'
        'AbsoluteLocation' = ''
    }

    Write-Debug "Resolving file path '$Path'"

    # Testing for http URL
    [System.Uri]$Uri = $null
    [string]$UriToUse = $null

    # Test the path as an absolute and as a relative URL
    if ([System.Uri]::IsWellFormedUriString($Path, [System.UriKind]::Absolute)) {
        $UriToUse = $Path
    } elseif ($BasePath) {
        # Escape the relative part of the URL as it can contain a filename that is not directly URL-compatible, see issue #39
        $JoinedUrl = $BasePath.TrimEnd('/', '\') + '/' + [System.Uri]::EscapeUriString($Path.TrimStart('/', '\'))
        if ([System.Uri]::IsWellFormedUriString($JoinedUrl, [System.UriKind]::Absolute)) {
            $UriToUse = $JoinedUrl
        }
    }

    if ($UriToUse -and [System.Uri]::TryCreate($UriToUse, [System.UriKind]::Absolute, [ref]$Uri)) {
        if ($Uri.Scheme -in 'http', 'https') {
            $PathInfo.Type = 'HTTP'
            $PathInfo.AbsoluteLocation = $UriToUse
            $PathInfo.Valid = $true

            if ($TestURLReachable) {
                $Request = [System.Net.HttpWebRequest]::CreateHttp($UriToUse)
                $Request.Method = 'HEAD'
                $Request.Timeout = 8000
                $Request.KeepAlive = $false
                $Request.AllowAutoRedirect = $true

                if ((Test-Path -LiteralPath "Variable:\Proxy") -and $Proxy) {
                    $webProxy = [System.Net.WebProxy]::new($Proxy)
                    $webProxy.BypassProxyOnLocal = $false
                    if ((Test-Path -LiteralPath "Variable:\ProxyCredential") -and $ProxyCredential) {
                        $webProxy.Credentials = $ProxyCredential.GetNetworkCredential()
                    } elseif ((Test-Path -LiteralPath "Variable:\ProxyUseDefaultCredentials") -and $ProxyUseDefaultCredentials) {
                        # If both ProxyCredential and ProxyUseDefaultCredentials are passed,
                        # UseDefaultCredentials will overwrite the supplied credentials.
                        # This behaviour, comment and code are replicated from Invoke-WebRequest
                        $webproxy.UseDefaultCredentials = $true
                    }
                    $Request.Proxy = $webProxy
                }

                try {
                    $response = $Request.GetResponse()
                    if ([int]$response.StatusCode -ge 200 -and [int]$response.StatusCode -le 299) {
                        $PathInfo.Reachable = $true
                    }
                    $response.Dispose()
                }
                catch {
                    Write-Debug "Could not connect to URL ${UriToUse}: $_"
                }
            }

            return $PathInfo
        }
    }

    # Test for filesystem path
    if ((Test-Path -LiteralPath $Path) -and
        (Get-Item -LiteralPath $Path).PSProvider.ToString() -eq 'Microsoft.PowerShell.Core\FileSystem') {
            $PathInfo.Valid = $true
            $PathInfo.Reachable = $true
            $PathInfo.Type = 'FILE'
            $PathInfo.AbsoluteLocation = (Get-Item -LiteralPath $Path).FullName
    } else {
        # Try again assuming that $Path is relative to $BasePath
        if (-not $BasePath) { $BasePath = (Get-Location -PSProvider 'Microsoft.PowerShell.Core\FileSystem').Path }
        $JoinedPath = Join-Path -Path $BasePath -ChildPath $Path -ErrorAction Ignore
        if ($JoinedPath -and (Test-Path -LiteralPath $JoinedPath) -and
            (Get-Item -LiteralPath $JoinedPath).PSProvider.ToString() -eq 'Microsoft.PowerShell.Core\FileSystem') {
            $PathInfo.Valid = $true
            $PathInfo.Reachable = $true
            $PathInfo.Type = 'FILE'
            $PathInfo.AbsoluteLocation = (Get-Item -LiteralPath $JoinedPath).FullName
        } else {
            # Writing an error with ErrorAction SilentlyContinue has the purpose of adding it to
            # ErrorVariable (and the global $ERROR) but not returning it via the pipeline
            Write-Error "'$Path' is not a supported URL and does not exist as a filesystem path" -ErrorAction SilentlyContinue
        }
    }

    return $PathInfo
}
