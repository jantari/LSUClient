function Expand-LSUpdate {
    Param (
        [Parameter( Position = 0, ValueFromPipeline = $true, Mandatory = $true )]
        [pscustomobject]$Package,
        [Parameter( Mandatory = $true )]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
        [string]$Path
    )

    if (Get-ChildItem -Path $Path -File) {
        if ($Package.Extracter.Command) {
            $extractionProcess = Invoke-PackageCommand -Path $Path -Command $Package.Extracter.Command
            if ($extractionProcess.ExitCode -ne 0) {
                Write-Warning "Extraction of package $($PackageToProcess.ID) may have failed!`r`n"
            }
        } else {
            Write-Verbose "This package does not require extraction."
        }
    } else {
        Write-Warning "This package was not downloaded or deleted (empty folder), skipping extraction ...`r`n"
    }
}