﻿function Debug-LongRunningProcess {
    [CmdletBinding()]
    Param (
        [Parameter( Mandatory = $true )]
        [System.Diagnostics.Process]$Process
    )

    # Maybe try-catch this in case the Assemblys aren't available?
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes

    function Get-WindowInfo {
        [CmdletBinding()]
        Param (
            [IntPtr]$WindowHandle,
            [switch]$IncludeUIAInfo
        )

        [int]$GWL_STYLE = -16
        [Uint32]$WS_DISABLED = 0x08000000

        $IsVisible = [LSUClient.User32]::IsWindowVisible($WindowHandle)

        $style = [LSUClient.User32]::GetWindowLong($WindowHandle, $GWL_STYLE)
        [LSUClient.User32+RECT]$RECT = New-Object 'LSUClient.User32+RECT'
        $null = [LSUClient.User32]::GetWindowRect($WindowHandle, [ref]$RECT)

        $InfoHashtable = @{
            'Width'      = $RECT.Right - $RECT.Left
            'Height'     = $RECT.Bottom - $RECT.Top
            'IsVisible'  = $IsVisible
            'IsDisabled' = ($style -band $WS_DISABLED) -eq $WS_DISABLED
            'StyleHex'   = '0x{0:X8}' -f $style
            'UIAWindowTitle' = ''
            'UIAElements'    = @()
        }

        if ($IncludeUIAInfo) {
            $WindowUIA = $null
            try {
                # If a window(handle) doesn't exist anymore this throws an ElementNotAvailable exception
                $WindowUIA = [System.Windows.Automation.AutomationElement]::FromHandle($WindowHandle)
            }
            catch {}
            if ($WindowUIA) {
                # Get element text by implementing https://stackoverflow.com/a/23851560
                $patternObj = $null
                if ($WindowUIA.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref] $patternObj)) {
                    $ElementText = $patternObj.Current.Value
                } elseif ($WindowUIA.TryGetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern, [ref] $patternObj)) {
                    $ElementText = $patternObj.DocumentRange.GetText(-1).TrimEnd("`r") # often there is an extra CR hanging off the end
                } else {
                    $ElementText = $WindowUIA.Current.Name
                }

                if ([string]::IsNullOrWhiteSpace($ElementText)) {
                    # If the ElementText is entirely blank (e.g. empty terminal window)
                    # then discard the whitespace and just set it to an empty string
                    $ElementText = ''
                } else {
                    # If there is non-whitespace content in the ElementText,
                    # only trim whitespace from the end of every line
                    [string[]]$ElementText = $ElementText.Split(
                        [string[]]("`r`n", "`r", "`n"),
                        [StringSplitOptions]::None
                    ) | ForEach-Object -MemberName TrimEnd
                }

                $InfoHashtable['UIAWindowTitle'] = $ElementText -join "`r`n"

                $UIADescendants = $WindowUIA.FindAll([Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
                $UIAElements = foreach ($UIAE in @($UIADescendants)) {
                    # Get element text by implementing https://stackoverflow.com/a/23851560
                    $patternObj = $null
                    if ($UIAE.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref] $patternObj)) {
                        $ElementText = $patternObj.Current.Value
                    } elseif ($UIAE.TryGetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern, [ref] $patternObj)) {
                        $ElementText = $patternObj.DocumentRange.GetText(-1).TrimEnd("`r") # often there is an extra CR hanging off the end
                    } else {
                        $ElementText = $UIAE.Current.Name
                    }

                    if ([string]::IsNullOrWhiteSpace($ElementText)) {
                        # If the ElementText is entirely blank (e.g. empty terminal window)
                        # then discard the whitespace and just set it to an empty string
                        $ElementText = ''
                    } else {
                        # If there is non-whitespace content in the ElementText,
                        # only trim whitespace from the end of every line
                        [string[]]$ElementText = $ElementText.Split(
                            [string[]]("`r`n", "`r", "`n"),
                            [StringSplitOptions]::None
                        ) | ForEach-Object -MemberName TrimEnd
                    }

                    [PSCustomObject]@{
                        'ControlType' = $UIAE.Current.ControlType.ProgrammaticName
                        'Text' = $ElementText -join "`r`n"
                        'XPosition' = $UIAE.Current.BoundingRectangle.X
                        'YPosition' = $UIAE.Current.BoundingRectangle.Y
                    }
                }

                if ($UIAElements) {
                    $InfoHashtable['UIAElements'] = @($UIAElements | Sort-Object -Property YPosition, XPosition)
                }
            }
        }

        return [PSCustomObject]$InfoHashtable
    }

    # Look into the process
    [bool]$AllThreadsWaiting = $true
    [UInt32]$WindowCount     = 0
    $InteractableWindows     = [System.Collections.Generic.List[PSObject]]::new()
    $CimProcessInformation   = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $($Process.ID)" -Property ParentProcessId, CommandLine -Verbose:$false

    Write-Debug "Process $($Process.ID) ('$($Process.ProcessName)'):"
    Write-Debug "  Session: $($Process.SessionId)"
    if ($CimProcessInformation.CommandLine) {
        Write-Debug "  CommandLine: $($CimProcessInformation.CommandLine)"
    } else {
        Write-Debug "  CommandLine: <BLANK / INACCESSIBLE>"
    }
    Write-Debug "  StartTime: $($Process.StartTime.TimeOfDay)"
    if ($CimProcessInformation.ParentProcessId) {
        Write-Debug "  Parent Id: $($CimProcessInformation.ParentProcessId)"
    } else {
        Write-Debug "  Parent Id: <BLANK / INACCESSIBLE>"
    }

    if ($Process.Threads.ThreadState -ne 'Wait') {
        $AllThreadsWaiting = $false
    }

    foreach ($Thread in $Process.Threads) {
        $ThreadWindows = [System.Collections.Generic.List[IntPtr]]::new()
        $null = [LSUClient.User32]::EnumThreadWindows($thread.id, { Param($hwnd, $lParam) $ThreadWindows.Add($hwnd); return $true }, [System.IntPtr]::Zero)

        if ($ThreadWindows) {
            Write-Debug "  Thread $($thread.id) in state $($thread.ThreadState) ($($thread.WaitReason)) has $($ThreadWindows.Count) windows:"
        } else {
            Write-Debug "  Thread $($thread.id) in state $($thread.ThreadState) ($($thread.WaitReason)) has no windows"
        }
        foreach ($window in $ThreadWindows) {
            $WindowCount++

            $WindowInfo = Get-WindowInfo -WindowHandle $window -IncludeUIAInfo
            if ($WindowInfo.IsVisible -and -not $WindowInfo.IsDisabled -and $WindowInfo.Width -gt 0 -and $WindowInfo.Height -gt 0) {
                $InteractableWindows.Add([PSCustomObject]@{
                    'WindowTitle'    = $WindowInfo.UIAWindowTitle
                    'WindowElements' = $WindowInfo.UIAElements
                    'WindowText'     = if ($WindowInfo.UIAElements) { $WindowInfo.UIAElements.Text }
                })
            }

            # Even if a window is not interactable (not visible and/or disabled) it is worth logging in debug mode,
            # because for example windows in session 0 will never be visible or interactable but can still open and cause a hang
            Write-Debug "    ThreadWindow ${window}, Title: $($WindowInfo.UIAWindowTitle)"
            Write-Debug "      IsVisible: $($WindowInfo.IsVisible), IsDisabled: $($WindowInfo.IsDisabled), Style: $($WindowInfo.StyleHex), Size: $($WindowInfo.Width) x $($WindowInfo.Height):"
            Write-Debug "      UIA Info: Got $($WindowInfo.UIAElements.Count) UIAElements from this window handle:"
            foreach ($UIAElement in $WindowInfo.UIAElements) {
                if ($UIAElement.Text) {
                    Write-Debug "        Type: $($UIAElement.ControlType), Text: $($UIAElement.Text -replace '(?s)^(.{60})(.*)', '$1...')"
                } else {
                    Write-Debug "        Type: $($UIAElement.ControlType), no Text"
                }
            }
        }
    }

    return [PSCustomObject]@{
        'ProcessName'         = $Process.ProcessName
        'AllThreadsWaiting'   = $AllThreadsWaiting
        'WindowCount'         = $WindowCount
        'InteractableWindows' = $InteractableWindows
    }
}
