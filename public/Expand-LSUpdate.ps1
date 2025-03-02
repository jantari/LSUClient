function Expand-LSUpdate {
    <#
        .SYNOPSIS
        Extracts package installers.

        .DESCRIPTION
        Extracts package installers.

        .PARAMETER Package
        The Lenovo package or packages whose installer to extract

        .PARAMETER Path
        The directory containing the previously downloaded packages.
        Use `Save-LSUpdate` to download packages.
    #>
    [CmdletBinding()]
    Param (
        [Parameter( Position = 0, ValueFromPipeline = $true, Mandatory = $true )]
        [PSCustomObject]$Package,
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
        [System.IO.DirectoryInfo]$Path = "$env:TEMP\LSUPackages"
    )

    begin {
        if ($PSBoundParameters['Debug'] -and $DebugPreference -eq 'Inquire') {
            Write-Verbose "Adjusting the DebugPreference to 'Continue'."
            $DebugPreference = 'Continue'
        }
    }

    process {
        foreach ($PackageToExtract in $Package) {
            if ($PackageToExtract.Installer.ExtractCommand) {
                Write-Verbose "Extracting package $($PackageToExtract.ID) ..."
                $PackageDirectory = Join-Path -Path $Path -ChildPath $PackageToExtract.ID
                $extractionProcess = Invoke-PackageCommand -Path $PackageDirectory -Command $PackageToExtract.Installer.ExtractCommand -RuntimeLimit $script:LSUClientConfiguration.MaxExtractRuntime
                if ($extractionProcess.Err) {
                    Write-Warning "Extraction of package $($PackageToExtract.ID) has failed!"
                } elseif ($extractionProcess.Info.ExitCode -ne 0) {
                    Write-Warning "Extraction of package $($PackageToExtract.ID) may have failed!"
                }
            } else {
                Write-Verbose "The package '$($PackageToExtract.ID)' does not require extraction."
            }
        }
    }
}
