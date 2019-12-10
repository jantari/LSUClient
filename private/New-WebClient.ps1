function New-WebClient {
    [OutputType('System.Net.WebClient')]
    Param (
        [Uri]$Proxy,
        [pscredential]$ProxyCredential,
        [switch]$ProxyUseDefaultCredentials
    )

    $webClient = [System.Net.WebClient]::new()

    if ($Proxy) {
        $webProxy = [System.Net.WebProxy]::new($Proxy)
        $webProxy.BypassProxyOnLocal = $false
        if ($ProxyCredential) {
            $webProxy.Credentials = $ProxyCredential.GetNetworkCredential()
        } elseif ($ProxyUseDefaultCredentials) {
            # If both ProxyCredential and ProxyUseDefaultCredentials are passed,
            # UseDefaultCredentials will overwrite the supplied credentials.
            # This behaviour, comment and code are replicated from Invoke-WebRequest
            $webproxy.UseDefaultCredentials = $true
        }
        $webClient.Proxy = $webProxy
    }

    return $webClient
}