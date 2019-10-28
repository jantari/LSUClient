function Test-RunningAsAdmin {
    $Identity = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    return [bool]$Identity.IsInRole( [Security.Principal.WindowsBuiltInRole]::Administrator )
}