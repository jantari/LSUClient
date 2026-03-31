function Test-RunningAsAdmin {
    if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) {
        $Identity = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        return [bool]$Identity.IsInRole( [Security.Principal.WindowsBuiltInRole]::Administrator )
    } else {
        return $false
    }
}
