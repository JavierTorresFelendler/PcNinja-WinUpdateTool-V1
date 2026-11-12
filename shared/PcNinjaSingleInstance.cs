// PcNinja shared single-instance guard.
//
// ONE SOURCE FILE shared by every PcNinja Windows tool (and the future unified
// tool). Keep this file byte-identical across repositories and keep it C# 5
// compatible: it is compiled by .NET 8 SDK projects, .NET Framework 4.8
// projects, the legacy csc.exe v4 compiler and PowerShell 5.1 Add-Type.
// No expression-bodied members, string interpolation, nameof, ?. or out var.
//
// Model
//   * One named, auto-reset event per app id and per Windows logon session:
//       Local\PcNinja.<AppId>.SingleInstance.v1
//     The first GUI process creates it and keeps the handle for its lifetime.
//     The kernel removes it when that process exits or crashes, so a stale
//     lock cannot survive.
//   * A later launch opens the same event, grants the running instance the
//     right to take the foreground (AllowSetForegroundWindow) and signals it.
//     The running instance restores and focuses its own window. Activating our
//     own window avoids UIPI limits between elevated and standard processes.
//   * The event DACL lets interactive users signal it and its integrity label
//     is Medium, so an unelevated launch can activate an elevated instance
//     before asking for UAC (no pointless UAC prompt).
//   * Fail open: if the guard itself fails, the app starts normally.
//
// Use only for GUI entry points. CLI/automation modes must not be blocked by
// an open window; protect shared operations with their own operation locks.

using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using System.Threading;
using Microsoft.Win32.SafeHandles;

namespace PcNinja.Shared
{
    public sealed class PcNinjaSingleInstance : IDisposable
    {
        /// <summary>Process environment marker: "AppId|ProcessId" of the holder.</summary>
        public const string HeldEnvironmentName = "PCNINJA_SINGLE_INSTANCE_HELD";

        private const int ErrorAlreadyExists = 183;
        private const int ErrorAccessDenied = 5;
        private const uint Synchronize = 0x00100000;
        private const uint EventModifyState = 0x0002;
        private const int AsfwAny = -1;

        private readonly string appId;
        private readonly WaitHandle activationEvent;
        private readonly ManualResetEvent stopEvent;
        private readonly Thread listener;
        private readonly bool owner;
        private int disposed;

        /// <summary>Optional callback raised on a background thread after activation.</summary>
        public Action ActivationRequested { get; set; }

        /// <summary>True when this process owns the instance (always true for a fail-open holder).</summary>
        public bool IsOwner { get { return owner; } }

        public string AppId { get { return appId; } }

        private PcNinjaSingleInstance(string appId, IntPtr handle)
        {
            this.appId = appId;
            owner = true;
            if (handle == IntPtr.Zero) return; // Fail-open or nested holder: nothing to listen to.

            activationEvent = new NativeWaitHandle(handle);
            stopEvent = new ManualResetEvent(false);
            listener = new Thread(Listen);
            listener.IsBackground = true;
            listener.Name = "PcNinja single-instance listener";
            listener.Start();
            Environment.SetEnvironmentVariable(HeldEnvironmentName, Marker(appId));
        }

        /// <summary>
        /// Name of the per-session event for an app id. Ids are fixed product
        /// identifiers such as "WinUpgradeTool"; changing one breaks detection
        /// between old and new builds, so never derive it from a version.
        /// </summary>
        public static string GetEventName(string appId)
        {
            if (appId == null || !Regex.IsMatch(appId, "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"))
                throw new ArgumentException("The single-instance app id is invalid.", "appId");
            return @"Local\PcNinja." + appId + ".SingleInstance.v1";
        }

        /// <summary>
        /// Lightweight probe for a launcher that is about to self-elevate.
        /// Returns true only when a running instance was found and signalled;
        /// the caller should then exit without requesting UAC.
        /// </summary>
        public static bool TryActivateExisting(string appId)
        {
            string name = GetEventName(appId);
            try
            {
                IntPtr handle = NativeMethods.OpenEvent(Synchronize | EventModifyState, false, name);
                if (handle == IntPtr.Zero) return false; // Not running (or not reachable): continue normally.
                try { return Signal(handle); }
                finally { NativeMethods.CloseHandle(handle); }
            }
            catch (Exception)
            {
                return false;
            }
        }

