function Join-LSUrl {
    <#
        .NOTES
        The noun-prefix in this case was only added because Join-Url
        is a fairly generic function name and it conflicts with some
        other popular modues' exported commands, e.g. PSSharedGoods.
    #>
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
