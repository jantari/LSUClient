function Expand-LSUpdate {
    Param (
        [Parameter( Mandatory = $true )]
        [pscustomobject]$Package,
        [Parameter( Mandatory = $true )]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
        [string]$WorkingDirectory
    )

    if ($Package.Installer.ExtractCommand) {
        $extractionProcess = Invoke-PackageCommand -Path $WorkingDirectory -Command $Package.Installer.ExtractCommand -RuntimeLimit $script:LSUClientConfiguration.MaxExtractRuntime
        if ($extractionProcess.Err) {
            Write-Warning "Extraction of package $($Package.ID) has failed!`r`n"
        } elseif ($extractionProcess.Info.ExitCode -ne 0) {
            Write-Warning "Extraction of package $($Package.ID) may have failed!`r`n"
        }
    } else {
        Write-Verbose "The package '$($Package.ID)' does not require extraction.`r`n"
    }
}
