function Expand-LSUpdate {
    <#
        .SYNOPSIS
        Extracts a packages installer.

        .DESCRIPTION
        Extracts a packages installer.

        .PARAMETER Package
        The Lenovo package object to extract

        .PARAMETER Path
        The directory containing the package files to extract.
    #>
    [CmdletBinding()]
    Param (
        [Parameter( Position = 0, ValueFromPipeline = $true, Mandatory = $true )]
        [PSCustomObject]$Package,
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
        [System.IO.DirectoryInfo]$Path = "$env:TEMP\LSUPackages"
    )

    if ($Package.Installer.ExtractCommand) {
        Write-Verbose "Extracting package $($Package.ID) ..."
        $PackageDirectory = Join-Path -Path $Path -ChildPath $Package.ID
        $extractionProcess = Invoke-PackageCommand -Path $PackageDirectory -Command $Package.Installer.ExtractCommand -RuntimeLimit $script:LSUClientConfiguration.MaxExtractRuntime
        if ($extractionProcess.Err) {
            Write-Warning "Extraction of package $($Package.ID) has failed!"
        } elseif ($extractionProcess.Info.ExitCode -ne 0) {
            Write-Warning "Extraction of package $($Package.ID) may have failed!"
        }
    } else {
        Write-Verbose "The package '$($Package.ID)' does not require extraction."
    }
}
