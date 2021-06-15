function Get-PackagePathInfo {
    <#
        .DESCRIPTION
        Tests for the validity, existance and type of a location/path.
        Returns whether the path locator is valid, whether the resource is accessible and whether
        it is http/web based or filesystem based.

        .PARAMETER Path
        The absolute or relative path to get.

        .PARAMETER BasePath
        In cases where the Path is relative, this BasePath will be used to resolve the absolute location of the resource.
    #>
    [CmdletBinding()]
    Param (
        [Parameter( Mandatory = $true )]
        [string]$Path,
        [string]$BasePath
    )

    [string]$Type = 'Unknown'
    [bool]$Valid = $false
    [bool]$Reachable = $false
    [string]$AbsoluteLocation = ''

    Write-Debug "Testing and getting basic information on package path '$Path'"

    # Testing for http URL
    [System.Uri]$Uri = $null
    [string]$UriToUse = $null

    # Test the path as an absolute and as a relative URL
    if ([System.Uri]::IsWellFormedUriString($Path, [System.UriKind]::Absolute)) {
        $UriToUse = $Path
    } elseif ($BasePath) {
        $JoinedUrl = Join-LSUrl -BaseUri $BasePath -ChildUri $Path
        if ([System.Uri]::IsWellFormedUriString($JoinedUrl, [System.UriKind]::Absolute)) {
            $UriToUse = $JoinedUrl
        }
    }

    if ($UriToUse -and [System.Uri]::TryCreate($UriToUse, [System.UriKind]::Absolute, [ref]$Uri)) {
        if ($Uri.Scheme -in 'http', 'https') {
            $Type = 'HTTP'
            $AbsoluteLocation = $UriToUse
            $Valid = $true

            $Request = [System.Net.HttpWebRequest]::CreateHttp($UriToUse)
            $Request.Method = 'HEAD'
            $Request.Timeout = 5000
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
                    $Reachable = $true
                }
                $response.Dispose()
            }
            catch {
                Write-Debug "Could not connect to URL ${UriToUse}: $_"
            }
        }
    }

    # Test for filesystem path
    if ((Test-Path -LiteralPath $Path) -and
        (Get-Item -LiteralPath $Path).PSProvider.ToString() -eq 'Microsoft.PowerShell.Core\FileSystem') {
            $Valid = $true
            $Reachable = $true
            $Type = 'FILE'
            $AbsoluteLocation = (Get-Item -LiteralPath $Path).FullName
    } else {
        # Try again assuming that $Path is relative to $BasePath
        if (-not $BasePath) { $BasePath = (Get-Location -PSProvider 'Microsoft.PowerShell.Core\FileSystem').Path }
        $JoinedPath = Join-Path -Path $BasePath -ChildPath $Path -ErrorAction SilentlyContinue
        if ($JoinedPath -and (Test-Path -LiteralPath $JoinedPath) -and
            (Get-Item -LiteralPath $JoinedPath).PSProvider.ToString() -eq 'Microsoft.PowerShell.Core\FileSystem') {
            $Valid = $true
            $Reachable = $true
            $Type = 'FILE'
            $AbsoluteLocation = (Get-Item -LiteralPath $JoinedPath).FullName
        }
    }

    [PSCustomObject]@{
        'Valid'            = $Valid
        'Reachable'        = $Reachable
        'Type'             = $Type
        'AbsoluteLocation' = $AbsoluteLocation
    }
}
