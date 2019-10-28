function Test-Wflash2ForSCCMParameter {
    <#
        .DESCRIPTION
        This function tests for wflash2.exe versions that do not support the /sccm (suppress reboot) argument
        because when you supply wflash2.exe an unknown argument it displays some usage help and then waits for
        something to be written to its CONIN$ console input buffer. Redirecting the StdIn handle of wflash2.exe
        and writing to that does not suffice to break this deadlock - real console keyboard input has to be made,
        so this is the only solution I've found that can accomplish this even in a non-interactive session.

        .NOTES
        While this approach may look like a crazy hack, it's actually the only working way
        I've found to send STDIN to wflash2.exe so that it exits when printing the usage help.
        Redirecting STDIN through StartInfo.RedirectStandardInput does nothing, and the SendInput
        API is simpler but only works in interactive sessions.
    #>

    [CmdletBinding()]
    Param (
        [ValidateNotNullOrEmpty()]
        [ValidateScript({ [System.IO.File]::Exists($_) })]
        [string]$PathToWFLASH2EXE
    )

    Add-Type -TypeDefinition @'
    using System;
    using System.Runtime.InteropServices;

    public class WinAPI {
        private const uint FILE_SHARE_WRITE = 0x00000002;
        private const uint GENERIC_WRITE    = 0x40000000;
        private const uint OPEN_EXISTING    = 0x00000003;
        private const ushort KEY_EVENT      = 0x0001;

        [DllImport("kernel32.dll", CharSet = CharSet.Auto,
        CallingConvention = CallingConvention.StdCall,
        SetLastError = true)]
        private static extern IntPtr CreateFile(
            string lpFileName,
            uint dwDesiredAccess,
            uint dwShareMode,
            IntPtr SecurityAttributes,
            uint dwCreationDisposition,
            uint dwFlagsAndAttributes,
            IntPtr hTemplateFile
        );

        [StructLayout(LayoutKind.Explicit, CharSet = CharSet.Unicode)]
        private struct INPUT_RECORD
        {
            public const ushort KEY_EVENT = 0x0001;
            [FieldOffset(0)]
            public ushort EventType;

            [FieldOffset(2)]
            public KEY_EVENT_RECORD KeyEvent;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct KEY_EVENT_RECORD
        {
            public bool bKeyDown;
            public ushort wRepeatCount;
            public ushort wVirtualKeyCode;
            public ushort wVirtualScanCode;
            public char UnicodeChar;
            public uint dwControlKeyState;
        }

        [DllImport("kernel32.dll", EntryPoint = "WriteConsoleInputW", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool WriteConsoleInput(
            IntPtr hConsoleInput,
            INPUT_RECORD[] lpBuffer,
            uint nLength,
            out uint lpNumberOfEventsWritten
        );

        public struct ReturnValues {
            public bool WCIReturnValue;
            public uint WCIEventsWritten;
            public int LastWin32Error;
        }

        public static ReturnValues WriteCharToConin() {
            IntPtr hConIn = CreateFile(
                "CONIN$",
                GENERIC_WRITE,
                FILE_SHARE_WRITE,
                IntPtr.Zero,
                OPEN_EXISTING,
                0,
                IntPtr.Zero
            );

            INPUT_RECORD[] record                = new INPUT_RECORD[1];
            record[0]                            = new INPUT_RECORD();
            record[0].EventType                  = INPUT_RECORD.KEY_EVENT;
            record[0].KeyEvent                   = new KEY_EVENT_RECORD();
            record[0].KeyEvent.bKeyDown          = false;
            record[0].KeyEvent.wRepeatCount      = 1;
            record[0].KeyEvent.wVirtualKeyCode   = 0x4C; // "L"-key
            record[0].KeyEvent.wVirtualScanCode  = 0;
            record[0].KeyEvent.dwControlKeyState = 0;
            record[0].KeyEvent.UnicodeChar       = 'L';

            ReturnValues output     = new ReturnValues();
            output.WCIEventsWritten = 0;
            output.WCIReturnValue   = WriteConsoleInput(hConIn, record, 1, out output.WCIEventsWritten);
            output.LastWin32Error   = Marshal.GetLastWin32Error();

            return output;
        }
    }
'@

    [bool]$SupportsSCCMSwitch = $false

    $process                                  = [System.Diagnostics.Process]::new()
    $process.StartInfo.FileName               = "$PathToWFLASH2EXE"
    $process.StartInfo.UseShellExecute        = $false
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError  = $true
    $process.StartInfo.Arguments              = "/quiet /sccm"
    $process.StartInfo.WorkingDirectory       = "$env:USERPROFILE"
    $null = $process.Start()

    do {
        Start-Sleep -Seconds 1
        [WinAPI+ReturnValues]$APICALL = [WinAPI]::WriteCharToConin()
        if ($APICALL.WCIReturnValue   -ne $true -or
            $APICALL.WCIEventsWritten -ne 1 -or
            $APICALL.LastWin32Error   -ne 0) {
                Write-Warning "Could not test this ThinkCentre BIOS-Update for the /sccm (suppress reboot) parameter: A problem occured when calling the native API 'WriteConsoleInput'. Try running this script in a terminal that supports it, such as the default conhost or anything that builds atop of ConPTY."
                $process.Kill()
        }
    } until ($process.HasExited)

    [string]$STDOUT = $process.StandardOutput.ReadToEnd()

    if (-not [System.String]::IsNullOrEmpty($STDOUT)) {
        if (-not [regex]::Match($STDOUT, '^Usage',      'Multiline').Success -and
            -not [regex]::Match($STDOUT, '^Arguments:', 'Multiline').Success -and
            -not [regex]::Match($STDOUT, '^Examples:',  'Multiline').Success) {
                $SupportsSCCMSwitch = $true
        }
    }

    return $SupportsSCCMSwitch
}