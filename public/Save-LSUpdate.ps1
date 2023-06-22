function Save-LSUpdate {
    <#
        .SYNOPSIS
        Downloads Lenovo update packages to disk

        .DESCRIPTION
        Downloads Lenovo update packages to disk

        .PARAMETER Package
        The Lenovo package or packages to download

        .PARAMETER Proxy
        Specifies the URL of a proxy server to use for the connection to the update repository.

        .PARAMETER ProxyCredential
        Specifies a user account that has permission to use the proxy server that is specified by the -Proxy
        parameter.

        .PARAMETER ProxyUseDefaultCredentials
        Indicates that the cmdlet uses the credentials of the current user to access the proxy server that is
        specified by the -Proxy parameter.

        .PARAMETER ShowProgress
        Shows a progress animation during the downloading process, recommended for interactive use
        as downloads can be quite large and without any progress output the script may appear stuck

        .PARAMETER Force
        Redownload and overwrite packages even if the files already exist in the target path.

        .PARAMETER Path
        The target directory to download the packages to. In this directory,
        a subfolder will be created for each downloaded package containing its files.
    #>

    [CmdletBinding()]
    Param (
        [Parameter( Position = 0, ValueFromPipeline = $true, Mandatory = $true )]
        [PSCustomOobject]$Package,
        [Uri]$Proxy = $script:LSUClientConfiguration.Proxy,
        [PSCredential]$ProxyCredential = $script:LSUClientConfiguration.ProxyCredential,
        [switch]$ProxyUseDefaultCredentials = $script:LSUClientConfiguration.ProxyUseDefaultCredentials,
        [switch]$ShowProgress,
        [switch]$Force,
        [System.IO.DirectoryInfo]$Path = "$env:TEMP\LSUPackages"
    )

    begin {
        if ($PSBoundParameters['Debug'] -and $DebugPreference -eq 'Inquire') {
            Write-Verbose "Adjusting the DebugPreference to 'Continue'."
            $DebugPreference = 'Continue'
        }
        $transfers = [System.Collections.Generic.List[System.Threading.Tasks.Task]]::new()
    }

    process {
        foreach ($PackageToGet in $Package) {
            Write-Verbose "Processing package '$($PackageToGet.ID) - $($PackageToGet.Title)'"
            $DownloadDirectory = Join-Path -Path $Path -ChildPath $PackageToGet.ID

            if (-not (Test-Path -Path $DownloadDirectory -PathType Container)) {
                Write-Verbose "Destination directory did not exist, created it: '$DownloadDirectory'"
                $null = New-Item -Path $DownloadDirectory -Force -ItemType Directory
            }

            # Ensure all the packages' files are present locally, download if not
            foreach ($File in $PackageToGet.Files) {
                $DownloadSrc  = $File.AbsoluteLocation
                $DownloadDest = Join-Path -Path $DownloadDirectory -ChildPath $File.Name

                Write-Debug "Testing whether PkgFile ${DownloadDest} is already cached, downloading if not"
                if ($Force -or -not (Test-Path -Path $DownloadDest -PathType Leaf) -or (
                   (Get-FileHash -Path $DownloadDest -Algorithm SHA256).Hash -ne $File.Checksum)) {
                    # Checking if this package was already downloaded, if yes skipping redownload
                    $webClient = New-WebClient -Proxy $Proxy -ProxyCredential $ProxyCredential -ProxyUseDefaultCredentials:$ProxyUseDefaultCredentials
                    Write-Verbose "Starting download of '$DownloadSrc'"
                    $transfers.Add( $webClient.DownloadFileTaskAsync($DownloadSrc, $DownloadDest) )
                }
            }
        }
    }

    end {
        if ($ShowProgress -and $transfers) {
            Show-DownloadProgress -Transfers $transfers
        } else {
            $DownloadTimer = [System.Diagnostics.Stopwatch]::StartNew()

            [TimeSpan]$LastPrinted = [TimeSpan]::FromMinutes(9)
            while ($transfers.IsCompleted -contains $false) {
                # Print message once every minute after an initial 10 minutes of silence
                if ($DownloadTimer.Elapsed - $LastPrinted -ge [TimeSpan]::FromMinutes(1)) {
                    [array]$PendingDownloads = @($transfers | Where-Object IsCompleted -eq $false)
                    Write-Warning "Downloads have been running for $($DownloadTimer.Elapsed) - $($PendingDownloads.Count) remaining:"
                    $PendingDownloads.AsyncState | ForEach-Object -MemberName ToString | ForEach-Object { Write-Warning "- $_" }

                    $LastPrinted = $DownloadTimer.Elapsed
                }
                Start-Sleep -Milliseconds 200
            }

            $DownloadTimer.Stop()
        }

        if ($transfers.Status -contains "Faulted" -or $transfers.Status -contains "Canceled") {
            $errorString = "Not all packages could be downloaded, the following errors were encountered:"
            foreach ($transfer in $transfers.Where{ $_.Status -in "Faulted", "Canceled"}) {
                $errorString += "`r`n$($transfer.AsyncState.AbsoluteUri) : $($transfer.Exception.InnerExceptions.Message)"
            }
            Write-Error $errorString
        }

        foreach ($webClient in $transfers) {
            $webClient.Dispose()
        }
    }
}
