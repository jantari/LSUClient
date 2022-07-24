function Debug-LongRunningProcess {
    [CmdletBinding()]
    Param (
        [Parameter( Mandatory = $true )]
        [System.Diagnostics.Process]$Process
    )

    # Maybe try-catch this in case the Assemblys aren't available?
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes

    Add-Type -Debug:$false -TypeDefinition @'
    using System;
    using System.Text;
    using System.Runtime.InteropServices;

    public class User32 {
        // callback
        public delegate bool EnumThreadDelegate(IntPtr hWnd, IntPtr lParam);

        [DllImport("user32.dll", CharSet = CharSet.Auto, CallingConvention = CallingConvention.StdCall, SetLastError = true)]
        public static extern bool EnumThreadWindows(int dwThreadId, EnumThreadDelegate lpfn, IntPtr lParam);

        [DllImport("user32.dll", SetLastError=true, CharSet = CharSet.Auto, CallingConvention = CallingConvention.StdCall)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool IsWindowVisible(IntPtr hWnd);

        [DllImport("user32.dll", SetLastError=true, CharSet = CharSet.Auto)]
        public static extern UInt32 GetWindowLong(IntPtr hWnd, int nIndex);

        [DllImport("user32.dll", SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

        [StructLayout(LayoutKind.Sequential)]
        public struct RECT
        {
            public int Left;        // x position of upper-left corner
            public int Top;         // y position of upper-left corner
            public int Right;       // x position of lower-right corner
            public int Bottom;      // y position of lower-right corner
        }
    }
'@

    function Get-ChildProcesses {
        [CmdletBinding()]
        Param (
            [Parameter(Mandatory = $true)]
            $ParentProcessId
        )
        Get-CimInstance -ClassName Win32_Process -Filter "ParentProcessId = '$ParentProcessId'" | Foreach-Object {
            $_.ProcessId
            if ($_.ParentProcessId -ne $_.ProcessId) {
                Get-ChildProcesses -ParentProcessId $_.ProcessId
            }
        }
    }

    function Get-WindowInfo {
        [CmdletBinding()]
        Param (
            [IntPtr]$WindowHandle,
            [switch]$IncludeUIAInfo
        )

        [int]$GWL_STYLE = -16
        [Uint32]$WS_DISABLED = 0x08000000
        [Uint32]$WS_VISIBLE  = 0x10000000

        $IsVisible = [User32]::IsWindowVisible($WindowHandle)

        $style = [User32]::GetWindowLong($WindowHandle, $GWL_STYLE)
        [User32+RECT]$RECT = New-Object 'User32+RECT'
        $null = [User32]::GetWindowRect($WindowHandle, [ref]$RECT)

        $InfoHashtable = @{
            'Width'      = $RECT.Right - $RECT.Left
            'Height'     = $RECT.Bottom - $RECT.Top
            'IsVisible'  = $IsVisible
            'IsDisabled' = ($style -band $WS_DISABLED) -eq $WS_DISABLED
            'Style'      = $style
            'UIAWindowTitle' = ''
            'UIAElements'    = @()
        }

        if ($IncludeUIAInfo) {
            $WindowUIA = [System.Windows.Automation.AutomationElement]::FromHandle($WindowHandle)
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
                    }
                }

                if ($UIAElements) {
                    $InfoHashtable['UIAElements'] = @($UIAElements)
                }
            }
        }

        return [PSCustomObject]$InfoHashtable
    }

    [int]$GWL_STYLE = -16
    [Uint32]$WS_DISABLED = 0x08000000
    [Uint32]$WS_VISIBLE  = 0x10000000

    # Look into the process
    [bool]$InteractableWindowOpen    = $false
    [bool]$AllThreadsWaiting         = $true
    [UInt32]$ProcessCount            = 0
    [UInt32]$ThreadCount             = 0
    [UInt32]$WindowCount             = 0
    [System.Text.StringBuilder]$InteractableWindowText = [System.Text.StringBuilder]::new()
    $InteractableWindows = [System.Collections.Generic.List[PSObject]]::new()

    # Get all child processes too
    [array]$ChildProcesses = $Process.ID
    [array]$ChildProcesses += Get-ChildProcesses -ParentProcessId $Process.ID -Verbose:$false

    foreach ($SpawnedProcessID in $ChildProcesses) {
        $ProcessCount++
        $SpawnedProcess = Get-Process -Id $SpawnedProcessID
        Write-Debug "Process $($SpawnedProcess.ID) ('$($SpawnedProcess.ProcessName)')"

        if ($SpawnedProcess.Threads.ThreadState -ne 'Wait') {
            $AllThreadsWaiting = $false
        }

        foreach ($Thread in $SpawnedProcess.Threads) {
            $ThreadCount++

            $ThreadWindows = [System.Collections.Generic.List[IntPtr]]::new()
            $null = [User32]::EnumThreadWindows($thread.id, { Param($hwnd, $lParam) $ThreadWindows.Add($hwnd); return $true }, [System.IntPtr]::Zero)

            if ($ThreadWindows) {
                Write-Debug "  Thread $($thread.id) in state $($thread.ThreadState) ($($thread.WaitReason)) has $($ThreadWindows.Count) windows:"
            } else {
                Write-Debug "  Thread $($thread.id) in state $($thread.ThreadState) ($($thread.WaitReason)) has no windows"
            }
            foreach ($window in $ThreadWindows) {
                $WindowCount++

                $WindowInfo = Get-WindowInfo -WindowHandle $window -IncludeUIAInfo
                if ($WindowInfo.IsVisible -and -not $WindowInfo.IsDisabled -and $WindowInfo.Width -gt 0 -and $WindowInfo.Height -gt 0) {
                    $InteractableWindowOpen = $true
                    $WindowIsInteractable = $true
                    $InteractableWindows.Add([PSCustomObject]@{
                        'WindowTitle' = $WindowInfo.UIAWindowTitle
                        'WindowElements' = $WindowInfo.UIAElements
                    })
                } else {
                    $WindowIsInteractable = $false
                }

                # Print the debug output of the interactable window in capital letters to identify it easily
                Write-Debug "    ThreadWindow ${window}, IsVisible: $($WindowInfo.IsVisible), IsDisabled: $($WindowInfo.IsDisabled), Style: $($WindowInfo.Style), Size: $($WindowInfo.Width) x $($WindowInfo.Height):"
                Write-Debug "      UIA Info: Got $($WindowInfo.UIAElements.Count) UIAElements from this window handle:"
                foreach ($UIAElement in $WindowInfo.UIAElements) {
                    if ($UIAElement.Text) {
                        if ($WindowIsInteractable) {
                            $null = $InteractableWindowText.AppendLine($UIAElement.Text)
                        }
                        Write-Debug "        Type: $($UIAElement.ControlType), Text: $($UIAElement.Text -replace '(?s)^(.{60})(.*)', '$1...')"
                    } else {
                        Write-Debug "        Type: $($UIAElement.ControlType), no Text"
                    }
                }
            }
        }
    }

    return [PSCustomObject]@{
        'ProcessCount'            = $ProcessCount
        'ThreadCount'             = $ThreadCount
        'AllThreadsWaiting'       = $AllThreadsWaiting
        'WindowCount'             = $WindowCount
        'InteractableWindows'     = $InteractableWindows
    }
}
