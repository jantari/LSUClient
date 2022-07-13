function Debug-LongRunningProcess {
    [CmdletBinding()]
    Param (
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
        [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
        public static extern int GetWindowTextLength(IntPtr hWnd);

        [DllImport("user32.dll", CharSet = CharSet.Auto)]
        public static extern IntPtr SendMessage(IntPtr hWnd, UInt32 Msg, int wParam, StringBuilder lParam);

        // callbacks
        public delegate bool EnumThreadDelegate(IntPtr hWnd, IntPtr lParam);
        public delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr lParam);

        [DllImport("user32.dll", CharSet = CharSet.Auto, CallingConvention = CallingConvention.StdCall, SetLastError = true)]
        public static extern bool EnumThreadWindows(int dwThreadId, EnumThreadDelegate lpfn, IntPtr lParam);

        [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool EnumChildWindows(IntPtr window, EnumWindowsProc callback, IntPtr i);

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

    function Get-ChildWindows {
        [CmdletBinding()]
        Param (
            [IntPtr]$Parent
        )

        $ChildWindows = [System.Collections.Generic.List[IntPtr]]::new()
        $ECW_RETURN = [User32]::EnumChildWindows($Parent, { Param([IntPtr]$handle, $lParam) $ChildWindows.Add($handle); $true }, [IntPtr]::Zero)
        #Write-Debug "[ECW: $ECW_RETURN]: window $Parent has $($ChildWindows.Count) child windows total"

        return $ChildWindows
    }

    function Get-WindowInfo {
        [CmdletBinding()]
        Param (
            [IntPtr]$WindowHandle,
            [switch]$IncludeUIAInfo
        )

        [int]$WM_GETTEXT = 0xD
        [int]$GWL_STYLE = -16
        [Uint32]$WS_DISABLED = 0x08000000
        [Uint32]$WS_VISIBLE  = 0x10000000

        $WindowTextLen = [User32]::GetWindowTextLength($WindowHandle) + 1

        [System.Text.StringBuilder]$sb = [System.Text.StringBuilder]::new($WindowTextLen)
        $null = [User32]::SendMessage($WindowHandle, $WM_GETTEXT, $WindowTextLen, $sb)
        $windowTitle = $sb.Tostring()

        $IsVisible = [User32]::IsWindowVisible($WindowHandle)

        $style = [User32]::GetWindowLong($WindowHandle, $GWL_STYLE)
        [User32+RECT]$RECT = New-Object 'User32+RECT'
        $null = [User32]::GetWindowRect($WindowHandle, [ref]$RECT)

        $InfoHashtable = @{
            'Title'      = $windowTitle
            'Width'      = $RECT.Right - $RECT.Left
            'Height'     = $RECT.Bottom - $RECT.Top
            'IsVisible'  = $IsVisible
            'IsDisabled' = ($style -band $WS_DISABLED) -eq $WS_DISABLED
            'Style'      = $style
            'UIAElements' = @()
        }

        if ($IncludeUIAInfo) {
            #$root = [Windows.Automation.AutomationElement]::RootElement
            #$condition = New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::NativeWindowHandleProperty, $WindowHandle.ToInt32())
            #$mainwindowUIA = $root.FindFirst([Windows.Automation.TreeScope]::Children, $condition)
            $mainwindowUIA = [System.Windows.Automation.AutomationElement]::FromHandle($WindowHandle)
            if ($mainwindowUIA) {
                $UIAElements = $mainwindowUIA.FindAll([Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)

                $UIAElementsCustom = foreach ($UIAE in @($mainwindowUIA) + @($UIAElements)) {
                    # Get element text by implementing https://stackoverflow.com/a/23851560
                    $patternObj = $null
                    if ($UIAE.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref] $patternObj)) {
                        $ElementText = $patternObj.Current.Value
                    } elseif ($UIAE.TryGetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern, [ref] $patternObj)) {
                        $ElementText = $patternObj.DocumentRange.GetText(-1).TrimEnd("`r") # often there is an extra CR hanging off the end
                    } else {
                        $ElementText = $UIAE.Current.Name
                    }

                    $UIAE.Current |
                        Select-Object @{n = 'ControlType'; e = { $_.ControlType.ProgrammaticName }}, ClassName, HasKeyboardFocus,
                            IsKeyboardFocusable, IsContentElement, Name, @{'n' = 'Text'; 'e' = { $ElementText }}
                }

                if ($UIAElements) {
                    $InfoHashtable['UIAElements'] = @($UIAElementsCustom)
                }
            }
        }

        return [PSCustomObject]$InfoHashtable
    }

    [int]$WM_GETTEXT = 0xD
    [int]$GWL_STYLE = -16
    [Uint32]$WS_DISABLED = 0x08000000
    [Uint32]$WS_VISIBLE  = 0x10000000

    # Look into the process
    [bool]$InteractableWindowOpen = $false
    [bool]$AllThreadsWaiting      = $true

    # Get all child processes too
    [array]$ChildProcesses = $Process.ID
    [array]$ChildProcesses += Get-ChildProcesses -ParentProcessId $Process.ID -Verbose:$false

    foreach ($SpawnedProcessID in $ChildProcesses) {
        $SpawnedProcess = Get-Process -Id $SpawnedProcessID
        Write-Debug "Process $($SpawnedProcess.ID) ('$($SpawnedProcess.ProcessName)')"

        if ($SpawnedProcess.Threads.ThreadState -ne 'Wait') {
            $AllThreadsWaiting = $false
        }

        foreach ($Thread in $SpawnedProcess.Threads) {
            $ThreadWindows = [System.Collections.Generic.List[IntPtr]]::new()
            $null = [User32]::EnumThreadWindows($thread.id, { Param($hwnd, $lParam) $ThreadWindows.Add($hwnd); return $true }, [System.IntPtr]::Zero)

            if ($ThreadWindows) {
                Write-Debug "  Thread $($thread.id) in state $($thread.ThreadState) ($($thread.WaitReason)) has $($ThreadWindows.Count) windows:"
            } else {
                Write-Debug "  Thread $($thread.id) in state $($thread.ThreadState) ($($thread.WaitReason)) has no windows"
            }
            foreach ($window in $ThreadWindows) {
                $WindowInfo = Get-WindowInfo -WindowHandle $window -IncludeUIAInfo
                if ($WindowInfo.IsVisible -and -not $WindowInfo.IsDisabled -and $WindowInfo.Width -gt 0 -and $WindowInfo.Height -gt 0) {
                    $InteractableWindowOpen = $true
                }

                # Print the debug output of the interactable window in capital letters to identify it easily
                Write-Debug "    ThreadWindow ${window}, IsVisible: $($WindowInfo.IsVisible), IsDisabled: $($WindowInfo.IsDisabled), Style: $($WindowInfo.Style), Size: $($WindowInfo.Width) x $($WindowInfo.Height), TitleCaption '$($WindowInfo.Title)'"
                Write-Debug "      UIA Info: Got $($WindowInfo.UIAElements.Count) UIAElements from this window handle:"
                foreach ($UIAElement in $WindowInfo.UIAElements) {
                    if ($UIAElement.Text) {
                        Write-Debug "        Type: $($UIAElement.ControlType), Text: $($UIAElement.Text -replace '(?s)^(.{60})(.*)', '$1...')"
                    } else {
                        Write-Debug "        Type: $($UIAElement.ControlType), no Text"
                    }
                }

                $AllChildWindows = @(Get-ChildWindows -Parent $window)
                foreach ($ChildWindow in $AllChildWindows) {
                    $WindowInfo = Get-WindowInfo -WindowHandle $ChildWindow -IncludeUIAInfo
                    if ($WindowInfo.IsVisible -and -not $WindowInfo.IsDisabled -and $WindowInfo.Width -gt 0 -and $WindowInfo.Height -gt 0) {
                        $InteractableWindowOpen = $true
                    }

                    # Print the debug output of the interactable window in capital letters to identify it easily
                    Write-Debug "      ChildWindow $($ChildWindow), IsVisible: $($WindowInfo.IsVisible), IsDisabled: $($WindowInfo.IsDisabled), Style: $($WindowInfo.Style), Size: $($WindowInfo.Width) x $($WindowInfo.Height), TitleCaption '$($WindowInfo.Title)'"
                    Write-Debug "        UIA Info: Got $($WindowInfo.UIAElements.Count) UIAElements from this window handle:"
                    foreach ($UIAElement in $WindowInfo.UIAElements) {
                        if ($UIAElement.Text) {
                            Write-Debug "          Type: $($UIAElement.ControlType), Text: $($UIAElement.Text -replace '(?s)^(.{60})(.*)', '$1...')"
                        } else {
                            Write-Debug "          Type: $($UIAElement.ControlType), no Text"
                        }
                    }
                }
            }
        }
    }

    Write-Debug "CONCLUSION: The process looks $( if ($InteractableWindowOpen -and $AllThreadsWaiting) { 'blocked' } else { 'normal' } )."
}
