function Join-Url {
    Param (
        [Parameter( Mandatory = $true )]
        [string]$BaseUri,
        [string[]]$ChildUri
    )

    if ($ChildUri.Length -eq 0) {
        return $BaseUri
    }

    [string]$NewUri = $BaseUri
    foreach ($Part in $ChildUri) {
        $NewUri = [String]::Format(
            "{0}/{1}",
            $NewUri.TrimEnd('/', '\'),
            $Part.TrimStart('/', '\')
        )
    }

    return $NewUri
}
