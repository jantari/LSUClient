function Show-DownloadProgress {
    Param (
        [Parameter( Mandatory=$true )]
        [ValidateNotNullOrEmpty()]
        [array]$Transfers
    )

    [char]$ESC               = 0x1b
    [int]$TotalTransfers     = $Transfers.Count
    [int]$InitialCursorYPos  = $host.UI.RawUI.CursorPosition.Y
    [console]::CursorVisible = $false
    [int]$TransferCountChars = $TotalTransfers.ToString().Length
    [console]::Write("[ {0}   ] Downloading files ...`r[ " -f (' ' * ($TransferCountChars * 2 + 4)))
    while ($Transfers.IsCompleted -contains $false) {
        $i = $Transfers.Where{ $_.IsCompleted }.Count
        [console]::Write("`r[ {0,$TransferCountChars} of $TotalTransfers /" -f $i)
        Start-Sleep -Milliseconds 75
        [console]::Write("`r[ {0,$TransferCountChars} of $TotalTransfers $ESC(0q$ESC(B" -f $i)
        Start-Sleep -Milliseconds 75
        [console]::Write("`r[ {0,$TransferCountChars} of $TotalTransfers \" -f $i)
        Start-Sleep -Milliseconds 65
        [console]::Write("`r[ {0,$TransferCountChars} of $TotalTransfers |" -f $i)
        Start-Sleep -Milliseconds 65
    }
    [console]::SetCursorPosition(1, $InitialCursorYPos)
    if ($Transfers.Status -contains "Faulted" -or $Transfers.Status -contains "Canceled") {
        Write-Host ("$ESC[91m {0} !! {0} $ESC[0m] Downloaded {1} of {2} packages" -f (' ' * ($TransferCountChars + 1)),
            $Transfers.Where{ $_.Status -notin 'Faulted', 'Canceled'}.Count,
            $Transfers.Count)
    } else {
        Write-Host ("$ESC[92m {0} OK {0} $ESC[0m] Downloaded all packages" -f (' ' * ($TransferCountChars + 1)))
    }
    [console]::CursorVisible = $true
}