        /// <summary>
        /// Takes the single-instance ownership for this process. Returns null
        /// when another instance already runs; that instance has been asked to
        /// come to the front and the caller must exit. Dispose the returned
        /// holder only when the app closes.
        /// </summary>
        public static PcNinjaSingleInstance Acquire(string appId)
        {
            string name = GetEventName(appId);

            // The same process may enter twice (an EXE host that runs the
            // PowerShell UI in-process). Child processes inherit the variable,
            // so the marker also carries the holder's process id.
            if (string.Equals(Environment.GetEnvironmentVariable(HeldEnvironmentName), Marker(appId), StringComparison.Ordinal))
                return new PcNinjaSingleInstance(appId, IntPtr.Zero);

            try
            {
                int error;
                IntPtr handle = CreateEvent(name, out error);
                if (handle == IntPtr.Zero)
                {
                    if (error == ErrorAccessDenied)
                    {
                        // Exists but this account cannot open it fully: try to signal it.
                        TryActivateExisting(appId);
                        return null;
                    }

                    Trace.WriteLine("PcNinja single-instance guard unavailable: " + new Win32Exception(error).Message);
                    return new PcNinjaSingleInstance(appId, IntPtr.Zero);
                }

                if (error == ErrorAlreadyExists)
                {
                    try { Signal(handle); }
                    finally { NativeMethods.CloseHandle(handle); }
                    return null;
                }

                return new PcNinjaSingleInstance(appId, handle);
            }
            catch (Exception ex)
            {
                Trace.WriteLine("PcNinja single-instance guard failed open: " + ex.Message);
                return new PcNinjaSingleInstance(appId, IntPtr.Zero);
            }
        }

        public void Dispose()
        {
            if (Interlocked.Exchange(ref disposed, 1) != 0) return;
            if (stopEvent != null)
            {
                stopEvent.Set();
                if (listener != null && listener != Thread.CurrentThread) listener.Join(2000);
                stopEvent.Close();
            }

            if (activationEvent != null)
            {
                activationEvent.Close();
                if (string.Equals(Environment.GetEnvironmentVariable(HeldEnvironmentName), Marker(appId), StringComparison.Ordinal))
                    Environment.SetEnvironmentVariable(HeldEnvironmentName, null);
            }
        }

        /// <summary>Restores and focuses the main visible window of the current process.</summary>
        public static bool ActivateCurrentProcessWindow()
        {
            IntPtr main = FindMainWindow((uint)Process.GetCurrentProcess().Id);
            if (main == IntPtr.Zero) return false;

            if (NativeMethods.IsIconic(main)) NativeMethods.ShowWindow(main, 9); // SW_RESTORE
            else NativeMethods.ShowWindow(main, 5); // SW_SHOW

            // A modal dialog owned by the main window should receive focus.
            IntPtr target = NativeMethods.GetLastActivePopup(main);
            if (target == IntPtr.Zero || !NativeMethods.IsWindowVisible(target)) target = main;

            NativeMethods.BringWindowToTop(target);
            if (NativeMethods.SetForegroundWindow(target)) return true;

            // Windows refused the focus change: flash the taskbar button instead.
            NativeMethods.FLASHWINFO flash = new NativeMethods.FLASHWINFO();
            flash.cbSize = (uint)Marshal.SizeOf(typeof(NativeMethods.FLASHWINFO));
            flash.hwnd = target;
            flash.dwFlags = 3 | 12; // FLASHW_ALL | FLASHW_TIMERNOFG
            flash.uCount = 3;
            NativeMethods.FlashWindowEx(ref flash);
            return false;
        }

        private void Listen()
        {
            WaitHandle[] handles = new WaitHandle[] { stopEvent, activationEvent };
            while (true)
            {
                int index;
                try { index = WaitHandle.WaitAny(handles); }
                catch (Exception) { return; }
                if (index != 1) return;

                try
                {
                    ActivateCurrentProcessWindow();
                    Action callback = ActivationRequested;
                    if (callback != null) callback();
                }
                catch (Exception ex)
                {
                    Trace.WriteLine("PcNinja single-instance activation failed: " + ex.Message);
                }
            }
        }

        private static bool Signal(IntPtr handle)
        {
            // Must run while this process still owns the user's foreground
            // permission (the user just launched it).
            NativeMethods.AllowSetForegroundWindow(AsfwAny);
            return NativeMethods.SetEvent(handle);
        }

        private static IntPtr CreateEvent(string name, out int error)
        {
            IntPtr handle = IntPtr.Zero;
            IntPtr descriptor = IntPtr.Zero;
            try
            {
                // SYSTEM and Administrators: full; interactive users: wait + signal;
                // creator: full. Medium label so unelevated launches can signal.
                string userSid;
                using (System.Security.Principal.WindowsIdentity identity = System.Security.Principal.WindowsIdentity.GetCurrent())
                    userSid = identity.User.Value;
                string sddl = "D:(A;;GA;;;SY)(A;;GA;;;BA)(A;;0x00100002;;;IU)(A;;GA;;;" + userSid + ")S:(ML;;NW;;;ME)";
                uint size;
                if (NativeMethods.ConvertStringSecurityDescriptorToSecurityDescriptor(sddl, 1, out descriptor, out size))
                {
                    NativeMethods.SECURITY_ATTRIBUTES attributes = new NativeMethods.SECURITY_ATTRIBUTES();
                    attributes.nLength = Marshal.SizeOf(typeof(NativeMethods.SECURITY_ATTRIBUTES));
                    attributes.lpSecurityDescriptor = descriptor;
                    attributes.bInheritHandle = false;
                    handle = NativeMethods.CreateEventEx(ref attributes, name, 0, Synchronize | EventModifyState);
                    error = Marshal.GetLastWin32Error();
                    if (handle != IntPtr.Zero || error == ErrorAccessDenied) return handle;
                }
            }
            finally
            {
                if (descriptor != IntPtr.Zero) NativeMethods.LocalFree(descriptor);
            }

            // Security descriptor could not be applied: default object security.
            handle = NativeMethods.CreateEventExDefault(IntPtr.Zero, name, 0, Synchronize | EventModifyState);
            error = Marshal.GetLastWin32Error();
            return handle;
        }

