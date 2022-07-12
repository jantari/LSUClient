function Invoke-PackageCommand {
    <#
        .SYNOPSIS
        Tries to run a command and returns an object containing an error
        code and optionally information about the process that was run.
    #>

    [CmdletBinding()]
    [OutputType('ExternalProcessResult')]
    Param (
        [ValidateNotNullOrEmpty()]
        [string]$Path,
        [ValidateNotNullOrEmpty()]
        [Parameter( Mandatory = $true )]
        [string]$Command,
        [switch]$FallbackToShellExecute
    )

    # Remove any trailing backslashes from the Path.
    # This isn't necessary, because Split-ExecutableAndArguments can handle and trims
    # extra backslashes, but this will make the path look more sane in errors and warnings.
    $Path = $Path.TrimEnd('\')

    # Lenovo sometimes forgets to put a directory separator betweeen %PACKAGEPATH% and the executable so make sure it's there
    # If we end up with two backslashes, Split-ExecutableAndArguments removes the duplicate from the executable path, but
    # we could still end up with a double-backslash after %PACKAGEPATH% somewhere in the arguments for now.
    [string]$ExpandedCommandString = Resolve-CmdVariable -String $Command -ExtraVariables @{'PACKAGEPATH' = "${Path}\"; 'WINDOWS' = $env:SystemRoot}
    $ExeAndArgs = Split-ExecutableAndArguments -Command $ExpandedCommandString -WorkingDirectory $Path
    # Split-ExecutableAndArguments returns NULL if no executable could be found
    if (-not $ExeAndArgs) {
        Write-Warning "The command or file '$Command' could not be found from '$Path' and was not run"
        return [ExternalProcessResult]::new(
            [ExternalProcessError]::FILE_NOT_FOUND,
            $null
        )
    }

    $ExeAndArgs.Arguments = Remove-CmdEscapeCharacter -String $ExeAndArgs.Arguments
    Write-Debug "Starting external process:`r`n  File: $($ExeAndArgs.Executable)`r`n  Arguments: $($ExeAndArgs.Arguments)`r`n  WorkingDirectory: $Path"

    $Runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateOutOfProcessRunspace($null)
    $Runspace.Open()

    $Powershell = [PowerShell]::Create().AddScript{
        [CmdletBinding()]
        Param (
            [ValidateNotNullOrEmpty()]
            [string]$WorkingDirectory,
            [ValidateNotNullOrEmpty()]
            [Parameter( Mandatory = $true )]
            [string]$Executable,
            [string]$Arguments,
            [switch]$FallbackToShellExecute
        )

        Set-StrictMode -Version 3.0

        # This value is used to communicate problems and errors that can be handled and or remedied/retried
        # internally to the calling function. It stays 0 when no known errors occurred.
        $HandledError = 0
        $ProcessStarted = $false
        [string[]]$StdOutLines = @()
        [string[]]$StdErrLines = @()

        $process                                  = [System.Diagnostics.Process]::new()
        $process.StartInfo.WindowStyle            = [System.Diagnostics.ProcessWindowStyle]::Hidden
        $process.StartInfo.UseShellExecute        = $false
        $process.StartInfo.WorkingDirectory       = $WorkingDirectory
        $process.StartInfo.FileName               = $Executable
        $process.StartInfo.Arguments              = $Arguments
        $process.StartInfo.RedirectStandardOutput = $true
        $process.StartInfo.RedirectStandardError  = $true

        if ($FallbackToShellExecute) {
            $process.StartInfo.UseShellExecute        = $true
            $process.StartInfo.RedirectStandardOutput = $false
            $process.StartInfo.RedirectStandardError  = $false
        }

        try {
            if (-not $process.Start()) {
                $HandledError = 1
            } else {
                $ProcessStarted = $true
            }
        }
        catch {
            # In case we get ERROR_ELEVATION_REQUIRED (740) retry with ShellExecute to elevate with UAC
            if ($null -ne $_.Exception.InnerException -and $_.Exception.InnerException.NativeErrorCode -eq 740) {
                $HandledError = 740
            # In case we get ERROR_BAD_EXE_FORMAT (193) retry with ShellExecute to open files like MSI
            } elseif ($null -ne $_.Exception.InnerException -and $_.Exception.InnerException.NativeErrorCode -eq 193) {
                $HandledError = 193
            # In case we get ERROR_ACCESS_DENIED (5, only observed on PowerShell 7 so far)
            } elseif ($null -ne $_.Exception.InnerException -and $_.Exception.InnerException.NativeErrorCode -eq 5) {
                $HandledError = 5
            } else {
                Write-Error $_
                $HandledError = 2 # Any other Process.Start exception
            }
        }

        if ($ProcessStarted) {
            $process.ID

            if (-not $FallbackToShellExecute) {
                # When redirecting StandardOutput or StandardError you have to start reading the streams asynchronously, or else it can cause
                # programs that output a lot (like package u3aud03w_w10 - Conexant USB Audio) to fill a stream and deadlock/hang indefinitely.
                # See issue #25 and https://stackoverflow.com/questions/11531068/powershell-capturing-standard-out-and-error-with-process-object
                $StdOutAsync = $process.StandardOutput.ReadToEndAsync()
                $StdErrAsync = $process.StandardError.ReadToEndAsync()
            }

            $process.WaitForExit()

            if (-not $FallbackToShellExecute) {
                $StdOutInOneString = $StdOutAsync.GetAwaiter().GetResult()
                $StdErrInOneString = $StdErrAsync.GetAwaiter().GetResult()

                [string[]]$StdOutLines = $StdOutInOneString.Split(
                    [string[]]("`r`n", "`r", "`n"),
                    [StringSplitOptions]::None
                )

                [string[]]$StdErrLines = $StdErrInOneString.Split(
                    [string[]]("`r`n", "`r", "`n"),
                    [StringSplitOptions]::None
                )
            }
        }

        return [PSCustomObject]@{
            'StandardOutput' = $StdOutLines
            'StandardError'  = $StdErrLines
            'ExitCode'       = $process.ExitCode
            'Runtime'        = $process.ExitTime - $process.StartTime
            'HandledError'   = $HandledError
        }
    }

    [void]$Powershell.AddParameters(@{
        'WorkingDirectory'       = $Path
        'Executable'             = $ExeAndArgs.Executable
        'Arguments'              = $ExeAndArgs.Arguments
        'FallbackToShellExecute' = $FallbackToShellExecute
    })

    $Powershell.Runspace = $Runspace
    $RunspaceStandardInput = [System.Management.Automation.PSDataCollection[PSObject]]::new()
    $RunspaceStandardInput.Complete()
    $RunspaceStandardOut = [System.Management.Automation.PSDataCollection[PSObject]]::new()
    [Datetime]$RunspaceStartTime = Get-Date
    $PSAsyncRunspace = $Powershell.BeginInvoke($RunspaceStandardInput, $RunspaceStandardOut)

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

        public delegate bool EnumThreadDelegate(IntPtr hWnd, IntPtr lParam);

        [DllImport("user32.dll", CharSet = CharSet.Auto, CallingConvention = CallingConvention.StdCall, SetLastError = true)]
        public static extern bool EnumThreadWindows(int dwThreadId, EnumThreadDelegate lpfn, IntPtr lParam);

        [DllImport("user32.dll", CharSet = CharSet.Auto, CallingConvention = CallingConvention.StdCall, SetLastError = true)]
        public static extern bool EnumWindows(EnumWindowsProc enumProc, IntPtr lParam);

        // callback to enumerate child windows
        public delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr lParam);

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

    # Very experimental code to try and detect hanging processes
    [int]$WM_GETTEXT = 0xD
    [int]$GWL_STYLE = -16
    [Uint32]$WS_DISABLED = 0x08000000
    [Uint32]$WS_VISIBLE  = 0x10000000
    while ($PSAsyncRunspace.IsCompleted -eq $false) {
        $ProcessRuntimeElapsed = (Get-Date) - $RunspaceStartTime
        # Only start looking into processes if they have been running for x time,
        # many are really short lived and don't need to be tested for 'hanging'
        if ($ProcessRuntimeElapsed.TotalMinutes -gt 1) { # Set to low time of 1 minute intentionally during testing
            if ($RunspaceStandardOut.Count -ge 1) {
                [bool]$InteractableWindowOpen = $false
                [bool]$AllThreadsWaiting      = $true

                $ProcessID = $RunspaceStandardOut[0]
                $process   = Get-Process -Id $ProcessID
                $TimeStamp = Get-Date -Format 'HH:mm:ss'

                Write-Debug "[$TimeStamp] Process $($process.ID) has been running for $ProcessRuntimeElapsed"
                #Write-Debug "Process has $($process.Threads.Count) threads"
                [array]$ChildProcesses = $process.ID
                [array]$ChildProcesses += Get-ChildProcesses -ParentProcessId $process.ID -Verbose:$false
                #Write-Debug "Process has $($ChildProcesses.Count - 1) child processes"

                foreach ($SpawnedProcessID in $ChildProcesses) {
                    $SpawnedProcess = Get-Process -Id $SpawnedProcessID
                    Write-Debug "Process $($SpawnedProcess.ID) ('$($SpawnedProcess.ProcessName)')"

                    #$ProcessWindows = [System.Collections.Generic.List[IntPtr]]::new()
                    #[User32]::EnumWindows({ Param($hwnd, $lParam) $ProcessWindows.Add($hwnd); return $true }, [IntPtr]::Zero)

                    #Write-Host "Process $SpawnedProcessID has $($ProcessWindows.Count) child windows"

                    #foreach ($ChildWindow in $ProcessWindows) {
                    #    $wi = Get-WindowInfo -WindowHandle $ChildWindow
                    #    if ($wi.Title) { Write-Host "    -> $($wi.Title)" }
                    #}

                    if ($SpawnedProcess.MainWindowHandle -ne [IntPtr]::Zero) {
                        $WindowInfo = Get-WindowInfo -WindowHandle $SpawnedProcess.MainWindowHandle -IncludeUIAInfo

                        Write-Debug "  has main window:"
                        if ($WindowInfo.IsVisible -and -not $WindowInfo.IsDisabled -and $WindowInfo.Width -gt 0 -and $WindowInfo.Height -gt 0) {
                            $InteractableWindowOpen = $true
                            Write-Debug "    MainWindow $($SpawnedProcess.MainWindowHandle), IsVisible: $($WindowInfo.IsVisible), IsDisabled: $($WindowInfo.IsDisabled), Style: $($WindowInfo.Style), Size: $($WindowInfo.Width) x $($WindowInfo.Height), TitleCaption '$($WindowInfo.Title)'".ToUpper()
                            Write-Debug "      UIA Info: Got $($WindowInfo.UIAElements.Count) UIAElements from this main window handle:"
                            foreach ($UIAElement in $WindowInfo.UIAElements) {
                                if ($UIAElement.Text) {
                                    Write-Debug "        Type: $($UIAElement.ControlType), Text: $($UIAElement.Text -replace '(?s)^(.{50})(.*)', '$1...')"
                                } else {
                                    Write-Debug "        Type: $($UIAElement.ControlType), no Text"
                                }
                            }
                        } else {
                            Write-Debug "    MainWindow $($SpawnedProcess.MainWindowHandle), IsVisible: $($WindowInfo.IsVisible), IsDisabled: $($WindowInfo.IsDisabled), Style: $($WindowInfo.Style), Size: $($WindowInfo.Width) x $($WindowInfo.Height), TitleCaption '$($WindowInfo.Title)'"
                        }

                        # I am pretty sure the MainWindow of a process is always also the window of
                        # a thread, idk where else it would come from - but maybe find definitive
                        # confirmation for that so this code can be removed
                        $ChildWindows = Get-ChildWindows -Parent $SpawnedProcess.MainWindowHandle
                        Write-Debug "    MainWindow has $($ChildWindows.Count) child windows"
                        foreach ($ChildWindow in $ChildWindows) {
                            $null = Get-WindowInfo -WindowHandle $ChildWindow
                        }
                    }

                    Write-Debug "  Getting UIA elements of process $($SpawnedProcess.Id):"
                    $root = [Windows.Automation.AutomationElement]::RootElement
                    $condition = New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::ProcessIdProperty, $SpawnedProcess.Id)
                    $setupUI = $root.FindFirst([Windows.Automation.TreeScope]::Children, $condition)
                    if ($setupUI) {
                        $UIAElements = $setupUI.FindAll([Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition).Current |
                            Select-Object @{n = 'ControlType'; e = { $_.ControlType.ProgrammaticName }}, ClassName, HasKeyboardFocus, IsKeyboardFocusable, IsContentElement, Name

                        foreach ($UIAElement in @($setupUI.Current) + @($UIAElements)) {
                            if ($UIAElement.Text) {
                                Write-Debug "    Type: $($UIAElement.ControlType), Text: $($UIAElement.Text -replace '(?s)^(.{50})(.*)', '$1...')"
                            } else {
                                Write-Debug "    Type: $($UIAElement.ControlType), no Text"
                            }
                        }
                    } else {
                        Write-Debug "  Process either has no windows or they're not accessible via UIAutomation (by ProcessId)"
                    }

                    if ($SpawnedProcess.Threads.ThreadState -ne 'Wait') {
                        $AllThreadsWaiting = $false
                    #} else {
                    #    Write-Debug "  All threads are waiting:"
                    #    '    ' + ($SpawnedProcess.Threads.WaitReason | Group-Object -NoElement | Sort-Object Count -Descending | % { "$($_.Count)x $($_.Name)" } ) -join ", " | Write-Debug
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
                                # Print the debug output of the interactable window in capital letters to identify it easily
                                Write-Debug "    ThreadWindow ${window}, IsVisible: $($WindowInfo.IsVisible), IsDisabled: $($WindowInfo.IsDisabled), Style: $($WindowInfo.Style), Size: $($WindowInfo.Width) x $($WindowInfo.Height), TitleCaption '$($WindowInfo.Title)'".ToUpper()
                                Write-Debug "      UIA Info: Got $($WindowInfo.UIAElements.Count) UIAElements from this window handle:"
                                foreach ($UIAElement in $WindowInfo.UIAElements) {
                                    if ($UIAElement.Text) {
                                        Write-Debug "        Type: $($UIAElement.ControlType), Text: $($UIAElement.Text -replace '(?s)^(.{50})(.*)', '$1...')"
                                    } else {
                                        Write-Debug "        Type: $($UIAElement.ControlType), no Text"
                                    }
                                }
                            } else {
                                Write-Debug "    ThreadWindow ${window}, IsVisible: $($WindowInfo.IsVisible), IsDisabled: $($WindowInfo.IsDisabled), Style: $($WindowInfo.Style), Size: $($WindowInfo.Width) x $($WindowInfo.Height), TitleCaption '$($WindowInfo.Title)'"
                            }

                            $AllChildWindows = @(Get-ChildWindows -Parent $window)
                            foreach ($ChildWindow in $AllChildWindows) {
                                $WindowInfo = Get-WindowInfo -WindowHandle $ChildWindow -IncludeUIAInfo
                                if ($WindowInfo.IsVisible -and -not $WindowInfo.IsDisabled -and $WindowInfo.Width -gt 0 -and $WindowInfo.Height -gt 0) {
                                    $InteractableWindowOpen = $true
                                    # Print the debug output of the interactable window in capital letters to identify it easily
                                    Write-Debug "      ChildWindow $($ChildWindow), IsVisible: $($WindowInfo.IsVisible), IsDisabled: $($WindowInfo.IsDisabled), Style: $($WindowInfo.Style), Size: $($WindowInfo.Width) x $($WindowInfo.Height), TitleCaption '$($WindowInfo.Title)'".ToUpper()
                                    Write-Debug "        UIA Info: Got $($WindowInfo.UIAElements.Count) UIAElements from this window handle:"
                                    foreach ($UIAElement in $WindowInfo.UIAElements) {
                                        if ($UIAElement.Text) {
                                            Write-Debug "          Type: $($UIAElement.ControlType), Text: $($UIAElement.Text -replace '(?s)^(.{50})(.*)', '$1...')"
                                        } else {
                                            Write-Debug "          Type: $($UIAElement.ControlType), no Text"
                                        }
                                    }
                                } else {
                                    Write-Debug "      ChildWindow $($ChildWindow), IsVisible: $($WindowInfo.IsVisible), IsDisabled: $($WindowInfo.IsDisabled), Style: $($WindowInfo.Style), Size: $($WindowInfo.Width) x $($WindowInfo.Height), TitleCaption '$($WindowInfo.Title)'"
                                }
                            }
                        }
                    }
                }
            }

            Write-Debug "CONCLUSION: The process looks $( if ($InteractableWindowOpen -and $AllThreadsWaiting) { 'blocked' } else { 'normal' } )."
            Write-Debug ""
            Start-Sleep -Seconds 30
        }

        Start-Sleep -Milliseconds 200
    }

    # Print any unhandled / unexpected errors as warnings
    if ($PowerShell.Streams.Error.Count -gt 0) {
        foreach ($ErrorRecord in $PowerShell.Streams.Error.ReadAll()) {
            Write-Warning $ErrorRecord
        }
    }

    $PowerShell.Runspace.Dispose()
    $PowerShell.Dispose()

    # Test for NULL before indexing into array. RunspaceStandardOut can be null
    # when the runspace aborted abormally, for example due to an exception.
    if ($null -ne $RunspaceStandardOut -and $RunspaceStandardOut.Count -gt 0) {
        switch ($RunspaceStandardOut[-1].HandledError) {
            # Success case
            0 {
                $NonEmptyPredicate = [Predicate[string]] { -not [string]::IsNullOrWhiteSpace($args[0]) }

                $StdOutFirstNonEmpty = [array]::FindIndex([string[]]$RunspaceStandardOut[-1].StandardOutput, $NonEmptyPredicate)
                if ($StdOutFirstNonEmpty -ne -1) {
                    $StdOutLastNonEmpty = [array]::FindLastIndex([string[]]$RunspaceStandardOut[-1].StandardOutput, $NonEmptyPredicate)
                    $StdOutTrimmed = $RunspaceStandardOut[-1].StandardOutput[$StdOutFirstNonEmpty..$StdOutLastNonEmpty]
                } else {
                    $StdOutTrimmed = @()
                }

                $StdErrFirstNonEmpty = [array]::FindIndex([string[]]$RunspaceStandardOut[-1].StandardError, $NonEmptyPredicate)
                if ($StdErrFirstNonEmpty -ne -1) {
                    $StdErrLastNonEmpty = [array]::FindLastIndex([string[]]$RunspaceStandardOut[-1].StandardError, $NonEmptyPredicate)
                    $StdErrTrimmed = $RunspaceStandardOut[-1].StandardError[$StdErrFirstNonEmpty..$StdErrLastNonEmpty]
                } else {
                    $StdErrTrimmed = @()
                }

                return [ExternalProcessResult]::new(
                    [ExternalProcessError]::NONE,
                    [ProcessReturnInformation]@{
                        'FilePath'         = $ExeAndArgs.Executable
                        'Arguments'        = $ExeAndArgs.Arguments
                        'WorkingDirectory' = $Path
                        'StandardOutput'   = $StdOutTrimmed
                        'StandardError'    = $StdErrTrimmed
                        'ExitCode'         = $RunspaceStandardOut[-1].ExitCode
                        'Runtime'          = $RunspaceStandardOut[-1].Runtime
                    }
                )
            }
            # Error cases that are handled explicitly inside the runspace
            1 {
                Write-Warning "No new process was created or a handle to it could not be obtained."
                Write-Warning "Executable was: '$($ExeAndArgs.Executable)' - this should *probably* not have happened"
                return [ExternalProcessResult]::new(
                    [ExternalProcessError]::PROCESS_NONE_CREATED,
                    $null
                )
            }
            2 {
                return [ExternalProcessResult]::new(
                    [ExternalProcessError]::UNKNOWN,
                    $null
                )
            }
            5 {
                return [ExternalProcessResult]::new(
                    [ExternalProcessError]::ACCESS_DENIED,
                    $null
                )
            }
            740 {
                if (-not $FallbackToShellExecute) {
                    Write-Warning "This process requires elevated privileges - falling back to ShellExecute, consider running PowerShell as Administrator"
                    Write-Warning "Process output cannot be captured when running with ShellExecute!"
                    return (Invoke-PackageCommand -Path:$Path -Command:$Command -FallbackToShellExecute)
                } else {
                    return [ExternalProcessResult]::new(
                        [ExternalProcessError]::PROCESS_REQUIRES_ELEVATION,
                        $null
                    )
                }
            }
            193 {
                if (-not $FallbackToShellExecute) {
                    Write-Warning "The file to be run is not an executable - falling back to ShellExecute"
                    return (Invoke-PackageCommand -Path:$Path -Command:$Command -FallbackToShellExecute)
                } else {
                    return [ExternalProcessResult]::new(
                        [ExternalProcessError]::FILE_NOT_EXECUTABLE,
                        $null
                    )
                }
            }
        }
    } else {
        Write-Warning "The external process runspace did not run to completion because an unexpected error occurred."
        return [ExternalProcessResult]::new(
            [ExternalProcessError]::RUNSPACE_DIED_UNEXPECTEDLY,
            $null
        )
    }

    Write-Warning "An unexpected error occurred when trying to run the extenral process."
    return [ExternalProcessResult]::new(
        [ExternalProcessError]::UNKNOWN,
        $null
    )
}
