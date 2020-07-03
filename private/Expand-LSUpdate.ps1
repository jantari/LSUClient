function Expand-LSUpdate {
    Param (
        [Parameter( Mandatory = $true )]
        [pscustomobject]$Package,
        [Parameter( Mandatory = $true )]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
        [string]$Path
    )

    if (Get-ChildItem -Path $Path -File) {
        if ($Package.Extracter.Command) {
            $extractionProcess = Invoke-PackageCommand -Path $Path -Command $Package.Extracter.Command
            if (-not $extractionProcess) {
                Write-Warning "Extraction of package $($Package.ID) has failed!`r`n"
            } elseif ($extractionProcess.ExitCode -ne 0) {
                Write-Warning "Extraction of package $($Package.ID) may have failed!`r`n"
            }
        } else {
            Write-Verbose "The package '$($Package.ID)' does not require extraction.`r`n"
        }
    } else {
        Write-Warning "The package '$($Package.ID)' could not be found, skipping extraction ...`r`n"
    }
}