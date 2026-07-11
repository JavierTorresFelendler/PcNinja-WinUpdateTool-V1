using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Management.Automation;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
using System.Windows.Forms;

[assembly: AssemblyTitle("PcNinja WinUpdate Tool")]
[assembly: AssemblyCompany("PcNinja")]
[assembly: AssemblyProduct("PcNinja WinUpdate Tool")]
[assembly: AssemblyCopyright("Copyright (c) PcNinja")]
[assembly: AssemblyVersion("1.1.3.0")]
[assembly: AssemblyFileVersion("1.1.3.0")]
[assembly: AssemblyInformationalVersion("V1.1.3-RC1")]

internal static class WinUpdateToolHost
{
    private const string AppUserModelId = "PcNinja.WinUpdateTool";

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern int SetCurrentProcessExplicitAppUserModelID(string appId);

    [STAThread]
    private static int Main(string[] args)
    {
        try
        {
            TrySetAppUserModelId();

            if (IsHelpRequest(args) || HasNonUiArguments(args))
            {
                ShowCliHelpMessage();
                return 0;
            }

            string appDir = AppDomain.CurrentDomain.BaseDirectory;
            string scriptPath = Path.Combine(appDir, "WinUpdateTool.ps1");

            if (!File.Exists(scriptPath))
            {
                throw new FileNotFoundException("WinUpdateTool.ps1 was not found beside the host executable.", scriptPath);
            }

            if (!IsAdministrator())
            {
                return RelaunchElevated(args);
            }

            Directory.SetCurrentDirectory(appDir);
            Environment.SetEnvironmentVariable("PSExecutionPolicyPreference", "Bypass", EnvironmentVariableTarget.Process);

            return RunPowerShellScript(scriptPath, args);
        }
        catch (Exception ex)
        {
            MessageBox.Show(
                "PcNinja WinUpdate Tool failed to start:\r\n\r\n" + ex.Message,
                "PcNinja WinUpdate Tool",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
            return 1;
        }
    }

    private static bool IsHelpRequest(string[] args)
    {
        foreach (string arg in args)
        {
            if (String.Equals(arg, "/?", StringComparison.OrdinalIgnoreCase) ||
                String.Equals(arg, "-?", StringComparison.OrdinalIgnoreCase) ||
                String.Equals(arg, "--help", StringComparison.OrdinalIgnoreCase) ||
                String.Equals(arg, "-help", StringComparison.OrdinalIgnoreCase) ||
                String.Equals(arg, "/help", StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }
        }

        return false;
    }

    private static bool HasNonUiArguments(string[] args)
    {
        if (args.Length == 0)
        {
            return false;
        }

        for (int index = 0; index < args.Length - 1; index++)
        {
            if (String.Equals(args[index], "-Mode", StringComparison.OrdinalIgnoreCase) ||
                String.Equals(args[index], "/Mode", StringComparison.OrdinalIgnoreCase))
            {
                return !String.Equals(args[index + 1], "UI", StringComparison.OrdinalIgnoreCase);
            }
        }

        return true;
    }

    private static void ShowCliHelpMessage()
    {
        MessageBox.Show(
            "Use PcNinja.WinUpdateTool.Cli.exe for command-line operations.\r\n\r\n" +
            "Examples:\r\n" +
            "PcNinja.WinUpdateTool.Cli.exe /?\r\n" +
            "PcNinja.WinUpdateTool.Cli.exe -Mode Status -Json\r\n" +
            "PcNinja.WinUpdateTool.Cli.exe -Mode DriverAudit -Json\r\n\r\n" +
            "The GUI entry point is PcNinja.WinUpdateTool.exe.",
            "PcNinja WinUpdate Tool CLI",
            MessageBoxButtons.OK,
            MessageBoxIcon.Information);
    }

    private static bool IsAdministrator()
    {
        WindowsIdentity identity = WindowsIdentity.GetCurrent();
        WindowsPrincipal principal = new WindowsPrincipal(identity);
        return principal.IsInRole(WindowsBuiltInRole.Administrator);
    }

    private static int RelaunchElevated(string[] args)
    {
        string exePath = Assembly.GetExecutingAssembly().Location;

        ProcessStartInfo startInfo = new ProcessStartInfo();
        startInfo.FileName = exePath;
        startInfo.Arguments = JoinArguments(args);
        startInfo.WorkingDirectory = AppDomain.CurrentDomain.BaseDirectory;
        startInfo.UseShellExecute = true;
        startInfo.Verb = "runas";

        try
        {
            Process.Start(startInfo);
            return 0;
        }
        catch (System.ComponentModel.Win32Exception ex)
        {
            if (ex.NativeErrorCode == 1223)
            {
                return 1223;
            }

            throw;
        }
    }

    private static int RunPowerShellScript(string scriptPath, string[] args)
    {
        Dictionary<string, object> parameters = ParsePowerShellParameters(args);

        if (!parameters.ContainsKey("Mode"))
        {
            parameters.Add("Mode", "UI");
        }

        using (PowerShell powerShell = PowerShell.Create())
        {
            powerShell.AddCommand(scriptPath);

            foreach (KeyValuePair<string, object> parameter in parameters)
            {
                powerShell.AddParameter(parameter.Key, parameter.Value);
            }

            powerShell.Invoke();

            if (powerShell.Streams.Error.Count > 0)
            {
                throw new RuntimeException(powerShell.Streams.Error[0].ToString());
            }
        }

        return 0;
    }

    private static Dictionary<string, object> ParsePowerShellParameters(string[] args)
    {
        Dictionary<string, object> parameters = new Dictionary<string, object>(StringComparer.OrdinalIgnoreCase);

        for (int index = 0; index < args.Length; index++)
        {
            string arg = args[index];

            if (String.IsNullOrWhiteSpace(arg) || (!arg.StartsWith("-", StringComparison.Ordinal) && !arg.StartsWith("/", StringComparison.Ordinal)))
            {
                continue;
            }

            string name = arg.TrimStart('-', '/');

            if (String.IsNullOrWhiteSpace(name))
            {
                continue;
            }

            object value = true;

            if ((index + 1) < args.Length)
            {
                string next = args[index + 1];
                if (!String.IsNullOrEmpty(next) && !next.StartsWith("-", StringComparison.Ordinal) && !next.StartsWith("/", StringComparison.Ordinal))
                {
                    value = next;
                    index++;
                }
            }

            parameters[name] = value;
        }

        return parameters;
    }

    private static string JoinArguments(string[] args)
    {
        if (args == null || args.Length == 0)
        {
            return String.Empty;
        }

        List<string> quoted = new List<string>();

        foreach (string arg in args)
        {
            quoted.Add(QuoteArgument(arg));
        }

        return String.Join(" ", quoted.ToArray());
    }

    private static string QuoteArgument(string arg)
    {
        if (arg == null)
        {
            return "\"\"";
        }

        if (arg.Length == 0)
        {
            return "\"\"";
        }

        if (arg.IndexOfAny(new[] { ' ', '\t', '"' }) < 0)
        {
            return arg;
        }

        StringBuilder builder = new StringBuilder();
        builder.Append('"');

        int backslashCount = 0;

        foreach (char character in arg)
        {
            if (character == '\\')
            {
                backslashCount++;
                continue;
            }

            if (character == '"')
            {
                builder.Append('\\', (backslashCount * 2) + 1);
                builder.Append('"');
                backslashCount = 0;
                continue;
            }

            builder.Append('\\', backslashCount);
            builder.Append(character);
            backslashCount = 0;
        }

        builder.Append('\\', backslashCount * 2);
        builder.Append('"');
        return builder.ToString();
    }

    private static void TrySetAppUserModelId()
    {
        try
        {
            SetCurrentProcessExplicitAppUserModelID(AppUserModelId);
        }
        catch
        {
            // Non-fatal. The EXE icon still provides the primary taskbar identity.
        }
    }
}









