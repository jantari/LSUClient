function Expand-LSUpdate {
    Param (
        [Parameter( Mandatory = $true )]
        [pscustomobject]$Package,
        [Parameter( Mandatory = $true )]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
        [string]$ExtractTo
    )

    if ($Package.Extracter.Command) {
        $Extracter = $PackageToProcess.Files.Where{ $_.Kind -eq 'Installer' }
        $extractionProcess = Invoke-PackageCommand -Path $Extracter.Container -Command $Package.Extracter.Command -PackagePath $ExtractTo
        if (-not $extractionProcess) {
            Write-Warning "Extraction of package $($Package.ID) has failed!`r`n"
        } elseif ($extractionProcess.ExitCode -ne 0) {
            Write-Warning "Extraction of package $($Package.ID) may have failed!`r`n"
        }
    } else {
        Write-Verbose "The package '$($Package.ID)' does not require extraction.`r`n"
    }
}
