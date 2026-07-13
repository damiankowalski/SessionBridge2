using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

namespace SessionBridge
{
    class Program
    {
        #region Win32 API Enums and Structs

        public enum WTS_CONNECTSTATE_CLASS
        {
            WTSActive,
            WTSConnected,
            WTSConnectQuery,
            WTSShadow,
            WTSDisconnected,
            WTSIdle,
            WTSListen,
            WTSReset,
            WTSDown,
            WTSInit
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct WTS_SESSION_INFO
        {
            public uint SessionId;
            [MarshalAs(UnmanagedType.LPStr)]
            public string pWinStationName;
            public WTS_CONNECTSTATE_CLASS State;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct STARTUPINFO
        {
            public int cb;
            public string lpReserved;
            public string lpDesktop;
            public string lpTitle;
            public uint dwX;
            public uint dwY;
            public uint dwXSize;
            public uint dwYSize;
            public uint dwXCountChars;
            public uint dwYCountChars;
            public uint dwFillAttribute;
            public uint dwFlags;
            public short wShowWindow;
            public short cbReserved2;
            public IntPtr lpReserved2;
            public IntPtr hStdInput;
            public IntPtr hStdOutput;
            public IntPtr hStdError;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct PROCESS_INFORMATION
        {
            public IntPtr hProcess;
            public IntPtr hThread;
            public uint dwProcessId;
            public uint dwThreadId;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct SECURITY_ATTRIBUTES
        {
            public int nLength;
            public IntPtr lpSecurityDescriptor;
            public bool bInheritHandle;
        }

        public enum SECURITY_IMPERSONATION_LEVEL
        {
            SecurityAnonymous,
            SecurityIdentification,
            SecurityImpersonation,
            SecurityDelegation
        }

        public enum TOKEN_TYPE
        {
            TokenPrimary = 1,
            TokenImpersonation
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct LUID
        {
            public uint LowPart;
            public int HighPart;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct LUID_AND_ATTRIBUTES
        {
            public LUID Luid;
            public uint Attributes;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct TOKEN_PRIVILEGES
        {
            public uint PrivilegeCount;
            [MarshalAs(UnmanagedType.ByValArray, SizeConst = 1)]
            public LUID_AND_ATTRIBUTES[] Privileges;
        }

        #endregion

        #region P/Invoke Declarations

        [DllImport("wtsapi32.dll", SetLastError = true)]
        static extern bool WTSEnumerateSessions(IntPtr hServer, int Reserved, int Version, out IntPtr ppSessionInfo, out int pCount);

        [DllImport("wtsapi32.dll")]
        static extern void WTSFreeMemory(IntPtr pMemory);

        [DllImport("wtsapi32.dll", SetLastError = true)]
        static extern bool WTSQueryUserToken(uint sessionId, out IntPtr Token);

        [DllImport("advapi32.dll", SetLastError = true)]
        static extern bool DuplicateTokenEx(IntPtr hExistingToken, uint dwDesiredAccess, ref SECURITY_ATTRIBUTES lpTokenAttributes, SECURITY_IMPERSONATION_LEVEL ImpersonationLevel, TOKEN_TYPE TokenType, out IntPtr phNewToken);

        [DllImport("userenv.dll", SetLastError = true)]
        static extern bool CreateEnvironmentBlock(out IntPtr lpEnvironment, IntPtr hToken, bool bInherit);

        [DllImport("userenv.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        static extern bool DestroyEnvironmentBlock(IntPtr lpEnvironment);

        [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern bool CreateProcessAsUser(IntPtr hToken, string lpApplicationName, StringBuilder lpCommandLine, ref SECURITY_ATTRIBUTES lpProcessAttributes, ref SECURITY_ATTRIBUTES lpThreadAttributes, bool bInheritHandles, uint dwCreationFlags, IntPtr lpEnvironment, string lpCurrentDirectory, ref STARTUPINFO lpStartupInfo, out PROCESS_INFORMATION lpProcessInformation);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool CloseHandle(IntPtr hSnapshot);

        [DllImport("advapi32.dll", SetLastError = true)]
        static extern bool AdjustTokenPrivileges(IntPtr TokenHandle, bool DisableAllPrivileges, ref TOKEN_PRIVILEGES NewState, uint BufferLength, IntPtr PreviousState, IntPtr ReturnLength);

        [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern bool LookupPrivilegeValue(string lpSystemName, string lpName, out LUID lpLuid);

        [DllImport("kernel32.dll")]
        static extern IntPtr GetCurrentProcess();

        [DllImport("advapi32.dll", SetLastError = true)]
        static extern bool OpenProcessToken(IntPtr ProcessHandle, uint DesiredAccess, out IntPtr TokenHandle);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern uint WaitForSingleObject(IntPtr hHandle, uint dwMilliseconds);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool GetExitCodeProcess(IntPtr hProcess, out uint lpExitCode);

        #endregion

        // Constants
        const uint MAXIMUM_ALLOWED = 0x2000000;
        const uint CREATE_UNICODE_ENVIRONMENT = 0x00000400;
        const uint TOKEN_ADJUST_PRIVILEGES = 0x0020;
        const uint TOKEN_QUERY = 0x0008;
        const uint SE_PRIVILEGE_ENABLED = 0x00000002;
        const uint INFINITE = 0xFFFFFFFF;

        const string LogFilePath = @"C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\SessionBridge.log";
        const string EventLogSource = "SessionBridge";
        const string EventLogName = "Application";

        /// <summary>
        /// Returns the command line exactly as it was passed to this process, minus
        /// SessionBridge.exe's own path/name - preserving the original quoting untouched.
        /// We deliberately do NOT rebuild this from args[] via string.Join, because .NET's
        /// argument parsing strips quotes when splitting into args[] - so any argument that
        /// contained a space (e.g. a script path like "...\App (4).ps1") becomes
        /// indistinguishable from two separate arguments once rejoined, silently corrupting
        /// the command line passed on to CreateProcessAsUser.
        /// </summary>
        static string GetRawArguments()
        {
            string full = Environment.CommandLine;
            int start;

            if (full.StartsWith("\""))
            {
                int endQuote = full.IndexOf('"', 1);
                start = (endQuote >= 0) ? endQuote + 1 : full.Length;
            }
            else
            {
                start = full.IndexOf(' ');
                if (start < 0) start = full.Length;
            }

            return full.Substring(start).TrimStart();
        }

        static void Main(string[] args)
        {
            int exitCode = 1; // default: treat "never actually launched anything" as failure
            try
            {
                exitCode = RunMain();
            }
            catch (Exception ex)
            {
                // Last-resort catch-all: if ANYTHING above throws unexpectedly (a bad
                // marshal, an access issue, etc.), log the full exception instead of the
                // process just vanishing with zero trace - which is impossible to debug.
                Log("FATAL UNHANDLED EXCEPTION: " + ex);
            }
            Environment.Exit(exitCode);
        }

        static int RunMain()
        {
            Log("SessionBridge started.");

            string uiPayloadCommand = GetRawArguments();

            if (string.IsNullOrWhiteSpace(uiPayloadCommand))
            {
                Log("No payload arguments supplied. Exiting.");
                return 1;
            }

            Log("Payload command: " + uiPayloadCommand);

            // Enable the two privileges CreateProcessAsUser needs.
            // These are usually present but DISABLED in the SYSTEM token, and
            // CreateProcessAsUser will fail with ERROR_PRIVILEGE_NOT_HELD (1314)
            // if they aren't explicitly turned on first.
            if (!EnablePrivilege("SeIncreaseQuotaPrivilege"))
                Log("WARNING: Failed to enable SeIncreaseQuotaPrivilege. Error: " + Marshal.GetLastWin32Error());

            if (!EnablePrivilege("SeAssignPrimaryTokenPrivilege"))
                Log("WARNING: Failed to enable SeAssignPrimaryTokenPrivilege. Error: " + Marshal.GetLastWin32Error());

            IntPtr ppSessionInfo = IntPtr.Zero;
            int count = 0;
            int lastExitCode = 1;
            bool launchedAny = false;

            if (WTSEnumerateSessions(IntPtr.Zero, 0, 1, out ppSessionInfo, out count))
            {
                int dataSize = Marshal.SizeOf(typeof(WTS_SESSION_INFO));
                long currentSessionInfo = ppSessionInfo.ToInt64();

                for (int i = 0; i < count; i++)
                {
                    WTS_SESSION_INFO sessionInfo = (WTS_SESSION_INFO)Marshal.PtrToStructure((IntPtr)currentSessionInfo, typeof(WTS_SESSION_INFO));
                    currentSessionInfo += dataSize;

                    if (sessionInfo.State == WTS_CONNECTSTATE_CLASS.WTSActive)
                    {
                        Log("Found active session: " + sessionInfo.SessionId);
                        int sessionExitCode;
                        if (LaunchProcessInSession(sessionInfo.SessionId, uiPayloadCommand, out sessionExitCode))
                        {
                            launchedAny = true;
                            // NOTE: on a normal single-user endpoint there's exactly one
                            // active session, so this is the exit code that matters. On a
                            // multi-session host (RDS etc.) this simply reports the LAST
                            // active session's result - fine for this tool's intended use
                            // (interactive endpoints), not designed for multi-user servers.
                            lastExitCode = sessionExitCode;
                        }
                    }
                }
                WTSFreeMemory(ppSessionInfo);

                if (!launchedAny)
                    Log("WARNING: No active session found or launch failed for all sessions. If run via Intune, this may mean no user is logged on, or the device is at the lock screen.");
            }
            else
            {
                Log("ERROR: WTSEnumerateSessions failed. Win32 error: " + Marshal.GetLastWin32Error());
            }

            Log("SessionBridge finished. Returning exit code: " + lastExitCode);
            return lastExitCode;
        }

        static bool LaunchProcessInSession(uint sessionId, string commandLine, out int exitCode)
        {
            exitCode = 1;
            IntPtr hToken = IntPtr.Zero;
            IntPtr hDuplicatedToken = IntPtr.Zero;
            IntPtr lpEnvironment = IntPtr.Zero;
            bool success = false;

            try
            {
                if (!WTSQueryUserToken(sessionId, out hToken))
                {
                    Log("ERROR: WTSQueryUserToken failed for session " + sessionId + ". Win32 error: " + Marshal.GetLastWin32Error());
                    return false;
                }

                SECURITY_ATTRIBUTES sa = new SECURITY_ATTRIBUTES();
                sa.nLength = Marshal.SizeOf(sa);

                if (!DuplicateTokenEx(hToken, MAXIMUM_ALLOWED, ref sa, SECURITY_IMPERSONATION_LEVEL.SecurityIdentification, TOKEN_TYPE.TokenPrimary, out hDuplicatedToken))
                {
                    Log("ERROR: DuplicateTokenEx failed for session " + sessionId + ". Win32 error: " + Marshal.GetLastWin32Error());
                    return false;
                }

                if (!CreateEnvironmentBlock(out lpEnvironment, hDuplicatedToken, false))
                {
                    Log("ERROR: CreateEnvironmentBlock failed for session " + sessionId + ". Win32 error: " + Marshal.GetLastWin32Error());
                    return false;
                }

                STARTUPINFO si = new STARTUPINFO();
                si.cb = Marshal.SizeOf(si);
                si.lpDesktop = @"winsta0\default";
                // Force-hide the window at the process-creation level itself, so it stays
                // hidden even if the payload's own hide switch (e.g. powershell.exe's
                // -WindowStyle Hidden) gets misparsed or omitted. STARTF_USESHOWWINDOW +
                // SW_HIDE.
                //
                // NOTE: if the payload itself needs to show a window (e.g. our
                // Show-ProcessCloseWarning.ps1 WPF dialog), the payload's own window will
                // still appear normally - this flag only affects the console host window
                // of the launched process itself, not windows that process explicitly
                // creates.
                si.dwFlags = 0x00000001;
                si.wShowWindow = 0;

                PROCESS_INFORMATION pi = new PROCESS_INFORMATION();
                StringBuilder cmdLineBuffer = new StringBuilder(commandLine);

                bool created = CreateProcessAsUser(
                    hDuplicatedToken,
                    null,
                    cmdLineBuffer,
                    ref sa,
                    ref sa,
                    false,
                    CREATE_UNICODE_ENVIRONMENT,
                    lpEnvironment,
                    // Explicitly set the working directory rather than passing null.
                    // null means "inherit the caller's own current directory" - which,
                    // when this exe is invoked by a service like Intune Management
                    // Extension, can be a SYSTEM-only path the duplicated (limited
                    // user) token has no access to, causing CreateProcessAsUser itself
                    // to fail with ERROR_ACCESS_DENIED (5) before the child even
                    // starts. C:\Windows\Temp is readable/traversable by all local
                    // users by default, so it's a safe, universal choice here.
                    Environment.GetEnvironmentVariable("windir") + @"\Temp",
                    ref si,
                    out pi);

                if (!created)
                {
                    int err = Marshal.GetLastWin32Error();
                    Log("ERROR: CreateProcessAsUser failed for session " + sessionId + ". Win32 error: " + err +
                        (err == 1314 ? " (ERROR_PRIVILEGE_NOT_HELD - check EnablePrivilege calls succeeded)" : ""));
                    return false;
                }

                Log("Launched process in session " + sessionId + ". PID: " + pi.dwProcessId + ". Waiting for it to exit...");

                // Block here until the bridged process exits. This is what makes
                // SessionBridge usable for "show a window, wait for the user's answer,
                // then continue" scenarios instead of pure fire-and-forget.
                WaitForSingleObject(pi.hProcess, INFINITE);

                uint rawExitCode;
                if (GetExitCodeProcess(pi.hProcess, out rawExitCode))
                {
                    exitCode = unchecked((int)rawExitCode);
                    Log("Process in session " + sessionId + " exited with code " + exitCode);
                }
                else
                {
                    Log("WARNING: Process in session " + sessionId + " exited but GetExitCodeProcess failed. Win32 error: " + Marshal.GetLastWin32Error());
                }

                success = true;

                if (pi.hProcess != IntPtr.Zero) CloseHandle(pi.hProcess);
                if (pi.hThread != IntPtr.Zero) CloseHandle(pi.hThread);
            }
            finally
            {
                if (lpEnvironment != IntPtr.Zero) DestroyEnvironmentBlock(lpEnvironment);
                if (hDuplicatedToken != IntPtr.Zero) CloseHandle(hDuplicatedToken);
                if (hToken != IntPtr.Zero) CloseHandle(hToken);
            }

            return success;
        }

        /// <summary>
        /// Enables a privilege (e.g. SeIncreaseQuotaPrivilege, SeAssignPrimaryTokenPrivilege)
        /// on the CURRENT process token. Must be called before duplicating the target
        /// user's token, since it's this process's (SYSTEM's) privileges that matter here.
        /// </summary>
        static bool EnablePrivilege(string privilegeName)
        {
            IntPtr hProcessToken = IntPtr.Zero;
            try
            {
                if (!OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, out hProcessToken))
                    return false;

                LUID luid;
                if (!LookupPrivilegeValue(null, privilegeName, out luid))
                    return false;

                TOKEN_PRIVILEGES tp = new TOKEN_PRIVILEGES();
                tp.PrivilegeCount = 1;
                tp.Privileges = new LUID_AND_ATTRIBUTES[1];
                tp.Privileges[0].Luid = luid;
                tp.Privileges[0].Attributes = SE_PRIVILEGE_ENABLED;

                bool result = AdjustTokenPrivileges(hProcessToken, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
                // AdjustTokenPrivileges can return true but still set ERROR_NOT_ALL_ASSIGNED (1300)
                // if the privilege isn't present in the token at all.
                return result && Marshal.GetLastWin32Error() == 0;
            }
            finally
            {
                if (hProcessToken != IntPtr.Zero) CloseHandle(hProcessToken);
            }
        }

        /// <summary>
        /// Logs to both a plain text file (always works, no setup needed) and the
        /// Windows Application Event Log (needs the source registered once, see below).
        /// Never throws - logging failures must not crash the actual task.
        /// </summary>
        static void Log(string message)
        {
            string line = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " - " + message;

            try
            {
                string dir = Path.GetDirectoryName(LogFilePath);
                if (!Directory.Exists(dir)) Directory.CreateDirectory(dir);
                File.AppendAllText(LogFilePath, line + Environment.NewLine);
            }
            catch
            {
                // Swallow - don't let a locked/inaccessible log file break the actual task.
            }

            try
            {
                if (!EventLog.SourceExists(EventLogSource))
                    EventLog.CreateEventSource(EventLogSource, EventLogName);

                EventLog.WriteEntry(EventLogSource, message,
                    message.StartsWith("ERROR") ? EventLogEntryType.Error :
                    message.StartsWith("WARNING") ? EventLogEntryType.Warning :
                    EventLogEntryType.Information);
            }
            catch
            {
                // Swallow - file log above is the guaranteed fallback.
            }
        }
    }
}
