using System;
using System.Runtime.InteropServices;

namespace LSUClient
{
    public class ImportTest {}

    public class JobAPI {
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        public static extern IntPtr CreateJobObject(IntPtr a, string lpName);

        [DllImport("Kernel32.dll", EntryPoint = "QueryInformationJobObject", SetLastError = true, CharSet = CharSet.Unicode)]
        public static extern bool QueryInformationJobObject(
            IntPtr hJob,
            int JobObjectInfoClass,
            IntPtr lpJobObjectInfo,
            int cbJobObjectLength,
            out uint lpReturnLength
        );

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern bool SetInformationJobObject(IntPtr hJob, JobObjectInfoType infoType, IntPtr lpJobObjectInfo, UInt32 cbJobObjectInfoLength);

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        public static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool CloseHandle(IntPtr hObject);

        public enum JobObjectInfoType
        {
            AssociateCompletionPortInformation = 7,
            BasicLimitInformation = 2,
            BasicUIRestrictions = 4,
            EndOfJobTimeInformation = 6,
            ExtendedLimitInformation = 9,
            SecurityLimitInformation = 5,
            GroupInformation = 11
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct JOBOBJECT_BASIC_PROCESS_ID_LIST
        {
            public uint NumberOfAssignedProcesses;
            public uint NumberOfProcessIdsInList;
            public IntPtr ProcessIdList;
        }
    }

    public class User32 {
        // callback
        public delegate bool EnumThreadDelegate(IntPtr hWnd, IntPtr lParam);

        [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto, CallingConvention = CallingConvention.StdCall)]
        public static extern bool EnumThreadWindows(int dwThreadId, EnumThreadDelegate lpfn, IntPtr lParam);

        [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto, CallingConvention = CallingConvention.StdCall)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool IsWindowVisible(IntPtr hWnd);

        [DllImport("user32.dll", SetLastError=true, CharSet = CharSet.Auto)]
        public static extern UInt32 GetWindowLong(IntPtr hWnd, int nIndex);

        [DllImport("user32.dll", SetLastError=true, CharSet = CharSet.Auto)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

        [StructLayout(LayoutKind.Sequential)]
        public struct RECT
        {
            public int Left;    // x position of upper-left corner
            public int Top;     // y position of upper-left corner
            public int Right;   // x position of lower-right corner
            public int Bottom;  // y position of lower-right corner
        }
    }

    public class WinAPI {
        private const uint FILE_SHARE_WRITE = 0x00000002;
        private const uint GENERIC_WRITE    = 0x40000000;
        private const uint OPEN_EXISTING    = 0x00000003;
        private const ushort KEY_EVENT      = 0x0001;

        [DllImport("kernel32.dll", CharSet = CharSet.Auto, CallingConvention = CallingConvention.StdCall, SetLastError = true)]
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
}