        private static IntPtr FindMainWindow(uint processId)
        {
            IntPtr found = IntPtr.Zero;
            NativeMethods.EnumWindows(delegate (IntPtr window, IntPtr unused)
            {
                uint owner;
                NativeMethods.GetWindowThreadProcessId(window, out owner);
                if (owner != processId || !NativeMethods.IsWindowVisible(window)) return true;
                if (NativeMethods.GetWindow(window, 4) != IntPtr.Zero) return true; // GW_OWNER: skip owned dialogs.
                found = window; // EnumWindows walks the Z order; first match is the top one.
                return false;
            }, IntPtr.Zero);
            return found;
        }

        private static string Marker(string appId)
        {
            return appId + "|" + Process.GetCurrentProcess().Id.ToString(System.Globalization.CultureInfo.InvariantCulture);
        }

        private sealed class NativeWaitHandle : WaitHandle
        {
            public NativeWaitHandle(IntPtr handle)
            {
                SafeWaitHandle = new SafeWaitHandle(handle, true);
            }
        }

        private static class NativeMethods
        {
            internal delegate bool EnumWindowsProc(IntPtr window, IntPtr parameter);

            [StructLayout(LayoutKind.Sequential)]
            internal struct SECURITY_ATTRIBUTES
            {
                public int nLength;
                public IntPtr lpSecurityDescriptor;
                public bool bInheritHandle;
            }

            [StructLayout(LayoutKind.Sequential)]
            internal struct FLASHWINFO
            {
                public uint cbSize;
                public IntPtr hwnd;
                public uint dwFlags;
                public uint uCount;
                public uint dwTimeout;
            }

            [DllImport("kernel32.dll", EntryPoint = "CreateEventExW", SetLastError = true, CharSet = CharSet.Unicode)]
            internal static extern IntPtr CreateEventEx(ref SECURITY_ATTRIBUTES attributes, string name, uint flags, uint desiredAccess);

            [DllImport("kernel32.dll", EntryPoint = "CreateEventExW", SetLastError = true, CharSet = CharSet.Unicode)]
            internal static extern IntPtr CreateEventExDefault(IntPtr attributes, string name, uint flags, uint desiredAccess);

            [DllImport("kernel32.dll", EntryPoint = "OpenEventW", SetLastError = true, CharSet = CharSet.Unicode)]
            internal static extern IntPtr OpenEvent(uint desiredAccess, bool inheritHandle, string name);

            [DllImport("kernel32.dll", SetLastError = true)]
            internal static extern bool SetEvent(IntPtr handle);

            [DllImport("kernel32.dll", SetLastError = true)]
            internal static extern bool CloseHandle(IntPtr handle);

            [DllImport("kernel32.dll")]
            internal static extern IntPtr LocalFree(IntPtr memory);

            [DllImport("advapi32.dll", EntryPoint = "ConvertStringSecurityDescriptorToSecurityDescriptorW", SetLastError = true, CharSet = CharSet.Unicode)]
            internal static extern bool ConvertStringSecurityDescriptorToSecurityDescriptor(string sddl, uint revision, out IntPtr descriptor, out uint size);

            [DllImport("user32.dll")]
            internal static extern bool AllowSetForegroundWindow(int processId);

            [DllImport("user32.dll")]
            internal static extern bool EnumWindows(EnumWindowsProc callback, IntPtr parameter);

            [DllImport("user32.dll")]
            internal static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);

            [DllImport("user32.dll")]
            internal static extern bool IsWindowVisible(IntPtr window);

            [DllImport("user32.dll")]
            internal static extern bool IsIconic(IntPtr window);

            [DllImport("user32.dll")]
            internal static extern IntPtr GetWindow(IntPtr window, uint command);

            [DllImport("user32.dll")]
            internal static extern IntPtr GetLastActivePopup(IntPtr window);

            [DllImport("user32.dll")]
            internal static extern bool ShowWindow(IntPtr window, int command);

            [DllImport("user32.dll")]
            internal static extern bool BringWindowToTop(IntPtr window);

            [DllImport("user32.dll")]
            internal static extern bool SetForegroundWindow(IntPtr window);

            [DllImport("user32.dll")]
            internal static extern bool FlashWindowEx(ref FLASHWINFO info);
        }
    }
}
